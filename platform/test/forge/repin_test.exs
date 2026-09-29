defmodule Forge.RepinTest do
  @moduledoc """
  Re-pinning a ticket's workflow (`Forge.Engine.repin/2`, `docs/design/workflow-grammar-v1.md`
  § Pinning): a command script is read at the pin and never from the branch, so a fix that lands on
  the default branch reaches a ticket already failing on the old one only when a person re-pins it.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Engine, Events, FakeWorker, Jobs, Tickets}

  @workflow """
  version: 1
  initial: implementing
  commands:
    build:
      run: .forge/commands/build.sh
      produces: build.log
      timeout: 20m
  states:
    implementing:
      prompt: agents/implement.md
      produces: [implementation.md, changeset]
      budget: { turns: 20, cost: 2.00 }
    packaging:
      invoke: [build]
      exit: { 0: done, "*": build_failed }
    human_testing: {}
  transitions:
    - { from: implementing, to: packaging }
    - { from: packaging, to: human_testing }
  limits:
    ticket_cost: 25.00
  """

  @broken ~S"""
  #!/bin/sh
  cd "$(dirname "$0")/../.." && exec make
  """

  @fixed "#!/bin/sh\nexec make\n"

  setup do
    repo =
      seeded_repo(%{
        ".forge/workflow.yml" => @workflow,
        ".forge/commands/build.sh" => @broken
      })

    {:ok, project} =
      register_owned!(%{name: "repin-#{System.unique_integer([:positive])}", repo_path: repo})

    user = member_fixture(project)
    funded!(project)

    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

    {:ok, ticket} = Tickets.admit(project, %{title: "Package it", body: "."}, {:user, user.id})
    %{project: project, ticket: ticket, user: user, worker: FakeWorker.connect()}
  end

  # Implemented, then packaging failed with no edge for it: stuck in `packaging`, nothing live.
  defp stuck_in_packaging(%{ticket: ticket, worker: worker}) do
    [job] = Jobs.for_ticket(ticket.id)
    written = %{"implementation.md" => "---\noutcome: done\n---\n# Done\n"}
    {:ok, _job} = FakeWorker.run(job, worker, "success", written: written)

    [build] = Jobs.commands_for_ticket(ticket.id)
    {:ok, _job} = build |> FakeWorker.assign(worker) |> FakeWorker.finish_command(1)

    ticket = Tickets.get!(ticket.id)
    assert %{state: "packaging", status: :stuck} = ticket
    ticket
  end

  test "a fix on the default branch reaches the ticket once it is re-pinned", context do
    %{project: project, user: user} = context
    ticket = stuck_in_packaging(context)
    pinned = ticket.workflow_commit

    assert Tickets.drift(ticket, project) == nil

    head =
      commit_to_default(project, %{
        ".forge/commands/build.sh" => @fixed,
        ".forge/workflow.yml" => String.replace(@workflow, "timeout: 20m", "timeout: 30m"),
        "README.md" => "x\n"
      })

    # Only what the ticket runs: `.forge/`, and not the README beside it.
    assert %{head: ^head, paths: [".forge/commands/build.sh", ".forge/workflow.yml"]} =
             Tickets.drift(ticket, project)

    # Run again without re-pinning, and it is the old script. Running again unsticks it, and a
    # ticket that is not stuck gives no reason, however recently it was.
    assert Engine.why_stuck(ticket)
    {:ok, _ticket} = Engine.retry(ticket, user.id)
    assert Engine.why_stuck(Tickets.get!(ticket.id)) == nil
    [old] = Enum.filter(Jobs.commands_for_ticket(ticket.id), &(&1.status == :pending))
    assert Jobs.spec(old).command["script"] == @broken
    {:ok, _job} = old |> FakeWorker.assign(context.worker) |> FakeWorker.finish_command(1)

    {:ok, repinned} = Engine.repin(Tickets.get!(ticket.id), user.id)

    assert repinned.workflow_commit == head
    # The definition and the commit move together: the script is read at the one, and its
    # timeout comes from the other.
    assert Tickets.workflow(repinned).commands["build"].timeout_ms == :timer.minutes(30)
    assert repinned.base_commit == ticket.base_commit
    assert repinned.state == "packaging"
    assert Tickets.drift(repinned, project) == nil

    assert %{payload: %{"from" => ^pinned, "to" => ^head}} =
             ticket.id |> Events.for_ticket() |> Enum.find(&(&1.type == "ticket.repinned"))

    {:ok, _ticket} = Engine.retry(repinned, user.id)
    [new] = Enum.filter(Jobs.commands_for_ticket(ticket.id), &(&1.status == :pending))
    assert Jobs.spec(new).command["script"] == @fixed
  end

  # The batch is found by the log, not by what the state is now: a re-pin can make a command
  # state something else after its batch ran, and the batch is still what the ticket leaves with.
  test "a batch decided under the old pin goes with the ticket out of the state", context do
    %{project: project, user: user} = context
    ticket = stuck_in_packaging(context)

    human =
      @workflow
      |> String.replace(
        "  packaging:\n    invoke: [build]\n    exit: { 0: done, \"*\": build_failed }\n",
        "  packaging: {}\n"
      )
      |> String.replace(
        "  - { from: packaging, to: human_testing }\n",
        "  - { from: packaging, to: human_testing }\n  - { from: packaging, to: implementing }\n"
      )

    assert human =~ "packaging: {}" and human =~ "from: packaging, to: implementing"
    commit_to_default(project, %{".forge/workflow.yml" => human})

    {:ok, repinned} = Engine.repin(ticket, user.id)
    {:ok, _ticket} = Engine.choose(repinned, user.id, "implementing")

    [job] = ticket.id |> Jobs.for_ticket() |> Enum.filter(&(&1.status == :pending))
    assert %{"from" => "packaging", "batch" => batch} = job.spec["entered"]
    assert is_binary(batch)
  end

  test "is refused with nothing new to pin", context do
    ticket = stuck_in_packaging(context)
    assert {:error, :already_pinned} = Engine.repin(ticket, context.user.id)
  end

  # A job made from the old pin would run on it: its spec carries the prompt and script it was
  # made with.
  test "is refused while a job for the state is live", context do
    commit_to_default(context.project, %{".forge/agents/implement.md" => "Implement it better.\n"})

    assert {:error, {:job_live, "implementing"}} =
             Engine.repin(context.ticket, context.user.id)

    assert Tickets.get!(context.ticket.id).workflow_commit == context.ticket.workflow_commit
  end

  test "is refused when the new workflow has no state the ticket is in", context do
    ticket = stuck_in_packaging(context)

    renamed =
      @workflow
      |> String.replace("packaging", "shipping")

    commit_to_default(context.project, %{".forge/workflow.yml" => renamed})

    assert {:error, {:no_state, "packaging"}} = Engine.repin(ticket, context.user.id)
  end

  test "is refused while an approval is pending", context do
    ticket = stuck_in_packaging(context)
    commit_to_default(context.project, %{".forge/commands/build.sh" => @fixed})

    {:ok, pending} =
      ticket
      |> Ecto.Changeset.change(pending_transition: %{"to" => "human_testing"})
      |> Forge.Repo.update()

    assert {:error, :pending_approval} = Engine.repin(pending, context.user.id)
  end

  test "is refused on a ticket that is not open", context do
    ticket = stuck_in_packaging(context)
    commit_to_default(context.project, %{".forge/commands/build.sh" => @fixed})
    {:ok, cancelled} = Engine.cancel(ticket, context.user.id)

    assert {:error, {:not_repinnable, :cancelled}} = Engine.repin(cancelled, context.user.id)
  end
end
