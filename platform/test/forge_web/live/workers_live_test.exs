defmodule ForgeWeb.WorkersLiveTest do
  @moduledoc """
  The machines, and the one column the CLI cannot have.

  Connection lives in a registry inside the running platform, so the case worth pinning down is
  a row that is `ready` and *not* connected: a machine healthy on every other surface that
  cannot take work. See `docs/design/ui.md` § The workers page.
  """

  use ForgeWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Forge.{Jobs, Workers}

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:forge, Workers, [])
    on_exit(fn -> Application.put_env(:forge, Workers, previous) end)
    :ok
  end

  defp view_row(conn, worker) do
    {:ok, view, _html} = live(conn, ~p"/workers")
    view |> element("#worker-#{worker.id}") |> render()
  end

  # Rendered HTML as the words an operator reads, whitespace collapsed: what a line *says*, which
  # is the assertion that notices a stray separator a class-name match would not.
  defp text(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
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

  # Templates used to be a link inside the explanation beneath the header, and the only way there
  # from a laptop. It is a button, filled while the viewer has no template, because then nothing
  # will ever appear on this page by waiting.
  describe "the Templates button" do
    test "is filled, with a line saying why, while the viewer has no template", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workers")

      # Filled: the one way forward on a page with nothing to show.
      assert view |> element("#templates-button") |> render() =~ "ui-btn--primary"

      assert has_element?(
               view,
               "#no-templates",
               "You have no templates, so the platform can make no machine for you"
             )

      assert has_element?(view, ~s(#templates-button[href="/templates"]))
    end

    test "is plain once the viewer has one, and someone else's does not count", %{
      conn: conn,
      user: user
    } do
      template = fn owner ->
        {:ok, _template} =
          Forge.Provisioning.create_template(owner, %{
            name: "t-#{System.unique_integer([:positive])}",
            provider: "fake",
            memory: 8 * 1024 * 1024 * 1024,
            cores: 4,
            max_workers: 1
          })
      end

      template.(Forge.AccountsFixtures.user_fixture())
      {:ok, view, _html} = live(conn, ~p"/workers")
      assert has_element?(view, "#no-templates")

      template.(user)
      {:ok, view, _html} = live(conn, ~p"/workers")
      # The views already lead there; a second way would be a button saying nothing new.
      refute has_element?(view, "#templates-button")
      refute has_element?(view, "#no-templates")
    end
  end

  test "an empty fleet names what would fill it", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/workers")

    assert html =~ "You have no machines"
    assert html =~ "added with + Add a machine"
  end

  # Anybody approved may mint a machine of their own (`docs/design/identity.md` § Minting a
  # permanent machine). The owner is the session's, the project is checked before the row exists,
  # and the environment is on the page once.
  describe "minting a permanent machine" do
    defp minted_env(view) do
      text = view |> element("#minted-env") |> render() |> Floki.parse_fragment!() |> Floki.text()

      text
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        [name, value] = String.split(line, "=", parts: 2)
        {name, value}
      end)
    end

    test "mints one for the viewer and shows its environment once", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/workers")

      view |> element("#new-machine") |> render_click()
      view |> element("#mint-form") |> render_submit(%{"project" => ""})

      env = minted_env(view)
      # Where it goes, said beside it: nothing on the page can show it again.
      assert has_element?(view, "#minted", "forge-config")
      # The same block a freshly issued token is shown in (`Operator.Components.shown_once/1`),
      # so the two say the same thing about what happens once it is dismissed.
      assert has_element?(view, "#minted .ui-notice", "Copy it now. It is not shown again.")
      # A warning, not the amber of a decision: nothing waits on you here (UX re-check #5).
      assert has_element?(view, "#minted .ui-notice--warning")
      refute has_element?(view, "#mint-form")
      # One more click would throw the environment away, so there is nothing to click.
      refute has_element?(view, "#new-machine")
      assert [worker] = Workers.list(user)
      refute worker.managed
      assert env["FORGE_WORKER_ID"] == worker.id
      assert {:ok, _worker} = Workers.authenticate(worker.id, env["FORGE_WORKER_TOKEN"])
      assert has_element?(view, "#worker-#{worker.id}", "no project, so it takes no work")

      view |> element("#minted button", "I have copied it") |> render_click()

      refute has_element?(view, "#minted")
      refute render(view) =~ env["FORGE_WORKER_TOKEN"]
      assert has_element?(view, "#new-machine")
    end

    # The page holds the user it mounted with; an account suspended since is refused anyway.
    test "is refused once the viewer is suspended, though the page is still open", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/workers")
      admin = Forge.AccountsFixtures.node_admin_fixture()
      {:ok, _suspended} = Forge.Accounts.suspend_user(user, admin)

      html = render_submit(view, "mint", %{"project" => ""})

      assert html =~ "your account may not own a machine"
      refute has_element?(view, "#minted")
      assert Forge.Repo.aggregate(Forge.Workers.Worker, :count) == 0
    end

    test "serves the project chosen", %{conn: conn, user: user} do
      {:ok, project} = Forge.Projects.register(%{name: "first", repo_path: repo_path()}, user)
      {:ok, view, _html} = live(conn, ~p"/workers")

      view |> element("#new-machine") |> render_click()
      view |> element("#mint-form") |> render_submit(%{"project" => project.id})

      assert [worker] = Workers.list(user)
      assert [%{name: "first"}] = Workers.projects(worker)
    end

    # The form has no owner field; one sent by hand is not read.
    test "is the viewer's whatever owner the request names", %{conn: conn, user: user} do
      other = Forge.AccountsFixtures.user_fixture()
      {:ok, view, _html} = live(conn, ~p"/workers")

      render_submit(view, "mint", %{"project" => "", "owner" => other.id, "user_id" => other.id})

      assert [_worker] = Workers.list(user)
      assert Workers.list(other) == []
    end

    # The id is the client's: a project the viewer is not in is refused, and no row is left with a
    # token nobody was shown.
    test "into somebody else's project is refused, and nothing is made", %{conn: conn} do
      outsider = Forge.AccountsFixtures.user_fixture()
      {:ok, theirs} = Forge.Projects.register(%{name: "theirs", repo_path: repo_path()}, outsider)
      {:ok, view, _html} = live(conn, ~p"/workers")

      html = render_submit(view, "mint", %{"project" => theirs.id})

      assert html =~ "you are not in that project"
      refute has_element?(view, "#minted")
      assert Forge.Repo.aggregate(Forge.Workers.Worker, :count) == 0
    end

    test "can be put away without minting anything", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workers")

      view |> element("#new-machine") |> render_click()
      assert has_element?(view, "#mint-form")
      refute has_element?(view, "#new-machine")

      view |> element("#mint-form button", "Cancel") |> render_click()

      refute has_element?(view, "#mint-form")
      assert has_element?(view, "#new-machine")
    end

    # A refusal's sentence is about that attempt; the next one, or putting the form away, clears it.
    test "a refusal is cleared by the next mint, and by cancelling", %{conn: conn} do
      outsider = Forge.AccountsFixtures.user_fixture()

      {:ok, theirs} =
        Forge.Projects.register(%{name: "elsewhere", repo_path: repo_path()}, outsider)

      {:ok, view, _html} = live(conn, ~p"/workers")

      view |> element("#new-machine") |> render_click()

      assert render_submit(view, "mint", %{"project" => theirs.id}) =~
               "you are not in that project"

      view |> element("#mint-form button", "Cancel") |> render_click()
      refute render(view) =~ "you are not in that project"

      view |> element("#new-machine") |> render_click()

      assert render_submit(view, "mint", %{"project" => theirs.id}) =~
               "you are not in that project"

      refute render_submit(view, "mint", %{"project" => ""}) =~ "you are not in that project"
    end

    # A file, drawn as one: the lines stay lines on screen, not one run of text to pick apart.
    test "the environment is drawn line for line", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workers")

      view |> element("#new-machine") |> render_click()
      view |> element("#mint-form") |> render_submit(%{"project" => ""})

      assert has_element?(view, "pre#minted-env.whitespace-pre-wrap")
    end

    # A node whose default provider is blank cannot make a row at all, and says so plainly.
    test "a row the node cannot make is said as that", %{conn: conn} do
      previous = Application.get_env(:forge, Forge.Provider, [])
      on_exit(fn -> Application.put_env(:forge, Forge.Provider, previous) end)
      Application.put_env(:forge, Forge.Provider, Keyword.put(previous, :default, ""))
      {:ok, view, _html} = live(conn, ~p"/workers")

      assert render_submit(view, "mint", %{"project" => ""}) =~ "could not mint a machine"
      refute has_element?(view, "#minted")
    end
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

  # UX pass, D14: a row says nothing that contradicts itself.
  describe "a row that does not contradict itself" do
    # Busy or ready and not connected is the state that cost a day: in danger, with the words.
    test "busy and not connected is said in danger, and idle is not said while busy", %{
      conn: conn,
      user: user
    } do
      w = worker(user)
      {:ok, _} = Workers.ready(w, %{"memory_budget" => 8_000_000_000})
      quiet = worker(user)

      Forge.Repo.update_all(from(x in Forge.Workers.Worker, where: x.id == ^w.id),
        set: [status: :busy, idle_since: DateTime.utc_now(:second)]
      )

      {:ok, view, _html} = live(conn, ~p"/workers")

      assert has_element?(view, "#worker-#{w.id} .machine-head .machine-dot--danger")

      # The danger is on the word that names the problem; busy stays ink (UX re-check #17).
      assert has_element?(view, "#worker-#{w.id} .machine-status", "busy")
      refute has_element?(view, "#worker-#{w.id} .machine-status.text-danger")
      assert has_element?(view, "#worker-#{w.id} .machine-ids .text-danger", "not connected")

      refute view |> element("#worker-#{w.id}") |> render() =~ "· idle"
      # A machine still being made is not stranded, only not connected yet.
      refute has_element?(view, "#worker-#{quiet.id} .machine-dot--danger")
    end

    test "a machine being made says nothing of its release or what it has free", %{
      conn: conn,
      user: user
    } do
      w = worker(user)
      {:ok, view, _html} = live(conn, ~p"/workers")
      row = view |> element("#worker-#{w.id}") |> render()

      refute row =~ "takes no agent job"
      refute row =~ "GiB of"
    end

    test "a destroyed machine says nothing of what it has free", %{conn: conn, user: user} do
      w = worker(user)
      {:ok, _} = Workers.ready(w, %{"memory_budget" => 8_000_000_000})

      Forge.Repo.update_all(from(x in Forge.Workers.Worker, where: x.id == ^w.id),
        set: [status: :destroyed]
      )

      {:ok, view, _html} = live(conn, ~p"/workers")
      view |> element("button[phx-click=toggle-destroyed]") |> render_click()
      refute view |> element("#worker-#{w.id}") |> render() =~ "GiB of"
    end

    test "the harness is named as You names it", %{conn: conn, user: user} do
      w = worker(user)
      {:ok, _} = Workers.ready(w, %{"harness" => %{"driver" => "claude_code"}})

      {:ok, view, _html} = live(conn, ~p"/workers")
      row = view |> element("#worker-#{w.id} .machine-facts") |> render()
      assert row =~ "Claude Code"
      refute row =~ "claude_code"
    end
  end

  # The field is labelled with a size, so it is filled with one (UX pass, D15).
  test "Set what it offers is filled with the size it has, not a byte count", %{
    conn: conn,
    user: user
  } do
    w = worker(user, %{managed: false})
    {:ok, _} = Workers.ready(w, %{"memory_budget" => 8 * 1024 * 1024 * 1024})

    {:ok, view, _html} = live(conn, ~p"/workers")
    view |> element("button[phx-click=edit][phx-value-id=\"#{w.id}\"]") |> render_click()

    field = view |> element("#offer-memory-#{w.id}") |> render()
    assert field =~ ~s(value="8GiB")
    assert view |> element("#offer-#{w.id}") |> render() =~ "Memory (e.g. 8GiB)"
  end

  # The machine installs or updates its own Claude Code before it reports `ready`, and a failed
  # attempt is a machine that may be running nothing at all — which the operator has to be able
  # to see here rather than in a journal on the machine (`docs/design/worker-tier.md` § Updating
  # a worker).
  test "a worker whose Claude Code update failed says so, with what went wrong", %{
    conn: conn,
    user: user
  } do
    w = worker(user)

    {:ok, _w} =
      Workers.ready(w, %{
        "memory_budget" => 8_000,
        "harness" => %{
          "driver" => "claude_code",
          "credential" => "per_job",
          "update" => %{
            "outcome" => "failed",
            "error" => "curl: (6) could not resolve host"
          }
        }
      })

    {:ok, view, _html} = live(conn, ~p"/workers")

    line = view |> element("#claude-update-#{w.id}") |> render()

    assert line =~ "claude update failed"
    assert line =~ "could not resolve host"
    # The one state here that is a fault, and the only one drawn in error (`ui.md` § Colour).
    assert line =~ "text-danger"
  end

  # Every harness a machine offers is drawn, not only the first: Codex's version and the outcome
  # of its own update, loud only when it failed, and a machine with none installed says so.
  test "the other harnesses a machine offers are drawn, with their update outcome", %{
    conn: conn,
    user: user
  } do
    w = worker(user)
    claude = %{"driver" => "claude_code", "name" => "Claude Code", "credential" => "per_job"}

    {:ok, _w} =
      Workers.ready(w, %{
        "memory_budget" => 8_000,
        "harness" => claude,
        "harnesses" => [
          claude,
          %{
            "driver" => "codex",
            "name" => "Codex",
            "update" => %{"outcome" => "failed", "error" => "curl: (6) no route"}
          }
        ]
      })

    {:ok, view, _html} = live(conn, ~p"/workers")
    line = view |> element("#harness-#{w.id}-codex") |> render()

    assert text(line) =~ "Codex not installed"
    assert text(line) =~ "update failed: curl: (6) no route"
    assert line =~ "text-danger"
    refute has_element?(view, "#harness-#{w.id}-claude_code")

    {:ok, _w} =
      Workers.ready(w, %{
        "memory_budget" => 8_000,
        "harness" => claude,
        "harnesses" => [
          claude,
          %{
            "driver" => "codex",
            "name" => "Codex",
            "version" => "0.46.0",
            "credential" => "per_job",
            "update" => %{"outcome" => "succeeded"}
          }
        ]
      })

    {:ok, view, _html} = live(conn, ~p"/workers")
    line = view |> element("#harness-#{w.id}-codex") |> render()

    assert text(line) == "Codex 0.46.0 · update succeeded"
    refute line =~ "text-error"
  end

  # An attempt that worked is still drawn — the operator asked whether it succeeded, not only
  # whether it failed — and quietly, because the one loud thing in the interface is an item
  # waiting on a human (`docs/design/ui.md` § Colour).
  test "an update that succeeded is shown without being loud", %{conn: conn, user: user} do
    w = worker(user)

    {:ok, _w} =
      Workers.ready(w, %{
        "memory_budget" => 8_000,
        "harness" => %{
          "driver" => "claude_code",
          "credential" => "per_job",
          "version" => "2.1.270",
          "update" => %{"outcome" => "succeeded", "version" => "2.1.270"}
        }
      })

    {:ok, view, _html} = live(conn, ~p"/workers")
    line = view |> element("#claude-update-#{w.id}") |> render()

    # The whole of what the line says, so a stray empty `: ` from an error that is not there
    # fails here rather than being read as a success with a colon.
    assert text(line) == "claude update succeeded"
    # Not in accent and not in error: a machine that is fine says so quietly. Asserted on this
    # line alone, because the block around it carries a Destroy button that is in danger by
    # right.
    assert line =~ "text-ink-3"
    refute line =~ "text-danger"
  end

  # A machine whose image predates the unit reports no `update` key, and the line is not drawn at
  # all — the same treatment an absent `cores` gets. The mutation this is aimed at is a component
  # that renders whatever it was given: that one draws a bare "claude update" here.
  test "a worker that attempted no update has no line about one", %{conn: conn, user: user} do
    w = worker(user)

    {:ok, _w} =
      Workers.ready(w, %{
        "memory_budget" => 8_000,
        "harness" => %{"driver" => "claude_code", "credential" => "per_job"}
      })

    {:ok, view, _html} = live(conn, ~p"/workers")

    assert has_element?(view, "#worker-#{w.id}")
    refute has_element?(view, "#claude-update-#{w.id}")
    refute view |> element("#worker-#{w.id}") |> render() =~ "claude update"
  end

  # **A machine can push anything into `harness`, and one release pushing a map where a string
  # belongs took this page down for good**: `Phoenix.HTML.Safe` is not implemented for a map, the
  # value is persisted in the jsonb column, and every later mount crashed on it again — for every
  # operator who could see that row, not just the one who provoked it. `harness_text/1` is the
  # guard. The mutation it is aimed at is dropping that call from any of the five fields.
  describe "a harness map with the wrong types in it" do
    @malformed %{
      "name" => %{"not" => "a string"},
      "driver" => ["claude_code"],
      "version" => %{"major" => 2},
      "login" => %{"status" => "invalid"},
      "credential" => "per_job",
      "update" => %{"outcome" => "failed", "error" => %{"why" => "a map"}}
    }

    test "renders the row instead of taking the page down", %{conn: conn, user: user} do
      w = worker(user)
      {:ok, _w} = Workers.ready(w, %{"memory_budget" => 8_000, "harness" => @malformed})

      {:ok, view, _html} = live(conn, ~p"/workers")

      # The row is here at all, which is the whole assertion: before the guard this raised.
      assert has_element?(view, "#worker-#{w.id}")
      # The outcome is a string and is drawn; the error is not one and is dropped, rather than
      # being drawn as `%{"why" => "a map"}` or raising on the way.
      line = view |> element("#claude-update-#{w.id}") |> render()
      assert text(line) == "claude update failed"
      # A `login` that is not a string is not an unhealthy login, it is an unreadable one.
      refute view |> element("#worker-#{w.id}") |> render() =~ "login"
    end

    # Numbers are the one non-string worth drawing: a version that arrived unquoted is a
    # malformed report, not a reason to show the operator nothing where the version goes.
    test "still shows a number, which is malformed but readable", %{conn: conn, user: user} do
      w = worker(user)

      {:ok, _w} =
        Workers.ready(w, %{
          "memory_budget" => 8_000,
          "harness" => %{"driver" => "claude_code", "credential" => "per_job", "version" => 2.1}
        })

      assert view_row(conn, w) =~ "2.1"
    end
  end

  # The `update` value itself, not the strings inside it. The review that sent this back found the
  # guard on `claude_update/1`'s head was untested and a comment claimed no test could reach it —
  # these two are the test. Each would pass against a head relaxed to `%{"update" => _}` only if
  # the page then drew nothing, and it does not: the first raises in `Access.get/3` and the second
  # draws a line out of a number.
  test "an update that is not a map at all draws nothing", %{conn: conn, user: user} do
    w = worker(user)

    {:ok, _w} =
      Workers.ready(w, %{
        "memory_budget" => 8_000,
        "harness" => %{"driver" => "claude_code", "credential" => "per_job", "update" => "oops"}
      })

    {:ok, view, _html} = live(conn, ~p"/workers")

    assert has_element?(view, "#worker-#{w.id}")
    refute has_element?(view, "#claude-update-#{w.id}")
  end

  test "an outcome that is not a string draws nothing", %{conn: conn, user: user} do
    w = worker(user)

    {:ok, _w} =
      Workers.ready(w, %{
        "memory_budget" => 8_000,
        "harness" => %{
          "driver" => "claude_code",
          "credential" => "per_job",
          "update" => %{"outcome" => 3}
        }
      })

    {:ok, view, _html} = live(conn, ~p"/workers")

    assert has_element?(view, "#worker-#{w.id}")
    refute has_element?(view, "#claude-update-#{w.id}")
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

  # A refused destroy writes `last_error` too, on a machine that was made and goes on running:
  # it read "never made" for good.
  test "a machine the driver would not destroy says that, not that it was never made", %{
    conn: conn,
    user: user
  } do
    w = worker(user, %{managed: true, provider_id: "fake-9"})
    {:ok, _} = Workers.update(w, %{last_error: "the provider is down"})

    {:ok, _view, html} = live(conn, ~p"/workers")

    assert html =~ "would not destroy: the provider is down"
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

      view |> element("button[phx-click=edit][phx-value-id=\"#{w.id}\"]") |> render_click()

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
      |> element("button[phx-click=edit][phx-value-id=\"#{permanent.id}\"]")
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
      view |> element("button[phx-click=edit][phx-value-id=\"#{w.id}\"]") |> render_click()

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

  describe "setting less than one job's worth" do
    # An owner's figure below the least a job can run in is a machine that takes nothing, and it
    # is refused by name. The machine's own report of zero is another matter — it could not read
    # its memory — and is not this form's to refuse.
    test "is refused, naming the minimum, and the minimum itself is taken", %{
      conn: conn,
      user: user
    } do
      w = worker(user, %{managed: false})
      {:ok, _} = Workers.ready(w, %{"memory_budget" => 0, "cores" => 4})
      assert Workers.get!(w.id).memory_budget == 0

      {:ok, view, _html} = live(conn, ~p"/workers")
      view |> element("button[phx-click=edit][phx-value-id=\"#{w.id}\"]") |> render_click()

      html =
        view
        |> element("form[phx-submit=save]")
        |> render_submit(%{"worker_id" => w.id, "memory" => "511MiB", "cores" => "2"})

      assert html =~ "memory must be at least 512MiB, the least a job can run in"
      assert Workers.get!(w.id).memory_budget == 0

      view
      |> element("form[phx-submit=save]")
      |> render_submit(%{"worker_id" => w.id, "memory" => "512MiB", "cores" => "2"})

      assert Workers.get!(w.id).memory_budget == 536_870_912
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

    # The select offers what is not assigned yet, starting on a blank that assigns nothing, and is
    # not drawn once there is nothing left to offer (UX pass, D5).
    test "Assign offers only the projects the machine does not serve yet", %{
      conn: conn,
      user: user
    } do
      {:ok, served} = Forge.Projects.register(%{name: "served", repo_path: repo_path()}, user)
      {:ok, other} = Forge.Projects.register(%{name: "other", repo_path: repo_path()}, user)
      w = worker(user, %{managed: false})
      {:ok, _} = Workers.assign(user, w.id, served.id)

      {:ok, view, _html} = live(conn, ~p"/workers")
      select = view |> element("#worker-#{w.id} form[phx-submit=assign] select") |> render()

      refute select =~ ~s(value="#{served.id}")
      assert select =~ ~s(value="#{other.id}")
      assert select =~ ~r/<option value="" disabled="" selected="">add a project…/

      {:ok, _} = Workers.assign(user, w.id, other.id)
      {:ok, view, _html} = live(conn, ~p"/workers")
      refute has_element?(view, "#worker-#{w.id} form[phx-submit=assign]")
      assert has_element?(view, ~s(#worker-#{w.id} button[phx-value-project="#{other.id}"]))
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
      w = worker(user, Forge.Provisioning.Template.worker_attrs(template))

      {:ok, view, _html} = live(conn, ~p"/workers")

      # In the head of its row, where a permanent machine says `permanent`.
      assert text_of(view, "#worker-#{w.id} .machine-where") =~ "agents · through"
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
      view |> element("button[phx-click=edit][phx-value-id=\"#{mine.id}\"]") |> render_click()

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
          "protocol" => ForgeCore.WorkerProtocol.current(),
          "release" => "0.2.1 (8rh57whmgk6m)",
          "build" => "8rh57whmgk6m"
        })

      :ok =
        Workers.admit(other.id, %{
          "protocol" => ForgeCore.WorkerProtocol.current(),
          "release" => "0.2.0 (aaaaaaaaaaaa)",
          "build" => "aaaaaaaaaaaa"
        })

      {:ok, view, _html} = live(conn, ~p"/workers")

      assert text_of(view, "#worker-#{current.id}") =~ "0.2.1 (8rh57whmgk6m) · current"
      assert text_of(view, "#worker-#{other.id}") =~ "0.2.0 (aaaaaaaaaaaa) · other build"

      # Not joined since the release was on the wire: nothing to compare.
      refute view |> element("#worker-#{silent.id}") |> render() =~ "build"
    end

    # A machine that says only its protocol is not running the build this platform ships.
    test "a machine that said nothing of its release is not current", %{conn: conn, user: user} do
      w = worker(user)
      :ok = Workers.admit(w.id, %{"protocol" => ForgeCore.WorkerProtocol.current()})

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

      :ok =
        Workers.admit(w.id, %{
          "protocol" => ForgeCore.WorkerProtocol.current(),
          "release" => "0.2.1 (8rh57whmgk6m)",
          "build" => "8rh57whmgk6m"
        })

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

      # Not "being made" beside it (UX pass, D14).
      assert has_element?(view, "#worker-#{w.id} .machine-doing", "turned away at its join")
    end

    test "a machine that was taken says nothing of the sort", %{conn: conn, user: user} do
      w = worker(user, %{managed: false})
      :ok = Workers.admit(w.id, %{"protocol" => ForgeCore.WorkerProtocol.current()})

      {:ok, view, _html} = live(conn, ~p"/workers")

      refute view |> element("#worker-#{w.id}") |> render() =~ "refused"
    end

    # `docs/design/ui.md` § The workers page: what the machine said, and what happens next — which
    # is one of three things, and the line says which.
    test "a machine whose systemd stopped answering says so, and what happens next", %{
      conn: conn,
      user: user
    } do
      told = worker(user, %{managed: true})
      {:ok, %{reboot: true}} = Workers.unhealthy(told.id, "PID 1 did not answer")

      permanent = worker(user, %{managed: false})
      {:ok, %{reboot: false}} = Workers.unhealthy(permanent.id, "PID 1 did not answer")

      again = worker(user, %{managed: true})
      earlier = DateTime.add(DateTime.utc_now(), -10, :minute)
      {:ok, _} = Workers.update(again, %{rebooted_at: earlier})
      {:ok, %{reboot: false}} = Workers.unhealthy(again.id, "PID 1 did not answer")

      well = worker(user, %{managed: true})

      # Gone past its grace: the row says it was destroyed, and a line about what happens next
      # would be about a machine that is not there.
      gone = worker(user, %{managed: true})
      {:ok, _answer} = Workers.unhealthy(gone.id, "PID 1 did not answer")
      {:ok, _} = Workers.status(Workers.get!(gone.id), :destroyed)

      {:ok, view, _html} = live(conn, ~p"/workers")
      row = &(view |> element("#worker-#{&1.id}") |> render())
      at = Workers.get!(told.id).rebooted_at

      assert row.(told) =~
               "unhealthy since #{Calendar.strftime(at, "%H:%M UTC")}: PID 1 did not answer"

      assert row.(told) =~
               "told to reboot at #{Calendar.strftime(at, "%H:%M UTC")}; takes work again when " <>
                 "it rejoins healthy"

      assert row.(permanent) =~ "not the platform&#39;s to reboot: restart it"
      refute row.(permanent) =~ "told to reboot"
      assert row.(again) =~ "rebooted within the hour, so not again: destroy it"
      refute row.(again) =~ "told to reboot"
      refute row.(well) =~ "unhealthy"

      view |> element("button[phx-click=toggle-destroyed]") |> render_click()
      refute row.(gone) =~ "unhealthy"
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

      assert has_element?(view, "#destroy-#{w.id}-ask", "Destroy machine")
      assert render(button) =~ "Destroy it"
      # The confirm says what will happen, from the one definition of it, in place.
      assert view |> element("#destroy-#{w.id}-confirm") |> render() =~
               "It is deleted at the provider, and its 1 running job is requeued."

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

      confirm = view |> element("#destroy-#{w.id}-confirm") |> render()
      assert render(button) =~ "Retire it"
      assert confirm =~ "the machine itself keeps running"
      assert confirm =~ "nothing is running on it to requeue"

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
      # In the row whose button was pressed (`ui.md` § Errors stay where you acted).
      assert view |> element("#worker-#{w.id} #refused-#{w.id}[role=alert]") |> render() =~
               "--force"

      # That row and no other: a second machine draws nothing of it.
      other = worker(user, %{managed: true, provider_id: "fake-8"})
      {:ok, view, _html} = live(conn, ~p"/workers")
      view |> element("#worker-#{w.id} button[phx-click=destroy]") |> render_click()
      assert has_element?(view, "#worker-#{w.id} [role=alert]")
      refute has_element?(view, "#worker-#{other.id} [role=alert]")

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

      assert view |> element("#destroy-#{w.id}-confirm") |> render() =~
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
    assert quiet =~ "being made"
    assert quiet =~ "last seen never"
    refute quiet =~ "idle now"

    {:ok, w} = Workers.ready(w, %{"memory_budget" => 8_000})
    job = Forge.ForgeFixtures.job_fixture(%{status: :running, worker_id: w.id})

    {:ok, view, _html} = live(conn, ~p"/workers")
    busy = text_of(view, "#worker-#{w.id}")

    assert busy =~ "#{job.state} ##{job.attempt}"
    refute busy =~ "being made"
    assert busy =~ "last seen just now"
  end

  test "an idle machine says since when", %{conn: conn, user: user} do
    w = worker(user)
    {:ok, _w} = Workers.ready(w, %{"memory_budget" => 8_000})

    {:ok, view, _html} = live(conn, ~p"/workers")

    # In the sentence's own words under a minute: never "last seen now · idle now" (r3 L3).
    assert text_of(view, "#worker-#{w.id}") =~ "last seen just now · idle &lt;1m"
  end

  # On a provider that bills every started hour, an idle machine outlives its period to the end of
  # the hour it has paid for — which, undrawn, reads as a sweep that forgot it.
  test "an idle machine the platform made says when it goes", %{conn: conn, user: user} do
    Forge.Provider.Fake.billing(:timer.hours(1))
    on_exit(&Forge.Provider.Fake.allow/0)

    w = worker(user)
    {:ok, _w} = Workers.ready(w, %{"memory_budget" => 8_000})

    # Twenty minutes and a half into its hour, so its last five open in thirty-four and a half.
    made = DateTime.add(DateTime.utc_now(:second), -(20 * 60 + 30))
    require Ecto.Query

    Forge.Repo.update_all(
      Ecto.Query.from(r in Forge.Workers.Worker, where: r.id == ^w.id),
      set: [inserted_at: made]
    )

    permanent = worker(user, %{managed: false})
    {:ok, _permanent} = Workers.ready(permanent, %{"memory_budget" => 8_000})

    {:ok, view, _html} = live(conn, ~p"/workers")

    assert text_of(view, "#worker-#{w.id}") =~ "idle &lt;1m"
    assert text_of(view, "#worker-#{w.id} .machine-doing") =~ "goes in 34m unless work arrives"
    # The sweep never takes a machine the platform did not make.
    refute text_of(view, "#worker-#{permanent.id}") =~ "goes"
  end

  # Criterion 24: a machine that predates counting tokens during a run takes no job of any kind,
  # and the page says why — not the per-job-credentials sentence, which would be the wrong cause.
  test "a machine on protocol 10 is said to take no job, and why", %{conn: conn, user: user} do
    old = worker(user)
    {:ok, old} = Workers.ready(old, %{"memory_budget" => 8_000})
    current = worker(user)
    {:ok, current} = Workers.ready(current, %{"memory_budget" => 8_000})

    require Ecto.Query

    for {w, protocol} <- [{old, Jobs.usage_protocol() - 1}, {current, Jobs.usage_protocol()}] do
      Forge.Repo.update_all(Ecto.Query.from(r in Forge.Workers.Worker, where: r.id == ^w.id),
        set: [protocol: protocol]
      )
    end

    {:ok, view, _html} = live(conn, ~p"/workers")

    assert text_of(view, "#worker-#{old.id}-too-old") =~
             "takes no job: it speaks protocol 10 and counting tokens during a run needs 11; update it"

    refute has_element?(view, "#worker-#{current.id}-too-old")
  end

  # `Format.until/2` says "now" for a moment already here, and the row would read "goes in now".
  test "an idle machine whose moment has come says it goes now", %{conn: conn, user: user} do
    w = worker(user)
    {:ok, w} = Workers.ready(w, %{"memory_budget" => 8_000})

    {:ok, _w} =
      Workers.update(w, %{idle_since: DateTime.add(DateTime.utc_now(:second), -600)})

    {:ok, view, _html} = live(conn, ~p"/workers")

    assert text_of(view, "#worker-#{w.id} .machine-doing") =~ "goes now unless work arrives"
    refute text_of(view, "#worker-#{w.id}") =~ "goes in"
  end

  # The head of a row says what the machine is doing in words (`12f`), and names the ticket a job
  # is for — but only in a project the viewer is in. The machine is the owner's; the work it runs
  # is a project's, and its owner may have left that project since.
  describe "what a machine is doing" do
    test "a job names its ticket only in a project the viewer is in", %{conn: conn, user: user} do
      w = worker(user)
      {:ok, w} = Workers.ready(w, %{"memory_budget" => 8_000})

      mine =
        Forge.ForgeFixtures.project_fixture(%{name: "mine-#{System.unique_integer([:positive])}"})

      Forge.ForgeFixtures.join!(mine, user)

      theirs =
        Forge.ForgeFixtures.project_fixture(%{
          name: "hidden-#{System.unique_integer([:positive])}"
        })

      seen = Forge.ForgeFixtures.ticket_fixture(%{project: mine, state: "implementing"})
      unseen = Forge.ForgeFixtures.ticket_fixture(%{project: theirs, state: "reviewing"})
      Forge.ForgeFixtures.job_fixture(%{ticket: seen, status: :running, worker_id: w.id})
      Forge.ForgeFixtures.job_fixture(%{ticket: unseen, status: :running, worker_id: w.id})

      {:ok, view, html} = live(conn, ~p"/workers")
      doing = text_of(view, "#worker-#{w.id} .machine-doing")

      assert doing =~ "implementing #1 · #{mine.name}##{seen.number}"
      assert doing =~ "reviewing #1"
      refute html =~ theirs.name
    end

    test "a chat says it is one", %{conn: conn, user: user} do
      w = worker(user)
      project = Forge.ForgeFixtures.project_fixture()
      Forge.ForgeFixtures.join!(project, user)
      Forge.ForgeFixtures.chat_fixture(%{project: project, status: :running, worker_id: w.id})

      {:ok, view, _html} = live(conn, ~p"/workers")

      assert text_of(view, "#worker-#{w.id} .machine-doing") =~ "chat · #{project.name}"
    end

    test "a machine with nothing to do waits for work, and a destroyed one says when it went", %{
      conn: conn,
      user: user
    } do
      waiting = worker(user, %{managed: false})
      {:ok, _} = Workers.ready(waiting, %{"memory_budget" => 8_000})
      gone = worker(user)
      {:ok, _} = Workers.status(gone, :destroyed)

      {:ok, view, _html} = live(conn, ~p"/workers")
      render_click(view, "toggle-destroyed")

      assert text_of(view, "#worker-#{waiting.id} .machine-doing") =~ "waiting for work"
      assert text_of(view, "#worker-#{gone.id} .machine-doing") =~ "destroyed just now"
      assert text_of(view, "#worker-#{gone.id} .machine-status") =~ "gone"
    end
  end

  # The subline adds up the fleet, and the slots say how full the viewer's templates are (`12f`).
  describe "the summary" do
    defp full_template(user, max) do
      {:ok, template} =
        Forge.Provisioning.create_template(user, %{
          name: "t-#{System.unique_integer([:positive])}",
          provider: "fake",
          memory: 8_000,
          cores: 2,
          max_workers: max
        })

      template
    end

    test "counts busy and idle machines, and the templates at their limit", %{
      conn: conn,
      user: user
    } do
      full = full_template(user, 1)
      _room = full_template(user, 3)
      made = worker(user, Forge.Provisioning.Template.worker_attrs(full))
      {:ok, made} = Workers.ready(made, %{"memory_budget" => 8_000})
      {:ok, _} = Workers.status(made, :busy)
      idle = worker(user, %{managed: false})
      {:ok, _} = Workers.ready(idle, %{"memory_budget" => 8_000})

      {:ok, view, _html} = live(conn, ~p"/workers")

      assert text_of(view, "#top-bar .ui-top-title > .ui-top-sub") =~
               "1 busy · 1 idle · 1 template at its limit"

      # One slot per machine there is, then one per machine the templates may still make.
      assert length(Regex.scan(~r/machines-slot--busy/, render(view))) == 1
      assert length(Regex.scan(~r/machines-slot--up/, render(view))) == 1
      assert length(Regex.scan(~r/machines-slot--free/, render(view))) == 3
    end

    test "a template with room is not at its limit", %{conn: conn, user: user} do
      template = full_template(user, 2)
      worker(user, Forge.Provisioning.Template.worker_attrs(template))

      {:ok, view, _html} = live(conn, ~p"/workers")

      assert text_of(view, "#top-bar .ui-top-title > .ui-top-sub") =~ "0 busy"
      refute render(view) =~ "at its limit"
    end
  end

  # Machines · Templates · Credentials, in the strip on a phone and the tabs on a desktop, from one
  # list (`docs/design/ui.md` § Machines).
  test "the three views lead to the machines, the templates and the credentials", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workers")

    assert has_element?(view, ~s(.frame-strip a[href="/workers"]), "Machines")
    assert has_element?(view, ~s(.frame-strip a[href="/templates"]), "Templates")

    assert has_element?(
             view,
             ~s(.frame-strip a[href="/templates?view=credentials"]),
             "Credentials"
           )
  end

  # The wide screen's right column (`12o`): the viewer's own templates, each with its slots, and
  # credentials, each with how many templates name it — and nobody else's.
  test "the right column lists the viewer's templates and credentials", %{conn: conn, user: user} do
    {:ok, credential} =
      Forge.Provisioning.create_credential(user, %{
        name: "acct",
        provider: "fake",
        secret: %{"token" => "t"}
      })

    {:ok, template} =
      Forge.Provisioning.create_template(user, %{
        name: "mine-cx32",
        provider: "fake",
        memory: 8_000,
        cores: 2,
        max_workers: 1,
        provider_credential_id: credential.id
      })

    worker(user, Forge.Provisioning.Template.worker_attrs(template))

    {:ok, _} =
      Forge.Provisioning.create_template(Forge.AccountsFixtures.user_fixture(), %{
        name: "theirs-cx22",
        provider: "fake",
        memory: 8_000,
        cores: 2
      })

    {:ok, view, html} = live(conn, ~p"/workers")

    assert has_element?(
             view,
             ~s(#machines-templates a[href="/templates?template=#{template.id}"] .template-slots--full),
             "1 of 1"
           )

    assert text_of(view, "#machines-credentials") =~ "fake · 1 template"
    refute html =~ "theirs-cx22"
  end

  test "it requires a logged-in operator" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/workers")
  end

  test "a worker's unassign and its select hold the 46px floor", %{conn: conn, user: user} do
    {:ok, project} =
      Forge.Projects.register(
        %{name: "floor", repo_path: Forge.GitFixtures.seeded_repo()},
        user
      )

    {:ok, worker, _token} =
      Workers.create(%{provider: "fake", managed: false, user_id: user.id})

    {:ok, _} = Workers.assign(user, worker.id, project.id)
    # A second project, so the select has one to offer.
    {:ok, _} =
      Forge.Projects.register(
        %{name: "floor-2", repo_path: Forge.GitFixtures.seeded_repo()},
        user
      )

    {:ok, view, _html} = live(conn, ~p"/workers")

    unassign = view |> element(~s(button[phx-click="unassign"])) |> render()
    assert unassign =~ "min-h-[46px]"
    assert unassign =~ "min-w-[46px]"
    assert view |> element(~s(form[phx-submit="assign"] select)) |> render() =~ "h-[46px]"
  end
end
