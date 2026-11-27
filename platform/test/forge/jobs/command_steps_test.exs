defmodule Forge.Jobs.CommandStepsTest do
  @moduledoc """
  What the platform records of a command's steps, line times and folder sizes
  (`docs/design/worker-tier.md` § Looking into a copy): one `command.step` event for each step, in
  the transaction that records the result or the failure; the unrecorded event for a release that
  predates them; the times blob only when it is the job's own; and the folder sizes on the row.
  """

  use Forge.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Forge.WarmFixtures, only: [ticket_in_checking!: 0]

  alias Forge.{Engine, Events, FakeWorker, Jobs, Repo, Storage, Tickets}
  alias Forge.Events.Event
  alias Forge.Jobs.Lines
  alias ForgeCore.Job.Result

  @steps [
    %{"name" => "snapshot", "at" => 1_700_000_000_000, "ms" => 40, "source" => "copy"},
    %{"name" => "fetch", "at" => 1_700_000_000_040, "ms" => 7},
    %{"name" => "devshell", "at" => 1_700_000_000_050, "skipped" => "no_env"},
    %{"name" => "script", "at" => 1_700_000_000_060, "ms" => 900},
    %{"name" => "keep", "at" => 1_700_000_000_960, "skipped" => "status"},
    %{"name" => "other", "at" => 1_700_000_000_970, "ms" => 3}
  ]

  setup do
    %{project: project, commands: [build | _]} = context = ticket_in_checking!()
    Map.merge(context, %{build: build, worker: FakeWorker.connect(project: project)})
  end

  defp step_events(job_id),
    do:
      Repo.all(
        from e in Event, where: e.job_id == ^job_id and like(e.type, "command.%"), order_by: e.seq
      )

  test "a result's steps are recorded as one event each, in the order the worker took them",
       %{build: build, worker: worker} do
    {:ok, _job} =
      build |> FakeWorker.assign(worker) |> FakeWorker.finish_command(0, steps: @steps)

    events = step_events(build.id)
    assert Enum.map(events, & &1.type) == List.duplicate("command.step", 6)
    assert Enum.map(events, & &1.payload["name"]) == Enum.map(@steps, & &1["name"])
    assert Enum.map(events, & &1.payload) == @steps
    assert {:steps, recorded} = Jobs.command_steps(build.id)
    assert recorded == @steps
  end

  test "a skipped step is recorded as skipped and never as a zero", %{
    build: build,
    worker: worker
  } do
    {:ok, _job} =
      build |> FakeWorker.assign(worker) |> FakeWorker.finish_command(0, steps: @steps)

    {:steps, steps} = Jobs.command_steps(build.id)
    skipped = Enum.find(steps, &(&1["name"] == "devshell"))
    assert skipped["skipped"] == "no_env"
    refute Map.has_key?(skipped, "ms")
  end

  test "what a worker reports that is not a step is dropped", %{build: build, worker: worker} do
    junk = [%{"name" => "teleport", "ms" => 1}, %{"name" => "fetch", "ms" => -5} | @steps]
    {:ok, _job} = build |> FakeWorker.assign(worker) |> FakeWorker.finish_command(0, steps: junk)

    assert {:steps, recorded} = Jobs.command_steps(build.id)
    assert recorded == @steps
  end

  describe "a command from a release that reports no steps" do
    test "below protocol 18 is recorded as unrecorded, with the protocol", %{
      build: build,
      project: project
    } do
      old = FakeWorker.connect(project: project, protocol: 17)
      {:ok, _job} = build |> FakeWorker.assign(old) |> FakeWorker.finish_command(0)

      assert [%{type: "command.steps_unrecorded", payload: %{"protocol" => 17}}] =
               step_events(build.id)

      assert Jobs.command_steps(build.id) == {:unrecorded, :release}
    end

    test "from protocol 18 with none is nothing at all", %{build: build, worker: worker} do
      {:ok, _job} = build |> FakeWorker.assign(worker) |> FakeWorker.finish_command(0)

      assert step_events(build.id) == []
      assert Jobs.command_steps(build.id) == {:unrecorded, :before}
    end
  end

  test "a command that failed carries its steps too", %{build: build, worker: worker} do
    FakeWorker.assign(build, worker)

    assert {:ok, _job} =
             Jobs.fail(build.id, {:worker, "no checkout"}, steps: Enum.take(@steps, 2))

    assert {:steps, [%{"name" => "snapshot"}, %{"name" => "fetch"}]} =
             Jobs.command_steps(build.id)
  end

  describe "a command that is cancelled or goes back to the queue" do
    setup do
      on_exit(fn -> Application.delete_env(:forge, :command_lines_drop_ms) end)
      :ok
    end

    defp wait_until(fun, tries \\ 200) do
      cond do
        fun.() -> :ok
        tries == 0 -> flunk("never became true")
        true -> Process.sleep(10) && wait_until(fun, tries - 1)
      end
    end

    test "keeps the steps its late result reports, once, and drops its live lines", ctx do
      %{build: build, worker: worker, ticket: ticket, user: user} = ctx
      Application.put_env(:forge, :command_lines_drop_ms, 0)
      assignment = FakeWorker.assign(build, worker)
      Lines.put(build.id, 0, [[1, "compiling"]])

      {:ok, _cancelled} = Engine.cancel(Tickets.get!(ticket.id), user.id)

      # What the machine answers a cancel with: the run's result, with the steps it took.
      assert {:error, :already_recorded} =
               FakeWorker.finish_command(assignment, nil, outcome: :cancelled, steps: @steps)

      assert {:steps, @steps} = Jobs.command_steps(build.id)

      # Re-sent until acked: heard again, and still one event for each step.
      # (The log is not uploaded again: the store refuses a key twice.)
      assert {:error, :already_recorded} =
               Jobs.complete(build.id, %Result{
                 status: :finished,
                 outcome: :cancelled,
                 steps: @steps
               })

      assert length(step_events(build.id)) == length(@steps)
      wait_until(fn -> Lines.all(build.id) == nil end)
    end

    test "a cancelled command's late result drops its lines when the cancel did not", ctx do
      %{build: build, worker: worker} = ctx
      Application.put_env(:forge, :command_lines_drop_ms, 0)
      FakeWorker.assign(build, worker)
      Lines.put(build.id, 0, [[1, "compiling"]])

      # Cancelled some way other than the ticket's cancel (which drops the lines itself): the job is
      # finished as cancelled, and the machine's answer comes later.
      {:ok, _} =
        build
        |> Jobs.Job.progress_changeset(%{
          status: :finished,
          outcome: :cancelled,
          finished_at: DateTime.utc_now(:second)
        })
        |> Repo.update()

      assert {:error, :already_recorded} =
               Jobs.complete(build.id, %Result{
                 status: :finished,
                 outcome: :cancelled,
                 steps: @steps
               })

      wait_until(fn -> Lines.all(build.id) == nil end)
      assert {:steps, @steps} = Jobs.command_steps(build.id)
    end

    test "a requeued command's next run is heard from its first line", %{
      build: build,
      worker: worker
    } do
      on_exit(fn -> Lines.drop(build.id) end)
      FakeWorker.assign(build, worker)
      Lines.put(build.id, 0, [[1, "the lost run"], [2, "its second line"]])

      {:ok, _job} = Jobs.requeue(build.id, :worker_lost_job)

      assert Lines.all(build.id) == nil
      Lines.put(build.id, 0, [[5, "the new run"]])
      assert %{lines: [[5, "the new run"]], total_seen: 1} = Lines.all(build.id)
    end
  end

  test "step events are lifecycle events, kept for good, and are not in the lists of events",
       %{build: build, worker: worker} do
    {:ok, _job} =
      build |> FakeWorker.assign(worker) |> FakeWorker.finish_command(0, steps: @steps)

    for type <- ["command.step", "command.steps_unrecorded"] do
      assert %{rows: [[false]]} = Repo.query!("SELECT forge_event_swept($1)", [type])
    end

    assert %{rows: [[true]]} =
             Repo.query!("SELECT forge_event_swept($1)", ["job.harness.tool_use"])

    refute Enum.any?(Events.for_job(build.id), &String.starts_with?(&1.type, "command.step"))
    assert [_ | _] = Events.command_step_events(build.id)
  end

  describe "the times of a log's lines" do
    test "are recorded in job.finished when the blob is the job's own and there", ctx do
      %{build: build, worker: worker} = ctx
      assignment = FakeWorker.assign(build, worker)
      {:ok, _job} = FakeWorker.finish_command(assignment, 0, times: "0\n12\n")

      finished = Events.latest_for_job(build.id, "job.finished")
      assert finished.payload["times"] == assignment["store"]["times_key"]
      refute finished.payload["times"] == finished.payload["log"]
    end

    test "are dropped for a key that is another job's", ctx do
      %{build: build, worker: worker, commands: [_, other | _]} = ctx
      foreign = Storage.Key.job(other.id, "times-1-x.txt")
      {:ok, _info} = Storage.put(foreign, "0\n")

      {:ok, _job} =
        build
        |> FakeWorker.assign(worker)
        |> FakeWorker.finish_command(0, times: "0\n", times_key: foreign)

      assert Events.latest_for_job(build.id, "job.finished").payload["times"] == nil
    end

    test "are dropped for a key the store does not hold", ctx do
      %{build: build, worker: worker} = ctx

      {:ok, _job} =
        build
        |> FakeWorker.assign(worker)
        |> FakeWorker.finish_command(0,
          times: "0\n",
          times_key: Storage.Key.job(build.id, "times-9-gone.txt")
        )

      assert Events.latest_for_job(build.id, "job.finished").payload["times"] == nil
    end

    test "the assignment carries a key and a token of the job's own", %{
      build: build,
      worker: worker
    } do
      assignment = FakeWorker.assign(build, worker)
      store = assignment["store"]

      assert Storage.Key.job?(store["times_key"], build.id)
      assert store["times_key"] != store["log_key"]
      assert :ok = Storage.Token.verify(store["times_token"], :put, store["times_key"])
    end
  end

  test "the saved sizes of the ignored folders are recorded on the row of the command that kept them",
       %{build: build, worker: worker} do
    folders = %{
      "folders" => [
        %{"path" => "target", "bytes" => 900},
        %{"path" => "x" <> <<255>>, "bytes" => 1}
      ],
      "more" => %{"count" => 0, "bytes" => 0},
      "loose" => %{"count" => 2, "bytes" => 8},
      "rest" => 50
    }

    warm = %{"source" => "clone", "kept" => true, "size" => 959, "folders" => folders}
    {:ok, job} = build |> FakeWorker.assign(worker) |> FakeWorker.finish_command(0, warm: warm)

    assert job.warm_folders["folders"] == [%{"path" => "target", "bytes" => 900}]
    assert job.warm_folders["loose"] == %{"count" => 2, "bytes" => 8}
    assert job.warm_folders["rest"] == 50
  end

  test "a build that was not kept has no folder sizes", %{build: build, worker: worker} do
    warm = %{
      "source" => "clone",
      "kept" => false,
      "unkept" => "status",
      "folders" => %{"folders" => [], "rest" => 1}
    }

    {:ok, job} = build |> FakeWorker.assign(worker) |> FakeWorker.finish_command(2, warm: warm)

    assert job.warm_folders == nil
  end
end
