defmodule Forge.Look.Setups.StepsOrder do
  @moduledoc """
  The order Steps draws a ticket's visits in once it has passed an update step (`docs/design/ui.md`
  § Steps): a ticket that began in a conversation step (`refining`), went through `refresh`, had an
  agent that invoked two commands, a command state, a review that sent the work back, and is in
  `implementing` again with the agent waiting for a machine.

  Users: `member`. Paths: `ticket` (the ticket page, Steps).

  Built by the engine with a fake worker answering each job, because the order in question is the
  one the platform's own events were written in; a fixture's job writes no creation event, and
  would sort last whatever the page does. Made-up data only.
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures, only: [run!: 1]
  import Forge.ProjectFixtures, only: [commit_files!: 3]

  alias Forge.{Artifacts, Conversations, FakeWorker, Jobs, Operator, Projects, Repo, Tickets}
  alias Forge.Jobs.Job
  alias Forge.Look.Setups.Decision

  @workflow """
  version: 1
  initial: refining
  commands:
    build:
      run: .forge/commands/build.sh
      timeout: 20m
  states:
    refining:
      chat: true
      prompt: agents/refine.md
      inputs: [ticket]
      produces: [refinement.md]
    refresh:
      on_enter: update
    implementing:
      prompt: agents/implement.md
      inputs: [refinement.md]
      produces: [implementation.md, changeset]
      may_invoke:
        build: { max: 3 }
      budget: { turns: 200, tokens: 2M }
    checking:
      invoke: [build]
      exit: { 0: done, "*": checks_failed }
    reviewing:
      prompt: agents/verify.md
      inputs: [implementation.md]
      produces: [review.md, commit-message]
      outcomes: [done, changes_requested]
      budget: { turns: 60, tokens: 600k }
    review_ready: {}
  transitions:
    - { from: refining,   to: refresh }
    - { from: refresh,    to: implementing }
    - { from: implementing, to: checking }
    - { from: checking,   to: reviewing }
    - { from: checking,   to: implementing, when: checks_failed, max: 3 }
    - { from: reviewing,  to: review_ready }
    - { from: reviewing,  to: implementing, when: changes_requested, max: 2 }
  limits:
    ticket_tokens: 5M
  """

  @impl true
  def build do
    member = user_fixture()
    project = Decision.project!("look-steps-order", @workflow, member)

    commit_files!(Projects.repo_path(project), "main", %{
      ".forge/commands/build.sh" => "#!/bin/sh\nexec make \"$@\"\n"
    })

    worker = FakeWorker.connect()

    {:ok, ticket} =
      Tickets.admit(project, %{title: "Ticket timeline wrong order"}, {:user, member.id})

    ticket = refine!(ticket, member)
    ticket = implement!(ticket, worker)
    ticket = check!(ticket, worker, 0)
    ticket = review!(ticket, worker)
    # Back in `implementing`, the agent waiting for a machine.
    %{state: "implementing"} = ticket

    %{
      users: %{"member" => member},
      paths: %{"ticket" => "/tickets/#{project.name}/#{ticket.number}"}
    }
  end

  # The conversation step answers and the person accepts it: the ticket takes the edge into
  # `refresh`, which runs, and on into `implementing`.
  defp refine!(ticket, member) do
    [chat] = Jobs.step_chats_for_ticket(ticket.id)

    run!(chat)

    {:ok, chat} =
      Conversations.record_turn(chat, %{
        "turn" => 1,
        "commit" => String.duplicate("a", 40),
        "documents" => %{"refinement.md" => "# Refinement\n\nThe order is wrong.\n"},
        "harness" => %{"turns" => 1, "usage" => 2_000, "cost_usd" => 0.01, "session_id" => "s"}
      })

    seen = %{"refinement.md" => Artifacts.latest(ticket.id, "refinement.md").version}
    {:ok, ticket} = Operator.accept_step(Repo.get!(Job, chat.id), member, "done", seen)
    ticket
  end

  # The agent invokes `build` twice from inside `implementing`, the commands end, and the agent
  # answers.
  defp implement!(ticket, worker) do
    assignment = FakeWorker.assign(pending(ticket), worker)

    {:ok, _parked} =
      FakeWorker.park(assignment, [
        %{"command" => "build", "args" => ["--release"]},
        %{"command" => "build", "args" => []}
      ])

    check!(ticket, worker, 0)
    run(ticket, worker, "implementation.md")
  end

  defp review!(ticket, worker), do: run(ticket, worker, "review.md", "changes_requested")

  defp pending(ticket), do: ticket.id |> Jobs.for_ticket() |> Enum.find(&(&1.status == :pending))

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

  defp check!(ticket, worker, status) do
    for job <- Jobs.commands_for_ticket(ticket.id), job.status == :pending do
      {:ok, _job} = job |> FakeWorker.assign(worker) |> FakeWorker.finish_command(status)
    end

    Tickets.get!(ticket.id)
  end
end
