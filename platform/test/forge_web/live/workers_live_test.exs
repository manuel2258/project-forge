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

    assert view |> element("tr", String.slice(old.id, 0, 8)) |> render() =~ "takes no agent job"

    refute view |> element("tr", String.slice(current.id, 0, 8)) |> render() =~
             "takes no agent job"
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
        |> element("tr form[phx-submit=assign]")
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
    assert view |> element("tr", String.slice(kept.id, 0, 8)) |> render() =~ "managed"
    assert view |> element("tr", String.slice(permanent.id, 0, 8)) |> render() =~ "permanent"
  end

  test "destroyed rows are history and are hidden until asked for", %{conn: conn, user: user} do
    w = worker(user)
    {:ok, _w} = Workers.status(w, :destroyed)

    {:ok, view, html} = live(conn, ~p"/workers")
    refute html =~ String.slice(w.id, 0, 8)

    assert view |> element("button", "Show destroyed") |> render_click() =~
             String.slice(w.id, 0, 8)
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
