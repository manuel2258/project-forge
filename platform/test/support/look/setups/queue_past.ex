defmodule Forge.Look.Setups.QueuePast do
  @moduledoc """
  What a queue item shows of its ticket's past (`docs/design/ui.md` § What each kind shows): a
  ticket stuck on a spent loop, one stuck in a command step whose build failed, one ready to merge
  with a presentation, and a document approval with a long document.

  Users: `member`. Paths: `loop` (stuck in `reviewing`), `command` (stuck in `checking`), `review`,
  `document`.

  Built by the engine with a fake worker answering each job, because a past is what the engine
  recorded: a retry, a loop's rounds and a batch's commands are not rows worth writing by hand.
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures
  import Forge.ProjectFixtures, only: [commit_files!: 3]
  import Forge.MergeFixtures

  alias Forge.{Artifacts, FakeWorker, Jobs, Projects, Repo, Tickets}
  alias Forge.Events.Event
  alias Forge.Look.Setups.Decision

  @example Path.expand("../../../../../core/test/fixtures/workflow_example.yml", __DIR__)
  @external_resource @example

  @workflow """
  version: 1
  initial: implementing
  commands:
    build:
      run: .forge/commands/build.sh
      timeout: 20m
  states:
    implementing:
      prompt: agents/implement.md
      inputs: [ticket]
      produces: [implementation.md, changeset]
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
    merged:
      on_enter: merge
  transitions:
    - { from: implementing, to: checking }
    - { from: checking,     to: reviewing }
    - { from: checking,     to: implementing, when: checks_failed, max: 3 }
    - { from: reviewing,    to: review_ready }
    - { from: reviewing,    to: implementing, when: changes_requested, max: 2 }
    - { from: review_ready, to: merged,       approve: [changeset] }
    - { from: review_ready, to: implementing }
  limits:
    ticket_tokens: 5M
  """

  @build_log """
  ==> Compiling the game
  warning: unused variable `delta` (lib/game/scores.ex:41)
  ==> Compiling lib/game/leaderboard.ex
  error: undefined function rank_of/2 (lib/game/leaderboard.ex:58)
    58 |     rank = rank_of(scores, player)
       |            ^^^^^^^
  == Compilation failed: 1 error
  """

  @impl true
  def build do
    member = user_fixture()
    project = Decision.project!("look-queue-past", @workflow, member)

    commit_files!(Projects.repo_path(project), "main", %{
      ".forge/commands/build.sh" => "#!/bin/sh\nexec make \"$@\"\n"
    })

    worker = FakeWorker.connect()

    loop = loop!(project, member, worker)
    command = command!(project, member, worker)
    review = review!(project, member, worker)
    document = document!(member)

    %{
      users: %{"member" => member},
      paths: %{
        "loop" => "/?item=stuck-#{loop.id}",
        "command" => "/?item=stuck-#{command.id}",
        "review" => "/?item=review-#{review.id}",
        "document" => "/?item=approval-#{document.id}"
      }
    }
  end

  # The review sent the work back twice and a third time sticks it: a ticket that has been
  # round the loop.
  defp loop!(project, member, worker) do
    {:ok, ticket} =
      Tickets.admit(
        project,
        %{title: "Pin the player's row under the leaderboard"},
        {:user, member.id}
      )

    ticket =
      Enum.reduce(1..3, ticket, fn _round, ticket ->
        ticket = run(ticket, worker, "implementation.md")
        ticket = check(ticket, worker, 0)
        run(ticket, worker, "review.md", "changes_requested")
      end)

    job = ticket.id |> Jobs.for_ticket() |> Enum.filter(&(&1.state == "reviewing")) |> List.last()

    said!(
      ticket,
      job,
      "Two comments are still open: the empty table has no copy, and the sort is not stable " <>
        "when two players tie."
    )

    ticket
  end

  # Four builds that did not compile: stuck in the command step itself, whose last batch is what
  # the queue has to show.
  defp command!(project, member, worker) do
    {:ok, ticket} =
      Tickets.admit(project, %{title: "Show the rank outside the top ten"}, {:user, member.id})

    Enum.reduce(1..4, ticket, fn _round, ticket ->
      ticket = run(ticket, worker, "implementation.md")
      check(ticket, worker, 2, log: String.duplicate("==> Compiling\n", 3) <> @build_log)
    end)
  end

  # Resting for a person, with the change, the message its merge will write and a presentation.
  defp review!(project, member, worker) do
    {:ok, ticket} =
      Tickets.admit(project, %{title: "Sound toggle in settings"}, {:user, member.id})

    ticket = run(ticket, worker, "implementation.md")
    ticket = check(ticket, worker, 0)
    ticket = run(ticket, worker, "review.md")

    sha =
      commit_files!(Projects.repo_path(project), ticket.branch, %{
        "lib/game/settings.ex" => "defmodule Game.Settings do\n  defstruct sound: true\nend\n",
        "test/game/settings_test.exs" => "defmodule Game.SettingsTest do\nend\n"
      })

    changeset!(ticket, sha)

    commit_message!(
      ticket,
      "Add a sound toggle to settings\n\nPersists in the save file, defaults to on.\n"
    )

    {:ok, _version} =
      Artifacts.record_version(ticket.id, "overview", :presentation, :system, %{
        content: "# Sound toggle\n\nOne switch in settings; it is remembered between sessions.\n"
      })

    ticket
  end

  # A document approval whose document is longer than the box that holds it.
  defp document!(member) do
    project = Decision.project!("look-queue-past-docs", File.read!(@example), member)

    {:ok, ticket} =
      Tickets.admit(project, %{title: "Persist the high score table"}, {:user, member.id})

    body =
      for n <- 1..14, into: "" do
        "## Step #{n}\n\nThe table is read at the start of a round and written when it ends, " <>
          "so a crash in the middle loses at most the round in progress.\n\n"
      end

    {:ok, _version} =
      Artifacts.record_version(ticket.id, "refinement.md", :document, :system, %{
        content: "---\noutcome: done\n---\n# Refinement\n\n" <> body
      })

    ticket
    |> Ecto.Changeset.change(
      state: "refining",
      pending_transition: %{
        "from" => "refining",
        "to" => "planning",
        "outcome" => "done",
        "approve" => ["refinement.md"]
      }
    )
    |> Repo.update!()
  end

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

  defp check(ticket, worker, status, opts \\ []) do
    for job <- Jobs.commands_for_ticket(ticket.id), job.status == :pending do
      {:ok, _job} = job |> FakeWorker.assign(worker) |> FakeWorker.finish_command(status, opts)
    end

    Tickets.get!(ticket.id)
  end

  defp said!(ticket, job, text) do
    Repo.insert!(%Event{
      ticket_id: ticket.id,
      project_id: ticket.project_id,
      job_id: job.id,
      actor: %{"kind" => "job", "id" => job.id},
      type: "job.harness.text",
      payload: %{"text" => text}
    })
  end
end
