defmodule ForgeWeb.WorkerLiveTest do
  @moduledoc """
  One machine's log, read by its owner and nobody else (`docs/design/worker-log.md` § The page).
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Forge.Workers
  alias Forge.Workers.Log

  setup :register_and_log_in_user

  defp worker(owner, attrs \\ %{}) do
    {:ok, worker, _token} =
      Workers.create(Map.merge(%{provider: "fake", managed: true, user_id: owner.id}, attrs))

    worker
  end

  defp text_of(view, selector) do
    view
    |> element(selector)
    |> render()
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/, " ")
  end

  # The header's own class, not its children's: the provider beside the id is dimmed on every row.
  defp header_class(view) do
    [_all, class] = Regex.run(~r/<header[^>]*id="machine"[^>]*class="([^"]*)"/, render(view))
    class
  end

  defp line_ids(html),
    do: ~r/id="line-(\d+)"/ |> Regex.scan(html) |> Enum.map(fn [_, id] -> id end)

  test "the owner reads what the platform saw and what the machine said, newest first", %{
    conn: conn,
    user: user
  } do
    w = worker(user)
    job_id = Ecto.UUID.generate()
    at = DateTime.add(DateTime.utc_now(), -60)

    :ok =
      Log.accept(w.id, %{
        "at" => DateTime.to_iso8601(at),
        "type" => "job.accepted",
        "message" => "took on a workflow job",
        "job_id" => job_id
      })

    :ok = Log.record(w.id, "create.refused", :error, "fake refused: no image")

    {:ok, view, html} = live(conn, ~p"/workers/#{w.id}")

    [refused, accepted] = Log.for_worker(w.id)
    assert line_ids(html) == [to_string(refused.id), to_string(accepted.id)]
    refute html =~ "Nothing has been written yet."

    refused_text = text_of(view, "#line-#{refused.id}")
    assert refused_text =~ "platform create.refused fake refused: no image"
    assert refused_text =~ Calendar.strftime(refused.at, "%Y-%m-%d %H:%M:%S")

    accepted_text = text_of(view, "#line-#{accepted.id}")

    # The first eight characters of the job's id, and not the rest of it: asserting the prefix
    # alone would pass with the whole id drawn.
    assert accepted_text =~
             "machine job.accepted took on a workflow job job #{String.slice(job_id, 0, 8)}"

    refute accepted_text =~ job_id

    assert accepted_text =~ Calendar.strftime(at, "%Y-%m-%d %H:%M:%S")

    # An error is drawn as one, and nothing else is — a warning included.
    assert view |> element("#line-#{refused.id}") |> render() =~ "text-danger"
    refute view |> element("#line-#{accepted.id}") |> render() =~ "text-danger"

    :ok = Log.record(w.id, "unreachable", :warning, "not heard from")
    send(view.pid, :refresh)
    [warned | _] = Log.for_worker(w.id)
    assert text_of(view, "#line-#{warned.id}") =~ "unreachable not heard from"
    refute view |> element("#line-#{warned.id}") |> render() =~ "text-danger"

    # Headed by the same line that heads the machine's block on /workers.
    assert text_of(view, "#machine") =~ "#{String.slice(w.id, 0, 8)} fake creating"
    assert text_of(view, "#machine") =~ "not connected managed"
    refute header_class(view) =~ "machine--gone"
  end

  test "a machine with nothing written says so", %{conn: conn, user: user} do
    w = worker(user)
    {:ok, _view, html} = live(conn, ~p"/workers/#{w.id}")
    assert html =~ "Nothing has been written yet."
  end

  # The same five seconds as the workers page, and the same message.
  test "a line written while the page is open appears at the next refresh", %{
    conn: conn,
    user: user
  } do
    w = worker(user)
    {:ok, view, _html} = live(conn, ~p"/workers/#{w.id}")

    :ok = Log.record(w.id, "joined", :info, "release 0.3.0, build abc, protocol 1")
    refute render(view) =~ "release 0.3.0"

    send(view.pid, :refresh)
    assert render(view) =~ "release 0.3.0, build abc, protocol 1"
  end

  test "the page reads the log again by itself", %{conn: conn, user: user} do
    previous = Application.get_env(:forge, Workers, [])
    on_exit(fn -> Application.put_env(:forge, Workers, previous) end)
    Application.put_env(:forge, Workers, Keyword.put(previous, :page_refresh_ms, 20))

    w = worker(user)
    {:ok, view, _html} = live(conn, ~p"/workers/#{w.id}")
    :ok = Log.record(w.id, "joined", :info, "release 0.3.0, build abc, protocol 1")

    assert Enum.any?(1..50, fn _ ->
             Process.sleep(20)
             render(view) =~ "release 0.3.0"
           end)
  end

  # The header is re-read with the log: a machine that connects, is retired or joins with another
  # release while the page is open says so at the next refresh.
  test "the header is read again with the log", %{conn: conn, user: user} do
    previous = Application.get_env(:forge, Workers, [])
    on_exit(fn -> Application.put_env(:forge, Workers, previous) end)
    Application.put_env(:forge, Workers, Keyword.put(previous, :current_build, "8rh57whmgk6m"))

    w = worker(user, %{managed: false})
    {:ok, view, _html} = live(conn, ~p"/workers/#{w.id}")
    assert text_of(view, "#machine") =~ "not connected"

    :ok =
      Workers.admit(w.id, %{
        "protocol" => ForgeCore.WorkerProtocol.current(),
        "release" => "0.2.1 (8rh57whmgk6m)",
        "build" => "8rh57whmgk6m"
      })

    :ok = Workers.connected(w.id)
    {:ok, _} = Workers.update(Workers.get!(w.id), %{status: :idle})
    send(view.pid, :refresh)

    header = text_of(view, "#machine")
    assert header =~ "idle"
    assert header =~ " connected"
    refute header =~ "not connected"
    assert header =~ "0.2.1 (8rh57whmgk6m) · current"
  end

  # An inner page like every other: the queue button on the left of its top bar (the handoff's
  # RULES § 9 names `12g` as drawn without one).
  test "the top bar keeps the queue button", %{conn: conn, user: user} do
    w = worker(user)
    {:ok, view, _html} = live(conn, ~p"/workers/#{w.id}")

    assert has_element?(view, ~s(#top-bar a.ui-queue-btn[href="/"]))
    assert text_of(view, "#top-bar .ui-top-title > .ui-top-name") =~ String.slice(w.id, 0, 8)
  end

  test "the subline says how it stands and where it comes from", %{conn: conn, user: user} do
    w = worker(user, %{managed: false})
    {:ok, view, _html} = live(conn, ~p"/workers/#{w.id}")

    assert text_of(view, "#top-bar .ui-top-title > .ui-top-sub") =~
             "creating · permanent · no project"

    {:ok, []} = Workers.retire(w, by: :owner)
    {:ok, view, _html} = live(conn, ~p"/workers/#{w.id}")

    assert text_of(view, "#top-bar .ui-top-title > .ui-top-sub") =~
             "destroyed just now · permanent · no project"
  end

  # A job id opens its job page — **only in a project the viewer is in**: the machine is the
  # owner's, the work it ran is a project's (`docs/design/identity.md` § Workers).
  test "a job id links to its page only where the viewer may open it", %{conn: conn, user: user} do
    w = worker(user)
    mine = Forge.ForgeFixtures.project_fixture()
    Forge.ForgeFixtures.join!(mine, user)
    ticket = Forge.ForgeFixtures.ticket_fixture(%{project: mine})
    seen = Forge.ForgeFixtures.job_fixture(%{ticket: ticket})
    chat = Forge.ForgeFixtures.chat_fixture(%{project: mine})
    unseen = Forge.ForgeFixtures.job_fixture()

    for job <- [seen, chat, unseen] do
      :ok =
        Log.accept(w.id, %{
          "at" => DateTime.to_iso8601(DateTime.utc_now()),
          "type" => "job.accepted",
          "message" => "took it on",
          "job_id" => job.id
        })
    end

    {:ok, view, html} = live(conn, ~p"/workers/#{w.id}")

    assert has_element?(
             view,
             ~s(#log a[href="/tickets/#{mine.name}/#{ticket.number}/jobs/#{seen.id}"]),
             "job #{String.slice(seen.id, 0, 8)}"
           )

    assert has_element?(view, ~s(#log a[href="/chats/#{chat.id}"]))
    # Its short id, as text and never a link: the page does not say whose project it ran in.
    assert html =~ "job #{String.slice(unseen.id, 0, 8)}"
    refute html =~ unseen.id
    refute html =~ "/jobs/#{unseen.id}"
  end

  # **Somebody else's machine is not here, as a missing one is not** — the same answer, so the
  # page cannot be used to learn which ids exist (`docs/design/identity.md` § Sequencing).
  test "another person's machine is not here, and neither is a missing one", %{conn: conn} do
    theirs = worker(Forge.AccountsFixtures.user_fixture())
    :ok = Log.record(theirs.id, "created", :info, "their secret machine")

    assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/workers/#{theirs.id}") end
    assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/workers/#{Ecto.UUID.generate()}") end
    assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/workers/not-a-uuid") end
  end

  # "Why did it go away?" is asked afterwards.
  test "a destroyed machine's log is still here, and linked from its block", %{
    conn: conn,
    user: user
  } do
    w = worker(user, %{managed: false})
    {:ok, []} = Workers.retire(w, by: :owner)

    {:ok, list, _html} = live(conn, ~p"/workers")
    render_click(list, "toggle-destroyed")

    {:ok, view, _html} =
      list
      |> element("#worker-#{w.id} a.machine-head")
      |> render_click()
      |> follow_redirect(conn, ~p"/workers/#{w.id}")

    assert text_of(view, "#machine") =~ "destroyed"
    # Dimmed, as its block is on /workers.
    assert header_class(view) =~ "machine--gone"
    assert render(view) =~ "by its owner, from the workers page"
  end
end
