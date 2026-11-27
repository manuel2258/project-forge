defmodule Forge.BuildFixtures do
  @moduledoc """
  A ticket whose workflow has a command that keeps its build, with commands that kept it on
  machines, as the platform holds one: finished jobs with their `warm_*` columns
  (`ForgeWeb.ExploreLivePagesTest`, `ForgeWeb.CommandPagesTest`). Made-up data only.
  """

  import Ecto.Query, only: [from: 2]
  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{FakeWorker, Jobs, Projects, Repo, Tickets}
  alias Forge.Jobs.Job

  @keeping """
  version: 1
  initial: implementing
  commands:
    build:
      run: .forge/commands/build.sh
      produces: build.log
      timeout: 20m
      keep_build: [0, 1]
  states:
    implementing:
      prompt: agents/implement.md
      produces: [implementation.md, changeset]
      may_invoke:
        build: { max: 3 }
      budget: { turns: 20, tokens: 400k }
    done: {}
  transitions:
    - { from: implementing, to: done }
  limits:
    ticket_tokens: 5M
  """

  @doc "The workflow: one command, `build`, which keeps its build on exit status 0 or 1."
  def keeping, do: @keeping

  @doc "A project the user is a member of, and a ticket in it."
  def ticket_on(user, workflow \\ @keeping) do
    repo =
      seeded_repo(%{
        ".forge/workflow.yml" => workflow,
        ".forge/commands/build.sh" => "#!/bin/sh\nexec make \"$@\"\n"
      })

    {:ok, project} =
      Projects.register(
        %{name: "bv-#{System.unique_integer([:positive])}", repo_path: repo},
        user
      )

    funded!(project)
    {:ok, ticket} = Tickets.admit(project, %{title: "Build it"}, {:user, user.id})
    {project, ticket}
  end

  @doc "The ticket's `build` commands, one for each list of arguments, oldest first, all pending."
  def invoke_builds(ticket, worker, args_lists) do
    [job] = Jobs.for_ticket(ticket.id)
    invocations = Enum.map(args_lists, &%{"command" => "build", "args" => &1})
    {:ok, _parked} = FakeWorker.park(FakeWorker.assign(job, worker), invocations)
    ticket |> then(&Jobs.commands_for_ticket(&1.id)) |> Enum.sort_by(& &1.attempt)
  end

  @doc """
  Finishes `command` on `worker` with `status` and sets the columns a keeping worker reports:
  kept, its size, and the saved folder sizes when `:folders` is given.
  """
  def keep(command, worker, status \\ 0, opts \\ []) do
    {:ok, _} = command |> FakeWorker.assign(worker) |> FakeWorker.finish_command(status)

    Repo.update_all(from(j in Job, where: j.id == ^command.id),
      set: [
        warm_epoch: Keyword.get(opts, :epoch, 0),
        warm_source: "clone",
        warm_kept: true,
        warm_size: Keyword.get(opts, :size, 5_242_880),
        warm_folders: Keyword.get(opts, :folders)
      ]
    )

    Jobs.get!(command.id)
  end

  @doc "Records `steps` (a worker's report) as the step events of a command."
  def record_steps(job, steps) do
    {:ok, _} = Ecto.Multi.new() |> Forge.Jobs.Steps.put(job, steps) |> Repo.transaction()
    :ok
  end

  @doc "A tree of saved folder sizes, in the shape `ForgeCore.WarmBuild.folders/1` keeps."
  def folders do
    %{
      "folders" => [
        %{"path" => "target/", "bytes" => 3_000_000_000},
        %{"path" => "deps/", "bytes" => 120_000_000}
      ],
      "more" => %{"count" => 2, "bytes" => 4_096},
      "loose" => %{"count" => 3, "bytes" => 512},
      "rest" => 9_000_000
    }
  end
end
