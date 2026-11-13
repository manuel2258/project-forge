defmodule ForgeWeb.FrameTest do
  @moduledoc """
  The frame every signed-in page is drawn in (`docs/design/ui.md` § The frame): that every page has
  it and no sign-in screen does; the queue button's count, what it counts and for whom, and how it
  is kept current without a read for a change in somebody else's project; the usage lines and
  whose credentials they draw; the title menu, its figures read when it opens; and the version.

  The widths themselves are CSS no test here can apply. What is pinned is the markup each rule
  depends on.
  """

  use ForgeWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Artifacts, Events, Git, Jobs, Projects, Queue, Repo}

  # The count as the desktop header draws it; the same assign the phone's queue button reads.
  defp count(view) do
    view
    |> element("#desktop-header .frame-queue .ui-count")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
    |> String.to_integer()
  end

  # Up to 1.5 s for the frame's own timer to bring the count to `expected`.
  defp await_count(view, expected, tries \\ 30) do
    cond do
      count(view) == expected ->
        :ok

      tries == 0 ->
        flunk("the count stayed #{count(view)}, not #{expected}")

      true ->
        Process.sleep(50)
        await_count(view, expected, tries - 1)
    end
  end

  defp open_menu(view), do: view |> element("#top-bar .ui-top-title") |> render_click()

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # A document carrying blocking questions, as an agent leaves one.
  defp ask(ticket, keys, blocking \\ true) do
    job = job_fixture(%{ticket: ticket})

    blocks =
      for key <- keys do
        """
        ```question
        key: #{key}
        text: Which #{key}?
        options: [{label: a, detail: About a, recommended: true}, {label: b, detail: About b}]
        blocking: #{blocking}
        #{if blocking, do: "", else: "assumption: went with a"}
        ```
        """
      end

    {:ok, _version} =
      Artifacts.record_version(ticket.id, "refinement.md", :document, {:job, job.id}, %{
        content: "---\noutcome: done\n---\n# Refinement\n\n" <> Enum.join(blocks, "\n")
      })
  end

  defp stuck!(ticket),
    do: ticket |> Ecto.Changeset.change(status: :stuck) |> Repo.update!()

  describe "every signed-in page" do
    setup %{conn: conn} do
      repos = node_repos_dir()
      original = Application.get_env(:forge, Forge.Jobs)
      Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :repos_dir, repos))
      on_exit(fn -> Application.put_env(:forge, Forge.Jobs, original) end)

      # A node admin, so `/accounts` is one of the pages, and a member of the project the rest
      # are about.
      user = node_admin_fixture()

      {:ok, project} =
        Projects.register(
          %{name: "frame-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
          user
        )

      ticket = ticket_fixture(%{project: project})
      # A budget, because the job page draws one.
      job =
        job_fixture(%{
          ticket: ticket,
          spec: %{"prompt" => "agents/refine.md", "budget" => %{"turns" => 20, "cost" => 0.5}}
        })

      chat = chat_fixture(%{project: project})

      {:ok, worker, _token} =
        Forge.Workers.create(%{provider: "fake", managed: false, user_id: user.id})

      {:ok, head} = Git.resolve(Projects.repo_path(project), "refs/heads/main")

      params = %{
        "name" => project.name,
        "project" => project.name,
        "number" => to_string(ticket.number),
        "job_id" => job.id,
        "sha" => head
      }

      release =
        Forge.Repo.insert!(%Forge.ReleaseRecords.Record{
          project_id: project.id,
          ticket_id: ticket.id,
          version: "1.0.0",
          concluded_at: DateTime.utc_now(),
          commit_sha: head,
          tag_name: "v1.0.0",
          tag_status: :tagged
        })

      ids = %{
        "/workers/:id" => worker.id,
        "/chats/:id" => chat.id,
        "/projects/:name/releases/:id" => release.id
      }

      %{conn: log_in_user(conn, user), params: params, ids: ids}
    end

    # Enumerated from the router, so a page added to a signed-in session is in here without
    # anybody remembering to add it. The one left out redirects from its mount whatever it is
    # given: it confirms an email change and goes on to the settings page, which is in here.
    test "draws the frame: the top bar, the header and both usage lines", %{
      conn: conn,
      params: params,
      ids: ids
    } do
      paths =
        for %{path: path, metadata: %{phoenix_live_view: {_, _, _, %{name: session}}}} <-
              ForgeWeb.Router.__routes__(),
            session in [:operator, :node_admin, :require_authenticated_user],
            path != "/users/settings/confirm-email/:token" do
          id = ids[path]

          path
          |> String.split("/")
          |> Enum.map_join("/", fn
            ":id" -> id
            ":" <> param -> Map.fetch!(params, param)
            segment -> segment
          end)
        end

      assert length(paths) >= 21
      # Every `:id` named, or the path would be a different page's with a trailing slash.
      refute Enum.any?(paths, &(&1 != "/" and String.ends_with?(&1, "/")))

      for path <- paths do
        {:ok, view, _html} = live(conn, path)

        for selector <- ~w(#frame #top-bar #desktop-header #usage-5h #usage-week #title-row) do
          assert has_element?(view, selector), "#{path} draws no #{selector}"
        end
      end
    end
  end

  describe "a sign-in screen" do
    # No usage lines, no queue and no version: nobody signed in yet is told anything about the
    # node (`docs/design/ui.md` § Signing in).
    test "draws no frame, no usage and no version" do
      user = user_fixture()
      {token, _raw} = generate_user_magic_link_token(user)
      pending = pending_user_fixture()

      views = [
        live(build_conn(), ~p"/users/log-in"),
        live(build_conn(), ~p"/users/log-in/#{token}"),
        live(log_in_user(build_conn(), pending), ~p"/users/pending")
      ]

      for {:ok, view, _html} <- views do
        assert has_element?(view, "#sign-in")

        for selector <- ~w(#frame #top-bar #usage-5h #usage-week #forge-version) do
          refute has_element?(view, selector)
        end
      end
    end
  end

  describe "the queue count" do
    setup :register_and_log_in_user

    setup %{user: user} do
      project = project_fixture()
      join!(project, user, :member)
      %{project: project}
    end

    # One of every kind the queue page groups or leaves out, and one in a project the viewer is
    # not in: the count is the items the page draws, from the same reading.
    test "is the number of items the queue page draws", %{
      conn: conn,
      user: user,
      project: project
    } do
      # Two blocking questions in one document version: one item.
      ask(ticket_fixture(%{project: project}), ["backend", "db"])
      # An assumption alone: waiting on nobody, no item.
      ask(ticket_fixture(%{project: project}), ["naming"], false)
      # A stuck ticket: one item.
      stuck!(ticket_fixture(%{project: project}))
      # Elsewhere, where the viewer is not a member.
      ask(ticket_fixture(), ["elsewhere"])

      {:ok, view, _html} = live(conn, ~p"/")

      drawn =
        view |> render() |> LazyHTML.from_document() |> LazyHTML.query("#queue-decisions .ui-row")

      assert Enum.count(drawn) == 2
      assert Queue.count(user) == 2
      assert count(view) == 2
    end

    # An account waiting on an admin is a decision too (`12i`), and only an admin's.
    test "counts the waiting accounts for a node admin, and for nobody else", %{conn: conn} do
      _waiting = pending_user_fixture()
      admin = node_admin_fixture()

      {:ok, admin_view, _html} = live(log_in_user(build_conn(), admin), ~p"/projects")
      assert count(admin_view) == 1
      assert has_element?(admin_view, ~s(#top-bar a[aria-label="Queue, 1 waiting"]))

      {:ok, view, _html} = live(conn, ~p"/projects")
      assert count(view) == 0
    end

    # No ticket event announces an account signing up, so the tick is what brings an admin's
    # open page up to date.
    test "the tick recounts what no event announces", %{conn: conn} do
      admin = node_admin_fixture()
      {:ok, view, _html} = live(log_in_user(conn, admin), ~p"/projects")
      assert count(view) == 0

      _waiting = pending_user_fixture()
      send(view.pid, :capacity_tick)
      assert count(view) == 1
    end

    # The queue's own top bar draws no queue button — it is the queue — and every other top-level
    # page keeps it on the left (`19c`).
    test "the queue button is on every page but the queue's", %{conn: conn} do
      {:ok, queue, _html} = live(conn, ~p"/")
      refute has_element?(queue, "#top-bar .ui-queue-btn")

      for path <- [~p"/projects", ~p"/chats", ~p"/workers"] do
        {:ok, view, _html} = live(conn, path)
        assert has_element?(view, ~s(#top-bar a.ui-queue-btn[href="/"])), path
      end
    end
  end

  describe "keeping the count current" do
    setup :register_and_log_in_user

    setup %{user: user} do
      project = project_fixture()
      join!(project, user, :member)
      %{project: project, other: project_fixture()}
    end

    # The view's own queries, and nobody else's: the handler runs in the process that queried.
    defp watch_queries(view) do
      test = self()
      handler = "frame-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:forge, :repo, :query],
        fn _event, _measurements, _metadata, pid ->
          if self() == pid, do: send(test, :queried)
        end,
        view.pid
      )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    defp flush_queries do
      receive do
        :queried -> flush_queries()
      after
        0 -> :ok
      end
    end

    # CLAUDE.md § Rules: a handler on a global topic filters before it does any work. Every open
    # page hears every change on the node, so a change elsewhere must cost it nothing.
    test "a change in another project costs no read; one in the viewer's recounts", %{
      conn: conn,
      project: project,
      other: other
    } do
      {:ok, view, _html} = live(conn, ~p"/projects")
      watch_queries(view)

      send(view.pid, {:queue_changed, other.id})
      _ = render(view)
      refute_received :queried

      stuck!(ticket_fixture(%{project: project}))
      send(view.pid, {:queue_changed, project.id})
      _ = render(view)
      assert_received :queried
      assert count(view) == 1
    end

    # At most once a second: the first change is counted at once, the rest of that second are one
    # recount at its end.
    test "recounts at most once a second", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects")
      watch_queries(view)

      send(view.pid, {:queue_changed, project.id})
      _ = render(view)
      assert_received :queried
      flush_queries()

      stuck!(ticket_fixture(%{project: project}))
      send(view.pid, {:queue_changed, project.id})
      _ = render(view)
      refute_received :queried
      assert count(view) == 0

      # The second's end, which the throttle scheduled for itself.
      send(view.pid, :frame_recount)
      _ = render(view)
      assert_received :queried
      assert count(view) == 1
    end

    # The second's end leaves the frame open again: a change after it is counted at once.
    test "counts at once again after a quiet second", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects")
      watch_queries(view)

      send(view.pid, {:queue_changed, project.id})
      send(view.pid, :frame_recount)
      _ = render(view)
      flush_queries()

      stuck!(ticket_fixture(%{project: project}))
      send(view.pid, {:queue_changed, project.id})
      _ = render(view)
      assert_received :queried
      assert count(view) == 1
    end

    # A busy second's end recounts and keeps the throttle on for one more second, at whose end
    # what changed meanwhile is counted too. Real time: the second's end is the page's own timer.
    test "a busy second's end schedules the next one", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      send(view.pid, {:queue_changed, project.id})
      stuck!(ticket_fixture(%{project: project}))
      send(view.pid, {:queue_changed, project.id})
      assert count(view) == 0
      await_count(view, 1)

      stuck!(ticket_fixture(%{project: project}))
      send(view.pid, {:queue_changed, project.id})
      assert count(view) == 1
      await_count(view, 2)
    end

    # Joining a project while a page is open: the tick reads the viewer's projects again, so a
    # change there is counted from then on rather than filtered as somebody else's.
    test "the tick reads the viewer's projects again", %{conn: conn, user: user, other: other} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      join!(other, user, :member)
      send(view.pid, :capacity_tick)
      _ = render(view)

      stuck!(ticket_fixture(%{project: other}))
      send(view.pid, {:queue_changed, other.id})
      assert count(view) == 1
    end

    test "a ticket's change is announced with its project", %{project: project} do
      ticket = ticket_fixture(%{project: project})
      Events.subscribe_queue()

      Events.notify(ticket.id)
      assert_received {:queue_changed, project_id}
      assert project_id == project.id
    end

    test "a conversation's change is announced with its project", %{project: project} do
      chat = chat_fixture(%{project: project})
      Events.subscribe_queue()

      Events.notify_chat(chat)
      assert_received {:queue_changed, project_id}
      assert project_id == project.id
    end

    # A reply streams one content block at a time, and every open page hears every
    # announcement: only the block that makes the conversation wait on its person changes a queue,
    # so only it is announced. The lists of conversations still hear each one.
    test "a streaming reply is announced to the queue once, on its first words", %{
      project: project
    } do
      chat = chat_fixture(%{project: project, status: :running})
      Events.subscribe_queue()
      Events.subscribe_chats()

      say = fn text ->
        Forge.Jobs.record_harness_event(chat.id, %{
          type: "job.harness.text",
          payload: %{"text" => text}
        })
      end

      say.("  ")
      assert_received {:chat_changed, _, _, _}
      refute_received {:queue_changed, _}

      say.("First words.")
      assert_received {:queue_changed, project_id}
      assert project_id == project.id

      say.("More of the same reply.")
      assert_received {:chat_changed, _, _, _}
      refute_received {:queue_changed, _}

      # A subagent's words are no part of the reply and announce nothing.
      Forge.Jobs.record_harness_event(chat.id, %{
        type: "job.harness.text",
        payload: %{"text" => "report", "parent_tool_use_id" => "t1"}
      })

      refute_received {:queue_changed, _}

      # The person speaks, and the next reply's first words wait on them again.
      {:ok, _} = Forge.Conversations.send(chat, "and then?")
      assert_received {:queue_changed, _}
      say.("Then this.")
      assert_received {:queue_changed, _}
      say.("And this.")
      refute_received {:queue_changed, _}
    end
  end

  describe "the title menu" do
    setup :register_and_log_in_user

    # On a phone the two usage lines are too thin to hit, and only show: the menu's Usage row is
    # the way into the panel, which opens in the menu's place (UX pass, A3).
    test "its Usage row opens the usage panel in place", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      open_menu(view)
      view |> element("#menu-usage") |> render_click()

      refute has_element?(view, "#title-menu")
      assert has_element?(view, "#usage-panel #usage-panel-set", "your 0 credentials")
    end

    # The switch says which part of the product the page is in: a chat's is Chats, not Projects,
    # and a page of no section says Menu (UX pass, A6).
    test "the desktop switch names the page's section", %{conn: conn, user: user} do
      project = project_fixture()
      join!(project, user, :member)
      chat = chat_fixture(%{project: project})

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      assert has_element?(view, "#desktop-header .frame-switch", "Chats")

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")
      assert has_element?(view, "#desktop-header .frame-switch", "Projects")

      {:ok, view, _html} = live(conn, ~p"/chats")
      assert has_element?(view, "#desktop-header .frame-switch", "Chats")
    end

    # Each destination with its state, scoped as the page it leads to is: a project the viewer is
    # not in is not counted, nor what waits there.
    test "names every top-level place with the viewer's own figures", %{conn: conn, user: user} do
      mine = project_fixture()
      join!(mine, user, :member)
      stuck!(ticket_fixture(%{project: mine}))
      quiet = project_fixture()
      join!(quiet, user, :member)

      elsewhere = project_fixture()
      stuck!(ticket_fixture(%{project: elsewhere}))
      _theirs = chat_fixture(%{project: elsewhere})
      _chat = chat_fixture(%{project: mine})
      # Ended: counted, and not live.
      chat_fixture(%{project: mine})
      |> Ecto.Changeset.change(status: :finished, outcome: :converged)
      |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/projects")
      refute has_element?(view, "#title-menu")

      open_menu(view)

      assert text(view, ~s(#title-menu a[href="/"] .frame-menu-state)) == "1 decision"
      # In words read without a key (UX pass, A17, A11).
      assert text(view, ~s(#title-menu a[href="/projects"] .frame-menu-state)) ==
               "2 projects · 1 waits on you"

      assert text(view, ~s(#title-menu a[href="/chats"] .frame-menu-state)) == "▸ 1 live of 2"
      assert text(view, ~s(#title-menu a[href="/workers"] .frame-menu-state)) == "none yet"
      assert text(view, "#menu-usage .frame-menu-state") == "no figures yet"
      # The queue's figure is amber while something waits.
      assert has_element?(view, ~s(#title-menu a[href="/"] .frame-menu-waiting), "1 decision")
      assert has_element?(view, ~s(#title-menu a[href="/projects"][aria-current="page"]))
      assert has_element?(view, "#top-bar .ui-top-menu", "▴")
    end

    test "counts the viewer's machines, busy and idle, and not a destroyed one", %{
      conn: conn,
      user: user
    } do
      for status <- [:busy, :busy, :idle, :destroyed] do
        {:ok, worker, _token} =
          Forge.Workers.create(%{provider: "fake", managed: false, user_id: user.id})

        worker |> Ecto.Changeset.change(status: status) |> Repo.update!()
      end

      {:ok, worker, _token} =
        Forge.Workers.create(%{provider: "fake", managed: false, user_id: user_fixture().id})

      worker |> Ecto.Changeset.change(status: :busy) |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/")
      open_menu(view)

      assert text(view, ~s(#title-menu a[href="/workers"] .frame-menu-state)) == "2 busy · 1 idle"
    end

    # The waiting accounts are node-wide, so only a node admin's menu names them.
    test "names the waiting accounts to a node admin only", %{conn: conn} do
      _waiting = pending_user_fixture()

      {:ok, view, _html} = live(conn, ~p"/")
      open_menu(view)
      refute has_element?(view, "#menu-accounts")

      {:ok, view, _html} = live(log_in_user(build_conn(), node_admin_fixture()), ~p"/")
      open_menu(view)
      assert text(view, ~s(#menu-accounts[href="/accounts"] .frame-menu-state)) == "1 waiting ›"
    end

    # The account, signing out, and the version last. The theme is on You (`user_live/settings`),
    # and not here any more.
    test "ends with the account, sign out and the version", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/")
      open_menu(view)

      menu = view |> element("#title-menu") |> render()
      assert menu =~ user.email
      refute menu =~ "phx:set-theme"

      order =
        for marker <- [
              ~s(href="/users/settings"),
              ~s(href="/users/log-out"),
              ~s(id="menu-version")
            ] do
          {at, _length} = :binary.match(menu, marker)
          at
        end

      assert order == Enum.sort(order)
      assert text(view, "#menu-version") == "forge #{ForgeWeb.Layouts.version()}"
    end

    # The title again, the handle at its foot, or a tap outside folds it.
    test "folds from the title, the handle or the scrim", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      for fold <- [
            fn -> open_menu(view) end,
            fn -> view |> element("#title-menu .frame-handle") |> render_click() end,
            fn -> view |> element(".frame-drop--menu .ui-drop-scrim") |> render_click() end
          ] do
        open_menu(view)
        assert has_element?(view, "#title-menu")
        fold.()
        refute has_element?(view, "#title-menu")
      end
    end

    # Not a top-level page: its title drops its details, not the menu; the header's switch is the
    # menu at every page on a desktop.
    test "is the header's switch on a page that is not top-level", %{conn: conn, user: user} do
      project = project_fixture()
      join!(project, user, :member)
      ticket = ticket_fixture(%{project: project})

      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
      assert has_element?(view, ~s(#top-bar .ui-top-title[phx-click="frame:details"]))

      view |> element("#desktop-header .frame-switch") |> render_click()
      assert has_element?(view, "#title-menu")
    end
  end

  describe "the version" do
    setup :register_and_log_in_user

    test "is beside the wordmark and outside its link", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      version = String.trim(File.read!(Path.expand("../../../../VERSION", __DIR__)))

      assert ForgeWeb.Layouts.version() == version
      assert text(view, "#desktop-header #forge-version") == version
      refute has_element?(view, "#desktop-header a #forge-version")
    end
  end

  describe "the title row" do
    setup :register_and_log_in_user

    # The row's edges are the body's when nothing stands either side of the body, so the title
    # starts where the content does (UX re-check #16); beside a list column it stays at the
    # gutter, over the list.
    test "takes the body's measure on a page with no column either side", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tickets/new")

      assert has_element?(
               view,
               ~s(#title-row.frame-title-row--measured[style*="--frame-measure: 34rem"])
             )

      # A page that says nil runs to the frame's 90rem: no measure of its own on the row either.
      {:ok, view, _html} = live(conn, ~p"/usage")
      assert has_element?(view, "#title-row.frame-title-row--measured")
      refute has_element?(view, ~s(#title-row[style*="--frame-measure"]))

      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#title-row.frame-title-row--measured")
      refute has_element?(view, ~s(#title-row[style*="--frame-measure"]))
    end
  end

  describe "the views" do
    setup :register_and_log_in_user

    # One list, drawn twice: the phone's strip and the desktop title row's tabs.
    test "are the strip and the title row's tabs, from one list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/templates")

      assert has_element?(view, ~s(.frame-strip #tab-machines[href="/workers"]))
      assert has_element?(view, ~s(.frame-strip #tab-templates[aria-current="page"]))
      assert has_element?(view, ~s(#title-row .ui-tabs a[href="/workers"]), "Machines")
      assert has_element?(view, ~s(#title-row .ui-tabs a[aria-current="page"]), "Templates")
    end
  end

  describe "the usage lines" do
    setup :register_and_log_in_user

    setup %{user: user} do
      project = project_fixture()
      join!(project, user, :member)
      colleague = user_fixture()
      join!(project, colleague, :member)

      mine = pool!(project, credential_fixture(user))
      theirs = pool!(project, credential_fixture(colleague))

      # Somebody else's, in a project the viewer is not in: on no page of theirs, ever.
      elsewhere = project_fixture()
      stranger = pool!(elsewhere, credential_fixture(user_fixture()))

      reports!(project, mine, "allowed_warning", 0.9)
      reports!(project, theirs, "rejected", nil)
      reports!(elsewhere, stranger, "allowed_warning", 0.1)

      # The viewer's own, in the pool, reported — and revoked since: it funds nothing any more,
      # so it is in no line, theirs or the project's.
      gone = pool!(project, credential_fixture(user))
      reports!(project, gone, "allowed_warning", 0.1)
      {:ok, _} = Forge.Credentials.revoke(user, gone.id)

      %{project: project}
    end

    defp reports!(project, credential, status, utilization, windows \\ nil) do
      job = chat_fixture(%{project: project})

      Repo.update_all(from(j in Jobs.Job, where: j.id == ^job.id),
        set: [credential_id: credential.id]
      )

      :ok =
        Jobs.record_harness_event(job.id, %{
          type: "job.harness.rate_limit",
          payload: %{
            status: status,
            rate_limit_type: "five_hour",
            utilization: utilization,
            resets_at: System.os_time(:second) + 3600,
            windows: windows
          }
        })
    end

    defp line(view, window) do
      [value] =
        view
        |> element("#usage-#{window}")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.attribute("aria-valuenow")

      String.to_integer(value)
    end

    test "draw the viewer's own credentials away from a project", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert line(view, "5h") == 90
      assert text(view, "#usage-digits") == "90% 5h · — wk"
      assert has_element?(view, "#usage-week.ui-usage--empty")
    end

    # Every page about one project — the project, its settings and repository, a ticket, its
    # Changes, a job, a conversation — each switching once it has allowed the viewer.
    test "draw the project's pool on a page about it, other members' included", %{
      conn: conn,
      project: project
    } do
      ticket = ticket_fixture(%{project: project})

      job =
        job_fixture(%{
          ticket: ticket,
          spec: %{"prompt" => "agents/refine.md", "budget" => %{"turns" => 20, "cost" => 0.5}}
        })

      chat = chat_fixture(%{project: project})

      for path <- [
            ~p"/projects/#{project.name}",
            ~p"/projects/#{project.name}/settings",
            ~p"/tickets/#{project.name}/#{ticket.number}",
            ~p"/tickets/#{project.name}/#{ticket.number}?tab=changes",
            ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}",
            ~p"/chats/#{chat.id}"
          ] do
        {:ok, view, _html} = live(conn, path)

        # Its own 0.9 and the colleague's limited credential, counted as full: 0.95.
        assert line(view, "5h") == 95, path
      end
    end

    # Ticket 32: a report naming both windows and then one naming only the five-hour must not
    # take the week off the bar.
    test "keep the week after a newer report that names only the five-hour window", %{
      conn: conn,
      user: user,
      project: project
    } do
      credential = pool!(project, credential_fixture(user))
      hour = System.os_time(:second) + 3600
      week = System.os_time(:second) + 3 * 86_400

      reports!(project, credential, "allowed", nil, %{
        "five_hour" => %{"resets_at" => hour, "utilization" => 0.01},
        "seven_day" => %{"resets_at" => week, "utilization" => 0.3}
      })

      reports!(project, credential, "allowed", nil, %{
        "five_hour" => %{"resets_at" => hour, "utilization" => 0.02}
      })

      {:ok, view, _html} = live(conn, ~p"/")
      assert line(view, "week") == 30
    end

    test "are redrawn on the tick", %{conn: conn, user: user, project: project} do
      {:ok, view, _html} = live(conn, ~p"/")

      reports!(project, credential_fixture(user), "allowed_warning", 0.5)
      send(view.pid, :capacity_tick)

      assert line(view, "5h") == 70
    end

    # A window known but with no figure draws no fill: an empty set never reads as 0 %.
    test "draw no fill for a window with no figure, and nothing for nothing reported", %{
      conn: conn,
      project: project
    } do
      other = user_fixture()
      reports!(project, credential_fixture(other), "allowed", nil)

      {:ok, view, _html} = live(log_in_user(build_conn(), other), ~p"/")
      assert has_element?(view, "#usage-5h.ui-usage--empty")
      refute has_element?(view, "#usage-5h[role=meter]")

      {:ok, view, _html} = live(log_in_user(conn, user_fixture()), ~p"/")
      assert has_element?(view, "#usage-5h.ui-usage--empty")
      refute has_element?(view, "#usage-digits")
    end

    # 22e: tapping either line drops the panel, whose figures are the lines' own; the desktop
    # digits lead to `/usage` instead.
    test "open the usage panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#usage-panel")

      view |> element("#usage-5h") |> render_click()
      assert text(view, "#usage-panel-five_hour .frame-usage-figure") == "90%"
      assert text(view, "#usage-panel-five_hour") =~ "1 of 1 credential reporting"
      assert text(view, "#usage-panel-seven_day") =~ "No credential has reported this window."

      view |> element("#usage-week") |> render_click()
      refute has_element?(view, "#usage-panel")
      assert has_element?(view, ~s(a#usage-digits[href="/usage"]))
    end
  end

  describe "a passing message" do
    setup :register_and_log_in_user

    defp with_flash(conn, flash),
      do: Plug.Test.init_test_session(conn, %{"phoenix_flash" => flash})

    # 20b: a success is one toast that cannot be tapped — title and detail split on the first
    # newline — and a failure is never one (`docs/design/ui.md` § Toasts, § Errors stay where you
    # acted).
    test "a success is exactly one toast, with no button, that taps pass through", %{conn: conn} do
      conn = with_flash(conn, %{"info" => "Approved changeset v1\nmerging started"})
      {:ok, view, _html} = live(conn, ~p"/projects")

      assert [_] =
               view
               |> render()
               |> LazyHTML.from_document()
               |> LazyHTML.query("#toast")
               |> Enum.to_list()

      assert has_element?(view, "#toast .ui-toast.pointer-events-none[role=status]")
      assert text(view, "#toast .ui-toast-title") == "Approved changeset v1"
      assert text(view, "#toast .ui-toast-detail") == "merging started"
      refute has_element?(view, "#toast button")
    end

    # Errors are drawn where they were made (`ui.md` § Errors stay where you acted), so the frame
    # draws no `:error` flash at all: neither a toast nor a line of its own.
    test "a failure is never the frame's: no toast and no line", %{conn: conn} do
      conn = with_flash(conn, %{"error" => "Could not merge"})
      {:ok, view, html} = live(conn, ~p"/projects")

      refute has_element?(view, "#toast")
      refute has_element?(view, ".ui-toast")
      refute html =~ "Could not merge"
      refute render(view) =~ "Could not merge"
    end

    test "the sign-in screens draw the toast" do
      flash = %{"info" => "Logged out successfully."}
      conn = build_conn() |> log_in_user(pending_user_fixture()) |> with_flash(flash)

      {:ok, view, _html} = live(conn, ~p"/users/pending")

      assert has_element?(view, "#toast .ui-toast-title", "Logged out successfully.")
    end

    # Signing in draws its refusal where it was made (`ui.md` § Signing in): every refusal that
    # comes back to it carries the `:sign_in_error` flash, and only that page reads it.
    test "signing in draws the toast, and its refusal in place" do
      conn =
        with_flash(build_conn(), %{
          "info" => "Logged out successfully.",
          "sign_in_error" => "Expired"
        })

      {:ok, view, _html} = live(conn, ~p"/users/log-in")

      assert has_element?(view, "#toast .ui-toast-title", "Logged out successfully.")
      assert has_element?(view, "#sign-in-password-error", "Expired")
      refute has_element?(view, ".ui-toast", "Expired")
    end

    test "is put with its detail on a socket and on a conn, and split back", %{conn: conn} do
      assert ForgeWeb.Toast.split("Merged\nmain at abc123") == {"Merged", "main at abc123"}
      assert ForgeWeb.Toast.split("Merged") == {"Merged", nil}
      assert ForgeWeb.Toast.split("Merged\n  ") == {"Merged", nil}

      conn = conn |> Phoenix.ConnTest.fetch_flash() |> ForgeWeb.Toast.put("Merged", "main")
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Merged\nmain"

      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
      assert ForgeWeb.Toast.put(socket, "Merged").assigns.flash == %{"info" => "Merged"}
    end
  end

  describe "the connection" do
    setup :register_and_log_in_user

    # What the `Connection` hook needs of the markup (the browser test drives the hook itself):
    # LiveView's own bindings on the frame's top, and, in the phone bar and the desktop header,
    # the words it shows in place of the title and the line it writes the countdown into.
    test "is the frame's top's to draw, in the bar and in the header", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      assert has_element?(
               view,
               "#frame-top[phx-hook=Connection][phx-disconnected][phx-connected]"
             )

      assert has_element?(view, "#top-bar .ui-top-title .ui-top-offline", "Not connected")
      assert has_element?(view, "#top-bar .ui-top-offline [data-connection-line]")
      assert has_element?(view, "#desktop-header .frame-offline", "Not connected")
      assert has_element?(view, "#desktop-header .frame-offline [data-connection-line]")
    end
  end
end
