defmodule ForgeWeb.ProjectSettingsLiveTest do
  @moduledoc """
  Issuing, seeing and revoking a project's git credentials.

  The property worth pinning is that the secret appears exactly once and is never recoverable:
  only its hash is stored, so a page that could show it again would be a page that stored it.
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.GitFixtures

  alias Forge.Git.Tokens
  alias Forge.{Projects, Tickets, Workers}

  setup :register_and_log_in_user

  setup do
    {:ok, project} =
      Projects.register(%{
        name: "settings-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo()
      })

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

  # The same field as the new-chat form, and the same rule: a dropdown of what is connected.
  test "the default model is a dropdown of what the workers offer", %{
    conn: conn,
    project: project
  } do
    {:ok, worker, _token} = Workers.create(%{provider: "fake"})

    {:ok, _worker} =
      Workers.ready(worker, 8_000, %{
        "models" => [%{"id" => "claude-sonnet-5", "name" => "Claude Sonnet 5"}]
      })

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")

    assert has_element?(view, ~s(select#project_model option[value="claude-sonnet-5"]))

    view
    |> form("#model-form", %{"project" => %{"model" => "claude-sonnet-5"}})
    |> render_submit()

    assert Projects.get!(project.id).model == "claude-sonnet-5"
  end

  # The worker holding it may be asleep rather than gone, and a form that silently dropped it
  # would change a setting nobody touched — docs/design/workflow-grammar-v1.md § Model.
  test "a model nothing currently offers stays selected rather than being dropped", %{
    conn: conn,
    project: project
  } do
    {:ok, project} = Projects.set_model(project, "a-model-no-worker-has")
    {:ok, worker, _token} = Workers.create(%{provider: "fake"})
    {:ok, _worker} = Workers.ready(worker, 8_000, %{"aliases" => ["opus"]})

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")

    assert has_element?(
             view,
             ~s(select#project_model option[value="a-model-no-worker-has"][selected])
           )
  end

  test "it requires a logged-in operator", %{project: project} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(build_conn(), ~p"/projects/#{project.name}/settings")
  end
end
