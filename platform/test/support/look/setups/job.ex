defmodule Forge.Look.Setups.Job do
  @moduledoc """
  The job page (`docs/design/ui.md` § The job page, `6e`, `21a`, `21b`): a ticket in
  `implementing` whose first attempt ended `did_not_converge` after a failing test and whose
  second is running now, with a plan, edits, a failing then a passing test and the agent's
  words — and a command the second attempt invoked.

  Users: `member`. Paths: `failed` (the first attempt, `6e`), `running` (the second, `21a`,
  `21b`), `command`. Made from fixtures — no repository, so the strip's Changes counts nothing.
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.MachinesFixtures, only: [machine_fixture: 1]
  import Forge.TicketFixtures

  alias Forge.{Jobs, Repo}
  alias Forge.Jobs.Run

  @impl true
  def build do
    member = user_fixture()
    project = project_fixture(%{name: "game"}) |> join!(member)
    machine = machine_fixture(member)

    ticket =
      ticket_fixture(%{
        project: project,
        number: 41,
        branch: "forge/game-41",
        title: "Persist the high score table",
        state: "implementing"
      })

    ran!(ticket, "refining")
    planning = ran!(ticket, "planning")
    wrote!(ticket, "plan.md", "# Plan\n\nStore scores in a table.\n", {:job, planning.id})

    now = DateTime.utc_now(:second)
    failed = failed!(ticket, machine, now)
    running = running!(ticket, machine, now)
    command = command!(ticket, running, now)

    path = &"/tickets/#{project.name}/#{ticket.number}/jobs/#{&1.id}"

    %{
      users: %{"member" => member},
      paths: %{
        "failed" => path.(failed),
        "running" => path.(running),
        "command" => path.(command)
      }
    }
  end

  defp failed!(ticket, machine, now) do
    job =
      job_fixture(%{ticket: ticket, state: "implementing", attempt: 1, spec: spec(ticket)})

    tool!(job, "f1", "Read", %{"file_path" => "lib/game/scores.ex"}, "ok")
    said!(job, "The table lives in an Agent today. I'll add a repo and keep `top/1`'s signature.")
    tool!(job, "f2", "Edit", edit("lib/game/scores.ex"), "ok")

    tool!(
      job,
      "f3",
      "Bash",
      %{"command" => "mix test test/game/scores_test.exs"},
      "1) test top/1 orders ties by time\n   left:  [\"bo\", \"al\"]\n   right: [\"al\", \"bo\"]",
      true
    )

    said!(
      job,
      "Still failing on ties. Both rows come back in the same second, so `inserted_at` cannot separate them."
    )

    tool!(job, "f4", "Edit", edit("lib/game/scores.ex"), "ok")

    tool!(
      job,
      "f5",
      "Bash",
      %{"command" => "mix test test/game/scores_test.exs"},
      "1 failure",
      true
    )

    said!(job, "Out of turns before the tie order is settled.")

    run!(
      job,
      machine,
      DateTime.add(now, -1_300, :second),
      DateTime.add(now, -600, :second),
      620_000
    )

    job
    |> Jobs.Job.progress_changeset(%{
      status: :finished,
      outcome: :did_not_converge,
      turns: 30,
      started_at: DateTime.add(now, -1_300, :second),
      finished_at: DateTime.add(now, -600, :second)
    })
    |> Repo.update!()
  end

  defp running!(ticket, machine, now) do
    job =
      job_fixture(%{
        ticket: ticket,
        state: "implementing",
        attempt: 2,
        status: :running,
        model: "claude-sonnet-4-5",
        effort: "high",
        spec: spec(ticket)
      })

    tool!(job, "r0", "TodoWrite", %{"todos" => todos()}, "ok")
    tool!(job, "r1", "Read", %{"file_path" => "lib/game/scores.ex"}, "ok")
    tool!(job, "r2", "Read", %{"file_path" => "test/game/scores_test.exs"}, "ok")

    said!(
      job,
      "The table lives in an Agent today. I'll add a SQLite repo under `$FORGE_DATA_DIR`."
    )

    tool!(
      job,
      "r3",
      "Write",
      %{"file_path" => "priv/repo/migrations/1_scores.exs", "content" => "x"},
      "ok"
    )

    tool!(job, "r4", "Edit", edit("lib/game/scores.ex"), "ok")

    tool!(
      job,
      "r5",
      "Bash",
      %{"command" => "mix test test/game/scores_test.exs"},
      "2 failures · top/1 returns [] after restart",
      true
    )

    tool!(job, "r6", "Edit", edit("lib/game/scores.ex"), "ok")

    tool!(
      job,
      "r7",
      "Bash",
      %{"command" => "mix test test/game/scores_test.exs"},
      "9 tests, 0 failures"
    )

    run!(job, machine, DateTime.add(now, -420, :second), nil, 220_000)

    job
    |> Jobs.Job.progress_changeset(%{
      turns: 14,
      started_at: DateTime.add(now, -420, :second)
    })
    |> Repo.update!()
  end

  defp command!(ticket, parent, now) do
    command =
      job_fixture(%{
        ticket: ticket,
        state: "implementing",
        kind: :command,
        parent_job_id: parent.id,
        spec: %{
          "kind" => "command",
          "command" => %{
            "name" => "check",
            "script" => "#!/usr/bin/env bash\nexec mix check --fast \"$@\"\n",
            "args" => ["--only", "scores"],
            "at" => "9f3c1a0b2d4e6f8a",
            "run" => ".forge/commands/check.sh",
            "timeout_ms" => 600_000
          }
        }
      })

    command
    |> Jobs.Job.progress_changeset(%{
      status: :finished,
      outcome: :converged,
      exit_status: 0,
      started_at: DateTime.add(now, -200, :second),
      finished_at: DateTime.add(now, -188, :second)
    })
    |> Repo.update!()
  end

  defp spec(ticket) do
    %{
      "prompt" => "Implement the plan. Run the tests before you say you are done.",
      "branch" => ticket.branch,
      "commit" => "9f3c1a0b2d4e6f8a",
      "env" => "implement",
      "budget" => %{"turns" => 30, "cost" => 4.0},
      "inputs" => [%{"name" => "plan.md", "version" => 1}],
      "outcomes" => ["done", "blocked"],
      "produces" => ["summary.md"]
    }
  end

  defp todos do
    [
      %{"content" => "Add the schema and a migration", "status" => "completed"},
      %{"content" => "Write record/2 and top/1 against the repo", "status" => "completed"},
      %{"content" => "Replace the in-memory list", "status" => "completed"},
      %{
        "content" => "Run the full check",
        "activeForm" => "Running the full check",
        "status" => "in_progress"
      },
      %{"content" => "Write a summary for review", "status" => "pending"}
    ]
  end

  defp edit(path),
    do: %{
      "file_path" => path,
      "old_string" => "Agent.get(__MODULE__, & &1)",
      "new_string" => "Repo.all(Score)\n|> Enum.take(10)"
    }

  defp said!(job, text),
    do:
      :ok = Jobs.record_harness_event(job.id, %{type: "job.harness.text", payload: %{text: text}})

  defp tool!(job, id, name, input, excerpt, error? \\ false) do
    :ok =
      Jobs.record_harness_event(job.id, %{
        type: "job.harness.tool_use",
        payload: %{id: id, name: name, input: input}
      })

    :ok =
      Jobs.record_harness_event(job.id, %{
        type: "job.harness.tool_result",
        payload: %{tool_use_id: id, is_error: error?, excerpt: excerpt, bytes: byte_size(excerpt)}
      })
  end

  defp run!(job, machine, started, finished, usage) do
    Repo.insert!(%Run{
      job_id: job.id,
      worker_id: machine.id,
      started_at: started,
      finished_at: finished,
      usage: usage
    })
  end
end
