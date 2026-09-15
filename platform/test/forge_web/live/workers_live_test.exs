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

  defp worker(attrs \\ %{}) do
    {:ok, worker, _token} =
      Workers.create(Map.merge(%{provider: "fake", managed: true}, attrs))

    worker
  end

  test "an empty fleet names what would fill it", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/workers")

    assert html =~ "No machines"
    assert html =~ "mix forge.worker.new"
  end

  test "a row that is ready but holds no channel says both", %{conn: conn} do
    w = worker()
    {:ok, w} = Workers.ready(w, 6 * 1024 * 1024 * 1024)

    {:ok, _view, html} = live(conn, ~p"/workers")

    assert html =~ String.slice(w.id, 0, 8)
    assert html =~ "ready"

    # The point of the page: the database says ready, the registry says otherwise.
    assert html =~ "not connected"
    assert html =~ "0 connected"
  end

  # A machine minted without a working credential joins, reports ready, and then fails every job
  # it is given with *Not logged in*. The probe at `ready` is what makes that visible before the
  # first job instead of after it — docs/design/worker-channel.md § What a worker offers.
  test "a worker that is not logged in says so before it is given work", %{conn: conn} do
    w = worker()

    {:ok, _w} =
      Workers.ready(w, 6 * 1024 * 1024 * 1024, %{
        "name" => "Claude Code",
        "version" => "2.1.220",
        "login" => "invalid",
        "models" => []
      })

    {:ok, _view, html} = live(conn, ~p"/workers")

    assert html =~ "Claude Code"
    assert html =~ "2.1.220"
    assert html =~ "login invalid"
  end

  # A worker running a release older than the probe reports no harness at all, and is still a
  # worker: the column shows a dash rather than the page failing to render.
  test "a worker that reported no harness still renders", %{conn: conn} do
    w = worker()
    {:ok, _w} = Workers.ready(w, 6 * 1024 * 1024 * 1024)

    {:ok, _view, html} = live(conn, ~p"/workers")

    assert html =~ String.slice(w.id, 0, 8)
    refute html =~ "login"
  end

  test "a connected worker is shown as connected", %{conn: conn} do
    w = worker()
    {:ok, _w} = Workers.ready(w, 6 * 1024 * 1024 * 1024)

    # Registering is what a channel does when it joins; this process stands in for one.
    :ok = Workers.connected(w.id)

    {:ok, _view, html} = live(conn, ~p"/workers")

    assert html =~ "1 connected"
    refute html =~ "not connected"
  end

  test "capacity is shown as slices, which is what the scheduler decides on", %{conn: conn} do
    # Merged, not replaced: replacing drops every other key and silently changes what the page
    # reads the first time one of them stops having a call-site default.
    current = Application.get_env(:forge, Workers, [])

    Application.put_env(
      :forge,
      Workers,
      Keyword.put(current, :slice_bytes, 2 * 1024 * 1024 * 1024)
    )

    w = worker()
    {:ok, _w} = Workers.ready(w, 6 * 1024 * 1024 * 1024)

    {:ok, _view, html} = live(conn, ~p"/workers")

    assert html =~ "6.0 GiB"
    assert html =~ "3 slices"
  end

  test "managed and permanent are distinguished", %{conn: conn} do
    kept = worker(%{managed: true})
    permanent = worker(%{managed: false})

    {:ok, view, _html} = live(conn, ~p"/workers")

    # Tied to the row, not merely present on the page: asserting both words appear passes just
    # as well when the two labels are swapped.
    assert view |> element("tr", String.slice(kept.id, 0, 8)) |> render() =~ "managed"
    assert view |> element("tr", String.slice(permanent.id, 0, 8)) |> render() =~ "permanent"
  end

  test "destroyed rows are history and are hidden until asked for", %{conn: conn} do
    w = worker()
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
