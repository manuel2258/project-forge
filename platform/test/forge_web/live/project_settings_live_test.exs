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
  alias Forge.{Projects, Repo, Tickets, Workers}

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

  @defaults %{"name" => "ci", "git" => "reader", "api" => "none", "days" => "7"}

  # The ticket select only exists once git is `branch`, and `form/3` checks its params against the
  # rendered DOM — so git changes on its own first, which is also the order an operator does it in.
  defp issue(view, %{"git" => "branch"} = params) do
    view |> form("#token-form", %{"token" => %{"git" => "branch"}}) |> render_change()
    view |> form("#token-form", %{"token" => Map.merge(@defaults, params)}) |> render_submit()
  end

  defp issue(view, params) do
    view |> form("#token-form", %{"token" => Map.merge(@defaults, params)}) |> render_submit()
  end

  test "issues a read token and shows it once, with the line that uses it", ctx do
    %{conn: conn, project: project} = ctx
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")

    html = issue(view, %{"name" => "dashboard", "api" => "read"})

    assert html =~ "Copy this now"
    # What the token may do, said beside it: the row below can only describe it from now on.
    assert has_element?(view, "#issued", "dashboard: Git: read · API: read")
    assert has_element?(view, "#issued", "not shown again")
    assert html =~ ~s(id="issued-secret")
    assert html =~ ~s(id="issued-curl")
    assert html =~ "Authorization: Bearer"
    assert html =~ "/api/v1/tickets"

    assert html =~ ~s(id="issued-url")
    assert html =~ ~s(data-target="issued-url")
    assert html =~ "phx-hook"
    assert [token] = Tokens.list(project)
    assert token.name == "dashboard"
    assert token.git_access == :reader
    assert token.api_access == :read

    # The secret is on screen and in nothing that is stored, and opens both doors.
    assert [_, secret] = Regex.run(~r|forge:([A-Za-z0-9_-]+)@|, html)
    assert {:ok, %{id: id}} = Tokens.authorise(secret, project, :read)
    assert {:ok, %{id: ^id}} = Tokens.authenticate_api(secret)
    assert id == token.id

    # Dismissing it is the last time it exists anywhere.
    refute view |> element("button", "Done") |> render_click() =~ secret
    refute render(view) =~ secret
  end

  test "an API-only token is shown without a clone URL, and the issuer is recorded", ctx do
    %{conn: conn, project: project, user: user} = ctx
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")

    html = issue(view, %{"git" => "none", "api" => "write"})

    refute html =~ ~s(id="issued-url")
    assert html =~ ~s(id="issued-curl")
    assert [token] = Tokens.list(project)
    assert token.issued_by_id == user.id
    assert html =~ "issued by #{user.email}"
  end

  test "nothing that writes is preselected", %{conn: conn, project: project} do
    {:ok, view, html} = live(conn, ~p"/projects/#{project.name}/settings")

    assert has_element?(
             view,
             ~s(#token-form select[name="token[git]"] option[selected][value=reader])
           )

    assert has_element?(
             view,
             ~s(#token-form select[name="token[api]"] option[selected][value=none])
           )

    assert html =~ ~s(value="7")
  end

  test "a branch token is scoped to one ticket's branch", ctx do
    %{conn: conn, project: project, user: user} = ctx
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")

    html = issue(view, %{"git" => "branch", "ticket" => to_string(ticket.number)})

    assert [token] = Tokens.list(project)
    assert token.git_access == :branch
    assert token.ref == "refs/heads/" <> ticket.branch
    assert token.ticket_id == ticket.id
    assert html =~ "refs/heads/#{ticket.branch}"
  end

  test "developer and admin tokens name no ref, and admin says what it reaches", ctx do
    %{conn: conn, project: project} = ctx
    {:ok, view, html} = live(conn, ~p"/projects/#{project.name}/settings")

    assert html =~ "push any open ticket&#39;s branch"
    assert html =~ "the default branch"

    issue(view, %{"name" => "dev", "git" => "developer"})
    issue(view, %{"name" => "adm", "git" => "admin"})

    tokens = Map.new(Tokens.list(project), &{&1.name, &1})
    assert %{git_access: :developer, ref: nil} = tokens["dev"]
    assert %{git_access: :admin, ref: nil} = tokens["adm"]
  end

  test "a job's token cannot be asked for from the page", ctx do
    %{conn: conn, project: project} = ctx
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")
    issue(view, %{"name" => "plain"})

    assert [token] = Tokens.list(project)
    assert is_nil(token.job_id)
    assert is_nil(token.ref)
  end

  test "a branch token with no ticket chosen is refused, not issued", ctx do
    %{conn: conn, project: project} = ctx
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")

    html = issue(view, %{"git" => "branch", "ticket" => ""})

    assert html =~ "Choose the ticket"
    assert Tokens.list(project) == []
  end

  test "a refusal keeps what was typed and says what to change", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")

    html = issue(view, %{"name" => "keep me", "days" => "366"})
    assert html =~ "from 1 to 365"
    assert html =~ ~s(value="keep me")

    assert issue(view, %{"name" => "x", "days" => "0"}) =~ "from 1 to 365"
    assert issue(view, %{"name" => "x", "days" => "soon"}) =~ "from 1 to 365"
    assert issue(view, %{"name" => "  "}) =~ "Give the token a name"
    assert issue(view, %{"name" => "x", "git" => "none", "api" => "none"}) =~ "allows nothing"
    assert Tokens.list(project) == []
  end

  test "a name over sixty characters is refused, and one with markup is drawn as text", ctx do
    %{conn: conn, project: project} = ctx
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")

    # The input's own `maxlength` is the browser's; the server says it too.
    long = String.duplicate("n", 61)

    html =
      render_submit(view, "issue", %{
        "token" => Map.put(@defaults, "name", long) |> Map.put("nonce", nonce(view))
      })

    assert html =~ "A name is at most 60 characters."
    assert Tokens.list(project) == []

    html = issue(view, %{"name" => "<script>alert(1)</script>"})
    refute html =~ "<script>alert(1)"
    assert html =~ "&lt;script&gt;"
  end

  defp nonce(view) do
    [_, nonce] = Regex.run(~r/name="token\[nonce\]" value="([^"]+)"/, render(view))
    nonce
  end

  test "a second submit of the same form makes no second token", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")
    params = Map.put(@defaults, "nonce", nonce(view))

    render_submit(view, "issue", %{"token" => params})
    render_submit(view, "issue", %{"token" => params})

    assert [_one] = Tokens.list(project)
  end

  test "with no tokens the section says what one is for", %{conn: conn, project: project} do
    {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}/settings")

    assert html =~ "lets an outside program"
    refute html =~ "None yet. One issued above"
  end

  test "a row says what the token may do, who issued it and when it was used", ctx do
    %{conn: conn, project: project, user: user} = ctx
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")
    issue(view, %{"name" => "nightly", "api" => "read"})
    [token] = Tokens.list(project)

    Repo.update!(
      Ecto.Changeset.change(token, last_used_at: DateTime.utc_now(:second), last_used_via: :api)
    )

    {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}/settings")
    assert html =~ "nightly"
    assert html =~ "Git: read · API: read"
    assert html =~ "issued by #{user.email}"
    assert html =~ "via api"
  end

  test "a token whose issuer has gone says so, and keeps working", ctx do
    %{conn: conn, project: project, user: user} = ctx

    {:ok, secret, token} =
      Tokens.issue(project, name: "orphan", git: :reader, api: :read, issued_by_id: user.id)

    Repo.update!(Ecto.Changeset.change(token, issued_by_id: nil))
    {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}/settings")

    refute html =~ "removed account"
    refute html =~ "issued by"
    assert {:ok, _} = Tokens.authenticate_api(secret)
  end

  test "a hand-sent value outside the choices is refused, not a crash", ctx do
    %{conn: conn, project: project} = ctx
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")
    nonce = nonce(view)

    for {field, value} <- [{"git", "root"}, {"api", "admin"}, {"days", "7abc"}] do
      params = @defaults |> Map.put(field, value) |> Map.put("nonce", nonce)

      assert render_submit(view, "issue", %{"token" => params}) =~ "Choose the" or
               render(view) =~ "Days must be"
    end

    assert Tokens.list(project) == []
  end

  test "a branch token for a ticket that is not this project's is refused", ctx do
    %{conn: conn, project: project, user: user} = ctx
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")

    params = @defaults |> Map.merge(%{"git" => "branch", "ticket" => "#{ticket.number + 1}"})
    html = render_submit(view, "issue", %{"token" => Map.put(params, "nonce", nonce(view))})

    assert html =~ "Choose the ticket"
    assert Tokens.list(project) == []
  end

  test "a long name opens whole on a tap, and a short one is plain", ctx do
    %{conn: conn, project: project} = ctx
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")
    long = String.duplicate("long-name-", 5)
    issue(view, %{"name" => long})
    issue(view, %{"name" => "short"})

    html = render(view)
    assert html =~ ~r/<details[^>]*>\s*<summary[^>]*>\s*#{long}/
    refute html =~ ~r/<summary[^>]*>\s*short/
    assert html =~ "short"

    # Whole inside the opened part, and drawn there once: a name over the bound is not also plain.
    assert html =~ ~r/<p class="break-words">\s*#{long}\s*<\/p>/
    assert length(String.split(html, long)) - 1 == 2
  end

  test "the heading counts the live tokens, not the revoked ones", %{
    conn: conn,
    project: project
  } do
    {:ok, _secret, _kept} = Tokens.issue(project, name: "kept", git: :reader, api: :read)
    {:ok, _secret, gone} = Tokens.issue(project, name: "gone", git: :reader, api: :read)
    {:ok, _} = Tokens.revoke(gone.id)

    {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}/settings")

    assert html =~ "Tokens · 1 live"
  end

  test "four hundred tokens leave the page readable", %{conn: conn, project: project} do
    for i <- 1..400,
        do: {:ok, _, _} = Tokens.issue(project, name: "token #{i}", git: :reader, api: :read)

    {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}/settings")
    assert html =~ "Tokens · 400 live"
  end

  test "a live token can be revoked, and then is not live", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")
    issue(view, %{})
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
