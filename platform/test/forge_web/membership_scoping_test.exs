defmodule ForgeWeb.MembershipScopingTest do
  @moduledoc """
  What a logged-in non-member gets from each surface: a miss, not a refusal.

  Not a member and does not exist answer the same way on purpose, because a 403 on a project
  page tells you the project is there. These assert through the routes rather than the
  contexts, since a context guard says nothing about whether a page consults it.
  """

  use ForgeWeb.ConnCase, async: true

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Phoenix.LiveViewTest

  alias Forge.Accounts

  setup do
    owner = user_fixture()
    project = project_fixture()
    join!(project, owner)
    ticket = ticket_fixture(%{project: project})

    # A member of somewhere else, never of nothing: an account with no membership at all is
    # excluded by an inner join whatever the project filter says, so it cannot tell the two apart.
    %{
      project: project,
      ticket: ticket,
      owner: owner,
      outsider: member_fixture(project_fixture(), :admin)
    }
  end

  describe "an outsider on the pages" do
    test "the project page is a miss", %{conn: conn, project: project, outsider: outsider} do
      assert_raise Ecto.NoResultsError, fn ->
        conn |> log_in_user(outsider) |> live(~p"/projects/#{project.name}")
      end
    end

    test "the ticket page is a miss", %{
      conn: conn,
      project: project,
      ticket: ticket,
      outsider: outsider
    } do
      assert_raise Ecto.NoResultsError, fn ->
        conn |> log_in_user(outsider) |> live(~p"/tickets/#{project.name}/#{ticket.number}")
      end
    end

    test "the artifact bytes are a miss", %{
      conn: conn,
      project: project,
      ticket: ticket,
      outsider: outsider
    } do
      assert_raise Ecto.NoResultsError, fn ->
        conn
        |> log_in_user(outsider)
        |> get(~p"/tickets/#{project.name}/#{ticket.number}/artifacts/plan.md/1")
      end
    end

    # The same miss at a conversation's own address, which is guarded as its page is.
    test "a conversation's artifact bytes are a miss", %{
      conn: conn,
      project: project,
      outsider: outsider
    } do
      chat = chat_fixture(%{project: project})

      {:ok, _version} =
        Forge.Artifacts.record_version({:job, chat.id}, "notes.md", :document, {:job, chat.id}, %{
          content: "# private\n"
        })

      assert_raise Ecto.NoResultsError, fn ->
        conn
        |> log_in_user(outsider)
        |> get(~p"/chats/#{chat.id}/artifacts/notes.md/1")
      end
    end

    test "the board shows nothing", %{conn: conn, project: project, outsider: outsider} do
      {:ok, _view, html} = conn |> log_in_user(outsider) |> live(~p"/board")
      refute html =~ project.name
    end

    test "the member sees the same board with the project on it", %{
      conn: conn,
      project: project,
      owner: owner
    } do
      # The pair is the assertion: without it, "the board shows nothing" would pass against a
      # board that was broken for everyone.
      {:ok, _view, html} = conn |> log_in_user(owner) |> live(~p"/board")
      assert html =~ project.name
    end
  end

  describe "an outsider on the other pages" do
    test "the review page is a miss", %{
      conn: conn,
      project: project,
      ticket: ticket,
      outsider: outsider
    } do
      assert_raise Ecto.NoResultsError, fn ->
        conn
        |> log_in_user(outsider)
        |> live(~p"/tickets/#{project.name}/#{ticket.number}/review")
      end
    end

    test "a job page is a miss", %{
      conn: conn,
      project: project,
      ticket: ticket,
      outsider: outsider
    } do
      job = job_fixture(%{ticket: ticket})

      assert_raise Ecto.NoResultsError, fn ->
        conn
        |> log_in_user(outsider)
        |> live(~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}")
      end
    end

    test "starting a chat on someone else's project is a miss", %{
      conn: conn,
      project: project,
      outsider: outsider
    } do
      assert_raise Ecto.NoResultsError, fn ->
        conn |> log_in_user(outsider) |> live(~p"/chats/new?project=#{project.name}")
      end
    end
  end

  describe "the pages send their writes through the guard" do
    test "the queue's chat answer refuses an outsider's chat id", %{
      conn: conn,
      project: project
    } do
      # The one that was open: the queue hides the item, and hiding it was the whole defence.
      chat = chat_fixture(%{project: project, status: :running})
      outsider = member_fixture(project_fixture(), :admin)

      {:ok, view, html} = conn |> log_in_user(outsider) |> live(~p"/")
      refute html =~ chat.id

      render_click(view, "chat:answer", %{"chat" => chat.id, "choice" => "rm -rf please"})

      assert Forge.Conversations.messages(chat.id) == []
    end

    test "a member's answer does land", %{conn: conn, project: project, owner: owner} do
      chat = chat_fixture(%{project: project, status: :running})

      {:ok, view, _html} = conn |> log_in_user(owner) |> live(~p"/")
      render_click(view, "chat:answer", %{"chat" => chat.id, "choice" => "the first one"})

      assert Enum.map(Forge.Conversations.messages(chat.id), & &1.text) == ["the first one"]
    end

    test "a plain member cannot change the model by sending the event", %{
      conn: conn,
      project: project
    } do
      plain = member_fixture(project, :member)

      {:ok, view, _html} =
        conn |> log_in_user(plain) |> live(~p"/projects/#{project.name}/settings")

      # Not offered, since it would be refused.
      refute has_element?(view, "#model-form")

      render_change(view, "model", %{"project" => %{"model" => "evil-model"}})

      assert Forge.Projects.get!(project.id).model == nil
    end

    test "a plain member cannot revoke a token by sending the event", %{
      conn: conn,
      project: project,
      owner: owner
    } do
      {:ok, _secret, token} = Forge.Operator.issue_token(project, owner, [])
      plain = member_fixture(project, :member)

      {:ok, view, _html} =
        conn |> log_in_user(plain) |> live(~p"/projects/#{project.name}/settings")

      render_click(view, "revoke", %{"id" => token.id})

      assert [%{revoked_at: nil}] = Forge.Git.Tokens.list(project)
    end

    test "an admin cannot revoke another project's token by id", %{
      conn: conn,
      project: project,
      owner: owner
    } do
      victim = project_fixture()
      victim_admin = member_fixture(victim, :admin)
      {:ok, _secret, theirs} = Forge.Operator.issue_token(victim, victim_admin, [])

      {:ok, view, _html} =
        conn |> log_in_user(owner) |> live(~p"/projects/#{project.name}/settings")

      # The id is the whole request. A bare `Repo.get` revokes any token on the node.
      render_click(view, "revoke", %{"id" => theirs.id})

      assert [%{revoked_at: nil}] = Forge.Git.Tokens.list(victim)
    end

    test "an admin can revoke its own project's token", %{
      conn: conn,
      project: project,
      owner: owner
    } do
      {:ok, _secret, token} = Forge.Operator.issue_token(project, owner, [])

      {:ok, view, _html} =
        conn |> log_in_user(owner) |> live(~p"/projects/#{project.name}/settings")

      render_click(view, "revoke", %{"id" => token.id})

      assert [%{revoked_at: %DateTime{}}] = Forge.Git.Tokens.list(project)
    end

    test "a plain member is not shown the credentials at all", %{
      conn: conn,
      project: project,
      owner: owner
    } do
      {:ok, _secret, _token} = Forge.Operator.issue_token(project, owner, [])
      plain = member_fixture(project, :member)

      {:ok, view, _html} =
        conn |> log_in_user(plain) |> live(~p"/projects/#{project.name}/settings")

      # The table rendered every token's id to anyone who could mount the page, which is how a
      # member learned what to revoke in the first place.
      refute has_element?(view, "button[phx-click='revoke']")
    end

    test "a plain member cannot mint a token by sending the event", %{
      conn: conn,
      project: project
    } do
      plain = member_fixture(project, :member)

      {:ok, view, _html} =
        conn |> log_in_user(plain) |> live(~p"/projects/#{project.name}/settings")

      render_submit(view, "issue", %{"token" => %{"scope" => "read", "minutes" => "90"}})

      assert Forge.Git.Tokens.list(project) == []
    end
  end

  describe "the people section" do
    test "an admin can add an approved account and it gains access", %{
      conn: conn,
      project: project,
      owner: owner
    } do
      newcomer = user_fixture()

      {:ok, view, _html} =
        conn |> log_in_user(owner) |> live(~p"/projects/#{project.name}/settings")

      view
      |> form("form[phx-submit='add-member']", %{
        "member" => %{"email" => newcomer.email, "role" => "member"}
      })
      |> render_submit()

      assert Forge.Projects.role(project, newcomer) == :member
    end

    test "an address nobody has approved is not a person yet", %{
      conn: conn,
      project: project,
      owner: owner
    } do
      {:ok, view, _html} =
        conn |> log_in_user(owner) |> live(~p"/projects/#{project.name}/settings")

      html =
        view
        |> form("form[phx-submit='add-member']", %{
          "member" => %{"email" => "nobody@example.com", "role" => "member"}
        })
        |> render_submit()

      # There are no invitations, so an unknown address is an answer rather than a pending row.
      assert html =~ "No approved account for that address."
    end

    # The sentence above was false for exactly this case: a pending account has an address, so
    # the page handed it to `put_member/4`, which added it. Now the context refuses and the page
    # says what it says for an address with no account at all.
    test "a pending account gets the same answer, and is not added", %{
      conn: conn,
      project: project,
      owner: owner
    } do
      pending = pending_user_fixture()

      {:ok, view, _html} =
        conn |> log_in_user(owner) |> live(~p"/projects/#{project.name}/settings")

      html =
        view
        |> form("form[phx-submit='add-member']", %{
          "member" => %{"email" => pending.email, "role" => "member"}
        })
        |> render_submit()

      assert html =~ "No approved account for that address."
      assert Forge.Projects.role(project, pending) == nil
      refute html =~ pending.email
    end

    test "a suspended account is named as one, and is not added", %{
      conn: conn,
      project: project,
      owner: owner
    } do
      {:ok, suspended} = Accounts.suspend_user(user_fixture(), node_admin_fixture())

      {:ok, view, _html} =
        conn |> log_in_user(owner) |> live(~p"/projects/#{project.name}/settings")

      html =
        view
        |> form("form[phx-submit='add-member']", %{
          "member" => %{"email" => suspended.email, "role" => "member"}
        })
        |> render_submit()

      assert html =~ "That account is suspended."
      assert Forge.Projects.role(project, suspended) == nil
    end

    test "a plain member is not offered the section at all", %{conn: conn, project: project} do
      plain = member_fixture(project, :member)

      {:ok, view, _html} =
        conn |> log_in_user(plain) |> live(~p"/projects/#{project.name}/settings")

      refute has_element?(view, "form[phx-submit='add-member']")
    end

    test "and cannot reach it by sending the event anyway", %{conn: conn, project: project} do
      plain = member_fixture(project, :member)
      newcomer = user_fixture()

      {:ok, view, _html} =
        conn |> log_in_user(plain) |> live(~p"/projects/#{project.name}/settings")

      # The hidden form is cosmetics. This is the guard: a member who sends the event by hand
      # still changes nothing, because `Forge.Projects` is what refuses.
      render_click(view, "add-member", %{
        "member" => %{"email" => newcomer.email, "role" => "admin"}
      })

      refute Forge.Projects.member?(project, newcomer)
    end
  end

  describe "the surfaces a review found de-scoped without a test" do
    test "the conversation page itself is a miss", %{
      conn: conn,
      project: project,
      outsider: outsider
    } do
      chat = chat_fixture(%{project: project})

      # The list is one thing; this is where the transcript actually is.
      assert_raise Ecto.NoResultsError, fn ->
        conn |> log_in_user(outsider) |> live(~p"/chats/#{chat.id}")
      end
    end

    test "the queue page shows only the reader's projects", %{
      conn: conn,
      ticket: ticket,
      owner: owner,
      outsider: outsider
    } do
      stick(ticket)

      {:ok, _view, mine} = conn |> log_in_user(owner) |> live(~p"/")
      assert mine =~ ticket.title

      {:ok, _view, theirs} = conn |> log_in_user(outsider) |> live(~p"/")
      refute theirs =~ ticket.title
    end

    test "the new-ticket page offers only the reader's projects", %{
      conn: conn,
      project: project,
      owner: owner,
      outsider: outsider
    } do
      {:ok, _view, mine} = conn |> log_in_user(owner) |> live(~p"/tickets/new")
      assert mine =~ project.name

      {:ok, _view, theirs} = conn |> log_in_user(outsider) |> live(~p"/tickets/new")
      refute theirs =~ project.name
    end
  end

  describe "an outsider on the API" do
    test "sees no projects", %{conn: conn, project: project, outsider: outsider} do
      conn = api(conn, outsider) |> get(~p"/api/v1/projects")
      names = json_response(conn, 200)["projects"] |> Enum.map(& &1["name"])

      refute project.name in names
    end

    test "a member does see it", %{conn: conn, project: project, owner: owner} do
      conn = api(conn, owner) |> get(~p"/api/v1/projects")
      names = json_response(conn, 200)["projects"] |> Enum.map(& &1["name"])

      assert project.name in names
    end

    test "a ticket in a project they are not in is 404, not 403", %{
      conn: conn,
      project: project,
      ticket: ticket,
      outsider: outsider
    } do
      conn = api(conn, outsider) |> get(~p"/api/v1/tickets/#{project.name}/#{ticket.number}")

      assert json_response(conn, 404)
    end

    test "listing tickets by project name is 404", %{
      conn: conn,
      project: project,
      outsider: outsider
    } do
      conn = api(conn, outsider) |> get(~p"/api/v1/tickets?project=#{project.name}")
      assert json_response(conn, 404)
    end

    # **This is what proves the guard is `Operator.admit/3`'s.** The controller resolves the
    # project by name and has no membership check of its own, so an endpoint that called
    # `Tickets.admit/3` directly — as it used to, behind its own scoping — would admit this
    # ticket. The answer is the one a project that does not exist gets, byte for byte, and a
    # body that would not validate is refused the same way rather than as a 422.
    test "admitting a ticket into it is 404", %{conn: conn, project: project, outsider: outsider} do
      before = Forge.Tickets.list(project)

      refused =
        api(conn, outsider)
        |> post(~p"/api/v1/projects/#{project.name}/tickets", %{title: "theirs"})
        |> json_response(404)

      missing =
        api(conn, outsider)
        |> post(~p"/api/v1/projects/no-such-project/tickets", %{title: "theirs"})
        |> json_response(404)

      assert refused == missing

      assert api(conn, outsider)
             |> post(~p"/api/v1/projects/#{project.name}/tickets", %{title: ""})
             |> json_response(404) == missing

      assert Forge.Tickets.list(project) == before
    end

    test "reading its proposals is 404", %{conn: conn, project: project, outsider: outsider} do
      conn = api(conn, outsider) |> get(~p"/api/v1/projects/#{project.name}/proposals")
      assert json_response(conn, 404)
    end

    test "a member reaches all three", %{conn: conn, project: project, owner: owner} do
      # The negative tests above would all pass against an endpoint that 404s for everybody.
      assert json_response(
               api(conn, owner) |> get(~p"/api/v1/tickets?project=#{project.name}"),
               200
             )

      assert json_response(
               api(conn, owner) |> get(~p"/api/v1/projects/#{project.name}/proposals"),
               200
             )

      # 422 and not 201: this fixture's project has no seeded repository, so admission fails on
      # the ref. That is the point — the member gets *past* membership and is refused for a
      # different reason, while the outsider above never gets that far and sees 404.
      assert json_response(
               api(conn, owner)
               |> post(~p"/api/v1/projects/#{project.name}/tickets", %{title: "mine"}),
               422
             )
    end

    test "the queue is empty for them", %{conn: conn, outsider: outsider} do
      conn = api(conn, outsider) |> get(~p"/api/v1/queue")

      assert json_response(conn, 200)["items"] == []
    end
  end

  defp stick(ticket) do
    {:ok, ticket} =
      Forge.Repo.update(
        Forge.Tickets.Ticket.progress_changeset(ticket, %{
          state: ticket.state,
          status: :stuck,
          cost_usd: ticket.cost_usd
        })
      )

    ticket
  end

  defp api(conn, user) do
    put_req_header(conn, "authorization", "Bearer " <> Accounts.create_api_token(user, "test"))
  end
end
