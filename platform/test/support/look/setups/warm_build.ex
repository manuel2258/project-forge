defmodule Forge.Look.Setups.WarmBuild do
  @moduledoc """
  A ticket's warm build (`docs/design/ui.md` § The details, § The job page, § A job waiting for a
  machine): a ticket whose workflow has a command that keeps its build and holds a copy, with a
  long argument vector that has markup in it and a machine named at length; a ticket with such a
  workflow and no copy; a ticket whose workflow keeps nothing, which draws no block; and the
  commands' pages — one that started from the copy and kept nothing, one that waits for the
  machine holding it.

  Users: `member`. Paths: `copy`, `none`, `plain`, `started` (the command that started from the
  copy), `waiting` (the command that waits for it), `project` (the Tickets list, whose row of the
  waiting ticket reads the warm sentence). Made from fixtures, with made-up data only.
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.MachinesFixtures, only: [machine_fixture: 1]

  alias Forge.{Jobs, Repo}

  @impl true
  def build do
    member = user_fixture()
    project = project_fixture(%{name: "look-warm"}) |> join!(member)
    machine = machine_fixture(member)
    now = DateTime.utc_now(:second)

    keeping = &ticket_on(project, &1, &2, keeping_workflow())
    copy = keeping.(61, "Compile the dependencies once per ticket")
    none = keeping.(62, "Give commands a warm environment")

    plain =
      ticket_on(project, 63, "A ticket whose commands keep nothing", workflow_map())

    waiting = keeping.(64, "Run the gate again after the refinement")

    kept = kept!(copy, machine, now)
    started = started!(copy, machine, kept, now)
    pending = pending!(waiting)
    :ok = Jobs.record_wait(pending, "warm", ForgeCore.WarmBuild.wait_sentence())

    page = &"/tickets/#{project.name}/#{&1.number}"
    job = &"/tickets/#{project.name}/#{&1.ticket.number}/jobs/#{&2.id}"

    %{
      users: %{"member" => member},
      paths: %{
        "copy" => page.(copy),
        "none" => page.(none),
        "plain" => page.(plain),
        "started" => job.(%{ticket: copy}, started),
        "waiting" => job.(%{ticket: waiting}, pending),
        "project" => "/projects/#{project.name}"
      }
    }
  end

  defp keeping_workflow do
    Map.put(workflow_map(), "commands", %{
      "check" => %{
        "run" => ".forge/commands/check.sh",
        "timeout" => "10m",
        "keep_build" => [0, 1]
      }
    })
  end

  defp ticket_on(project, number, title, workflow) do
    ticket_fixture(%{
      project: project,
      number: number,
      branch: "ticket/#{number}",
      title: title,
      state: "implementing",
      workflow: workflow
    })
  end

  # Arguments as long as someone made them, with markup in them: the block wraps them and shows
  # the markup as text.
  @args [
    "--only",
    "<b>scores</b>",
    "--trace",
    "--seed",
    "0",
    "--include",
    "test/game/very/long/nested/directory/names/that/never/break/scores_ranking_ties_test.exs"
  ]

  defp command(ticket, attempt, args) do
    job_fixture(%{
      ticket: ticket,
      state: "implementing",
      attempt: attempt,
      kind: :command,
      spec: %{
        "kind" => "command",
        "command" => %{
          "name" => "check",
          "script" => "#!/usr/bin/env bash\nexec mix check \"$@\"\n",
          "args" => args,
          "at" => "9f3c1a0b2d4e6f8a1b2c3d4e5f60718293a4b5c6",
          "run" => ".forge/commands/check.sh",
          "timeout_ms" => 600_000,
          "keep_build" => [0, 1],
          "warm_start" => true
        }
      }
    })
  end

  # The command that kept the copy: 412 MiB, on the machine, a quarter of an hour ago.
  defp kept!(ticket, machine, now) do
    command(ticket, 1, @args)
    |> Jobs.Job.progress_changeset(%{
      status: :finished,
      outcome: :converged,
      exit_status: 0,
      worker_id: machine.id,
      started_at: DateTime.add(now, -1_000, :second),
      finished_at: DateTime.add(now, -900, :second),
      warm_epoch: 0,
      warm_source: "clone",
      warm_kept: true,
      warm_size: 412 * 1_048_576
    })
    |> Repo.update!()
  end

  # The command after it: started from the copy, and ended by its timeout, so it kept nothing.
  defp started!(ticket, machine, from, now) do
    command(ticket, 2, ["--only", "scores"])
    |> Jobs.Job.progress_changeset(%{
      status: :finished,
      outcome: :error,
      worker_id: machine.id,
      started_at: DateTime.add(now, -500, :second),
      finished_at: DateTime.add(now, -200, :second),
      warm_epoch: 0,
      warm_source: "copy",
      warm_from_id: from.id,
      warm_kept: false,
      warm_unkept: "timeout"
    })
    |> Repo.update!()
  end

  defp pending!(ticket), do: command(ticket, 1, ["--only", "scores"])
end
