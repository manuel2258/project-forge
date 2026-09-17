defmodule ForgeWeb.ReviewLiveTest do
  @moduledoc """
  The merge decision page: the diff beside what the platform knows about the change, and the
  approval that pins an exact commit.
  """

  use ForgeWeb.ConnCase, async: false

  import Forge.GitFixtures
  import Phoenix.LiveViewTest

  alias Forge.{Artifacts, Git, Projects, Tickets}

  setup :register_and_log_in_user

  setup %{scope: scope, user: user} do
    data_dir = tmp_dir("review-data")
    config = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(config, :data_dir, data_dir))
    on_exit(fn -> Application.put_env(:forge, Forge.Jobs, config) end)

    bare = seeded_repo()
    name = "review#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.register(%{name: name, repo_path: bare, default_branch: "main"}, user)

    {:ok, ticket} =
      Tickets.admit(project, %{title: "Persist scores", body: "do it"}, {:user, scope.user.id})

    %{project: project, bare: bare, ticket: ticket}
  end

  test "draws the diff, the documents, the answers and the usage", context do
    %{conn: conn, project: project, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)

    {:ok, _version} =
      Artifacts.record_version(ticket.id, "report.md", :document, :system, %{
        content: "---\noutcome: done\n---\n# Report\n\nAll tests pass.\n"
      })

    {:ok, _view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")

    assert html =~ "score.ex"
    assert html =~ "def persist"
    assert html =~ "report.md"
    assert html =~ "Questions answered"
    assert html =~ "allowance"
    # Dollars appear on no operator surface.
    refute html =~ "$"
  end

  test "the approval pins the changeset version and merges", context do
    %{conn: conn, project: project, ticket: ticket, bare: bare} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)
    pend_merge(ticket)

    {:ok, view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")
    assert html =~ "Approve changeset v1"

    view
    |> form("#merge-decision form", %{"comment" => "ship it"})
    |> render_submit(%{"decision" => "approved"})

    assert Tickets.get!(ticket.id).state == "merged"
    {:ok, head} = Git.resolve(bare, "refs/heads/main")
    assert Git.ancestor?(bare, sha, head)
  end

  test "says so plainly when no job has produced a changeset", context do
    %{conn: conn, project: project, ticket: ticket} = context

    {:ok, _view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")

    assert html =~ "No job has produced a changeset"
  end

  # The page marks each document with whether it was approved, and that mark is the operator's
  # only record on this page that a person signed the chain off rather than an agent writing it.
  # Nothing asserted it: the existing test checks that `report.md` is listed, which it is whether
  # the mark is there, missing or on the wrong document. Placement matters as much as presence —
  # `docs/design/ui.md` § Semantics that must not be lost — so the mark is looked for inside the
  # row of the document it belongs to, with the other document beside it left unmarked.
  test "a document is marked approved only once somebody has approved it", context do
    %{conn: conn, project: project, ticket: ticket, scope: scope} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)

    {:ok, refinement} =
      Artifacts.record_version(ticket.id, "refinement.md", :document, :system, %{
        content: "---\noutcome: done\n---\n# Refinement\n"
      })

    {:ok, _report} =
      Artifacts.record_version(ticket.id, "report.md", :document, :system, %{
        content: "---\noutcome: done\n---\n# Report\n"
      })

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")
    refute has_element?(view, ~s([id="review-doc-refinement.md"] .text-success))

    approve!(refinement, scope.user)

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")
    assert has_element?(view, ~s([id="review-doc-refinement.md"] .text-success), "approved")
    refute has_element?(view, ~s([id="review-doc-report.md"] .text-success))
  end

  test "the queue links to it only for an approval that pins the changeset", context do
    %{conn: conn, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)
    pend_merge(ticket)

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Read the change first"
  end

  test "the API serves the same material", context do
    %{project: project, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)

    token = Forge.Accounts.create_api_token(context.scope.user, "test")

    body =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get(~p"/api/v1/tickets/#{project.name}/#{ticket.number}/review")
      |> json_response(200)

    assert body["changeset"]["commit"] == sha
    assert body["changeset"]["version"] == 1
    assert body["merged"] == false
    assert [%{"path" => "score.ex"}] = body["diff"]["files"]
    assert body["diff"]["patch"] =~ "def persist"
  end

  # -- helpers ---------------------------------------------------------------------------------

  defp commit_on_branch(%{project: project, ticket: ticket}, path, content) do
    commit_over_http(project, ticket.branch, path, content)
  end

  defp changeset!(ticket, sha) do
    {:ok, _version} =
      Artifacts.record_version(ticket.id, "changeset", :blob, :system, %{
        blob_uri: "git:" <> sha
      })

    :ok
  end

  # An operator's decision on one document version, as `Forge.Engine` records one.
  defp approve!(version, user) do
    {:ok, _changes} =
      Ecto.Multi.new()
      |> Artifacts.put_approval(
        :approval,
        version,
        user.id,
        :approved,
        %{"from" => "refining", "to" => "planning"},
        "reads right"
      )
      |> Forge.Repo.transaction()

    :ok
  end

  defp pend_merge(ticket) do
    {:ok, ticket} =
      ticket
      |> Ecto.Changeset.change(
        state: "review_ready",
        pending_transition: %{
          "from" => "review_ready",
          "to" => "merged",
          "outcome" => nil,
          "approve" => ["changeset"]
        }
      )
      |> Forge.Repo.update()

    ticket
  end
end
