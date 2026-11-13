defmodule Forge.RejectNoteTest do
  @moduledoc """
  A reject needs a note (`docs/design/ui.md` § The decision row): `Engine.decide/4` refuses a
  rejection without one before anything is written, and the note is handed to the next job made
  on the ticket in `entered.comment`, the way a person's comment on a transition is.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Artifacts, Engine, Events, FakeWorker, Jobs, Repo, Tickets}
  alias Forge.Jobs.Job

  # The grammar example, with a way back from `planning` into `refining`: a transition into the
  # state that rejections are made at, which a person can take with a comment of its own.
  @workflow "../../../core/test/fixtures/workflow_example.yml"
            |> Path.expand(__DIR__)
            |> File.read!()
            |> String.replace(
              "    produces: [plan.md]\n",
              "    produces: [plan.md]\n    outcomes: [done, redo]\n"
            )
            |> String.replace(
              "  - { from: planning,      to: implementing }\n",
              "  - { from: planning,      to: implementing }\n" <>
                "  - { from: planning,      to: refining,      when: redo }\n"
            )

  setup do
    {:ok, project} =
      register_owned!(%{
        name: "reject-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo(%{".forge/workflow.yml" => @workflow})
      })

    user = member_fixture(project)
    funded!(project)

    data_dir = tmp_dir("data")
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :data_dir, data_dir))
    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))

    on_exit(fn ->
      Application.put_env(:forge, Forge.Jobs, original)
      Application.put_env(:forge, Forge.Storage, store)
    end)

    worker = FakeWorker.connect()
    {:ok, ticket} = Tickets.admit(project, %{title: "Scores"}, {:user, user.id})
    {:ok, _} = FakeWorker.run(pending(ticket), worker, "success", doc: "refinement.md")

    %{user: user, worker: worker, ticket: Tickets.get!(ticket.id)}
  end

  defp pending(ticket) do
    assert [%Job{status: :pending} = job] =
             Enum.filter(Jobs.for_ticket(ticket.id), &(&1.status == :pending))

    job
  end

  defp entered_comment(ticket), do: pending(ticket).spec["entered"]["comment"]

  test "a rejection without a note is refused and writes nothing", %{user: user, ticket: ticket} do
    assert ticket.pending_transition != nil
    version = Artifacts.latest(ticket.id, "refinement.md")
    events = length(Events.for_ticket(ticket.id))

    for comment <- [nil, "", "  \n"] do
      assert {:error, :note_required} = Engine.decide(ticket, user.id, :rejected, comment)
    end

    again = Tickets.get!(ticket.id)
    assert again.pending_transition == ticket.pending_transition
    assert again.status == ticket.status
    assert Artifacts.approvals(version.id) == []
    assert length(Events.for_ticket(ticket.id)) == events

    # An approval needs none.
    assert {:ok, %{state: "planning"}} = Engine.decide(ticket, user.id, :approved, nil)
  end

  test "the note reaches the job that runs the state again", %{user: user, ticket: ticket} do
    {:ok, rejected} = Engine.decide(ticket, user.id, :rejected, "Name the table.")
    assert {:ok, _} = Engine.retry(rejected, user.id)

    assert entered_comment(Tickets.get!(ticket.id)) == "Name the table."
  end

  test "a transition taken by hand after it carries the note and its own comment", %{
    user: user,
    ticket: ticket
  } do
    {:ok, rejected} = Engine.decide(ticket, user.id, :rejected, "Name the table.")
    {:ok, moved} = Engine.choose(rejected, user.id, "planning", comment: "Go on anyway.")

    assert moved.state == "planning"
    assert entered_comment(moved) == "Go on anyway.\n\nName the table."

    # The transition's event records what was written as it was taken; the note is the
    # rejection's own.
    assert %{payload: %{"comment" => "Go on anyway."}} =
             Events.latest_for_ticket(ticket.id, "transition.taken")
  end

  test "a note is for the first job after it, not a later one", %{
    user: user,
    worker: worker,
    ticket: ticket
  } do
    {:ok, rejected} = Engine.decide(ticket, user.id, :rejected, "Name the table.")
    {:ok, _} = Engine.retry(rejected, user.id)
    {:ok, _} = FakeWorker.run(pending(rejected), worker, "success", doc: "refinement.md")

    ticket = Tickets.get!(ticket.id)
    assert {:ok, %{state: "planning"} = moved} = Engine.decide(ticket, user.id, :approved, nil)
    assert entered_comment(moved) == nil
  end

  # A conversation opened by hand about the ticket is no workflow job: it is never handed the
  # note, so it must not use it up (`job-prompt.md` § How the job arrived).
  test "a chat opened about the rejected ticket leaves the note for the next job", %{
    user: user,
    ticket: ticket
  } do
    {:ok, rejected} = Engine.decide(ticket, user.id, :rejected, "Name the table.")

    {:ok, _chat} =
      Forge.Conversations.open(Forge.Projects.get!(ticket.project_id), "why was this rejected?",
        ticket: rejected,
        actor: {:user, user.id}
      )

    assert Engine.rejection_note(rejected) == "Name the table."
    assert {:ok, _} = Engine.retry(Tickets.get!(ticket.id), user.id)
    assert entered_comment(Tickets.get!(ticket.id)) == "Name the table."
  end

  # Whatever is handed the note uses it up: an agent's job, a chat step's conversation. A command
  # state's commands are handed no arrival, so they leave it for the agent after them. Logged as
  # the engine logs each, on the ticket.
  test "a chat step uses the note up, as a job does; a command state's commands do not", %{
    user: user,
    ticket: ticket
  } do
    {:ok, rejected} = Engine.decide(ticket, user.id, :rejected, "Name the table.")
    assert Engine.rejection_note(rejected) == "Name the table."

    for {type, payload, left} <- [
          {"commands.started", %{}, "Name the table."},
          {"chat.opened", %{"step" => true}, nil},
          {"job.created", %{}, nil}
        ] do
      # Each alone: the event is rolled back before the next is tried.
      Repo.transaction(fn ->
        {:ok, _} = Events.append(type, :system, %{ticket_id: ticket.id, payload: payload})
        assert Engine.rejection_note(rejected) == left, type
        Repo.rollback(:tried)
      end)
    end
  end

  # Two rejections with no work between them: the later one's note is the one handed on.
  test "of two rejections with nothing made between, the later note is handed on", %{
    ticket: ticket
  } do
    for note <- ["N1", "N2"] do
      {:ok, _} =
        Events.append("approval.rejected", :system, %{
          ticket_id: ticket.id,
          payload: %{"comment" => note}
        })
    end

    assert Engine.rejection_note(ticket) == "N2"
  end

  # Each attempt is told the rejection before it, not every rejection there has been.
  test "running again after a second rejection hands on the second note only", %{
    user: user,
    worker: worker,
    ticket: ticket
  } do
    {:ok, rejected} = Engine.decide(ticket, user.id, :rejected, "N1")
    {:ok, _} = Engine.retry(rejected, user.id)
    assert entered_comment(Tickets.get!(ticket.id)) == "N1"
    {:ok, _} = FakeWorker.run(pending(rejected), worker, "success", doc: "refinement.md")

    {:ok, rejected} = Engine.decide(Tickets.get!(ticket.id), user.id, :rejected, "N2")
    {:ok, _} = Engine.retry(rejected, user.id)

    assert %{"comment" => "N2", "from" => "refining", "by" => "person"} =
             pending(rejected).spec["entered"]
  end

  # A transition's own comment is the arrival's, and stays; only the older note goes.
  test "a second rejection replaces the first note and keeps the transition's comment", %{
    user: user,
    worker: worker,
    ticket: ticket
  } do
    ticket = back_into_refining(ticket, user, worker, "Redo it.")
    assert entered_comment(ticket) == "Redo it."
    {:ok, _} = FakeWorker.run(pending(ticket), worker, "success", doc: "refinement.md")

    {:ok, rejected} = Engine.decide(Tickets.get!(ticket.id), user.id, :rejected, "N1")
    {:ok, _} = Engine.retry(rejected, user.id)
    assert entered_comment(Tickets.get!(ticket.id)) == "Redo it.\n\nN1"
    {:ok, _} = FakeWorker.run(pending(rejected), worker, "success", doc: "refinement.md")

    {:ok, rejected} = Engine.decide(Tickets.get!(ticket.id), user.id, :rejected, "N2")
    {:ok, _} = Engine.retry(rejected, user.id)

    assert %{"comment" => "Redo it.\n\nN2", "from" => "planning"} =
             pending(rejected).spec["entered"]
  end

  # Approved on to `planning`, whose job fails; a person takes the ticket back with `comment`.
  defp back_into_refining(ticket, user, worker, comment) do
    {:ok, planning} = Engine.decide(ticket, user.id, :approved, nil)
    {:ok, _} = FakeWorker.run(pending(planning), worker, "nothing")

    {:ok, back} =
      Engine.choose(Tickets.get!(ticket.id), user.id, "refining", comment: comment)

    assert back.state == "refining"
    back
  end

  # The reviewer's sequence (round 2): an attempt that failed between two rejections copied the
  # first note on, and the job after the second rejection was told both.
  test "a failed attempt between two rejections does not carry the first note past the second",
       %{user: user, worker: worker, ticket: ticket} do
    {:ok, rejected} = Engine.decide(ticket, user.id, :rejected, "N1")
    {:ok, _} = Engine.retry(rejected, user.id)
    {:ok, _} = FakeWorker.run(pending(rejected), worker, "nothing")
    {:ok, _} = Engine.retry(Tickets.get!(ticket.id), user.id)
    assert entered_comment(Tickets.get!(ticket.id)) == "N1"
    {:ok, _} = FakeWorker.run(pending(rejected), worker, "success", doc: "refinement.md")

    {:ok, rejected} = Engine.decide(Tickets.get!(ticket.id), user.id, :rejected, "N2")
    {:ok, _} = Engine.retry(rejected, user.id)

    assert %{"comment" => "N2", "from" => "refining", "by" => "person"} =
             pending(rejected).spec["entered"]
  end

  # The same with a transition's comment in the arrival, which is kept through it all.
  test "a failed attempt between two rejections keeps the transition's comment", %{
    user: user,
    worker: worker,
    ticket: ticket
  } do
    ticket = back_into_refining(ticket, user, worker, "Redo it.")
    {:ok, _} = FakeWorker.run(pending(ticket), worker, "success", doc: "refinement.md")

    {:ok, rejected} = Engine.decide(Tickets.get!(ticket.id), user.id, :rejected, "N1")
    {:ok, _} = Engine.retry(rejected, user.id)
    {:ok, _} = FakeWorker.run(pending(rejected), worker, "nothing")
    {:ok, _} = Engine.retry(Tickets.get!(ticket.id), user.id)
    {:ok, _} = FakeWorker.run(pending(rejected), worker, "success", doc: "refinement.md")

    {:ok, rejected} = Engine.decide(Tickets.get!(ticket.id), user.id, :rejected, "N2")
    {:ok, _} = Engine.retry(rejected, user.id)

    assert entered_comment(rejected) == "Redo it.\n\nN2"
  end

  # A job that failed has not acted on the note it was handed; the attempt after it is told the
  # same.
  test "an attempt run again with no new rejection is told what the last one was", %{
    user: user,
    worker: worker,
    ticket: ticket
  } do
    {:ok, rejected} = Engine.decide(ticket, user.id, :rejected, "N1")
    {:ok, _} = Engine.retry(rejected, user.id)
    {:ok, _} = FakeWorker.run(pending(rejected), worker, "nothing")
    {:ok, _} = Engine.retry(Tickets.get!(ticket.id), user.id)

    assert entered_comment(Tickets.get!(ticket.id)) == "N1"
  end

  @through_commands """
  version: 1
  initial: refining
  commands:
    build:
      run: .forge/commands/build.sh
      timeout: 5m
  states:
    refining:
      prompt: agents/refine.md
      inputs: [ticket]
      produces: [refinement.md]
      budget: { turns: 20, tokens: 100k }
    checking:
      invoke: [build]
      exit: { 0: done, "*": checks_failed }
    planning:
      prompt: agents/plan.md
      inputs: [ticket]
      produces: [plan.md]
      budget: { turns: 40, tokens: 400k }
    review_ready: {}
  transitions:
    - { from: refining, to: checking, approve: [refinement.md] }
    - { from: checking, to: planning }
    - { from: checking, to: refining, when: checks_failed }
    - { from: planning, to: review_ready }
  limits:
    ticket_tokens: 5M
  """

  # A command state's commands have no arrival to be told it in, so the note goes on to the agent
  # after them (`job-prompt.md` § How the job arrived). It was used up by the batch and reached no
  # job at all.
  test "a note made before a command state reaches the agent job after it", %{worker: worker} do
    {:ok, project} =
      register_owned!(%{
        name: "reject-cmd-#{System.unique_integer([:positive])}",
        repo_path:
          seeded_repo(%{
            ".forge/workflow.yml" => @through_commands,
            ".forge/commands/build.sh" => "#!/bin/sh\nexec make\n"
          })
      })

    user = member_fixture(project)
    funded!(project)
    {:ok, ticket} = Tickets.admit(project, %{title: "Cache"}, {:user, user.id})
    {:ok, _} = FakeWorker.run(pending(ticket), worker, "success", doc: "refinement.md")

    {:ok, rejected} = Engine.decide(Tickets.get!(ticket.id), user.id, :rejected, "Use the cache.")
    {:ok, checking} = Engine.choose(rejected, user.id, "checking")
    assert checking.state == "checking"

    [build] = Enum.filter(Jobs.commands_for_ticket(ticket.id), &(&1.status == :pending))
    {:ok, _} = build |> FakeWorker.assign(worker) |> FakeWorker.finish_command(0)

    planning = Tickets.get!(ticket.id)
    assert planning.state == "planning"

    assert %{"from" => "checking", "comment" => "Use the cache."} =
             pending(planning).spec["entered"]
  end

  # A decision made on the versions a person was shown decides those (`Engine.decide/5`): a
  # version written between the page's check and the operation refuses it, whichever way it went.
  test "a decision on versions no longer the latest is refused and writes nothing", %{
    user: user,
    ticket: ticket
  } do
    {:ok, _v2} =
      Artifacts.record_version(ticket.id, "refinement.md", :document, :system, %{
        content: "# Refinement, again\n",
        parse: false
      })

    events = length(Events.for_ticket(ticket.id))

    for decision <- [:approved, :rejected] do
      assert {:error, {:stale, ["refinement.md"]}} =
               Engine.decide(ticket, user.id, decision, "No.", %{"refinement.md" => 1})
    end

    assert {:error, {:stale, ["plan.md"]}} =
             Engine.decide(ticket, user.id, :approved, nil, %{
               "refinement.md" => 2,
               "plan.md" => 1
             })

    assert Tickets.get!(ticket.id).pending_transition == ticket.pending_transition
    assert length(Events.for_ticket(ticket.id)) == events

    assert {:ok, %{state: "planning"}} =
             Engine.decide(ticket, user.id, :approved, nil, %{"refinement.md" => 2})

    assert [%{decision: :approved}] =
             Artifacts.approvals(Artifacts.latest(ticket.id, "refinement.md").id)
  end

  test "mix forge.approve refuses a rejection without --comment before reading anything" do
    for args <- [["nowhere#1", "--reject"], ["nowhere#1", "--reject", "--comment", "  "]] do
      assert_raise Mix.Error, ~r/needs --comment/, fn -> Mix.Tasks.Forge.Approve.run(args) end
    end
  end

  test "Activity reads the rejection with its note", %{user: user, ticket: ticket} do
    {:ok, _} = Engine.decide(ticket, user.id, :rejected, "Name the table.")
    event = Events.latest_for_ticket(ticket.id, "approval.rejected")

    assert Events.summary(event) == "rejected refining → planning: Name the table."
  end
end
