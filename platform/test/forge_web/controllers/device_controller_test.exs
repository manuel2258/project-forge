defmodule ForgeWeb.DeviceControllerTest do
  @moduledoc """
  What an installed forge asks of the platform (`docs/design/ui.md` § The installed app): the
  service worker's script, the offline page, the one read about its own person, and the manifest
  that names the shortcuts.
  """

  use ForgeWeb.ConnCase, async: true

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures

  alias Forge.Accounts
  alias Forge.Repo

  defp stuck!(ticket) do
    {:ok, ticket} =
      Repo.update(
        Forge.Tickets.Ticket.progress_changeset(ticket, %{
          state: ticket.state,
          status: :stuck,
          usage: ticket.usage
        })
      )

    ticket
  end

  describe "GET /push/waiting" do
    setup :register_and_log_in_user

    test "answers the person's own count and tags, and is never stored", %{conn: conn, user: user} do
      mine = ticket_fixture() |> join_ticket!(user) |> stuck!()

      conn = get(conn, ~p"/push/waiting")

      assert %{"count" => 1, "tags" => ["stuck-" <> id]} = json_response(conn, 200)
      assert id == mine.id
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    # The guard this ticket is for: the figure and the list are the signed-in person's own queue,
    # never another member's and never one for the project (criterion 22).
    test "two members of a project with different queues are told different things", %{
      conn: conn,
      user: user
    } do
      shared = project_fixture()
      join!(shared, user)
      other = member_fixture(shared)

      alone = ticket_fixture() |> join_ticket!(user) |> stuck!()
      shared_ticket = ticket_fixture(%{project: shared}) |> stuck!()

      mine = conn |> get(~p"/push/waiting") |> json_response(200)
      theirs = build_conn() |> log_in_user(other) |> get(~p"/push/waiting") |> json_response(200)

      assert mine["count"] == 2

      assert Enum.sort(mine["tags"]) ==
               Enum.sort(["stuck-#{alone.id}", "stuck-#{shared_ticket.id}"])

      assert theirs == %{"count" => 1, "tags" => ["stuck-#{shared_ticket.id}"]}
    end

    test "a node admin's count has the accounts waiting in it", %{conn: _conn} do
      admin = node_admin_fixture()
      _pending = pending_user_fixture()

      body = build_conn() |> log_in_user(admin) |> get(~p"/push/waiting") |> json_response(200)

      assert body == %{"count" => 1, "tags" => []}
    end

    # The worker asks in the background when a page opens, which can be the moment after a redirect
    # left a toast (`Logged out`) in the session for the page being drawn: reading the flash clears
    # it, so this read must not.
    test "leaves a flash waiting in the session for the page that will draw it", %{conn: conn} do
      conn =
        conn
        |> put_session("phoenix_flash", %{"info" => "Logged out successfully."})
        |> get(~p"/push/waiting")

      assert conn.status == 200
      assert get_session(conn, "phoenix_flash") == %{"info" => "Logged out successfully."}
    end

    test "a signed-out request is a 401 with nothing in it, not a redirect" do
      conn = get(build_conn(), ~p"/push/waiting")

      assert conn.status == 401
      assert conn.resp_body == ""
      assert get_resp_header(conn, "location") == []
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "a pending account is a 401 with nothing in it" do
      conn = build_conn() |> log_in_user(pending_user_fixture()) |> get(~p"/push/waiting")

      assert conn.status == 401
      assert conn.resp_body == ""
    end

    test "a suspended account is a 401 with nothing in it" do
      admin = node_admin_fixture()
      user = user_fixture()
      conn = log_in_user(build_conn(), user)
      {:ok, _user} = Accounts.suspend_user(user, admin)

      conn = get(conn, ~p"/push/waiting")

      assert conn.status == 401
      assert conn.resp_body == ""
    end

    test "a project token with no session reaches nothing", %{user: user} do
      project = project_fixture()
      join!(project, user)
      token = Accounts.create_api_token(user, "device")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> get(~p"/push/waiting")

      assert conn.status == 401
      assert conn.resp_body == ""
    end
  end

  describe "GET /sw.js" do
    test "is JavaScript, asked for every time, and sets no cookie", %{conn: conn} do
      conn = get(conn, "/sw.js")

      assert response(conn, 200)
      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "text/javascript"
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
      assert get_resp_header(conn, "set-cookie") == []
    end

    test "carries this release's version and exactly the files to precache", %{conn: conn} do
      body = conn |> get("/sw.js") |> response(200)
      [_, json] = Regex.run(~r/\Aconst FORGE = (\{.*\});\n/, body)

      assert %{"version" => version, "offline" => "/offline", "precache" => precache} =
               Jason.decode!(json)

      assert version == Forge.Changelog.running()
      assert precache == ForgeWeb.DeviceController.precache()
      assert hd(precache) == "/offline"
      assert length(precache) == 4
      assert Enum.any?(precache, &(&1 =~ "app.css"))
    end

    # The worker keeps these to draw the offline page, which uses the stylesheet and, through it,
    # the fonts: one that the stylesheet names and the list lacks is a page drawn in a fallback face.
    test "precaches every font the stylesheet names" do
      css = File.read!("assets/css/tokens.css")

      fonts =
        Regex.scan(~r/@font-face\s*\{[^}]*url\("(\/fonts\/[^"]+)"\)/s, css)
        |> Enum.map(&List.last/1)

      assert length(fonts) == 2
      assert fonts -- ForgeWeb.DeviceController.precache() == []
    end

    test "is no longer a static file", %{conn: _conn} do
      refute "sw.js" in ForgeWeb.static_paths()
      refute File.exists?("priv/static/sw.js")
    end
  end

  describe "GET /offline" do
    test "says what the phone is shown, with a button, signed in or not", %{conn: conn} do
      for conn <- [conn, log_in_user(build_conn(), user_fixture())] do
        conn = get(conn, "/offline")
        body = html_response(conn, 200)

        assert body =~ "forge can&#39;t be reached" or body =~ "forge can't be reached"
        assert body =~ "This device is offline, or the server isn"
        assert body =~ "The page will load as soon as it can."
        assert body =~ "Try again"
        assert body =~ ~s(rel="stylesheet" href="/assets/css/app.css)
      end
    end

    # What the device keeps must hold nothing of anybody's: no CSRF token, no cookie, no email.
    test "holds nothing of the person's and sets no cookie" do
      user = user_fixture()
      conn = build_conn() |> log_in_user(user) |> get("/offline")
      body = html_response(conn, 200)

      refute body =~ "csrf-token"
      refute body =~ user.email
      refute body =~ "phx-socket"
      assert get_resp_header(conn, "set-cookie") == []
      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "default-src 'self'"
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
    end

    test "reloads, and has no form", %{conn: conn} do
      body = conn |> get("/offline") |> html_response(200)

      assert body =~ "location.reload()"
      assert body =~ ~s("online")
      refute body =~ "<form"
    end
  end

  describe "the manifest" do
    setup do
      %{manifest: "priv/static/manifest.webmanifest" |> File.read!() |> Jason.decode!()}
    end

    test "is an app of its own, at the root", %{manifest: manifest} do
      assert %{"name" => "forge", "id" => "/", "scope" => "/", "start_url" => "/"} = manifest
      assert manifest["display"] == "standalone"
      assert manifest["background_color"] == ForgeWeb.Layouts.bar_colors().dark
      assert manifest["theme_color"] == ForgeWeb.Layouts.bar_colors().dark
    end

    test "has exactly three shortcuts, each a top-level page", %{manifest: manifest} do
      assert Enum.map(manifest["shortcuts"], &{&1["name"], &1["url"]}) == [
               {"Queue", "/"},
               {"Projects", "/projects"},
               {"Chats", "/chats"}
             ]

      routes = ForgeWeb.Router.__routes__() |> Enum.map(& &1.path)
      for %{"url" => url} <- manifest["shortcuts"], do: assert(url in routes)
    end
  end

  # Criterion 17: a shortcut or a tapped notification, signed out, goes through sign-in to the page
  # it was for.
  describe "signed out" do
    for path <- ["/", "/projects", "/chats"] do
      test "#{path} goes to log-in and back", %{conn: conn} do
        conn = get(conn, unquote(path))

        assert redirected_to(conn) == "/users/log-in"
        assert get_session(conn, :user_return_to) == unquote(path)
      end
    end
  end
end
