defmodule Forge.Look.Setups.MachineUpdates do
  @moduledoc """
  A permanent machine's update, as the machines pages draw it (`docs/design/ui.md` § The machines
  view): one owner's machines in each state the line has — waiting with the switch off, under way,
  pausing, failed with a retry, stopped, not accepted, on the old layout, a hostile long reason —
  and a disk breakdown, measured days ago, on one that is away. A node with a release, so the line
  has a version to name (`0.23.0`, made up).

  **Some machines are connected**: this setup keeps a process alive that registers as each one's
  channel, which is what makes *Update now* and the meters' absence appear; a look has otherwise no
  channel. Users: `owner`. Paths: `machines` (the list), `failed` (one machine's page).
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures

  alias Forge.{WorkerImage, Workers}

  @gib 1_073_741_824

  @impl true
  def build do
    owner = user_fixture()

    # A release the platform ships, made up: the line names its version and compares its build.
    Application.put_env(:forge, WorkerImage,
      release: %{
        "build" => "abcdef123456",
        "version" => "0.23.0",
        "protocol" => "13",
        "repository" => "ghcr.io/owner/forge-worker-image",
        "digest" => "sha256:" <> String.duplicate("a", 64),
        "raw_sha256" => String.duplicate("b", 64),
        "raw_size" => "4096"
      }
    )

    now_ms = System.os_time(:millisecond)

    waiting = machine(owner, %{auto_update: false}, connected: true)

    machine(owner, %{update_state: %{"step" => "installing", "target_version" => "0.23.0"}},
      connected: true
    )

    machine(
      owner,
      %{
        update_state: %{
          "step" => "pausing",
          "target_version" => "0.23.0",
          "jobs" => ["a", "b"],
          "chats" => ["c"]
        }
      },
      connected: true
    )

    failed =
      machine(
        owner,
        %{
          update_state: %{
            "step" => "failed",
            "failed_step" => "downloading",
            "reason" => "the download is not sha256:3f2a…",
            "target_version" => "0.23.0",
            "attempt" => 2,
            "next_at" => now_ms + 15 * 60_000
          }
        },
        connected: true
      )

    machine(
      owner,
      %{
        update_state: %{
          "step" => "gave_up",
          "failed_step" => "installing",
          "reason" =>
            "not enough room: 100 bytes free after collecting the Nix store, 15 GiB needed",
          "target_version" => "0.23.0"
        }
      },
      connected: true
    )

    machine(owner, %{
      update_state: %{
        "step" => "fell_back",
        "reason" => "the new system was not accepted by the platform within the time allowed",
        "target_version" => "0.23.0",
        "next_at" => now_ms + 3_600_000
      }
    })

    machine(owner, %{update_state: %{"unable" => "layout"}}, connected: true)

    machine(owner, %{
      update_state: %{
        "step" => "failed",
        "failed_step" => "installing",
        "reason" =>
          "<script>alert(1)</script> " <> String.duplicate("a very long reason with no end ", 12),
        "target_version" => "0.23.0",
        "next_at" => now_ms + 3_600_000
      }
    })

    machine(
      owner,
      %{
        disk_report: %{
          "at" => now_ms,
          "kinds" => %{
            "nix_store" => 42 * @gib,
            "volumes" => 3 * @gib + 100_000_000,
            "seeds" => 600_000_000,
            "jobs" => 12_000_000,
            "rest" => 5 * @gib
          },
          "cleanups" => %{
            "volumes" => %{"at" => now_ms - 2 * 3_600_000, "freed" => 3 * @gib + 100_000_000}
          }
        },
        disk_reported_at: DateTime.add(DateTime.utc_now(:second), -3 * 86_400)
      },
      []
    )

    %{
      users: %{"owner" => owner},
      paths: %{
        "machines" => "/workers",
        "failed" => "/workers/#{failed.id}",
        "waiting" => "/workers/#{waiting.id}"
      }
    }
  end

  defp machine(owner, attrs, opts \\ []) do
    {:ok, worker, _token} =
      Workers.create(%{provider: "fake", managed: false, user_id: owner.id})

    {:ok, worker} =
      Workers.update(
        worker,
        Map.merge(
          %{
            protocol: ForgeCore.WorkerProtocol.current(),
            build: "oldoldoldold",
            release: "0.22.0 (oldoldoldold)",
            harness: %{"driver" => "claude_code", "credential" => "per_job", "version" => "2.1.0"},
            status: :ready,
            memory_budget: 8 * @gib,
            cores: 4,
            last_seen_at: DateTime.utc_now(:second)
          },
          attrs
        )
      )

    if opts[:connected], do: hold_connected(worker.id)
    worker
  end

  # A channel that outlives the build: the registry lives with the process that registered.
  defp hold_connected(worker_id) do
    parent = self()

    spawn(fn ->
      :ok = Workers.connected(worker_id)
      send(parent, {:held, worker_id})
      Process.sleep(:infinity)
    end)

    receive do
      {:held, ^worker_id} -> :ok
    after
      5_000 -> raise "could not hold #{worker_id} connected"
    end
  end
end
