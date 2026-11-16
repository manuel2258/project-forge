defmodule Forge.Tickets.PastTest do
  @moduledoc """
  Where a ticket has been, as the queue draws it (`docs/design/ui.md` § What each kind shows,
  *Every item about a ticket*): the steps in the order they were reached, what counts as a run of
  each kind of step, and the loops as the engine counts them.

  Recorded the way the platform records them — a fake worker answers each job — because what is
  under test is a read of what the engine wrote.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Engine, FakeWorker, Jobs, Repo, Tickets}
  alias Forge.Jobs.Commands
  alias Forge.Tickets.Past

  # `planning` is declared before `implementing` and reached after it, so an order that follows the
  # workflow and not the ticket is a different order.
  @workflow """
  version: 1
  initial: implementing
  commands:
    build:
      run: .forge/commands/build.sh
      timeout: 20m
  states:
    planning:
      prompt: agents/plan.md
      inputs: [ticket]
      produces: [plan.md]
      budget: { turns: 40, tokens: 400k }
    implementing:
      prompt: agents/implement.md
      inputs: [ticket]
      produces: [implementation.md, changeset]
      outcomes: [done, plan_invalid]
      may_invoke:
        build: { max: 2 }
      budget: { turns: 200, tokens: 2M }
    checking:
      invoke: [build, [build, --all]]
      exit: { 0: done, "*": checks_failed }
    reviewing:
      prompt: agents/review.md
      inputs: [implementation.md]
      produces: [review.md, commit-message]
      outcomes: [done, changes_requested]
      budget: { turns: 60, tokens: 600k }
    human_testing:
      produces: [test-report.md]
    merged:
      on_enter: merge
  transitions:
    - { from: planning,      to: implementing }
    - { from: implementing,  to: checking }
    - { from: implementing,  to: planning,     when: plan_invalid }
    - { from: checking,      to: reviewing }
    - { from: checking,      to: implementing, when: checks_failed, max: 3 }
    - { from: reviewing,     to: human_testing }
    - { from: reviewing,     to: implementing, when: changes_requested, max: 2 }
    - { from: human_testing, to: merged,       approve: [changeset] }
    - { from: human_testing, to: implementing }
  limits:
    ticket_tokens: 5M
  """

  setup do
    repo =
      seeded_repo(%{
        ".forge/workflow.yml" => @workflow,
        ".forge/agents/review.md" => "Review the change.\n",
        ".forge/commands/build.sh" => "#!/bin/sh\nexec make \"$@\"\n"
      })

    {:ok, project} =
      register_owned!(%{name: "past-#{System.unique_integer([:positive])}", repo_path: repo})

    user = member_fixture(project)
    funded!(project)

    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

    {:ok, ticket} = Tickets.admit(project, %{title: "Save scores", body: "."}, {:user, user.id})
    %{ticket: ticket, user: user, worker: FakeWorker.connect()}
  end

  defp pending(ticket), do: ticket.id |> Jobs.for_ticket() |> Enum.find(&(&1.status == :pending))

  # The step's agent job answered with a document carrying `outcome`.
  defp run(ticket, worker, name, outcome \\ "done") do
    job = pending(ticket)
    written = %{name => "---\noutcome: #{outcome}\n---\n# #{name}\n"}

    written =
      if job.state == "reviewing",
        do: Map.put(written, "commit-message", FakeWorker.commit_message()),
        else: written

    {:ok, _job} = FakeWorker.run(job, worker, "success", written: written)
    Tickets.get!(ticket.id)
  end

  # Every pending command of the ticket finished with `status`.
  defp check(ticket, worker, status, opts \\ []) do
    for job <- Jobs.commands_for_ticket(ticket.id), job.status == :pending do
      {:ok, _job} = job |> FakeWorker.assign(worker) |> FakeWorker.finish_command(status, opts)
    end

    Tickets.get!(ticket.id)
  end

  defp steps(ticket) do
    ticket = Tickets.get!(ticket.id)
    {:ok, workflow} = Tickets.parsed_workflow(ticket)
    Past.steps(ticket, workflow, Jobs.for_ticket(ticket.id))
  end

  defp step(ticket, name), do: ticket |> steps() |> Enum.find(&(&1.name == name))

  describe "steps" do
    # A job nobody has started is a job waiting for a machine, not a run of its step: the ticket
    # stuck for want of a machine reads *not run yet* (criterion 6).
    test "a step whose job never started has not run", %{ticket: ticket} do
      assert [%{name: "implementing", kind: :agent, runs: 0, current: true, job: nil}] =
               steps(ticket)
    end

    # The order the ticket reached them, each once: `planning` is declared first and reached after
    # `implementing`, and `implementing` is run again without being listed twice.
    test "are in the order first reached, each once", %{ticket: ticket, worker: worker} do
      ticket = run(ticket, worker, "implementation.md", "plan_invalid")
      assert ticket.state == "planning"
      ticket = run(ticket, worker, "plan.md")
      assert ticket.state == "implementing"

      assert Enum.map(steps(ticket), & &1.name) == ["implementing", "planning"]
      assert step(ticket, "implementing").current
      assert step(ticket, "implementing").runs == 1
    end

    # A job that went `waiting` and was resumed is the same row, started once: one run.
    test "a job that waited and resumed is one run", %{ticket: ticket} do
      job = pending(ticket)

      job
      |> Ecto.Changeset.change(status: :pending, started_at: DateTime.utc_now(:second))
      |> Repo.update!()

      assert step(ticket, "implementing").runs == 1
    end

    test "a retry is a run, and how the last ended is what is said", %{
      ticket: ticket,
      worker: worker,
      user: user
    } do
      {:ok, _job} = FakeWorker.run(pending(ticket), worker, "nothing")
      stuck = Tickets.get!(ticket.id)
      assert stuck.status == :stuck
      assert %{runs: 1, last: "error"} = step(ticket, "implementing")

      {:ok, _ticket} = Engine.retry(stuck, user.id)
      # The retry's job is waiting for a machine: still one run.
      assert step(ticket, "implementing").runs == 1

      ticket = run(ticket, worker, "implementation.md")
      assert ticket.state == "checking"
      assert %{runs: 2, last: "done"} = step(ticket, "implementing")
    end

    test "a command step counts its batches, and a command an agent invoked is none", %{
      ticket: ticket,
      worker: worker
    } do
      # The agent invokes `build` from inside `implementing`: a command job in that state, no batch.
      assignment = FakeWorker.assign(pending(ticket), worker)
      {:ok, _parked} = FakeWorker.park(assignment, [%{"command" => "build", "args" => []}])
      assert Enum.map(steps(ticket), & &1.name) == ["implementing"]
      assert [%{runs: 1}] = steps(ticket)
      check(ticket, worker, 0)

      ticket = run(ticket, worker, "implementation.md")
      assert ticket.state == "checking"
      # Placed on a machine, not yet finished.
      assignments =
        for command <- Jobs.commands_for_ticket(ticket.id),
            command.status == :pending,
            do: FakeWorker.assign(command, worker)

      assert %{kind: :command, runs: 1, last: "running"} = step(ticket, "checking")

      for assignment <- assignments, do: {:ok, _job} = FakeWorker.finish_command(assignment, 1)
      ticket = Tickets.get!(ticket.id)
      assert ticket.state == "implementing"
      assert %{kind: :command, runs: 1, last: "checks_failed"} = step(ticket, "checking")

      ticket = run(ticket, worker, "implementation.md")
      ticket = check(ticket, worker, 0)
      assert ticket.state == "reviewing"
      assert %{runs: 2, last: "done"} = step(ticket, "checking")
      assert %{runs: 2} = step(ticket, "implementing")
    end

    test "a batch whose commands no machine has started has not run", %{
      ticket: ticket,
      worker: worker
    } do
      ticket = run(ticket, worker, "implementation.md")
      assert ticket.state == "checking"
      assert %{runs: 0, current: true} = step(ticket, "checking")
    end

    test "a human step counts its visits", %{ticket: ticket, worker: worker, user: user} do
      ticket = run(ticket, worker, "implementation.md")
      ticket = check(ticket, worker, 0)
      ticket = run(ticket, worker, "review.md")
      assert ticket.state == "human_testing"
      assert %{kind: :human, runs: 1, last: nil} = step(ticket, "human_testing")

      {:ok, _ticket} = Engine.choose(ticket, user.id, "implementing")
      ticket = run(ticket, worker, "implementation.md")
      ticket = check(ticket, worker, 0)
      ticket = run(ticket, worker, "review.md")
      assert ticket.state == "human_testing"
      assert %{kind: :human, runs: 2} = step(ticket, "human_testing")
    end

    # Steps and runs are read from what ran, so a workflow that cannot be read costs the kinds the
    # workflow would have given and not the lines (criterion 5).
    test "are still listed when the pinned workflow cannot be read", %{
      ticket: ticket,
      worker: worker
    } do
      ticket = run(ticket, worker, "implementation.md")
      check(ticket, worker, 0)

      ticket = Tickets.get!(ticket.id)

      assert [
               %{name: "implementing", kind: :agent, runs: 1},
               %{name: "checking", kind: :command, runs: 1},
               %{name: "reviewing", kind: :agent, runs: 0}
             ] = Past.steps(ticket, nil, Jobs.for_ticket(ticket.id))
    end
  end

  describe "loops" do
    # Counted by `Engine.rounds/1`, which is the count `max` is decided on: a person's own move
    # along the edge is a round, so a loop can read above its limit and is not clamped to it.
    test "count a person's move and are not clamped to their limit", %{
      ticket: ticket,
      worker: worker,
      user: user
    } do
      assert Past.loops(ticket, parsed(ticket)) == []

      ticket = reach_reviewing(ticket, worker)
      ticket = run(ticket, worker, "review.md", "changes_requested")
      assert ticket.state == "implementing"

      assert [%{from: "reviewing", to: "implementing", outcome: "changes_requested"} = loop] =
               Past.loops(ticket, parsed(ticket))

      assert %{rounds: 1, max: 2} = loop

      ticket = reach_reviewing(ticket, worker)
      ticket = run(ticket, worker, "review.md", "changes_requested")
      ticket = reach_reviewing(ticket, worker)
      ticket = run(ticket, worker, "review.md", "changes_requested")
      assert ticket.status == :stuck
      assert [%{rounds: 2, max: 2}] = Past.loops(ticket, parsed(ticket))

      {:ok, ticket} = Engine.choose(ticket, user.id, "implementing")
      assert [%{rounds: 3, max: 2}] = Past.loops(ticket, parsed(ticket))
    end

    test "list only an edge with a limit that has fired", %{ticket: ticket, worker: worker} do
      # `implementing → checking` fired and has no `max`; `checking → implementing` has one and
      # has not fired.
      ticket = run(ticket, worker, "implementation.md")
      assert ticket.state == "checking"
      assert Past.loops(ticket, parsed(ticket)) == []
    end

    test "list a fired edge the workflow no longer declares, without a limit", %{
      ticket: ticket,
      worker: worker
    } do
      ticket = reach_reviewing(ticket, worker)
      ticket = run(ticket, worker, "review.md", "changes_requested")
      workflow = parsed(ticket)

      gone = %{
        workflow
        | transitions:
            Enum.reject(
              workflow.transitions,
              &(&1.from == "reviewing" and &1.to == "implementing")
            )
      }

      assert [%{from: "reviewing", to: "implementing", rounds: 1, max: nil}] =
               Past.loops(ticket, gone)
    end

    # The reroute a merge conflict takes is logged as a transition on an edge no workflow declares,
    # and no `max` governs it: it is not a loop and not an edge the workflow dropped.
    test "leave out a merge-conflict reroute", %{ticket: ticket} do
      conflicted = fn outcome ->
        Repo.insert!(%Forge.Events.Event{
          ticket_id: ticket.id,
          project_id: ticket.project_id,
          actor: %{"kind" => "system", "id" => nil},
          type: "transition.taken",
          payload: %{"from" => "human_testing", "to" => "planning", "outcome" => outcome}
        })
      end

      conflicted.("merge_conflict")
      assert Past.loops(ticket, parsed(ticket)) == []
      assert Past.loops(ticket, nil) == []

      # The same edge with any other outcome is one the workflow does not declare.
      conflicted.("something_else")
      assert [%{outcome: "something_else", max: nil}] = Past.loops(ticket, parsed(ticket))
    end

    test "with no readable workflow list every fired edge, with no limit", %{
      ticket: ticket,
      worker: worker
    } do
      ticket = reach_reviewing(ticket, worker)

      assert [
               %{from: "checking", to: "reviewing", max: nil},
               %{from: "implementing", to: "checking", max: nil}
             ] = Past.loops(ticket, nil)
    end

    defp reach_reviewing(ticket, worker) do
      ticket = run(ticket, worker, "implementation.md")
      check(ticket, worker, 0)
    end

    defp parsed(ticket) do
      {:ok, workflow} = Tickets.parsed_workflow(Tickets.get!(ticket.id))
      workflow
    end
  end

  describe "the latest run of a step" do
    test "an agent's is its job and its closing words", %{ticket: ticket, worker: worker} do
      job = pending(ticket)
      ticket = run(ticket, worker, "implementation.md")

      # What it said last, after whatever the fake worker recorded.
      Repo.insert!(%Forge.Events.Event{
        ticket_id: ticket.id,
        project_id: ticket.project_id,
        job_id: job.id,
        actor: %{"kind" => "job", "id" => job.id},
        type: "job.harness.text",
        payload: %{"text" => "I wrote the table."}
      })

      step = step(ticket, "implementing")

      assert %{kind: :agent, job: %{id: id}, closing: "I wrote the table."} =
               Past.latest_run(ticket, step)

      assert id == job.id
    end

    test "a step that never ran, or is a human one, has none", %{ticket: ticket} do
      assert Past.latest_run(ticket, step(ticket, "implementing")) == nil
      assert Past.latest_run(ticket, %{kind: :human, name: "human_testing", runs: 1}) == nil
    end

    # What the Steps view shows under a failed command: the end of its log, from a whole line.
    test "a command step's is its batch, with the log's end for the commands that failed", %{
      ticket: ticket,
      worker: worker
    } do
      ticket = run(ticket, worker, "implementation.md")
      log = String.duplicate("compiling\n", 600) <> "error: boom\n"
      ticket = check(ticket, worker, 2, log: log)
      assert ticket.state == "implementing"

      assert %{kind: :command, outcome: "checks_failed", jobs: [job, _second], tails: tails} =
               Past.latest_run(ticket, step(ticket, "checking"))

      assert job.exit_status == 2
      # The end of the log from a whole line, with how much was cut said first.
      assert [marker, kept] = String.split(tails[job.id], "\n", parts: 2)
      assert marker =~ "bytes cut"
      assert byte_size(kept) <= Past.tail_bytes()
      assert String.starts_with?(kept, "compiling\n")
      assert String.ends_with?(kept, "error: boom\n")
    end

    test "a command that exited 0 has no tail", %{ticket: ticket, worker: worker} do
      ticket = run(ticket, worker, "implementation.md")
      ticket = check(ticket, worker, 0)
      assert ticket.state == "reviewing"

      assert %{outcome: "done", tails: tails} = Past.latest_run(ticket, step(ticket, "checking"))
      assert tails == %{}
    end
  end

  describe "Commands.latest_batch/3" do
    # The state's own newest batch: the ticket's newest is `checking`'s only because nothing ran
    # after it, and a ticket stuck in `checking` is read the same way.
    test "is the state's newest batch, not the ticket's", %{ticket: ticket, worker: worker} do
      ticket = run(ticket, worker, "implementation.md")
      ticket = check(ticket, worker, 1)
      ticket = run(ticket, worker, "implementation.md")
      ticket = check(ticket, worker, 0)
      assert ticket.state == "reviewing"

      assert %{outcome: "done", jobs: [%{exit_status: 0} = first, %{exit_status: 0} = second]} =
               Commands.latest_batch(ticket.id, "checking", nil)

      # In `invoke` order: the batch's commands are not read back in whatever order the rows come.
      assert Jobs.spec(first).command["args"] == []
      assert Jobs.spec(second).command["args"] == ["--all"]
      assert Commands.latest_batch(ticket.id, "reviewing", nil) == nil
    end
  end
end
