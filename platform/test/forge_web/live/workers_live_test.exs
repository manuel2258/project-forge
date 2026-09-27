defmodule ForgeWeb.WorkersLiveTest do
  @moduledoc """
  The machines, and the one column the CLI cannot have.

  Connection lives in a registry inside the running platform, so the case worth pinning down is
  a row that is `ready` and *not* connected: a machine healthy on every other surface that
  cannot take work. See `docs/design/ui.md` § The workers page.
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Forge.Workers

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:forge, Workers, [])
    on_exit(fn -> Application.put_env(:forge, Workers, previous) end)
    :ok
  end

  # Owned by the logged-in operator, because the page shows its viewer's own machines and nobody
  # else's (`docs/design/identity.md` § Workers).
  # A repository of the test's own, removed when it ends: `Projects.register/2` creates one on
  # disk, and a fixed path would be shared by every test and every run that used it.
  defp repo_path, do: Path.join(Forge.GitFixtures.tmp_dir("workers-live"), "p.git")

  defp worker(owner, attrs \\ %{}) do
    {:ok, worker, _token} =
      Workers.create(Map.merge(%{provider: "fake", managed: true, user_id: owner.id}, attrs))

    worker
  end

  test "an empty fleet names what would fill it", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/workers")

    assert html =~ "You have no machines"
    assert html =~ "mix forge.worker.new"
  end

  test "a row that is up but holds no channel says both", %{conn: conn, user: user} do
    w = worker(user)
    {:ok, w} = Workers.ready(w, %{"memory_budget" => 6 * 1024 * 1024 * 1024})

    {:ok, _view, html} = live(conn, ~p"/workers")

    assert html =~ String.slice(w.id, 0, 8)
    # Up with nothing to do is idle (`Forge.Workers.ready/2`).
    assert html =~ "idle"

    # The point of the page: the database says it is up, the registry says otherwise.
    assert html =~ "not connected"
    assert html =~ "0 connected"
  end

  # A machine minted without a working credential joins, reports ready, and then fails every job
  # it is given with *Not logged in*. The probe at `ready` is what makes that visible before the
  # first job instead of after it — docs/design/worker-channel.md § What a worker offers.
  test "a worker that is not logged in says so before it is given work", %{conn: conn, user: user} do
    w = worker(user)

    {:ok, _w} =
      Workers.ready(w, %{
        "memory_budget" => 6 * 1024 * 1024 * 1024,
        "harness" => %{
          "name" => "Claude Code",
          "version" => "2.1.220",
          "login" => "invalid",
          "models" => []
        }
      })

    {:ok, _view, html} = live(conn, ~p"/workers")

    assert html =~ "Claude Code"
    assert html =~ "2.1.220"
    assert html =~ "login invalid"
  end

  # A machine that looks healthy everywhere and is given no agent job is the state worth saying:
  # its release predates a job carrying its credential, so the gate passes it by
  # (`docs/design/credentials.md` § What a worker offers now).
  test "a machine whose release does not take a job's credential says it takes no agent job", %{
    conn: conn,
    user: user
  } do
    old = worker(user)

    {:ok, _} =
      Workers.ready(old, %{"memory_budget" => 8_000, "harness" => %{"driver" => "claude_code"}})

    current = worker(user)

    {:ok, _} =
      Workers.ready(current, %{
        "memory_budget" => 8_000,
        "harness" => %{"driver" => "claude_code", "credential" => "per_job"}
      })

    {:ok, view, _html} = live(conn, ~p"/workers")

    assert view |> element("#worker-#{old.id}") |> render() =~ "takes no agent job"
    refute view |> element("#worker-#{current.id}") |> render() =~ "takes no agent job"
  end

  # A worker running a release older than the probe reports no harness at all, and is still a
  # worker: the column shows a dash rather than the page failing to render.
  test "a worker that reported no harness still renders", %{conn: conn, user: user} do
    w = worker(user)
    {:ok, _w} = Workers.ready(w, %{"memory_budget" => 6 * 1024 * 1024 * 1024})

    {:ok, _view, html} = live(conn, ~p"/workers")

    assert html =~ String.slice(w.id, 0, 8)
    refute html =~ "login"
  end

  test "a connected worker is shown as connected", %{conn: conn, user: user} do
    w = worker(user)
    {:ok, _w} = Workers.ready(w, %{"memory_budget" => 6 * 1024 * 1024 * 1024})

    # Registering is what a channel does when it joins; this process stands in for one.
    :ok = Workers.connected(w.id)

    {:ok, _view, html} = live(conn, ~p"/workers")

    assert html =~ "1 connected"
    refute html =~ "not connected"
  end

  # Capacity is two figures now, because the gate reads two. It used to be a count of identical
  # slices, and every clause of that sentence stopped being true when a job could declare what
  # it needs — see `docs/design/ui.md` § The workers page.
  test "capacity is shown in both dimensions the gate reads", %{conn: conn, user: user} do
    # Merged, not replaced: replacing drops every other key and silently changes what the page
    # reads the first time one of them stops having a call-site default.
    current = Application.get_env(:forge, Workers, [])

    Application.put_env(
      :forge,
      Workers,
      Keyword.put(current, :slice_bytes, 2 * 1024 * 1024 * 1024)
    )

    w = worker(user)
    {:ok, _w} = Workers.ready(w, %{"memory_budget" => 6 * 1024 * 1024 * 1024, "cores" => 8})

    {:ok, _view, html} = live(conn, ~p"/workers")

    assert html =~ "6.0 GiB of 6.0 GiB free"
    assert html =~ "8 of 8 cores free"

    # And nothing about a disagreement, because there is not one. A machine agreeing with its
    # row is the ordinary case and must stay quiet, or the warning means nothing when it fires.
    refute html =~ "reports"
  end

  # A machine that has never reported cores is not gated on them, so the page must not invent a
  # figure — saying "0 of 0" would read as a machine that can hold nothing, which is the exact
  # opposite of what the gate does with it.
  test "a machine that has not reported cores says so rather than showing none", %{
    conn: conn,
    user: user
  } do
    w = worker(user)
    {:ok, _w} = Workers.ready(w, %{"memory_budget" => 6 * 1024 * 1024 * 1024})

    {:ok, _view, html} = live(conn, ~p"/workers")

    assert html =~ "cores not reported"
    refute html =~ "0 of 0 cores"
  end

  # The row governs the gate, so a machine reporting less than its row is one the platform will
  # overcommit — and the per-job ceiling cannot catch that, because what breaks is the sum.
  # Silently resolving it either way is what this refuses to do.
  test "a machine whose report disagrees with its row shows both", %{conn: conn, user: user} do
    w = worker(user)
    {:ok, w} = Workers.ready(w, %{"memory_budget" => 6 * 1024 * 1024 * 1024, "cores" => 8})
    {:ok, w} = Workers.update(w, %{memory_budget: 2 * 1024 * 1024 * 1024, cores: 2})

    {:ok, _} = Workers.ready(w, %{"memory_budget" => 6 * 1024 * 1024 * 1024, "cores" => 8})

    {:ok, _view, html} = live(conn, ~p"/workers")

    # The row is what the gate reads and what the page leads with.
    assert html =~ "2.0 GiB of 2.0 GiB free"
    assert html =~ "2 of 2 cores free"
    # And what the machine says is shown beside it rather than thrown away.
    assert html =~ "reports memory 6.0 GiB, cores 8"
  end

  # A machine that was never made is the row an operator most needs told about, and until this
  # was drawn a driver refusing to create was invisible on every surface they have.
  test "a row that never became a machine says why", %{conn: conn, user: user} do
    w = worker(user)
    {:ok, _} = Workers.update(w, %{last_error: "no Hetzner image configured"})

    {:ok, _view, html} = live(conn, ~p"/workers")

    assert html =~ "never made: no Hetzner image configured"
  end

  test "a row that did become a machine says nothing of the sort", %{conn: conn, user: user} do
    w = worker(user)
    {:ok, _} = Workers.ready(w, %{"memory_budget" => 8_000, "cores" => 4})

    {:ok, _view, html} = live(conn, ~p"/workers")

    refute html =~ "never made"
  end

  describe "setting what a permanent machine offers" do
    # The edit the whole "row governs" rule exists to protect. Without a way to make one, the
    # rule defends something nobody can do.
    test "a permanent machine's figures are the operator's, and survive a reconnect", %{
      conn: conn,
      user: user
    } do
      w = worker(user, %{managed: false})
      {:ok, w} = Workers.ready(w, %{"memory_budget" => 6 * 1024 * 1024 * 1024, "cores" => 8})

      {:ok, view, _html} = live(conn, ~p"/workers")

      view |> element("a[phx-click=edit][phx-value-id=\"#{w.id}\"]") |> render_click()

      html =
        view
        |> element("form[phx-submit=save]")
        |> render_submit(%{
          "worker_id" => w.id,
          "memory" => "2GiB",
          "cores" => "2",
          "accepts_chat" => "true"
        })

      assert html =~ "2.0 GiB of 2.0 GiB free"
      assert html =~ "2 of 2 cores free"
      assert html =~ "takes chat"

      # And the machine saying its original piece again does not undo it.
      {:ok, _} = Workers.ready(Workers.get!(w.id), %{"memory_budget" => 6_000_000, "cores" => 8})

      reloaded = Workers.get!(w.id)
      assert reloaded.memory_budget == 2 * 1024 * 1024 * 1024
      assert reloaded.cores == 2
      assert reloaded.accepts == [:chat]
    end

    # A machine the platform made is replaced rather than corrected, so an edit would have a
    # lifetime of one idle period. Refused on the server, not merely hidden — the id is off the
    # wire and `identity.md` § Sequencing records what hiding a form is worth.
    test "a managed machine is refused even when the id is supplied by hand", %{
      conn: conn,
      user: user
    } do
      permanent = worker(user, %{managed: false})
      managed = worker(user, %{managed: true})
      {:ok, _} = Workers.ready(managed, %{"memory_budget" => 8_000, "cores" => 4})
      {:ok, _} = Workers.ready(permanent, %{"memory_budget" => 8_000, "cores" => 4})

      {:ok, view, _html} = live(conn, ~p"/workers")

      view
      |> element("a[phx-click=edit][phx-value-id=\"#{permanent.id}\"]")
      |> render_click()

      html =
        view
        |> element("form[phx-submit=save]")
        |> render_submit(%{"worker_id" => managed.id, "memory" => "1GiB", "cores" => "1"})

      assert html =~ "replaced, not edited"
      assert Workers.get!(managed.id).memory_budget == 8_000
    end

    # Blank must not be read as "nothing said" here: this form *sets* what a machine offers,
    # and an empty memory field would silently un-gate the machine it was meant to correct.
    test "figures that are not figures are refused rather than stored", %{conn: conn, user: user} do
      w = worker(user, %{managed: false})
      {:ok, _} = Workers.ready(w, %{"memory_budget" => 8_000, "cores" => 4})

      {:ok, view, _html} = live(conn, ~p"/workers")
      view |> element("a[phx-click=edit][phx-value-id=\"#{w.id}\"]") |> render_click()

      # Each blank on its own as well as both: a page that read one of them as zero would store
      # it, zero being an offer, whenever the other was filled in.
      for {memory, cores} <- [{"", ""}, {"", "2"}, {"2GiB", ""}] do
        html =
          view
          |> element("form[phx-submit=save]")
          |> render_submit(%{"worker_id" => w.id, "memory" => memory, "cores" => cores})

        assert html =~ "not figures a machine can have", inspect({memory, cores})
        saved = Workers.get!(w.id)
        assert {saved.memory_budget, saved.cores} == {8_000, 4}, inspect({memory, cores})
      end
    end
  end

  describe "whose machines, and which projects they serve" do
    # Another person's row names the projects it serves, and a project a person is not in is not
    # one they may learn exists.
    test "only the viewer's own machines are listed", %{conn: conn, user: user} do
      mine = worker(user)
      theirs = worker(Forge.AccountsFixtures.user_fixture())

      {:ok, _view, html} = live(conn, ~p"/workers")

      assert html =~ String.slice(mine.id, 0, 8)
      refute html =~ String.slice(theirs.id, 0, 8)
    end

    test "a permanent machine is assigned to a project and taken out again", %{
      conn: conn,
      user: user
    } do
      {:ok, project} = Forge.Projects.register(%{name: "served", repo_path: repo_path()}, user)
      w = worker(user, %{managed: false})

      {:ok, view, html} = live(conn, ~p"/workers")
      assert html =~ "no project, so it takes no work"

      html =
        view
        |> element("#worker-#{w.id} form[phx-submit=assign]")
        |> render_submit(%{"worker" => w.id, "project" => project.id})

      refute html =~ "takes no work"
      assert [%{name: "served"}] = Workers.projects(w)

      view
      |> element(~s(button[phx-click=unassign][phx-value-project="#{project.id}"]))
      |> render_click()

      assert Workers.projects(w) == []
    end

    test "a machine the platform made names the template it serves through", %{
      conn: conn,
      user: user
    } do
      {:ok, project} = Forge.Projects.register(%{name: "through", repo_path: repo_path()}, user)

      {:ok, template} =
        Forge.Provisioning.create_template(user, %{
          name: "agents",
          provider: "fake",
          memory: 8_000,
          cores: 2
        })

      {:ok, _} = Forge.Provisioning.assign(user, template.id, project.id)
      worker(user, Forge.Provisioning.Template.worker_attrs(template))

      {:ok, _view, html} = live(conn, ~p"/workers")

      assert html =~ "serves through template agents:"
      assert html =~ "through"
    end

    # The ids are the client's. Neither another person's machine nor a project the viewer is not
    # in is reachable by sending them by hand.
    test "somebody else's machine is neither edited nor assigned from here", %{
      conn: conn,
      user: user
    } do
      {:ok, project} = Forge.Projects.register(%{name: "mine", repo_path: repo_path()}, user)
      mine = worker(user, %{managed: false})
      theirs = worker(Forge.AccountsFixtures.user_fixture(), %{managed: false})
      {:ok, _} = Workers.ready(theirs, %{"memory_budget" => 8_000, "cores" => 4})

      {:ok, view, _html} = live(conn, ~p"/workers")
      view |> element("a[phx-click=edit][phx-value-id=\"#{mine.id}\"]") |> render_click()

      html =
        view
        |> element("form[phx-submit=save]")
        |> render_submit(%{"worker_id" => theirs.id, "memory" => "1GiB", "cores" => "1"})

      assert html =~ "that machine is not here"
      assert Workers.get!(theirs.id).memory_budget == 8_000

      render_submit(view, "assign", %{"worker" => theirs.id, "project" => project.id})
      assert Workers.projects(theirs) == []
    end
  end

  test "managed and permanent are distinguished", %{conn: conn, user: user} do
    kept = worker(user, %{managed: true})
    permanent = worker(user, %{managed: false})

    {:ok, view, _html} = live(conn, ~p"/workers")

    # Tied to the row, not merely present on the page: asserting both words appear passes just
    # as well when the two labels are swapped.
    assert view |> element("#worker-#{kept.id}") |> render() =~ "managed"
    assert view |> element("#worker-#{permanent.id}") |> render() =~ "permanent"
  end

  test "destroyed rows are history and are hidden until asked for", %{conn: conn, user: user} do
    w = worker(user)
    {:ok, _w} = Workers.status(w, :destroyed)

    {:ok, view, html} = live(conn, ~p"/workers")
    refute html =~ String.slice(w.id, 0, 8)

    assert view |> element("button", "Show destroyed") |> render_click() =~
             String.slice(w.id, 0, 8)
  end

  describe "how full a machine is" do
    # The test process stands in for the machine's channel: it is what registers, and the only
    # process that may set the figures it registered (`worker-channel.md` § Live figures).
    defp reporting(worker, stats) do
      :ok = Workers.connected(worker.id)
      :ok = Workers.put_stats(worker.id, stats)
    end

    test "three meters, from the machine's own last report", %{conn: conn, user: user} do
      w = worker(user)
      {:ok, w} = Workers.ready(w, %{"memory_budget" => 8_000_000_000, "cores" => 4})

      reporting(w, %{
        "cpu" => 23.4,
        "memory_used" => 4 * 1024 * 1024 * 1024,
        "memory_total" => 16 * 1024 * 1024 * 1024,
        "disk_used" => 30 * 1024 * 1024 * 1024,
        "disk_total" => 100 * 1024 * 1024 * 1024
      })

      {:ok, view, _html} = live(conn, ~p"/workers")
      row = view |> element("#worker-#{w.id}") |> render()

      assert row =~ "23%"
      assert row =~ "of 4 cores"
      assert row =~ "25%"
      assert row =~ "4.0 GiB of 16.0 GiB"
      assert row =~ "30%"
      assert row =~ "30.0 GiB of 100.0 GiB"
      refute row =~ "disk nearly full"

      # Neutral, never accent: a full machine is not waiting on a human (`ui.md` § Colour).
      refute row =~ "accent"
    end

    # A full disk fails jobs rather than slowing them, so it is said as well as drawn.
    test "a disk at 95% or more says so, and one below it does not", %{conn: conn, user: user} do
      full = worker(user)
      nearly = worker(user)
      spawn_channel(nearly, %{"disk_used" => 94, "disk_total" => 100})
      spawn_channel(full, %{"disk_used" => 95, "disk_total" => 100})

      {:ok, view, _html} = live(conn, ~p"/workers")

      assert view |> element("#worker-#{full.id}") |> render() =~ "disk nearly full"
      refute view |> element("#worker-#{nearly.id}") |> render() =~ "disk nearly full"
    end

    # A figure the machine could not read is not drawn as an empty bar, which would say nothing
    # is used.
    test "a figure the machine could not read is a dash, not a zero", %{conn: conn, user: user} do
      w = worker(user)
      reporting(w, %{"cpu" => 10.0})

      {:ok, view, _html} = live(conn, ~p"/workers")
      row = view |> element("#worker-#{w.id}") |> render()

      assert row =~ "10%"
      # One bar, the CPU's: the other two figures could not be read and have none.
      assert length(Regex.scan(~r/style="width:/, row)) == 1
    end

    # A release from before the figures existed sends none, which is the thing to say.
    test "a connected machine that sends none is told to update", %{conn: conn, user: user} do
      w = worker(user)
      :ok = Workers.connected(w.id)

      {:ok, view, _html} = live(conn, ~p"/workers")

      assert view |> element("#worker-#{w.id}") |> render() =~ "no stats — update it"
    end

    # A release that speaks a protocol sends figures from its first tick, seconds after it joins:
    # it has none *yet*, and telling its owner to update it would be wrong.
    test "a current release that has not reported yet is not told to update", %{
      conn: conn,
      user: user
    } do
      w = worker(user)
      :ok = Workers.admit(w.id, %{"protocol" => ForgeCore.WorkerProtocol.current()})
      :ok = Workers.connected(w.id)

      {:ok, view, _html} = live(conn, ~p"/workers")
      row = view |> element("#worker-#{w.id}") |> render()

      assert row =~ "no stats yet"
      refute row =~ "no stats — update it"
    end

    # Guards on the arithmetic: a total of nothing is no percentage, a figure past its total is
    # drawn full rather than past the edge, and a detail line is drawn only for a figure there is.
    test "a meter draws only what adds up", %{conn: conn, user: user} do
      w = worker(user)

      reporting(w, %{
        "cpu" => 5.0,
        "memory_used" => 10,
        "memory_total" => 0,
        "disk_used" => 300,
        "disk_total" => 200
      })

      {:ok, view, _html} = live(conn, ~p"/workers")
      row = view |> element("#worker-#{w.id}") |> render()
      text = text_of(view, "#worker-#{w.id}")

      assert row =~ "width: 100%"
      assert text =~ "disk 100%"
      assert text =~ "ram —"
      refute text =~ "— of —"
      # No cores on the row, so none under the CPU figure either.
      refute text =~ "of cores"
    end

    # Its last figures would be a guess about now.
    test "a machine that is not connected draws no meters", %{conn: conn, user: user} do
      w = worker(user)

      {:ok, view, _html} = live(conn, ~p"/workers")
      row = view |> element("#worker-#{w.id}") |> render()

      refute row =~ "no stats"
      refute row =~ ~r/>\s*ram\s*</
      refute row =~ ~r/>\s*cpu\s*</
    end

    test "are read again on the page's refresh", %{conn: conn, user: user} do
      w = worker(user)
      reporting(w, %{"cpu" => 10.0})

      {:ok, view, _html} = live(conn, ~p"/workers")
      :ok = Workers.put_stats(w.id, %{"cpu" => 77.0})
      send(view.pid, :refresh)

      assert view |> element("#worker-#{w.id}") |> render() =~ "77%"
    end

    # And the page sends itself that refresh: the setting is there only so this need not wait
    # five seconds to see it.
    test "the page asks again by itself", %{conn: conn, user: user} do
      Application.put_env(
        :forge,
        Workers,
        Keyword.put(Application.get_env(:forge, Workers, []), :page_refresh_ms, 20)
      )

      w = worker(user)
      reporting(w, %{"cpu" => 10.0})

      {:ok, view, _html} = live(conn, ~p"/workers")
      :ok = Workers.put_stats(w.id, %{"cpu" => 77.0})

      assert Enum.any?(1..50, fn _ ->
               Process.sleep(20)
               view |> element("#worker-#{w.id}") |> render() =~ "77%"
             end)
    end
  end

  # What a reader sees in an element: its text, with the markup and the line breaks the template
  # puts between one span and the next taken out.
  defp text_of(view, selector) do
    view
    |> element(selector)
    |> render()
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/, " ")
  end

  # A process that holds a machine's channel for the rest of the test, for a test that needs more
  # than one machine connected — the test process can hold only one registration per id, and
  # stands in for one channel at a time.
  defp spawn_channel(worker, stats) do
    test = self()

    pid =
      spawn(fn ->
        :ok = Workers.connected(worker.id)
        :ok = Workers.put_stats(worker.id, stats)
        send(test, {:registered, worker.id})
        Process.sleep(:infinity)
      end)

    assert_receive {:registered, _id}
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  describe "what a machine runs" do
    setup do
      previous = Application.get_env(:forge, Workers, [])

      Application.put_env(
        :forge,
        Workers,
        Keyword.put(previous, :current_build, "8rh57whmgk6m")
      )

      :ok
    end

    test "its release, and whether it is the build this platform ships", %{
      conn: conn,
      user: user
    } do
      current = worker(user)
      other = worker(user)
      silent = worker(user)

      :ok =
        Workers.admit(current.id, %{
          "release" => "0.2.1 (8rh57whmgk6m)",
          "build" => "8rh57whmgk6m"
        })

      :ok =
        Workers.admit(other.id, %{"release" => "0.2.0 (aaaaaaaaaaaa)", "build" => "aaaaaaaaaaaa"})

      {:ok, view, _html} = live(conn, ~p"/workers")

      assert text_of(view, "#worker-#{current.id}") =~ "0.2.1 (8rh57whmgk6m) · current"
      assert text_of(view, "#worker-#{other.id}") =~ "0.2.0 (aaaaaaaaaaaa) · other build"

      # Not joined since the release was on the wire: nothing to compare.
      refute view |> element("#worker-#{silent.id}") |> render() =~ "build"
    end

    # A release too old to say is protocol 0, and not running the build this platform ships.
    test "a machine that said nothing is not current", %{conn: conn, user: user} do
      w = worker(user)
      :ok = Workers.admit(w.id, %{})

      {:ok, view, _html} = live(conn, ~p"/workers")

      assert text_of(view, "#worker-#{w.id}") =~ "release not reported · other build"
    end

    # A node built outside Nix knows no build of its own, and a hint there would be invented.
    test "a node that knows no build draws no hint", %{conn: conn, user: user} do
      Application.put_env(
        :forge,
        Workers,
        Keyword.delete(Application.get_env(:forge, Workers), :current_build)
      )

      w = worker(user)
      :ok = Workers.admit(w.id, %{"release" => "0.2.1 (8rh57whmgk6m)", "build" => "8rh57whmgk6m"})

      {:ok, view, _html} = live(conn, ~p"/workers")
      row = view |> element("#worker-#{w.id}") |> render()

      assert row =~ "0.2.1 (8rh57whmgk6m)"
      refute row =~ "current"
      refute row =~ "other build"
    end

    test "a machine turned away says why, and what would be taken", %{conn: conn, user: user} do
      w = worker(user, %{managed: false})
      too_new = ForgeCore.WorkerProtocol.current() + 1
      {:error, _} = Workers.admit(w.id, %{"protocol" => too_new})

      {:ok, view, _html} = live(conn, ~p"/workers")

      assert view |> element("#worker-#{w.id}") |> render() =~
               "refused: protocol #{too_new}, this platform accepts " <>
                 "#{ForgeCore.WorkerProtocol.range()} — update it"
    end

    test "a machine that was taken says nothing of the sort", %{conn: conn, user: user} do
      w = worker(user, %{managed: false})
      :ok = Workers.admit(w.id, %{"protocol" => ForgeCore.WorkerProtocol.current()})

      {:ok, view, _html} = live(conn, ~p"/workers")

      refute view |> element("#worker-#{w.id}") |> render() =~ "refused"
    end
  end

  describe "ending a machine" do
    setup do
      Forge.Provider.Fake.watch()
      on_exit(&Forge.Provider.Fake.allow/0)
      :ok
    end

    defp running_on(worker) do
      Forge.ForgeFixtures.job_fixture(%{status: :running, worker_id: worker.id})
    end

    test "a managed machine is destroyed at the provider, and its work requeued", %{
      conn: conn,
      user: user
    } do
      w = worker(user, %{managed: true, provider_id: "fake-7"})
      job = running_on(w)

      {:ok, view, _html} = live(conn, ~p"/workers")
      button = element(view, "#worker-#{w.id} button[phx-click=destroy]")

      assert render(button) =~ "Destroy machine"
      # The confirm says what will happen, from the one definition of it.
      assert render(button) =~ "It is deleted at the provider, and its 1 running job is requeued."

      html = render_click(button)

      assert_receive {:provider_destroy, "fake-7", _credential}
      assert Workers.get!(w.id).status == :destroyed
      assert Forge.Jobs.get!(job.id).status == :pending
      # History now, and hidden until asked for.
      assert html =~ "is gone; its 1 running job is requeued"
      refute has_element?(view, "#worker-#{w.id}")
    end

    test "a permanent machine is retired: forgotten, and left running", %{
      conn: conn,
      user: user
    } do
      w = worker(user, %{managed: false})

      {:ok, view, _html} = live(conn, ~p"/workers")
      button = element(view, "#worker-#{w.id} button[phx-click=destroy]")

      assert render(button) =~ "Retire"
      assert render(button) =~ "the machine itself keeps running"
      assert render(button) =~ "nothing is running on it to requeue"

      render_click(button)

      refute_receive {:provider_destroy, _id, _credential}
      assert Workers.get!(w.id).status == :destroyed
    end

    # The row is the platform's claim that nothing is billing, so a refusal leaves it — with the
    # driver's words, and the host-side way out named, since force is not on this page.
    test "a destroy the provider refuses keeps the row and says what to do", %{
      conn: conn,
      user: user
    } do
      Forge.Provider.Fake.refuse_destroy({:fake, "the API is down"})
      w = worker(user, %{managed: true, provider_id: "fake-7"})

      {:ok, view, _html} = live(conn, ~p"/workers")
      html = view |> element("#worker-#{w.id} button[phx-click=destroy]") |> render_click()

      assert Workers.get!(w.id).status != :destroyed
      assert view |> element("#worker-#{w.id}") |> render() =~ "the API is down"
      assert html =~ "mix forge.worker.retire #{w.id} --force"
      # And no promise of a retry: the sweeps retry only a machine that is unreachable or idle,
      # and one somebody just pressed Destroy on is usually neither.
      assert html =~ "The row stays, so the machine is still counted."
      refute html =~ "sweep"
    end

    # The id is the client's, modelled on the other two decisions: somebody else's machine is
    # neither edited, assigned nor ended from here.
    test "somebody else's machine is not ended from here", %{conn: conn, user: user} do
      mine = worker(user)
      theirs = worker(Forge.AccountsFixtures.user_fixture(), %{provider_id: "fake-8"})

      {:ok, view, _html} = live(conn, ~p"/workers")
      assert has_element?(view, "#worker-#{mine.id}")

      html = render_click(view, "destroy", %{"id" => theirs.id})

      assert html =~ "that machine is not here"
      refute_receive {:provider_destroy, _id, _credential}
      assert Workers.get!(theirs.id).status == :creating
    end

    test "the confirm counts every job it will requeue", %{conn: conn, user: user} do
      w = worker(user, %{managed: true})
      running_on(w)
      running_on(w)

      {:ok, view, _html} = live(conn, ~p"/workers")

      assert view |> element("#worker-#{w.id} button[phx-click=destroy]") |> render() =~
               "its 2 running jobs are requeued"
    end

    test "a destroyed row offers nothing to end", %{conn: conn, user: user} do
      w = worker(user)
      {:ok, _w} = Workers.status(w, :destroyed)

      {:ok, view, _html} = live(conn, ~p"/workers")
      view |> element("button", "Show destroyed") |> render_click()

      assert has_element?(view, "#worker-#{w.id}")
      refute has_element?(view, "#worker-#{w.id} button[phx-click=destroy]")
    end
  end

  # The lines the table used to carry in its own columns, each still drawn on the block.
  test "a row names its machine, what it runs, and when it was last heard from", %{
    conn: conn,
    user: user
  } do
    w = worker(user, %{provider_id: "srv-1234567890123456"})

    {:ok, view, _html} = live(conn, ~p"/workers")
    quiet = text_of(view, "#worker-#{w.id}")

    assert quiet =~ "fake · srv-12345678"
    refute quiet =~ "srv-123456789"
    assert quiet =~ "no harness reported"
    assert quiet =~ "running nothing"
    assert quiet =~ "last seen never"
    refute quiet =~ "idle now"

    {:ok, w} = Workers.ready(w, %{"memory_budget" => 8_000})
    job = Forge.ForgeFixtures.job_fixture(%{status: :running, worker_id: w.id})

    {:ok, view, _html} = live(conn, ~p"/workers")
    busy = text_of(view, "#worker-#{w.id}")

    assert busy =~ "#{job.state} ##{job.attempt}"
    refute busy =~ "running nothing"
    assert busy =~ "last seen now"
  end

  test "an idle machine says since when", %{conn: conn, user: user} do
    w = worker(user)
    {:ok, _w} = Workers.ready(w, %{"memory_budget" => 8_000})

    {:ok, view, _html} = live(conn, ~p"/workers")

    assert text_of(view, "#worker-#{w.id}") =~ "last seen now · idle now"
  end

  test "the laptop nav carries it and the phone bar does not", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # Placement, not a count: counting one occurrence passes just as well when the link is moved
    # *into* the phone bar. A machine is never a decision, and the phone is where decisions are
    # answered — see docs/design/ui.md.
    assert has_element?(view, ~s(header nav a[href="/workers"]))
    refute has_element?(view, ~s(nav.sm\\:hidden a[href="/workers"]))
    assert has_element?(view, ~s(nav.sm\\:hidden a[href="/board"]))
  end

  test "it requires a logged-in operator" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/workers")
  end
end
