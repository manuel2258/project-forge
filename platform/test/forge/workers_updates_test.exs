defmodule Forge.Workers.UpdatesTest do
  @moduledoc """
  What the platform says to a permanent machine about updating itself, and what it does with what
  the machine says back (`docs/design/worker-tier.md` § Updating a permanent machine).
  """

  use Forge.DataCase, async: false

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.ImageBuildsFixtures

  alias Forge.{Jobs, Repo, Workers}
  alias Forge.Workers.{Log, Updates}

  setup do
    put_release()
    %{owner: user_fixture()}
  end

  # A permanent machine of `owner`'s, joined as a current worker on an older build, and connected
  # as this test process: what it is sent arrives in the mailbox.
  defp permanent(owner, attrs \\ %{}) do
    {:ok, worker, _token} =
      Workers.create(Map.merge(%{provider: "fake", managed: false, user_id: owner.id}, attrs))

    {:ok, worker} =
      Workers.update(worker, %{
        protocol: ForgeCore.WorkerProtocol.current(),
        build: "oldoldoldold",
        release: "0.19.0 (oldoldoldold)",
        memory_budget: 64 * 1024 * 1024 * 1024,
        cores: 16,
        status: :ready
      })

    :ok = Workers.connected(worker.id)
    worker
  end

  defp running(worker, attrs \\ %{}) do
    job = job_fixture(Map.put(attrs, :status, :running))
    {:ok, job} = job |> Jobs.Job.progress_changeset(%{worker_id: worker.id}) |> Repo.update()
    job
  end

  describe "target/1" do
    test "is the platform's own build, and carries what a machine checks it against", %{
      owner: owner
    } do
      assert %{
               "build" => "abcdef123456",
               "version" => "0.20.0",
               "repository" => "ghcr.io/owner/forge-worker-image",
               "digest" => "sha256:" <> _,
               "raw_sha256" => _,
               "raw_size" => 4096
             } = Updates.target(permanent(owner))
    end

    test "is the same in either direction: a machine ahead of its platform follows it down", %{
      owner: owner
    } do
      worker = permanent(owner) |> then(&elem(Workers.update(&1, %{build: "zzzzzzzzzzzz"}), 1))
      assert Updates.target(worker)["build"] == "abcdef123456"
    end

    test "is nothing for a build that is the platform's, a switch that is off, or a node with no release",
         %{owner: owner} do
      worker = permanent(owner)
      {:ok, current} = Workers.update(worker, %{build: release_build()})
      assert Updates.target(current) == nil

      {:ok, off} = Workers.update(worker, %{auto_update: false})
      assert Updates.target(off) == nil
      assert Updates.wanted(off)["build"] == "abcdef123456"

      put_release(nil)
      assert Updates.target(worker) == nil
      assert Updates.wanted(worker) == nil
    end

    test "is nothing for a machine the platform made, which is replaced", %{owner: owner} do
      {:ok, template_worker, _token} =
        Workers.create(%{provider: "fake", managed: true, user_id: owner.id})

      assert Updates.target(template_worker) == nil

      # And a row with no template that is not permanent either: the platform may destroy it.
      {:ok, managed} = Workers.update(permanent(owner), %{managed: true})
      assert Updates.target(managed) == nil
    end
  end

  describe "permanent?/1" do
    test "needs no template as well as no management: a machine made from one is replaced" do
      alias Forge.Workers.Worker

      assert Updates.permanent?(%Worker{managed: false, template_id: nil})
      refute Updates.permanent?(%Worker{managed: false, template_id: Ecto.UUID.generate()})
      refute Updates.permanent?(%Worker{managed: true, template_id: nil})
    end
  end

  describe "unable/1 and update_now?/2" do
    test "a protocol before updating is unable, and never offered", %{owner: owner} do
      old = permanent(owner) |> then(&elem(Workers.update(&1, %{protocol: 11}), 1))
      assert Updates.unable(old) == "protocol"
      refute Updates.update_now?(old, true)
    end

    test "what the machine says of itself is why", %{owner: owner} do
      {:ok, worker} = Workers.update(permanent(owner), %{update_state: %{"unable" => "layout"}})
      assert Updates.unable(worker) == "layout"
      refute Updates.update_now?(worker, true)
    end

    test "is offered only to a connected machine on another build with nothing under way", %{
      owner: owner
    } do
      worker = permanent(owner)
      assert Updates.update_now?(worker, true)
      refute Updates.update_now?(worker, false)

      {:ok, going} = Workers.update(worker, %{update_state: %{"step" => "installing"}})
      refute Updates.update_now?(going, true)

      {:ok, failed} = Workers.update(worker, %{update_state: %{"step" => "failed"}})
      assert Updates.update_now?(failed, true)

      {:ok, current} = Workers.update(worker, %{build: release_build()})
      refute Updates.update_now?(current, true)
    end
  end

  describe "record/2" do
    test "keeps what a machine says, cleaned, and dates its retry by this platform's clock", %{
      owner: owner
    } do
      worker = permanent(owner)
      machine_now = 5_000_000_000_000
      before = System.os_time(:millisecond)

      Updates.record(worker.id, %{
        "step" => "failed",
        "failed_step" => "downloading",
        "reason" => "no route\0 to host",
        "at" => machine_now,
        "next_at" => machine_now + 15 * 60_000,
        "attempt" => 2,
        "secret_field" => "dropped"
      })

      state = Workers.get!(worker.id).update_state
      assert %{"step" => "failed", "failed_step" => "downloading", "attempt" => 2} = state
      assert state["reason"] == "no route to host"
      refute Map.has_key?(state, "secret_field")
      refute Map.has_key?(state, "at")
      # A machine whose clock is a century out still gets a retry fifteen minutes from now.
      assert_in_delta state["next_at"], before + 15 * 60_000, 5_000
    end

    test "a value of the wrong type is left out, and nothing raises", %{owner: owner} do
      worker = permanent(owner)

      Updates.record(worker.id, %{
        "step" => %{"a" => 1},
        "reason" => ["x"],
        "attempt" => "many",
        "jobs" => "none"
      })

      assert Workers.get!(worker.id).update_state == nil
      assert :ok = Updates.record(worker.id, "not even a map")
      assert :ok = Updates.record(worker.id, nil)
    end

    test "pausing stops the platform placing work there, and puts back what is not named", %{
      owner: owner
    } do
      worker = permanent(owner)
      resumes = running(worker)
      chat = running(worker)
      command = running(worker)
      demand = %{kind: :workflow, memory: 1, cores: 0}
      assert Workers.get!(worker.id).updating_at == nil

      Updates.record(worker.id, %{
        "step" => "pausing",
        "jobs" => [resumes.id],
        "chats" => [chat.id]
      })

      assert %{updating_at: %DateTime{}} = Workers.get!(worker.id)
      assert Jobs.get!(resumes.id).status == :running
      assert Jobs.get!(chat.id).status == :running
      assert Jobs.get!(command.id).status == :pending
      refute Workers.assignable(demand)
    end

    test "any other step lifts it", %{owner: owner} do
      worker = permanent(owner)
      Updates.record(worker.id, %{"step" => "pausing", "jobs" => []})
      assert Workers.get!(worker.id).updating_at
      Updates.record(worker.id, %{"step" => "restarting"})
      assert Workers.get!(worker.id).updating_at
      Updates.record(worker.id, %{"step" => "failed"})
      assert Workers.get!(worker.id).updating_at == nil
    end

    test "a pause that names no jobs puts nothing back, as a join's snapshot would", %{
      owner: owner
    } do
      worker = permanent(owner)
      job = running(worker)
      Updates.record(worker.id, %{"step" => "pausing"})
      assert Jobs.get!(job.id).status == :running
    end

    test "dates a retry by this platform's clock, and keeps none further off than a day", %{
      owner: owner
    } do
      worker = permanent(owner)
      before = System.os_time(:millisecond)

      Updates.record(worker.id, %{"step" => "failed", "at" => 1_000, "next_at" => 1_000 + 900_000})

      assert_in_delta Workers.get!(worker.id).update_state["next_at"], before + 900_000, 5_000

      # A retry the machine dates before its own `at` is not in the past here: it is now.
      Updates.record(worker.id, %{"step" => "failed", "at" => 5_000_000, "next_at" => 1_000})
      assert Workers.get!(worker.id).update_state["next_at"] >= before

      # A number a machine made up, which `DateTime.from_unix!` raises on, is not kept as a time.
      Updates.record(worker.id, %{
        "step" => "failed",
        "at" => 0,
        "next_at" => 1_000_000_000_000_000
      })

      assert Workers.get!(worker.id).update_state["next_at"] < before + 86_400_000 + 10_000
    end

    test "says nothing of a machine that is gone", %{owner: owner} do
      worker = permanent(owner)
      {:ok, _gone} = Workers.update(worker, %{status: :destroyed})
      assert :ok = Updates.record(worker.id, %{"step" => "installing"})
      assert Workers.get!(worker.id).update_state == nil
      assert :ok = Updates.record(Ecto.UUID.generate(), %{"step" => "installing"})
    end
  end

  describe "a machine that joins" do
    test "its own account of an update replaces a stale one, and lifts the hold", %{owner: owner} do
      worker = permanent(owner)
      Updates.record(worker.id, %{"step" => "pausing", "jobs" => []})

      # Joined without saying it is pausing: the worker restarted mid-update.
      assert %{updating_at: nil, update_state: nil} = Updates.joined(Workers.get!(worker.id), %{})
    end

    test "stays held when its join says it is restarting", %{owner: owner} do
      worker = permanent(owner)
      joined = Updates.joined(worker, %{"step" => "restarting"})
      assert joined.updating_at
    end
  end

  describe "the disk report" do
    test "is kept with its age, its cleanups dated by this platform's clock", %{owner: owner} do
      worker = permanent(owner)
      machine_now = 5_000_000_000_000
      before = System.os_time(:millisecond)

      Updates.record_disk(worker.id, %{
        "at" => machine_now,
        "kinds" => %{"nix_store" => 10, "rest" => 1, "junk" => 5},
        "cleanups" => %{"jobs" => %{"at" => machine_now - 3_600_000, "freed" => 7}}
      })

      row = Workers.get!(worker.id)
      assert row.disk_report["kinds"] == %{"nix_store" => 10, "rest" => 1}
      assert row.disk_reported_at
      assert_in_delta row.disk_report["cleanups"]["jobs"]["at"], before - 3_600_000, 5_000
    end

    test "is not written to a machine that has been destroyed", %{owner: owner} do
      worker = permanent(owner)
      {:ok, _gone} = Workers.update(worker, %{status: :destroyed})

      Updates.record_disk(worker.id, %{"at" => 1, "kinds" => %{"nix_store" => 10}})

      row = Workers.get!(worker.id)
      assert row.disk_report == nil
      assert row.disk_reported_at == nil
    end

    test "a report with nothing usable leaves the last good one", %{owner: owner} do
      worker = permanent(owner)

      Updates.record_disk(worker.id, %{
        "at" => 1,
        "kinds" => %{"nix_store" => 10},
        "cleanups" => %{}
      })

      Updates.record_disk(worker.id, %{"kinds" => %{"nix_store" => "lots"}})
      Updates.record_disk(worker.id, "nonsense")
      assert Workers.get!(worker.id).disk_report["kinds"] == %{"nix_store" => 10}
    end

    test "a report with no clock keeps its sizes and no claim about when a cleanup ran", %{
      owner: owner
    } do
      worker = permanent(owner)

      Updates.record_disk(worker.id, %{
        "kinds" => %{"nix_store" => 10},
        "cleanups" => %{"jobs" => %{"at" => 1, "freed" => 7}}
      })

      assert Workers.get!(worker.id).disk_report == %{
               "kinds" => %{"nix_store" => 10},
               "cleanups" => %{}
             }
    end
  end

  describe "set_automatic/3" do
    test "writes the switch, a line naming the owner, and tells a connected machine", %{
      owner: owner
    } do
      worker = permanent(owner)
      assert {:ok, %{auto_update: false}} = Updates.set_automatic(owner, worker.id, false)
      assert_received {:update, %{"target" => nil, "requested_by" => nil}}

      assert {:ok, %{auto_update: true}} = Updates.set_automatic(owner, worker.id, true)

      assert_received {:update,
                       %{"target" => %{"build" => "abcdef123456"}, "requested_by" => nil}}

      lines = Log.for_worker(worker.id) |> Enum.filter(&(&1.type == "update.switch"))

      assert Enum.map(lines, & &1.message) |> Enum.sort() ==
               Enum.sort([
                 "#{owner.email} turned automatic updates on",
                 "#{owner.email} turned automatic updates off"
               ])
    end

    test "is the owner's alone: somebody else's id, a node admin and a managed machine are not here",
         %{owner: owner} do
      worker = permanent(owner)
      stranger = user_fixture()
      admin = node_admin_fixture()

      for who <- [stranger, admin] do
        assert {:error, :not_found} = Updates.set_automatic(who, worker.id, false)
      end

      assert Workers.get!(worker.id).auto_update
      refute_received {:update, _payload}
      assert Log.for_worker(worker.id) |> Enum.filter(&(&1.type == "update.switch")) == []

      {:ok, template_made, _token} =
        Workers.create(%{provider: "fake", managed: true, user_id: owner.id})

      assert {:error, :not_found} = Updates.set_automatic(owner, template_made.id, false)
      assert {:error, :not_found} = Updates.set_automatic(owner, "not-a-uuid", false)
      assert {:error, :not_found} = Updates.set_automatic(owner, nil, false)
    end
  end

  describe "update_now/2" do
    test "sends the target to a connected machine, with the owner's name", %{owner: owner} do
      worker = permanent(owner)
      {:ok, _off} = Updates.set_automatic(owner, worker.id, false)
      assert_received {:update, _stand_down}

      assert {:ok, _worker} = Updates.update_now(owner, worker.id)

      assert_received {:update,
                       %{"target" => %{"build" => "abcdef123456"}, "requested_by" => requested}}

      assert requested == owner.email
    end

    test "is the owner's alone, and writes and sends nothing for anyone else", %{owner: owner} do
      worker = permanent(owner)

      for who <- [user_fixture(), node_admin_fixture()] do
        assert {:error, :not_found} = Updates.update_now(who, worker.id)
      end

      refute_received {:update, _payload}
    end

    test "is refused for a machine that is not connected, and nothing is kept for it", %{
      owner: owner
    } do
      {:ok, worker, _token} =
        Workers.create(%{provider: "fake", managed: false, user_id: owner.id})

      {:ok, worker} =
        Workers.update(worker, %{protocol: 13, build: "oldoldoldold", status: :ready})

      assert {:error, :not_connected} = Updates.update_now(owner, worker.id)
      refute_received {:update, _payload}
    end

    test "is refused when there is nothing to do, or something already under way", %{owner: owner} do
      worker = permanent(owner)
      {:ok, _worker} = Workers.update(worker, %{update_state: %{"step" => "downloading"}})
      assert {:error, :nothing_to_do} = Updates.update_now(owner, worker.id)

      {:ok, _worker} = Workers.update(worker, %{update_state: nil, build: release_build()})
      assert {:error, :nothing_to_do} = Updates.update_now(owner, worker.id)
      refute_received {:update, _payload}
    end
  end

  test "a machine that is updating is passed over by the scheduler, and a plain one is not", %{
    owner: owner
  } do
    project = project_fixture()
    worker = permanent(owner) |> serve!(project)
    demand = %{kind: :workflow, memory: 1, cores: 0, project_id: project.id}

    assert Workers.assignable(demand).id == worker.id
    {:ok, _worker} = Workers.update(worker, %{updating_at: DateTime.utc_now()})
    assert Workers.assignable(demand) == nil
  end
end
