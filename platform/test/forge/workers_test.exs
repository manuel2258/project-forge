defmodule Forge.WorkersTest do
  @moduledoc """
  Worker rows, tokens, the memory gate and the lifecycle: created when a job needs one,
  destroyed when nothing has for long enough.
  """

  use Forge.DataCase, async: false

  alias Forge.{Provider, Workers}

  setup do
    Provider.Fake.watch()
    previous = Application.get_env(:forge, Workers, [])
    on_exit(fn -> Application.put_env(:forge, Workers, previous) end)
    :ok
  end

  defp configure(opts) do
    current = Application.get_env(:forge, Workers, [])
    Application.put_env(:forge, Workers, Keyword.merge(current, opts))
  end

  describe "tokens" do
    test "are returned once and only their hash is kept" do
      {:ok, worker, token} = Workers.create(%{provider: "fake"})

      refute worker.token_hash == token
      assert {:ok, %{id: id}} = Workers.authenticate(worker.id, token)
      assert id == worker.id
    end

    test "do not open another worker, a destroyed one, or nothing at all" do
      {:ok, worker, token} = Workers.create(%{provider: "fake"})
      {:ok, other, _other_token} = Workers.create(%{provider: "fake"})

      assert :error = Workers.authenticate(other.id, token)
      assert :error = Workers.authenticate(worker.id, "nope")
      assert :error = Workers.authenticate(Ecto.UUID.generate(), token)
      assert :error = Workers.authenticate("not-a-uuid", token)

      {:ok, worker} = Workers.status(worker, :destroyed)
      assert :error = Workers.authenticate(worker.id, token)
    end
  end

  describe "the memory gate" do
    test "offers a worker only while its slice fits" do
      configure(slice_bytes: 1_000)
      {:ok, worker, _token} = Workers.create(%{provider: "fake"})
      {:ok, worker} = Workers.ready(worker, 2_500)
      :ok = Workers.connected(worker.id)

      assert %{id: id} = Workers.assignable(1_000)
      assert id == worker.id
      assert Workers.remaining(Workers.get!(worker.id)) == 2_500
      refute Workers.assignable(3_000)
    end

    test "ignores a worker nothing can reach" do
      configure(slice_bytes: 1_000)
      {:ok, worker, _token} = Workers.create(%{provider: "fake"})
      {:ok, worker} = Workers.ready(worker, 8_000)

      refute Workers.assignable(1_000)
      :ok = Workers.connected(worker.id)
      assert Workers.assignable(1_000)
    end
  end

  describe "providing a worker" do
    test "creates a machine when there is none, and the job waits for it" do
      configure(max_workers: 1)

      assert {:error, :creating} = Workers.provide(1_000)
      assert_receive {:provider_create, %{worker_id: worker_id, token: token}}
      assert is_binary(token)

      worker = Workers.get!(worker_id)
      assert worker.status == :creating
      assert worker.provider_id == "fake-" <> worker_id

      # Still creating: nothing is offered, and no second machine is made.
      assert {:error, :at_capacity} = Workers.provide(1_000)
      refute_receive {:provider_create, _opts}
    end

    test "offers the one it has rather than making another" do
      configure(max_workers: 1, slice_bytes: 1_000)
      {:ok, worker, _token} = Workers.create(%{provider: "fake"})
      {:ok, worker} = Workers.ready(worker, 8_000)
      :ok = Workers.connected(worker.id)

      assert {:ok, %{id: id}} = Workers.provide(1_000)
      assert id == worker.id
      refute_receive {:provider_create, _opts}
    end
  end

  describe "idle destroy" do
    test "destroys a machine that has had nothing to do for the period" do
      configure(idle_period_ms: 60_000)
      {:ok, worker, _token} = Workers.create(%{provider: "fake"})
      {:ok, worker} = Workers.update(worker, %{provider_id: "fake-1", status: :ready})
      :ok = Workers.connected(worker.id)

      # Nothing has happened yet, so nothing is destroyed.
      assert Workers.sweep_idle() == 0

      :ok = Workers.release(worker.id)
      assert Workers.get!(worker.id).status == :idle
      assert Workers.sweep_idle() == 0

      # The clock, moved rather than waited on.
      long_ago = DateTime.add(DateTime.utc_now(:second), -120)
      {:ok, _worker} = Workers.update(Workers.get!(worker.id), %{idle_since: long_ago})

      assert Workers.sweep_idle() == 1
      assert_receive {:provider_destroy, "fake-1"}
      assert Workers.get!(worker.id).status == :destroyed
    end

    test "a machine nothing can reach is destroyed, and its slot comes back" do
      configure(max_workers: 1, worker_timeout_ms: 60_000, slice_bytes: 1_000)
      {:ok, worker, _token} = Workers.create(%{provider: "fake"})
      {:ok, worker} = Workers.update(worker, %{provider_id: "fake-1", status: :idle})
      {:ok, _worker} = Workers.ready(Workers.get!(worker.id), 8_000)

      # Out of touch, but not for long enough: a worker is disconnected for a moment every
      # time the platform restarts.
      assert Workers.sweep_unreachable() == 0

      long_ago = DateTime.add(DateTime.utc_now(:second), -120)
      {:ok, _worker} = Workers.update(Workers.get!(worker.id), %{last_seen_at: long_ago})

      # Before the sweep, this row is the whole of max_workers and nothing can be created.
      assert {:error, :at_capacity} = Workers.provide(1_000)

      assert Workers.sweep_unreachable() == 1
      assert_receive {:provider_destroy, "fake-1"}
      assert Workers.get!(worker.id).status == :destroyed

      # And the capacity it was holding is available again.
      assert {:error, :creating} = Workers.provide(1_000)
    end

    test "a machine that never finished booting expires from when its row was made" do
      configure(max_workers: 1, worker_timeout_ms: 60_000)
      {:ok, worker, _token} = Workers.create(%{provider: "fake"})
      {:ok, worker} = Workers.update(worker, %{provider_id: "fake-2", status: :creating})

      # It has never reported, so there is no last_seen_at to time it from.
      assert worker.last_seen_at == nil
      assert Workers.sweep_unreachable() == 0

      long_ago = DateTime.add(DateTime.utc_now(:second), -120)

      Forge.Repo.update_all(
        Ecto.Query.from(w in Forge.Workers.Worker, where: w.id == ^worker.id),
        set: [inserted_at: long_ago]
      )

      assert Workers.sweep_unreachable() == 1
      assert Workers.get!(worker.id).status == :destroyed
    end

    test "an unmanaged worker is never destroyed by either sweep", %{} do
      configure(idle_period_ms: 60_000, worker_timeout_ms: 60_000)
      {:ok, worker, _token} = Workers.create(%{provider: "fake", managed: false})
      {:ok, worker} = Workers.update(worker, %{status: :idle})
      long_ago = DateTime.add(DateTime.utc_now(:second), -600)

      {:ok, _worker} =
        Workers.update(Workers.get!(worker.id), %{idle_since: long_ago, last_seen_at: long_ago})

      # The operator's machine, idle for ten minutes and out of touch for ten minutes. Neither
      # is the platform's business: it did not make this machine and cannot make another.
      assert Workers.sweep_idle() == 0
      assert Workers.sweep_unreachable() == 0
      assert Workers.get!(worker.id).status == :idle
      refute_receive {:provider_destroy, _id}
    end

    test "an unreachable unmanaged worker loses its jobs but keeps its row", %{} do
      configure(worker_timeout_ms: 60_000)

      {:ok, project} =
        Forge.Projects.register(%{
          name: "perm-#{System.unique_integer([:positive])}",
          repo_path: Forge.GitFixtures.seeded_repo()
        })

      {:ok, ticket} = Forge.Tickets.admit(project, %{title: "x"}, :system)
      [job] = Forge.Jobs.for_ticket(ticket.id)

      {:ok, worker, _token} = Workers.create(%{provider: "fake", managed: false})
      {:ok, worker} = Workers.ready(worker, 8_000_000_000)
      :ok = Workers.connected(worker.id)
      {:ok, _job} = Forge.Jobs.assign(job, worker)
      assert Forge.Jobs.get!(job.id).status == :running

      # The machine goes quiet. Its work has to come back — nothing is watching it — but a
      # destroyed row could never rejoin, and this machine may well return.
      Registry.unregister(Forge.Workers.Registry, worker.id)
      long_ago = DateTime.add(DateTime.utc_now(:second), -600)
      {:ok, _worker} = Workers.update(Workers.get!(worker.id), %{last_seen_at: long_ago})

      assert Workers.sweep_unreachable() == 1
      assert Forge.Jobs.get!(job.id).status == :pending
      refute Workers.get!(worker.id).status == :destroyed

      # And it does not keep saying so once there is nothing left to re-queue.
      assert Workers.sweep_unreachable() == 0
    end

    test "a connected worker is never swept, however quiet it has been" do
      configure(worker_timeout_ms: 60_000)
      {:ok, worker, _token} = Workers.create(%{provider: "fake"})
      {:ok, worker} = Workers.update(worker, %{provider_id: "fake-3", status: :ready})
      :ok = Workers.connected(worker.id)

      long_ago = DateTime.add(DateTime.utc_now(:second), -600)
      {:ok, _worker} = Workers.update(Workers.get!(worker.id), %{last_seen_at: long_ago})

      assert Workers.sweep_unreachable() == 0
      assert Workers.get!(worker.id).status == :ready
    end

    test "a worker with a job on it is not idle" do
      {:ok, project} =
        Forge.Projects.register(%{
          name: "idle-#{System.unique_integer([:positive])}",
          repo_path: Forge.GitFixtures.seeded_repo()
        })

      {:ok, ticket} = Forge.Tickets.admit(project, %{title: "x"}, :system)
      [job] = Forge.Jobs.for_ticket(ticket.id)

      {:ok, worker, _token} = Workers.create(%{provider: "fake"})
      {:ok, worker} = Workers.ready(worker, 8_000_000_000)
      :ok = Workers.connected(worker.id)
      {:ok, _job} = Forge.Jobs.assign(job, worker)

      assert Workers.get!(worker.id).status == :busy
      :ok = Workers.release(worker.id)
      assert Workers.get!(worker.id).status == :busy
    end
  end
end
