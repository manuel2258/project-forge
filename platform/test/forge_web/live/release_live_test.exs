defmodule ForgeWeb.ReleaseLiveTest do
  @moduledoc """
  The native release where an operator meets it (`docs/design/ticket-types.md` § Releases,
  `docs/design/ui.md` § The project page): the Release block a project admin sees and nobody else
  does, its five states, the ticket form that never offers the release, and the other doors that
  refuse it.
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Operator, Projects, Tickets}

  @dev """
  version: 1
  description: Ordinary work.
  initial: implementing
  states:
    implementing:
      prompt: agents/implement.md
      produces: [implementation.md]
      budget: { turns: 10, cost: 1.00 }
    review_ready: {}
  transitions:
    - { from: implementing, to: review_ready }
  limits: { ticket_cost: 5.00 }
  """

  @release """
  version: 1
  description: Cut a release.
  release: true
  initial: releasing
  states:
    releasing:
      prompt: agents/release.md
      produces: [release-notes.md]
      budget: { turns: 10, cost: 1.00 }
    published: {}
  transitions:
    - { from: releasing, to: published }
  limits: { ticket_cost: 5.00 }
  """

  setup :register_and_log_in_user

  setup %{user: user} do
    repos = node_repos_dir()
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :repos_dir, repos))
    on_exit(fn -> Application.put_env(:forge, Forge.Jobs, original) end)

    register = fn files ->
      {:ok, project} =
        Projects.register(
          %{
            name: "rel-#{System.unique_integer([:positive])}",
            repo_path:
              seeded_repo(
                Map.merge(
                  %{
                    ".forge/workflow.yml" => nil,
                    ".forge/agents/release.md" => "Cut it.\n",
                    ".forge/workflows/dev.yml" => @dev,
                    ".forge/workflows/release.yml" => @release
                  },
                  files
                )
              )
          },
          user
        )

      project
    end

    %{register: register, project: register.(%{})}
  end

  describe "the Release block" do
    test "a project admin sees the note box and one button, and a release starts", %{
      conn: conn,
      project: project
    } do
      {:ok, view, html} = live(conn, ~p"/projects/#{project.name}")

      assert html =~ "Release"
      assert has_element?(view, "#release-form textarea[name=note]")
      assert has_element?(view, ~S{#release-form button[type=submit]:not([disabled])}, "Release")
      # No title, no body, no version: one optional note and nothing else.
      refute has_element?(view, "#release-form input[type=text]")
      # Working while it is created, and unusable a second time.
      assert has_element?(view, "#release-form button[type=submit][phx-disable-with]")
      assert view |> element("#release-note") |> render() =~ ~r/><\/textarea>/

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("#release-form", %{"note" => "Fixes only."})
               |> render_submit()

      assert [ticket] = Tickets.list(project)
      assert to == "/tickets/#{project.name}/#{ticket.number}"
      assert {ticket.title, ticket.body} == {"Release in progress", "Fixes only."}
    end

    test "the box is part of a form a rejoin replays, and holds what was typed", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      assert has_element?(view, ~s(form#release-form[phx-change="draft:change"]))

      view |> form("#release-form", %{"note" => "half a note"}) |> render_change()
      assert view |> element("#release-note") |> render() =~ "half a note"
    end

    test "a member who is not an admin is drawn nothing, and the event is refused", %{
      conn: conn,
      project: project
    } do
      member = member_fixture(project, :member)
      {:ok, view, html} = live(log_in_user(conn, member), ~p"/projects/#{project.name}")

      refute has_element?(view, "#release")
      refute has_element?(view, "#release-form")
      refute html =~ "release: true"

      render_hook(view, "release:start", %{"note" => "sneaky"})

      assert render(view) =~ "Only a project admin can start a release."
      assert Tickets.list(project) == []
    end

    test "a note that is not a string is taken as no note", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      assert {:error, {:live_redirect, _}} = render_hook(view, "release:start", %{"note" => 7})
      assert [%{body: ""}] = Tickets.list(project)
    end

    test "with no workflow that sets the flag, an admin is told what would fill it", %{
      conn: conn,
      register: register
    } do
      project = register.(%{".forge/workflows/release.yml" => nil})
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      assert has_element?(view, "#release-none", "no workflow in the project sets release: true")
      refute has_element?(view, "#release-form")
    end

    test "with two, both are named and neither is chosen", %{conn: conn, register: register} do
      project = register.(%{".forge/workflows/dev.yml" => "release: true\n" <> @dev})
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      text = view |> element("#release-several") |> render()
      assert text =~ ".forge/workflows/dev.yml"
      assert text =~ ".forge/workflows/release.yml"
      assert text =~ "unset it in all but one"
      refute has_element?(view, "#release-form")
    end

    test "a release that does not parse is shown broken beside a button that cannot be used", %{
      conn: conn,
      register: register
    } do
      project = register.(%{".forge/workflows/release.yml" => @release <> "bogus: 1\n"})
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      text = view |> element("#release-broken") |> render()
      assert text =~ ".forge/workflows/release.yml"
      assert text =~ "bogus"
      assert has_element?(view, "#release-form button[type=submit][disabled]")

      # The other type is unaffected.
      {:ok, _view, form_html} = live(conn, ~p"/tickets/new?project=#{project.name}")
      assert form_html =~ "starts in implementing"
    end

    test "while one is open it links there and offers no second", %{
      conn: conn,
      project: project,
      user: user
    } do
      {:ok, ticket} = Operator.start_release(project, user, "")

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      assert has_element?(
               view,
               ~s(#release-open a[href="/tickets/#{project.name}/#{ticket.number}"]),
               "Release in progress"
             )

      refute has_element?(view, "#release-form")
    end

    test "a refusal says which, in words, and keeps what was typed", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")
      view |> form("#release-form", %{"note" => "Keep this."}) |> render_change()

      # The repository changes under the page, as it can between a load and a tap.
      commit_to_default(project, %{".forge/workflows/release.yml" => @release <> "bogus: 1\n"})

      html = view |> form("#release-form", %{"note" => "Keep this."}) |> render_submit()

      assert html =~ "Not started: its workflow does not parse"
      assert view |> element("#release-note") |> render() =~ "Keep this."
      assert Tickets.list(project) == []
    end

    test "a note typed on a page that has since lost its box is shown, and a refusal says why", %{
      conn: conn,
      project: project,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")
      view |> form("#release-form", %{"note" => "Keep this too."}) |> render_change()

      # Another admin starts one while this page is open.
      {:ok, _} = Operator.start_release(project, user, "")
      assert render(view) =~ "A release is already open"
      refute has_element?(view, "#release-form")
      assert view |> element("#release-draft") |> render() =~ "Keep this too."

      html = render_hook(view, "release:start", %{"note" => "Keep this too."})

      assert html =~ "Not started: a release is already open: #1"
      assert view |> element("#release-draft") |> render() =~ "Keep this too."
      assert length(Tickets.list(project)) == 1
    end

    test "the unsent note is drawn only where there is a note and no box", %{
      conn: conn,
      project: project,
      user: user
    } do
      # A box and a note: the note is in the box, and not drawn a second time.
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")
      view |> form("#release-form", %{"note" => "In the box."}) |> render_change()
      assert view |> element("#release-note") |> render() =~ "In the box."
      refute has_element?(view, "#release-draft")

      # No box and no note: no heading for nothing.
      {:ok, _} = Operator.start_release(project, user, "")
      assert render(view) =~ "A release is already open"
      {:ok, fresh, _html} = live(conn, ~p"/projects/#{project.name}")
      assert has_element?(fresh, "#release-open")
      refute has_element?(fresh, "#release-draft")
      refute render(fresh) =~ "Your unsent note"
    end

    test "a flag that moves under an open page is a refusal that shows the note, not the box", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")
      view |> form("#release-form", %{"note" => "Mine."}) |> render_change()

      # Not a ticket event, so nothing tells the page: only the refusal's reload does.
      commit_to_default(project, %{
        ".forge/workflows/release.yml" => String.replace(@release, "release: true\n", "")
      })

      assert render_hook(view, "release:start", %{"note" => "Mine."}) =~
               "Not started: no workflow in the project sets release: true"

      assert has_element?(view, "#release-none")
      refute has_element?(view, "#release-form")
      assert view |> element("#release-draft") |> render() =~ "Mine."
      assert Tickets.list(project) == []
    end

    test "the refusal words are the page's to say: no workflow, two, and a bad note", %{
      conn: conn,
      register: register
    } do
      none = register.(%{".forge/workflows/release.yml" => nil})
      {:ok, view, _html} = live(conn, ~p"/projects/#{none.name}")

      assert render_hook(view, "release:start", %{"note" => ""}) =~
               "Not started: no workflow in the project sets release: true"

      project = register.(%{})
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      assert render_hook(view, "release:start", %{"note" => "a\0b"}) =~
               "Not started: the note must be UTF-8 text with no NUL byte"
    end

    test "a very long note is bounded to the page, and markup in it is shown as text", %{
      conn: conn,
      project: project,
      user: user
    } do
      note = "<script>alert(1)</script><b>bold</b> " <> String.duplicate("x", 5_000)
      {:ok, ticket} = Operator.start_release(project, user, note)

      {:ok, _view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")

      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;&lt;b&gt;bold&lt;/b&gt;"
      refute html =~ "<script>alert(1)"
      # Wrapped rather than stretching the page: the body is the paragraph that carries it.
      assert html =~ ~r/<p[^>]*whitespace-pre-line[^>]*break-words[^>]*>\s*&lt;script/
    end

    test "the per-type table says which type is the release", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      assert has_element?(view, "#type-release", "the release")
      refute has_element?(view, "#type-dev", "the release")
    end
  end

  describe "restoring a cancelled release from its page" do
    test "while another is open says so in words", %{conn: conn, project: project, user: user} do
      {:ok, first} = Operator.start_release(project, user, "")
      {:ok, first} = Forge.Engine.cancel(first, user.id)
      {:ok, _second} = Operator.start_release(project, user, "")

      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{first.number}")
      html = view |> element("#restore-ticket") |> render_click()

      assert html =~ "a release is already open: #2"
      refute html =~ "something went wrong"
      assert Tickets.get!(first.id).status == :cancelled
    end
  end

  describe "the placeholder is a title everywhere" do
    test "on the board, the queue and the ticket page", %{
      conn: conn,
      project: project,
      user: user
    } do
      {:ok, ticket} = Operator.start_release(project, user, "")

      for path <- [
            ~p"/board",
            ~p"/projects/#{project.name}",
            ~p"/tickets/#{project.name}/#{ticket.number}"
          ] do
        {:ok, _view, html} = live(conn, path)
        assert html =~ "Release in progress", path
      end
    end

    test "and in the queue, once the release is stuck on something", %{
      conn: conn,
      project: project,
      user: user
    } do
      {:ok, ticket} = Operator.start_release(project, user, "")
      ticket |> Ecto.Changeset.change(status: :stuck) |> Forge.Repo.update!()

      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Release in progress"
    end

    test "and a rename is said in the ticket's timeline", %{
      conn: conn,
      project: project,
      user: user
    } do
      {:ok, ticket} = Operator.start_release(project, user, "")

      Forge.Repo.insert!(%Forge.Events.Event{
        type: "ticket.renamed",
        actor: %{"kind" => "system", "id" => nil},
        ticket_id: ticket.id,
        project_id: project.id,
        payload: %{"from" => "Release in progress", "to" => "0.17.0", "document" => "notes.md"}
      })

      {:ok, _view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=timeline")
      assert html =~ "renamed to 0.17.0, from notes.md"
    end

    test "and a rename shows wherever the title does", %{conn: conn, project: project, user: user} do
      {:ok, ticket} = Operator.start_release(project, user, "")

      ticket
      |> Ecto.Changeset.change(title: "0.17.0")
      |> Forge.Repo.update!()

      {:ok, _view, html} = live(conn, ~p"/board")
      assert html =~ "0.17.0"
      refute html =~ "Release in progress"
    end
  end

  describe "the ticket form" do
    test "does not offer the release, and implies the one ordinary type", %{
      conn: conn,
      project: project
    } do
      {:ok, view, html} = live(conn, ~p"/tickets/new?project=#{project.name}")

      refute html =~ "release"
      refute has_element?(view, ~s(select[name="ticket[ticket_type]"]))
      assert has_element?(view, "#implied-type", "dev")
    end

    test "says so, as it does for no workflow, on a project whose only type is the release", %{
      conn: conn,
      register: register
    } do
      project = register.(%{".forge/workflows/dev.yml" => nil})
      {:ok, view, html} = live(conn, ~p"/tickets/new?project=#{project.name}")

      assert html =~ "This project cannot take a ticket: its only workflow is its release"
      assert has_element?(view, ~s(#ticket-form button[type="submit"][disabled]))
    end

    test "the project page's proposal select leaves it out too", %{
      conn: conn,
      register: register
    } do
      project =
        register.(%{".forge/workflows/bug.yml" => String.replace(@dev, "implementing", "fixing")})

      job = job_fixture(%{ticket: ticket_fixture(%{project: project})})
      proposal_fixture(%{job: job, content: "# Lost slot\n\nSaving twice loses it."})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      assert has_element?(view, ~s(select[name="ticket_type"] option[value="bug"]))
      assert has_element?(view, ~s(select[name="ticket_type"] option[value="dev"]))
      refute has_element?(view, ~s(select[name="ticket_type"] option[value="release"]))
    end
  end

  describe "the other doors" do
    setup %{user: user} do
      %{token: Forge.Accounts.create_api_token(user, "test")}
    end

    test "the API refuses the release type with the sentence", %{
      conn: conn,
      project: project,
      token: token
    } do
      assert %{"error" => %{"reason" => "release_ticket_type", "detail" => detail}} =
               conn
               |> put_req_header("authorization", "Bearer " <> token)
               |> post(~p"/api/v1/projects/#{project.name}/tickets", %{
                 title: "x",
                 ticket_type: "release"
               })
               |> json_response(422)

      assert detail =~ "release is this project's release"
      assert detail =~ "Release on the project page"
      assert Tickets.list(project) == []
    end

    test "the API answers a project of nothing but the release", %{
      conn: conn,
      register: register,
      token: token
    } do
      project = register.(%{".forge/workflows/dev.yml" => nil})

      assert %{"error" => %{"reason" => "only_release_types"}} =
               conn
               |> put_req_header("authorization", "Bearer " <> token)
               |> post(~p"/api/v1/projects/#{project.name}/tickets", %{title: "x"})
               |> json_response(422)
    end

    test "a proposal that suggests the release is admitted as the ordinary type, never as it", %{
      conn: conn,
      project: project,
      token: token
    } do
      job = job_fixture(%{ticket: ticket_fixture(%{project: project})})

      version =
        proposal_fixture(%{job: job, content: "---\ntype: release\n---\n# Cut one\n\nNow."})

      assert %{"ticket_type" => "dev"} =
               conn
               |> put_req_header("authorization", "Bearer " <> token)
               |> post(~p"/api/v1/proposals/#{version.id}/accept", %{})
               |> json_response(200)

      assert Enum.all?(Tickets.list(project), &(&1.ticket_type != "release"))
    end

    test "restoring a cancelled release while another is open is a 409 naming it", %{
      conn: conn,
      project: project,
      user: user,
      token: token
    } do
      {:ok, first} = Operator.start_release(project, user, "")
      {:ok, first} = Forge.Engine.cancel(first, {:user, user.id})
      {:ok, second} = Operator.start_release(project, user, "")

      assert %{"error" => %{"reason" => "release_open", "detail" => detail}} =
               conn
               |> put_req_header("authorization", "Bearer " <> token)
               |> post(~p"/api/v1/tickets/#{project.name}/#{first.number}/restore")
               |> json_response(409)

      assert detail =~ "##{second.number}"
    end

    test "naming the release when accepting is refused", %{
      conn: conn,
      project: project,
      token: token
    } do
      job = job_fixture(%{ticket: ticket_fixture(%{project: project})})
      version = proposal_fixture(%{job: job, content: "# Cut one\n\nNow."})

      assert %{"error" => %{"reason" => "release_ticket_type"}} =
               conn
               |> put_req_header("authorization", "Bearer " <> token)
               |> post(~p"/api/v1/proposals/#{version.id}/accept", %{ticket_type: "release"})
               |> json_response(422)

      assert Enum.all?(Tickets.list(project), &(&1.ticket_type != "release"))
    end

    test "on the page, with one ordinary type and no select, a suggested release is accepted", %{
      conn: conn,
      project: project
    } do
      job = job_fixture(%{ticket: ticket_fixture(%{project: project})})

      version =
        proposal_fixture(%{job: job, content: "---\ntype: release\n---\n# Cut one\n\nNow."})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")
      refute has_element?(view, ~s(select[name="ticket_type"]))

      view
      |> element("#propose-#{version.id}")
      |> render_submit(%{"decision" => "accepted"})

      assert Enum.any?(
               Tickets.list(project),
               &(&1.ticket_type == "dev" and &1.title == "Cut one")
             )
    end
  end

  describe "the backlog a job reads" do
    test "lists no release type, since no agent can usefully suggest one", %{project: project} do
      %{"index" => index} = Forge.Backlog.compose(project)

      assert index =~ "Ordinary work."
      refute index =~ "Cut a release."
    end
  end
end
