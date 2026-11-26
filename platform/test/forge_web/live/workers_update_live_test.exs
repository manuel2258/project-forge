defmodule ForgeWeb.WorkersUpdateLiveTest do
  @moduledoc """
  What the machines view says about a permanent machine's update, and the two writes the owner
  has over it (`docs/design/ui.md` § The machines view, `docs/design/worker-tier.md` § Updating a
  permanent machine): the switch, the one line in words, *Update now*, the words that end the
  lines that said *update it*, the count in the subline and the disk breakdown.
  """

  use ForgeWeb.ConnCase, async: false

  import Forge.AccountsFixtures, only: [user_fixture: 0, node_admin_fixture: 0]
  import Forge.ImageBuildsFixtures, only: [put_release: 0, put_release: 1, release_build: 0]
  import Phoenix.LiveViewTest

  alias Forge.Workers
  alias ForgeWeb.WorkerUpdate

  setup :register_and_log_in_user

  setup do
    put_release()
    :ok
  end

  # A permanent machine of `owner`'s, current protocol, on an older build than the platform's.
  # `connected: true` registers this test process as its channel, so what the platform sends it
  # arrives in the mailbox.
  defp machine(owner, attrs \\ %{}, opts \\ []) do
    {:ok, worker, _token} =
      Workers.create(%{provider: "fake", managed: false, user_id: owner.id})

    {:ok, worker} =
      Workers.update(
        worker,
        Map.merge(
          %{
            protocol: ForgeCore.WorkerProtocol.current(),
            build: "oldoldoldold",
            release: "0.19.0 (oldoldoldold)",
            status: :ready,
            memory_budget: 8_000_000_000,
            cores: 4,
            last_seen_at: DateTime.utc_now(:second)
          },
          attrs
        )
      )

    if Keyword.get(opts, :connected, true), do: :ok = Workers.connected(worker.id)
    worker
  end

  defp page(conn, worker) do
    {:ok, view, _html} = live(conn, ~p"/workers")
    {view, text(view |> element("#worker-#{worker.id}") |> render())}
  end

  defp text(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp line(view, worker),
    do: view |> element("#update-line-#{worker.id}") |> render() |> text()

  describe "the switch" do
    test "is on a permanent machine, on, and saves when it is flipped", %{conn: conn, user: user} do
      worker = machine(user)
      {:ok, view, _html} = live(conn, ~p"/workers")

      assert has_element?(view, ~s(#update-auto-#{worker.id}[role="switch"][aria-checked="true"]))
      assert render(view) =~ "Update automatically"

      view |> element("#update-auto-#{worker.id}") |> render_click()
      refute Workers.get!(worker.id).auto_update
      assert has_element?(view, ~s(#update-auto-#{worker.id}[aria-checked="false"]))

      view |> element("#update-auto-#{worker.id}") |> render_click()
      assert Workers.get!(worker.id).auto_update
    end

    test "is not on a machine the platform made, nor on a node with no release", %{
      conn: conn,
      user: user
    } do
      made = machine(user, %{managed: true})
      {view, _text} = page(conn, made)
      refute has_element?(view, "#update-auto-#{made.id}")
      refute has_element?(view, "#update-#{made.id}")

      put_release(nil)
      permanent = machine(user)
      {view, _text} = page(conn, permanent)
      refute has_element?(view, "#update-auto-#{permanent.id}")
      refute has_element?(view, "#update-line-#{permanent.id}")
    end

    test "is not on a machine on the old layout, which cannot update itself", %{
      conn: conn,
      user: user
    } do
      worker = machine(user, %{update_state: %{"unable" => "layout"}})
      {view, text} = page(conn, worker)
      refute has_element?(view, "#update-auto-#{worker.id}")

      assert text =~
               "cannot update itself: its boot partition holds one system; reinstall it once from the current image"

      assert view |> element("#update-line-#{worker.id}") |> render() =~ "text-warning"
    end

    test "is the owner's: somebody else's id posted by hand is not here, and nothing is written",
         %{
           conn: conn,
           user: user
         } do
      mine = machine(user)
      theirs = machine(user_fixture())
      {view, _text} = page(conn, mine)

      html = render_click(view, "update-auto", %{"id" => theirs.id, "on" => "false"})
      assert html =~ "That machine is not here."
      assert Workers.get!(theirs.id).auto_update

      render_click(view, "update-auto", %{"id" => theirs.id, "on" => "banana"})
      assert render_click(view, "update-auto", %{"id" => mine.id, "on" => "banana"}) =~ "not here"
      render_click(view, "update-auto", %{})
      assert Workers.get!(theirs.id).auto_update
      assert Workers.get!(mine.id).auto_update
      refute_received {:update, _payload}
    end

    test "is not a node admin's: they may not write another person's machine", %{user: user} do
      mine = machine(user)
      admin = node_admin_fixture()

      assert {:error, :not_found} = Forge.Workers.Updates.set_automatic(admin, mine.id, false)
      assert {:error, :not_found} = Forge.Workers.Updates.update_now(admin, mine.id)
      assert Workers.get!(mine.id).auto_update
    end
  end

  describe "the line, in words" do
    test "says an update is waiting when automatic updates are off, with Update now", %{
      conn: conn,
      user: user
    } do
      worker = machine(user, %{auto_update: false})
      {view, _text} = page(conn, worker)
      assert line(view, worker) == "update to 0.20.0 waiting: automatic updates are off"
      assert has_element?(view, "#update-now-#{worker.id}")
    end

    test "names the version and never the build", %{conn: conn, user: user} do
      worker = machine(user, %{auto_update: false})
      {view, _text} = page(conn, worker)
      refute line(view, worker) =~ release_build()
    end

    test "says a machine not connected will update when it next connects", %{
      conn: conn,
      user: user
    } do
      worker = machine(user, %{}, connected: false)
      {view, _text} = page(conn, worker)
      assert line(view, worker) == "update to 0.20.0 waiting: it updates when it next connects"
    end

    test "draws nothing for a machine on the platform's own build", %{conn: conn, user: user} do
      worker = machine(user, %{build: release_build()})
      {view, _text} = page(conn, worker)
      refute has_element?(view, "#update-line-#{worker.id}")
    end

    test "draws every step of one under way, in steps and not percentages", %{
      conn: conn,
      user: user
    } do
      worker = machine(user)
      {:ok, view, _html} = live(conn, ~p"/workers")

      for {state, words} <- [
            {%{"step" => "downloading", "target_version" => "0.20.0"},
             "updating to 0.20.0: downloading"},
            {%{"step" => "installing", "target_version" => "0.20.0"},
             "updating to 0.20.0: installing"},
            {%{
               "step" => "pausing",
               "target_version" => "0.20.0",
               "jobs" => ["a", "b"],
               "chats" => ["c"]
             }, "updating to 0.20.0: pausing: 2 jobs paused, 1 chat ends after its turn"},
            {%{
               "step" => "pausing",
               "target_version" => "0.20.0",
               "jobs" => ["a"],
               "chats" => ["c", "d"]
             }, "updating to 0.20.0: pausing: 1 job paused, 2 chats end after its turn"},
            {%{"step" => "restarting", "target_version" => "0.20.0"},
             "updating to 0.20.0: restarting"},
            {%{"step" => "trying", "target_version" => "0.20.0"},
             "trying 0.20.0: kept once the platform accepts it"}
          ] do
        {:ok, _} = Workers.update(worker, %{update_state: state})
        send(view.pid, :refresh)
        assert line(view, worker) == words
        refute line(view, worker) =~ "%"
      end
    end

    test "says a failure in danger, where, why and when it tries again", %{
      conn: conn,
      user: user
    } do
      retry =
        DateTime.new!(Date.utc_today(), ~T[15:20:00], "Etc/UTC") |> DateTime.to_unix(:millisecond)

      worker =
        machine(user, %{
          update_state: %{
            "step" => "failed",
            "failed_step" => "downloading",
            "reason" => "the download is not sha256:abc",
            "next_at" => retry,
            "attempt" => 2,
            "target_version" => "0.20.0"
          }
        })

      {view, _text} = page(conn, worker)

      assert line(view, worker) ==
               "update to 0.20.0 failed while downloading: the download is not sha256:abc: tries again at 15:20 UTC (2 of 3)"

      assert view |> element("#update-line-#{worker.id}") |> render() =~ "text-danger"
      assert has_element?(view, "#update-now-#{worker.id}")
    end

    test "says when it stopped trying, and still offers Update now", %{conn: conn, user: user} do
      worker =
        machine(user, %{
          update_state: %{
            "step" => "gave_up",
            "failed_step" => "installing",
            "reason" => "no room",
            "target_version" => "0.20.0"
          }
        })

      {view, _text} = page(conn, worker)

      assert line(view, worker) ==
               "update to 0.20.0 failed while installing: no room: stopped after 3 tries"

      assert has_element?(view, "#update-now-#{worker.id}")
    end

    test "says a system that was not accepted, and what it is back on", %{conn: conn, user: user} do
      worker =
        machine(user, %{
          update_state: %{
            "step" => "fell_back",
            "reason" => "not accepted",
            "target_version" => "0.20.0"
          }
        })

      {view, _text} = page(conn, worker)

      assert line(view, worker) ==
               "0.20.0 was not accepted within 15 minutes; back on 0.19.0: stopped after 3 tries"

      assert view |> element("#update-line-#{worker.id}") |> render() =~ "text-danger"
    end

    test "says nothing of a failure on a machine that is on the platform's own build", %{
      conn: conn,
      user: user
    } do
      for step <- ["failed", "gave_up", "fell_back"] do
        worker = machine(user, %{build: release_build(), update_state: %{"step" => step}})
        {view, _text} = page(conn, worker)
        refute has_element?(view, "#update-line-#{worker.id}"), step
      end
    end

    test "says one that never came up differently", %{conn: conn, user: user} do
      worker =
        machine(user, %{
          update_state: %{
            "step" => "fell_back",
            "reason" => "the new system did not come up",
            "target_version" => "0.20.0",
            "next_at" => System.os_time(:millisecond) + 900_000
          }
        })

      {view, _text} = page(conn, worker)
      assert line(view, worker) =~ "0.20.0 did not come up; back on 0.19.0: tries again at"
    end
  end

  describe "Update now" do
    test "is offered to a connected machine on another build, with a confirm that says what it does",
         %{conn: conn, user: user} do
      worker = machine(user)
      {view, _text} = page(conn, worker)

      assert has_element?(view, "#update-now-#{worker.id}-ask", "Update now")

      assert view
             |> element("#update-now-#{worker.id}-confirm .ui-confirm-sentence")
             |> render()
             |> text() == WorkerUpdate.update_confirm(0, 0)

      assert WorkerUpdate.update_confirm(2, 1) ==
               "Update this machine now? It pauses its 2 running jobs, which resume afterwards, ends 1 conversation after its current turn, and restarts the machine."

      assert WorkerUpdate.update_confirm(0, 2) =~ "ends 2 conversations after their current turn"
    end

    test "counts what is running in the confirm", %{conn: conn, user: user} do
      worker = machine(user)

      for _job <- 1..2 do
        job = Forge.ForgeFixtures.job_fixture(%{status: :running})

        {:ok, _job} =
          job |> Forge.Jobs.Job.progress_changeset(%{worker_id: worker.id}) |> Forge.Repo.update()
      end

      {view, _text} = page(conn, worker)

      confirm =
        view
        |> element("#update-now-#{worker.id}-confirm .ui-confirm-sentence")
        |> render()
        |> text()

      assert confirm =~ "pauses its 2 running jobs"
    end

    test "sends the platform's target with the owner's name, and nothing else is changed", %{
      conn: conn,
      user: user
    } do
      worker = machine(user, %{auto_update: false})
      {view, _text} = page(conn, worker)

      view |> element("#update-now-#{worker.id}") |> render_click()
      assert_received {:update, %{"target" => %{"build" => build}, "requested_by" => requested}}
      assert build == release_build()
      assert requested == user.email
      refute Workers.get!(worker.id).auto_update
    end

    test "is not offered to a machine that is not connected, a refused one included", %{
      conn: conn,
      user: user
    } do
      away = machine(user, %{}, connected: false)
      refused = machine(user, %{protocol: 3}, connected: false)

      for worker <- [away, refused] do
        {view, _text} = page(conn, worker)
        refute has_element?(view, "#update-now-#{worker.id}")
      end

      assert {:error, :not_connected} = Forge.Workers.Updates.update_now(user, away.id)
      refute_received {:update, _payload}
    end

    test "is not offered while one is under way, nor on the platform's own build", %{
      conn: conn,
      user: user
    } do
      going = machine(user, %{update_state: %{"step" => "installing"}})
      current = machine(user, %{build: release_build()})

      for worker <- [going, current] do
        {view, _text} = page(conn, worker)
        refute has_element?(view, "#update-now-#{worker.id}")
      end
    end

    test "is the owner's: another person's id posted by hand sends nothing", %{
      conn: conn,
      user: user
    } do
      mine = machine(user)
      theirs = machine(user_fixture())
      {view, _text} = page(conn, mine)

      assert render_click(view, "update-now", %{"id" => theirs.id}) =~ "That machine is not here."
      assert render_click(view, "update-now", %{}) =~ "That machine is not here."
      refute_received {:update, _payload}
    end

    test "tells the owner when there is nothing to do, instead of failing", %{
      conn: conn,
      user: user
    } do
      worker = machine(user, %{build: release_build()})
      {view, _text} = page(conn, worker)
      assert render_click(view, "update-now", %{"id" => worker.id}) =~ "nothing to update"
    end
  end

  describe "the lines that said update it" do
    test "the refusal line points at the reinstall on a machine that cannot update itself", %{
      conn: conn,
      user: user
    } do
      worker =
        machine(user, %{protocol: 3, update_state: %{"unable" => "layout"}}, connected: false)

      {_view, text} = page(conn, worker)
      assert text =~ "refused: protocol 3, this platform accepts 4–17 — "
      assert text =~ "reinstall it once from the current image"
      refute text =~ "accepts 4–17 — update it"
    end

    test "with the switch on and an update that can run, it is updating itself", %{
      conn: conn,
      user: user
    } do
      worker =
        machine(user, %{protocol: ForgeCore.WorkerProtocol.current() + 1}, connected: false)

      {_view, text} = page(conn, worker)
      assert text =~ "this platform accepts 4–17 — it is updating itself"
    end

    test "with the switch off it says to turn it on, or to press Update now when connected", %{
      conn: conn,
      user: user
    } do
      away =
        machine(
          user,
          %{protocol: ForgeCore.WorkerProtocol.current() + 1, auto_update: false},
          connected: false
        )

      {_view, text} = page(conn, away)
      assert text =~ "— turn on automatic updates and it updates when it next connects"

      assert WorkerUpdate.ending(machine(user, %{auto_update: false}), true) == "press Update now"
    end

    test "a managed machine keeps update it, and so does a node with no release", %{user: user} do
      assert WorkerUpdate.ending(machine(user, %{managed: true}), true) == "update it"
      put_release(nil)
      assert WorkerUpdate.ending(machine(user), true) == "update it"
    end

    test "takes no job: it speaks protocol 10 ends with the reinstall sentence", %{
      conn: conn,
      user: user
    } do
      worker = machine(user, %{protocol: 10})
      {_view, text} = page(conn, worker)
      assert text =~ "needs 11; reinstall it once from the current image"
    end
  end

  describe "the subline" do
    test "counts machines that are updating", %{conn: conn, user: user} do
      machine(user, %{update_state: %{"step" => "installing"}})
      machine(user, %{update_state: %{"step" => "trying"}})
      machine(user)
      {:ok, view, _html} = live(conn, ~p"/workers")
      assert render(view) =~ "2 updating"
    end

    test "says nothing when none is", %{conn: conn, user: user} do
      machine(user)
      {:ok, view, _html} = live(conn, ~p"/workers")
      refute render(view) =~ ~r/\d updating/
    end
  end

  describe "the disk breakdown" do
    @report %{
      "at" => 1,
      "kinds" => %{
        "nix_store" => 12 * 1_073_741_824,
        "volumes" => 3_328_599_654,
        "seeds" => 1_048_576,
        "jobs" => 2048,
        "rest" => 100
      },
      "cleanups" => %{"volumes" => %{"at" => 0, "freed" => 3_328_599_654}}
    }

    defp reported(user, ago_s, extra \\ %{}, opts \\ []) do
      at = System.os_time(:millisecond) - 2 * 3_600_000
      report = put_in(@report, ["cleanups", "volumes", "at"], at)
      reported_at = DateTime.add(DateTime.utc_now(:second), -ago_s)

      machine(
        user,
        Map.merge(%{disk_report: report, disk_reported_at: reported_at}, extra),
        opts
      )
    end

    test "names each kind's size and each rule's last run, neutral", %{conn: conn, user: user} do
      worker = reported(user, 90)
      {view, text} = page(conn, worker)
      assert text =~ "Nix store 12.0 GiB"
      assert text =~ "ticket volumes 3.1 GiB"
      assert text =~ "seeds 1.0 MiB"
      assert text =~ "job directories 2 KiB"
      assert text =~ "the rest 100 B"
      assert text =~ "ticket volumes swept 2h ago, freed 3.1 GiB"
      assert text =~ "Nix store collected: not run since boot"
      assert text =~ "measured 1m ago"
      refute view |> element("#breakdown-#{worker.id}") |> render() =~ "text-warning"
      refute view |> element("#breakdown-#{worker.id}") |> render() =~ "text-danger"
    end

    test "is drawn while the machine is away, with its age, and the meters are not", %{
      conn: conn,
      user: user
    } do
      worker = reported(user, 3 * 86_400, %{}, connected: false)
      {view, text} = page(conn, worker)
      assert text =~ "measured 3d ago"
      assert text =~ "Nix store 12.0 GiB"
      refute has_element?(view, "#worker-#{worker.id} .machine-meters")
    end

    test "says not measured yet before its first report", %{conn: conn, user: user} do
      {_view, text} = page(conn, machine(user))
      assert text =~ "not measured yet"
    end

    test "says a release that sends none should be updated", %{conn: conn, user: user} do
      {_view, text} = page(conn, machine(user, %{protocol: 11}))
      assert text =~ "no breakdown: update it"
    end

    test "names no ticket, project or path", %{conn: conn, user: user} do
      worker = reported(user, 10)
      {view, _text} = page(conn, worker)
      html = view |> element("#breakdown-#{worker.id}") |> render()
      refute html =~ "/var/lib"
      refute html =~ "ticket/"
    end
  end

  describe "what a machine says is text" do
    test "is drawn escaped, clipped to a line, with the whole of it in the title", %{
      conn: conn,
      user: user
    } do
      hostile = "<script>alert(1)</script><b>" <> String.duplicate("x", 400)

      worker =
        machine(user, %{
          update_state: %{
            "step" => "failed",
            "failed_step" => "<i>installing</i>",
            "reason" => hostile,
            "target_version" => "<img src=x>"
          }
        })

      {view, _text} = page(conn, worker)
      html = view |> element("#update-line-#{worker.id}") |> render()
      refute html =~ "<script>"
      refute html =~ "<img"
      assert html =~ "&lt;script&gt;"
      assert html =~ ~s(title="update to &lt;img src=x&gt; failed)
      assert html =~ "machine-update-line"
    end

    test "a value of the wrong type is left out, and the page mounts for good", %{
      conn: conn,
      user: user
    } do
      worker =
        machine(user, %{
          update_state: %{
            "step" => %{"a" => 1},
            "reason" => ["x"],
            "next_at" => "soon",
            "failed_step" => 7,
            "jobs" => %{"k" => 1},
            "target_version" => %{"v" => 1}
          },
          disk_report: %{
            "kinds" => %{"nix_store" => "lots", "volumes" => %{"a" => 1}},
            "cleanups" => "none"
          }
        })

      {:ok, view, _html} = live(conn, ~p"/workers")
      assert has_element?(view, "#worker-#{worker.id}")
      assert line(view, worker) == "update to 0.20.0 waiting: it starts shortly"

      {:ok, _detail, html} = live(conn, ~p"/workers/#{worker.id}")
      assert html =~ "Update automatically"
    end

    test "a machine that has never joined has no line, since nothing is known of it yet" do
      worker = %Forge.Workers.Worker{
        managed: false,
        template_id: nil,
        status: :ready,
        protocol: nil,
        build: nil
      }

      assert WorkerUpdate.line(worker, false) == nil
    end

    test "a time past the year 9999 is a number and not a time, and the page still mounts", %{
      conn: conn,
      user: user
    } do
      absurd = 1_000_000_000_000_000

      worker =
        machine(user, %{
          update_state: %{
            "step" => "failed",
            "failed_step" => "downloading",
            "reason" => "no route",
            "attempt" => 2,
            "next_at" => absurd
          },
          disk_report: %{
            "kinds" => %{"nix_store" => 10},
            "cleanups" => %{"jobs" => %{"at" => absurd, "freed" => 5}}
          }
        })

      {:ok, view, _html} = live(conn, ~p"/workers")
      assert line(view, worker) == "update to 0.20.0 failed while downloading: no route"

      {:ok, _detail, html} = live(conn, ~p"/workers/#{worker.id}")
      assert html =~ "Update automatically"
      assert html =~ "job directories swept: not run since boot"
    end

    test "a cleanup the machine dates before 1970 is not drawn as having run",
         %{conn: conn, user: user} do
      # What the platform stores for a report whose `at` is far later than a cleanup's: the age is
      # subtracted from the time of receipt, which goes below zero.
      worker =
        machine(user, %{
          disk_report: %{
            "kinds" => %{"nix_store" => 10},
            "cleanups" => %{"jobs" => %{"at" => -200_000_000_000, "freed" => 5}}
          }
        })

      {:ok, _detail, html} = live(conn, ~p"/workers/#{worker.id}")
      assert html =~ "job directories swept: not run since boot"
      refute html =~ "job directories swept 23"
    end

    test "a disk report of the wrong shape is read as none", %{conn: conn, user: user} do
      worker = machine(user, %{disk_report: %{"kinds" => "huge"}})
      {_view, text} = page(conn, worker)
      assert text =~ "not measured yet"
    end
  end

  describe "the machine's own page" do
    test "draws the line, the breakdown and the switch, and the owner may use them", %{
      conn: conn,
      user: user
    } do
      worker = machine(user, %{disk_report: @report, disk_reported_at: DateTime.utc_now(:second)})
      {:ok, view, _html} = live(conn, ~p"/workers/#{worker.id}")

      assert has_element?(view, "#update-auto-#{worker.id}")
      assert has_element?(view, "#update-line-#{worker.id}")
      assert has_element?(view, "#breakdown-#{worker.id}", "Nix store 12.0 GiB")

      view |> element("#update-auto-#{worker.id}") |> render_click()
      refute Workers.get!(worker.id).auto_update
      assert render(view) =~ ~s(aria-checked="false")
    end

    test "says why a press did nothing", %{conn: conn, user: user} do
      worker = machine(user)
      {:ok, view, _html} = live(conn, ~p"/workers/#{worker.id}")

      assert render_click(view, "update-auto", %{"id" => Ecto.UUID.generate(), "on" => "false"}) =~
               "That machine is not here."

      assert render_click(view, "update-now", %{"id" => Ecto.UUID.generate()}) =~
               "That machine is not here."
    end

    test "is not another person's to open", %{conn: conn} do
      theirs = machine(user_fixture())
      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/workers/#{theirs.id}") end
    end
  end
end
