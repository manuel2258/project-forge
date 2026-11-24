defmodule Forge.WarmFixtures do
  @moduledoc """
  What the warm build's tests share (`docs/design/worker-tier.md` § The command copy): a project
  whose workflow has a command that keeps its build and a ticket sitting in the state that runs
  four of them, and a command row that ran and kept — or did not keep — its build on a machine.
  """

  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{FakeWorker, Jobs, Repo, Tickets}
  alias Forge.Jobs.Job

  @workflow """
  version: 1
  initial: implementing
  commands:
    build:
      run: .forge/commands/build.sh
      timeout: 20m
    test:
      run: .forge/commands/test.sh
      timeout: 30m
      keep_build: [0, 1]
  states:
    implementing:
      prompt: agents/implement.md
      produces: [implementation.md, changeset]
      budget: { turns: 20, tokens: 400k }
    checking:
      invoke: [build, test, test, test]
      exit: { 0: done, "*": checks_failed }
    review_ready: {}
  transitions:
    - { from: implementing, to: checking }
    - { from: checking, to: review_ready }
    - { from: checking, to: implementing, when: checks_failed, max: 3 }
  limits:
    ticket_tokens: 5M
  """

  @doc "The workflow the ticket is admitted under: `test` keeps its build on exit 0 and 1."
  def workflow, do: @workflow

  @doc """
  A project registered with `workflow/0`, a member of it, and a ticket in `checking` whose four
  commands (`build` and three of `test`) are pending, as `%{project, user, ticket, commands}` with
  the commands in the order they were made. Every command asks for 4000 bytes and one core, so a
  machine with a budget of 4000 holds exactly one.

  The agent job that got the ticket there ran on a machine of its own, which serves no project and
  so is never a place a command can go.
  """
  def ticket_in_checking! do
    repo =
      seeded_repo(%{
        ".forge/workflow.yml" => @workflow,
        ".forge/commands/build.sh" => "#!/bin/sh\nexec make\n",
        ".forge/commands/test.sh" => "#!/bin/sh\nexec make test \"$@\"\n"
      })

    {:ok, project} =
      register_owned!(%{name: "warm-#{System.unique_integer([:positive])}", repo_path: repo})

    user = member_fixture(project)
    funded!(project)

    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

    {:ok, ticket} = Tickets.admit(project, %{title: "Save scores", body: "."}, {:user, user.id})
    [agent] = Jobs.for_ticket(ticket.id)
    written = %{"implementation.md" => "---\noutcome: done\n---\n# Done\n"}
    {:ok, _job} = FakeWorker.run(agent, FakeWorker.connect(), "success", written: written)

    ticket = Tickets.get!(ticket.id)
    commands = ticket.id |> Jobs.commands_for_ticket() |> Enum.sort_by(& &1.inserted_at)

    for command <- commands do
      command |> Ecto.Changeset.change(memory_max: 4_000, cores: 1) |> Repo.update!()
    end

    %{
      project: project,
      user: user,
      ticket: ticket,
      commands: Enum.map(commands, &Jobs.get!(&1.id))
    }
  end

  @doc """
  A command of `ticket` that ran on `worker` and ended, as the platform records one a worker
  reported on: `warm_kept` true unless `:warm_kept` says otherwise, in `:epoch` (the ticket's own
  by default), finished `:ago` seconds ago (a minute by default), `:size` bytes.
  """
  def kept!(ticket, worker, opts \\ []) do
    ago = Keyword.get(opts, :ago, 60)
    finished = DateTime.add(DateTime.utc_now(:second), -ago, :second)
    name = Keyword.get(opts, :command, "test")

    job =
      job_fixture(%{
        ticket: ticket,
        kind: :command,
        attempt: System.unique_integer([:positive]),
        spec: %{
          "command" => %{
            "name" => name,
            "args" => Keyword.get(opts, :args, ["--all"]),
            "at" => String.duplicate("c", 40)
          }
        }
      })

    job
    |> Job.progress_changeset(%{
      status: :finished,
      outcome: :converged,
      exit_status: 0,
      worker_id: worker.id,
      started_at: DateTime.add(finished, -30, :second),
      finished_at: finished,
      warm_epoch: Keyword.get(opts, :epoch, ticket.warm_epoch),
      warm_source: Keyword.get(opts, :source, "clone"),
      warm_kept: Keyword.get(opts, :warm_kept, true),
      warm_size: Keyword.get(opts, :size, 1_048_576)
    })
    |> Repo.update!()
  end
end
