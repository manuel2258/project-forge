defmodule ForgeWeb.ProjectSettingsLiveTest do
  @moduledoc """
  Issuing, seeing and revoking a project's git credentials.

  The property worth pinning is that the secret appears exactly once and is never recoverable:
  only its hash is stored, so a page that could show it again would be a page that stored it.
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.ForgeFixtures, only: [credential_fixture: 2, pool!: 2, project_fixture: 0]
  import Forge.GitFixtures

  alias Forge.Git.Tokens
  alias Forge.{Projects, Tickets, Workers}

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, project} =
      Projects.register(
        %{
          name: "settings-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo()
        },
        user
      )

    %{project: project}
  end

  # The ticket select only exists once the scope is `write`, and `form/3` checks its params
  # against the rendered DOM — so the scope changes on its own first, which is also the order an
  # operator does it in.
  defp issue(view, %{"scope" => "write"} = params) do
    view |> form("#token-form", %{"token" => %{"scope" => "write"}}) |> render_change()
    view |> form("#token-form", %{"token" => params}) |> render_submit()
  end

  defp issue(view, params) do
    view |> form("#token-form", %{"token" => params}) |> render_submit()
  end

  test "issues a read token and shows it once", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")

    html = issue(view, %{"scope" => "read", "minutes" => "90"})

    assert html =~ "Copy this now"
    # What the token may do, said beside it: the row below can only describe it from now on.
    assert has_element?(view, "#issued", "It read, until")

    # The URL, with a button that copies it. The value stays visible: the clipboard API needs a
    # secure context and a LAN address over plain http is not one.
    assert html =~ ~s(id="issued-url")
    assert html =~ ~s(data-target="issued-url")
    assert html =~ "phx-hook"
    assert [token] = Tokens.list(project)
    refute token.write

    # The secret is in the clone URL on screen, and in nothing that is stored.
    assert [_, secret] = Regex.run(~r|forge:([A-Za-z0-9_-]+)@|, html)
    assert {:ok, ^token} = Tokens.authorise(secret, project, :read)

    # Dismissing it is the last time it exists anywhere.
    refute view |> element("button", "Done") |> render_click() =~ secret
    refute render(view) =~ secret
  end

  test "a write token is scoped to one ticket's branch", %{
    conn: conn,
    project: project,
    user: user
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")

    html =
      issue(view, %{"scope" => "write", "ticket" => to_string(ticket.number), "minutes" => "30"})

    assert [token] = Tokens.list(project)
    assert token.write
    assert token.ref == "refs/heads/" <> ticket.branch
    assert token.ticket_id == ticket.id
    assert html =~ "refs/heads/#{ticket.branch}"
  end

  test "a default-branch token is offered, named after the branch, and scoped to it", %{
    conn: conn,
    project: project
  } do
    {:ok, view, html} = live(conn, ~p"/projects/#{project.name}/settings")

    # Named after the branch rather than "the default branch", because which branch it is is the
    # thing the operator is choosing — `docs/design/ui.md` § Project settings.
    assert html =~ "write main, the default branch"

    html = issue(view, %{"scope" => "default", "minutes" => "30"})

    assert [token] = Tokens.list(project)
    assert token.write
    assert token.ref == "refs/heads/main"
    assert is_nil(token.ticket_id)
    assert is_nil(token.job_id)
    assert html =~ "refs/heads/main"
  end

  # The page may mint three shapes and only three. A job's is the engine's, and the ref a job
  # would be given is the one this page can never ask for.
  test "the page mints nothing wider than the branch chosen", %{
    conn: conn,
    project: project,
    user: user
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")

    issue(view, %{"scope" => "default", "minutes" => "30"})
    issue(view, %{"scope" => "write", "ticket" => to_string(ticket.number), "minutes" => "30"})
    issue(view, %{"scope" => "read", "minutes" => "30"})

    refs = project |> Tokens.list() |> Enum.map(& &1.ref) |> Enum.sort()
    assert refs == [nil, "refs/heads/main", "refs/heads/" <> ticket.branch]
    assert Enum.all?(Tokens.list(project), &is_nil(&1.job_id))
  end

  test "a write token with no ticket chosen is refused, not issued", %{
    conn: conn,
    project: project
  } do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")

    html = issue(view, %{"scope" => "write", "ticket" => "", "minutes" => "30"})

    assert html =~ "choose the ticket"
    assert Tokens.list(project) == []
  end

  test "minutes must be a number of minutes", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")

    assert issue(view, %{"scope" => "read", "minutes" => "soon"}) =~ "whole number of minutes"
    assert Tokens.list(project) == []
  end

  test "a live token can be revoked, and then is not live", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")
    issue(view, %{"scope" => "read", "minutes" => "90"})
    [token] = Tokens.list(project)

    html = view |> element(~s(button[phx-value-id="#{token.id}"])) |> render_click()

    assert [revoked] = Tokens.list(project)
    refute is_nil(revoked.revoked_at)
    refute Tokens.live?(revoked, DateTime.utc_now())

    # The row stays — it is the audit trail — but only behind the disclosure.
    refute html =~ "Revoke"
    assert view |> element("button", "Show expired and revoked") |> render_click() =~ "revoked"
  end

  test "a token a job holds is listed and not revocable by hand", %{
    conn: conn,
    project: project,
    user: user
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    [job] = Forge.Jobs.for_ticket(ticket.id)
    {:ok, _secret, token} = Tokens.issue_for_job(job, ticket, project)

    {:ok, view, html} = live(conn, ~p"/projects/#{project.name}/settings")

    assert html =~ "held by a job"
    refute has_element?(view, ~s(button[phx-value-id="#{token.id}"]))

    # And the context refuses it even if the button is bypassed: revoking mid-run fails the job
    # for a reason nothing records.
    assert {:error, :held_by_job} = Tokens.revoke(token.id)
  end

  # The same field as the new-chat form, and the same rule: the models are this project's pool's —
  # the accounts its jobs will actually run on — and not some other project's
  # (`docs/design/credentials.md` § Checked on save).
  test "the default model is a dropdown of what this project's credentials may use", %{
    conn: conn,
    project: project
  } do
    owner = Forge.AccountsFixtures.user_fixture()
    models = [%{"id" => "claude-sonnet-5", "name" => "Claude Sonnet 5"}]
    pool!(project, credential_fixture(owner, models: models))

    elsewhere = project_fixture()
    pool!(elsewhere, credential_fixture(owner, models: [%{"id" => "not-this-projects"}]))

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")

    assert has_element?(view, ~s(select#project_model option[value="claude-sonnet-5"]))
    refute has_element?(view, ~s(select#project_model option[value="not-this-projects"]))

    view
    |> form("#model-form", %{"project" => %{"model" => "claude-sonnet-5"}})
    |> render_submit()

    assert Projects.get!(project.id).model == "claude-sonnet-5"
  end

  defp connected_worker(offer) do
    {:ok, worker, _token} = Workers.create(%{provider: "fake"})
    {:ok, worker} = Workers.ready(worker, %{"memory_budget" => 8_000, "harness" => offer})
    worker
  end

  # A box because no worker is connected to offer a level, so a project can be configured before a
  # machine exists. `docs/design/workflow-grammar-v1.md` § Effort says why nothing here checks it.
  test "the default effort is a box that saves what is typed while nothing is offered", %{
    conn: conn,
    project: project
  } do
    {:ok, view, html} = live(conn, ~p"/projects/#{project.name}/settings")

    refute has_element?(view, ~s(select#project_effort))
    assert html =~ "No connected worker offers a level"

    view
    |> form("#effort-form", %{"project" => %{"effort" => "xhigh"}})
    |> render_submit()

    assert Projects.get!(project.id).effort == "xhigh"
  end

  test "the default effort is a dropdown of the levels the workers offer", %{
    conn: conn,
    project: project
  } do
    connected_worker(%{"efforts" => ~w(low high)})
    {:ok, project} = Projects.set_effort(project, "low")

    {:ok, view, html} = live(conn, ~p"/projects/#{project.name}/settings")

    refute has_element?(view, ~s(input#project_effort))
    assert html =~ "Offered by the workers connected now"

    assert has_element?(
             view,
             ~s(select#project_effort option[value=""]),
             "— the machine's —"
           )

    assert has_element?(view, ~s(select#project_effort option[value="low"][selected]))
    assert has_element?(view, ~s(select#project_effort option[value="high"]))

    view |> form("#effort-form", %{"project" => %{"effort" => "high"}}) |> render_submit()
    assert Projects.get!(project.id).effort == "high"

    view |> form("#effort-form", %{"project" => %{"effort" => ""}}) |> render_submit()
    assert is_nil(Projects.get!(project.id).effort)
  end

  # Decided on the levels reported, not on what the select would hold: a stored level counts as an
  # option to keep, and a select of one stored value cannot be typed over.
  test "a stored level with no one offering levels is still a box", %{
    conn: conn,
    project: project
  } do
    {:ok, project} = Projects.set_effort(project, "turbo")

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")
    assert has_element?(view, ~s(input#project_effort[type=text][value=turbo]))
    refute has_element?(view, ~s(select#project_effort))

    # Likewise a worker that reports aliases and no levels.
    connected_worker(%{"aliases" => ["opus"]})
    {:ok, view, html} = live(conn, ~p"/projects/#{project.name}/settings")
    assert has_element?(view, ~s(input#project_effort[type=text][value=turbo]))
    refute has_element?(view, ~s(select#project_effort))
    assert html =~ "No connected worker offers a level"
  end

  # The worker with the level may be asleep, or a later harness may have dropped it. A form that
  # dropped it would change a setting nobody touched, so saving unchanged must keep it.
  test "a stored level nothing offers stays selected, marked Set, and survives an unchanged save",
       %{
         conn: conn,
         project: project
       } do
    connected_worker(%{"efforts" => ~w(low high)})
    {:ok, project} = Projects.set_effort(project, "turbo")

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")

    assert has_element?(
             view,
             ~s(select#project_effort optgroup[label="Set"] option[value=turbo][selected])
           )

    view |> form("#effort-form") |> render_submit()

    assert Projects.get!(project.id).effort == "turbo"
  end

  test "an offered level is not also drawn as Set", %{conn: conn, project: project} do
    connected_worker(%{"efforts" => ~w(low high)})
    {:ok, project} = Projects.set_effort(project, "high")

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")

    assert has_element?(view, ~s(select#project_effort option[value=high][selected]))
    refute has_element?(view, ~s(select#project_effort optgroup[label="Set"]))
  end

  # The select is the browser's protection and not the platform's: a harness newer than the
  # workers may take a level they never reported.
  test "a level nobody offers is still stored", %{conn: conn, project: project} do
    connected_worker(%{"efforts" => ~w(low high)})

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")
    assert has_element?(view, ~s(select#project_effort))

    render_submit(view, "effort", %{"project" => %{"effort" => "ultra"}})

    assert Projects.get!(project.id).effort == "ultra"
  end

  # Escaped because HEEx escapes: adding `raw` to the option label is what the `refute` guards
  # against. The option assertion also fails if a reported level stops reaching the select.
  test "a level with markup in it is shown as text", %{conn: conn, project: project} do
    connected_worker(%{"efforts" => ["<b>x</b>"]})

    {:ok, view, html} = live(conn, ~p"/projects/#{project.name}/settings")

    assert has_element?(view, ~s(select#project_effort option), "<b>x</b>")
    refute has_element?(view, ~s(select#project_effort b))
    assert html =~ "&lt;b&gt;x&lt;/b&gt;"
  end

  # Saving one dial must not disturb the other: the two forms post separate params, and a
  # changeset that cast both from one would clear whichever was not on the page.
  test "saving the effort leaves the model alone, and the other way round", %{
    conn: conn,
    project: project
  } do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")

    # Free text, because no worker is connected to offer anything.
    view
    |> form("#model-form", %{"project" => %{"model" => "a-model-no-worker-has"}})
    |> render_submit()

    view
    |> form("#effort-form", %{"project" => %{"effort" => "max"}})
    |> render_submit()

    assert %{model: "a-model-no-worker-has", effort: "max"} = Projects.get!(project.id)

    # And back the other way: the model form posts no `effort`, so a changeset casting both from
    # one set of params would clear it here.
    view
    |> form("#model-form", %{"project" => %{"model" => "a-model-no-worker-has"}})
    |> render_submit()

    assert %{model: "a-model-no-worker-has", effort: "max"} = Projects.get!(project.id)
  end

  # The worker holding it may be asleep rather than gone, and a form that silently dropped it
  # would change a setting nobody touched — docs/design/workflow-grammar-v1.md § Model.
  test "a model nothing currently offers stays selected rather than being dropped", %{
    conn: conn,
    project: project
  } do
    {:ok, project} = Projects.set_model(project, "a-model-no-worker-has")
    {:ok, worker, _token} = Workers.create(%{provider: "fake"})

    {:ok, _worker} =
      Workers.ready(worker, %{"memory_budget" => 8_000, "harness" => %{"aliases" => ["opus"]}})

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")

    assert has_element?(
             view,
             ~s(select#project_model option[value="a-model-no-worker-has"][selected])
           )
  end

  # The model field shares `kept/2` with the effort field. A stored alias or model id that is
  # offered is in its own group and must not be drawn a second time under "Set".
  test "an offered alias or model id is not also drawn as Set", %{conn: conn, project: project} do
    owner = Forge.AccountsFixtures.user_fixture()
    pool!(project, credential_fixture(owner, models: [%{"id" => "claude-sonnet-5"}]))
    connected_worker(%{"aliases" => ["opus"]})

    for stored <- ["opus", "claude-sonnet-5"] do
      {:ok, project} = Projects.set_model(project, stored)
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")

      assert has_element?(view, ~s(select#project_model option[value="#{stored}"][selected]))
      refute has_element?(view, ~s(select#project_model optgroup[label="Set"]))
    end
  end

  test "it requires a logged-in operator", %{project: project} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(build_conn(), ~p"/projects/#{project.name}/settings")
  end
end
