defmodule Forge.ConversationsTest do
  @moduledoc """
  Opening a conversation, talking to it, and recording what it spends while it runs.

  The two that matter most are the cost — which the harness reports cumulatively and which adding
  would silently multiply — and the projection, which is the whole conversation and has no table
  behind it to check against.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures

  import Forge.GitFixtures

  alias Forge.{Conversations, Events, Git, Jobs, Projects, Spend, Tickets}

  setup do
    {:ok, project} =
      register_owned!(%{
        name: "chat-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo()
      })

    %{project: project}
  end

  describe "opening one" do
    test "a project chat gets a branch off the default branch", %{project: project} do
      assert {:ok, chat} = Conversations.open(project, "what is this repository?")

      assert chat.kind == :chat
      assert chat.status == :pending
      assert is_nil(chat.ticket_id)
      assert Git.branch_exists?(Projects.repo_path(project), "chat/" <> chat.id)
    end

    test "a ticket chat starts from the ticket's branch", %{project: project} do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)

      assert {:ok, chat} = Conversations.open(project, "why did it fail?", ticket: ticket)

      assert chat.ticket_id == ticket.id
      repo = Projects.repo_path(project)

      assert Git.resolve(repo, "refs/heads/chat/" <> chat.id) ==
               Git.resolve(repo, "refs/heads/" <> ticket.branch)
    end

    # The opening message is the first turn's prompt, and it is in the log rather than on the
    # row — the log is the conversation, and a copy on the row would be a second one.
    test "the opening message is the first thing in the conversation", %{project: project} do
      {:ok, chat} = Conversations.open(project, "hello there")

      assert [%{role: :user, text: "hello there"}] = Conversations.messages(chat.id)
    end

    # A project nobody has pushed to has an unborn default branch, so forking a chat branch from
    # it failed with `not a valid object name: 'refs/heads/main'` — and no push could have fixed
    # it, because `pre-receive` lets only the platform's own merge write the default branch.
    # Registering a project now puts an empty commit there, which is what everything starts from.
    test "a chat can be started on a project nobody has pushed to" do
      {:ok, empty} =
        register_owned!(%{
          name: "empty-#{System.unique_integer([:positive])}",
          repo_path: Path.join(Forge.GitFixtures.tmp_dir("bare"), "empty.git")
        })

      assert {:ok, chat} = Conversations.open(empty, "what is this repository?")
      assert Git.branch_exists?(Projects.repo_path(empty), "chat/" <> chat.id)
    end

    test "it is queued, so a worker will pick it up", %{project: project} do
      {:ok, chat} = Conversations.open(project, "hello")

      assert chat.id in (Jobs.pending(10) |> Enum.map(& &1.id))
    end
  end

  describe "recording a turn" do
    setup %{project: project} do
      {:ok, chat} = Conversations.open(project, "hello")
      %{chat: chat}
    end

    # A conversation never calls `Jobs.complete/2` — it has no outcome and no result — so if a
    # turn did not carry its proposals, nothing would ever record one and the chat preamble
    # would be promising something that does not happen.
    test "a conversation's proposals are recorded, turn by turn", %{chat: chat, project: project} do
      one = %{
        "score-table.md" => %{
          "title" => "Extract the score table",
          "body" => "Why.",
          "raw" => "# Extract the score table\n\nWhy."
        }
      }

      {:ok, chat} = Conversations.record_turn(chat, turn_with_proposals(1, one))

      assert [%{version: version}] = Forge.Proposals.open(project.id)
      assert version.content =~ "Extract the score table"

      # `out/proposals/` accumulates, so the same file is reported again next turn. It must not
      # become a second version, or deciding it once would not be deciding it.
      {:ok, _chat} = Conversations.record_turn(chat, turn_with_proposals(2, one))

      assert [%{version: %{id: still}}] = Forge.Proposals.open(project.id)
      assert still == version.id
    end

    test "a proposal the platform could not read is recorded as unreadable, not dropped", %{
      chat: chat
    } do
      {:ok, chat} =
        Conversations.record_turn(
          chat,
          turn_with_proposals(1, %{}, %{
            "half.md" => %{"reason" => "no heading", "raw" => "prose\n"}
          })
        )

      assert [event] =
               chat.id |> Events.for_job() |> Enum.filter(&(&1.type == "proposal.unreadable"))

      assert event.payload["reasons"]["half.md"] == "no heading"
    end

    # The harness reports total_cost_usd cumulatively across the session and num_turns per turn —
    # measured by `bin/measure streaming`. Adding the cost, as a job's is added, would count turn
    # one's in every later turn: by turn five the conversation reports several times what it
    # spent, and the daily cap trips early on money nobody spent. The figures stay plausible and
    # monotonic the whole way, which is exactly why this is pinned.
    test "cost is set from the cumulative figure, and turns accumulate", %{chat: chat} do
      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.01))
      assert Decimal.equal?(chat.cost_usd, Decimal.from_float(0.01))
      assert chat.turns == 1

      {:ok, chat} = Conversations.record_turn(chat, turn(2, 0.02))
      assert Decimal.equal?(chat.cost_usd, Decimal.from_float(0.02))
      assert chat.turns == 2

      {:ok, chat} = Conversations.record_turn(chat, turn(3, 0.03))
      assert Decimal.equal?(chat.cost_usd, Decimal.from_float(0.03))
      assert chat.turns == 3
    end

    # Recorded per turn rather than at the end, because a conversation does not have an end until
    # a person says so — and a cap that cannot see a chat running all afternoon is not a cap.
    test "what a live conversation has spent is in the day's total", %{chat: chat} do
      {:ok, chat} =
        chat
        |> Jobs.Job.progress_changeset(%{status: :running, started_at: DateTime.utc_now(:second)})
        |> Repo.update()

      before = Spend.day_total()
      {:ok, _chat} = Conversations.record_turn(chat, turn(1, 0.25))

      assert Decimal.compare(Spend.day_total(), before) == :gt
    end

    # The worker re-sends a turn until it is acked, so the same one can arrive twice.
    test "the same turn twice is recorded once", %{chat: chat} do
      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.01))
      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.01))

      assert chat.turns == 1
      turns = chat.id |> Events.for_job() |> Enum.count(&(&1.type == "chat.turn"))
      assert turns == 1
    end
  end

  describe "reaching the worker" do
    # A conversation is opened before it has a worker and spoken to afterwards, so a caller that
    # kept the row it opened holds `worker_id: nil` for the rest of the conversation. Reading the
    # worker off that struct means every message after the first goes nowhere — and it looks
    # exactly like a chat that stopped replying. The end-to-end run is what found this; no unit
    # test could, because none of them had a worker.
    test "a message is sent to the worker the row has now, not the one the caller remembers", %{
      project: project
    } do
      {:ok, opened} = Conversations.open(project, "hello")
      {:ok, worker, _token} = Forge.Workers.create(%{provider: "fake"})
      {:ok, worker} = Forge.Workers.ready(worker, 8_000_000_000)
      # The test process stands in for the channel: `Workers.push/2` sends to whatever is
      # registered for that worker.
      :ok = Forge.Workers.connected(worker.id)

      {:ok, _running} =
        opened
        |> Jobs.Job.progress_changeset(%{status: :running, worker_id: worker.id})
        |> Repo.update()

      # The stale struct: exactly what a page or a Mix task is holding.
      assert opened.worker_id == nil

      {:ok, _event} = Conversations.send(opened, "are you there?")

      assert_receive {"message", %{"text" => "are you there?", "job_id" => job_id}}
      assert job_id == opened.id
    end
  end

  describe "history" do
    # The transcript is fetched by the worker, not inlined: they run past a hundred kilobytes
    # each and a ticket has several, so inlining would put a megabyte through the channel and
    # into the prompt on every turn. What crosses is a key and a token, as the seed does.
    test "one entry per job that already ran, with its transcript by reference", %{
      project: project
    } do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
      [job] = Jobs.for_ticket(ticket.id)

      {:ok, _version} =
        Forge.Artifacts.record_version(
          ticket.id,
          "transcript-#{job.state}-1.jsonl",
          :blob,
          {:job, job.id},
          %{blob_uri: "store:job/#{job.id}/transcript-1.jsonl"}
        )

      assert [entry] = Conversations.history(ticket)

      # Nested, so a state retried three times reads as three attempts of one thing.
      assert entry["dir"] == "#{job.state}/#{job.attempt}"
      assert entry["metadata"] =~ job.state
      assert entry["metadata"] =~ job.id
      assert entry["transcript"]["key"] == "job/#{job.id}/transcript-1.jsonl"
      assert is_binary(entry["transcript"]["token"])

      # The bytes are not here, and that is the point.
      refute entry["metadata"] =~ "\"type\":"
    end

    test "a job that never uploaded a transcript still gets its metadata", %{project: project} do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)

      assert [entry] = Conversations.history(ticket)
      assert entry["transcript"] == nil
      assert entry["metadata"] =~ "Not kept."
    end

    test "conversations are not history; only the workflow is", %{project: project} do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
      {:ok, _chat} = Conversations.open(project, "about this", ticket: ticket)

      assert length(Conversations.history(ticket)) == 1
    end

    test "a project chat has no ticket and so no history" do
      assert Conversations.history(nil) == []
    end
  end

  describe "the projection" do
    setup %{project: project} do
      {:ok, chat} = Conversations.open(project, "first")
      %{chat: chat}
    end

    # The text of one reply arrives as several events and is one message to a person: a reply,
    # not the four pieces it was streamed in.
    test "a turn's text is one assistant message", %{chat: chat} do
      text(chat, "Thinking about ")
      text(chat, "your question. ")
      text(chat, "Here is the answer.")
      {:ok, _} = Conversations.record_turn(chat, turn(1, 0.01))

      assert [%{role: :user}, %{role: :assistant} = reply] = Conversations.messages(chat.id)
      assert reply.text == "Thinking about your question. Here is the answer."
      assert reply.turn == 1
    end

    # Both states, in order. A test asserting only the final state passes while queueing is
    # broken, and `docs/poc-plan.md` § Definition of usable names this as a criterion.
    test "a message is queued, then delivered", %{chat: chat} do
      {:ok, event} = Conversations.send(chat, "second")

      assert [_first, %{role: :user, text: "second", delivered: false}] =
               Conversations.messages(chat.id)

      delivered(chat, to_string(event.seq))

      assert [_first, %{role: :user, text: "second", delivered: true}] =
               Conversations.messages(chat.id)
    end

    test "a delivery for one message does not mark another", %{chat: chat} do
      {:ok, second} = Conversations.send(chat, "second")
      {:ok, _third} = Conversations.send(chat, "third")

      delivered(chat, to_string(second.seq))

      assert [_first, %{text: "second", delivered: true}, %{text: "third", delivered: false}] =
               Conversations.messages(chat.id)
    end

    test "tool calls and the rest of the stream stay out of the conversation", %{chat: chat} do
      :ok =
        Jobs.record_harness_event(chat.id, %{
          type: "job.harness.tool_use",
          payload: %{name: "Read"}
        })

      text(chat, "done")
      {:ok, _} = Conversations.record_turn(chat, turn(1, 0.01))

      assert [%{role: :user}, %{role: :assistant, text: "done"}] = Conversations.messages(chat.id)
    end
  end

  describe "summaries" do
    # `waiting` is what paints a row with the accent, and `docs/design/ui.md` is explicit that the
    # accent means exactly one thing: a human is being waited on. A live conversation whose last
    # line is the person's own is waiting on the *machine*, not on them — dropping the
    # `match?({:agent, _}, last)` half of the test leaves every live conversation accented, and
    # the product's one colour stops meaning anything.
    test "waiting is the agent having spoken last, not merely being live", %{project: project} do
      {:ok, chat} = Conversations.open(project, "what is this repository?")

      assert [summary] = Conversations.summaries(project_id: project.id)
      assert summary.live
      assert summary.said == {:user, "what is this repository?"}
      refute summary.waiting

      text(chat, "It is a workflow engine.")

      assert [summary] = Conversations.summaries(project_id: project.id)
      assert summary.said == {:agent, "It is a workflow engine."}
      assert summary.waiting
    end

    # And the other half of the `and`: a conversation that has stopped cannot be waiting on
    # anyone, however it ended, because there is nothing left to say anything to.
    test "a finished conversation is not waiting even if the agent spoke last", %{
      project: project
    } do
      {:ok, chat} = Conversations.open(project, "hello")
      text(chat, "goodbye")
      {:ok, _closed} = Conversations.ended(chat, nil, "closed")

      assert [summary] = Conversations.summaries(project_id: project.id)
      assert summary.said == {:agent, "goodbye"}
      refute summary.live
      refute summary.waiting
    end

    # The second half of "live ones first and newest within that". A list that only grows is only
    # usable if the thing you were just doing is at the top of it, so the order is the feature
    # rather than a presentation detail, and nothing rendered it before this.
    test "conversations of the same liveness come newest first", %{project: project} do
      {:ok, first_opened} = Conversations.open(project, "the older one")
      {:ok, second_opened} = Conversations.open(project, "the newer one")

      Repo.update_all(from(j in Jobs.Job, where: j.id == ^first_opened.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -3600, :second)]
      )

      assert [newer, older] = Conversations.summaries(project_id: project.id)
      assert newer.chat.id == second_opened.id
      assert older.chat.id == first_opened.id
    end

    # The first half, and the half that was wrong. `summaries/1` promises "live ones first and
    # newest within that" and `ForgeWeb.ChatsLive` repeats it — "Live first is what keeps it
    # useful: that is the one costing something and holding a machine". The sort key was `not
    # live` under a descending sorter, so `true` — a *finished* chat — came first.
    #
    # It hid because the two keys usually agree: the live conversation is normally also the
    # newest, so the second key put it on top regardless. They disagree exactly when you come
    # back to a machine you left running, which is the case the page exists for.
    test "a live conversation sorts above a newer finished one", %{project: project} do
      {:ok, older_live} = Conversations.open(project, "older, still running")
      {:ok, newer} = Conversations.open(project, "newer, already closed")
      {:ok, _closed} = Conversations.ended(newer, nil, "closed")

      Repo.update_all(from(j in Jobs.Job, where: j.id == ^older_live.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -3600, :second)]
      )

      assert [first, second] = Conversations.summaries(project_id: project.id)
      assert first.chat.id == older_live.id
      assert second.chat.id == newer.id
    end
  end

  describe "ending" do
    setup %{project: project} do
      {:ok, chat} = Conversations.open(project, "hello")
      %{chat: chat}
    end

    test "closing it finishes it; losing the machine only makes it dormant", %{chat: chat} do
      {:ok, closed} = Conversations.ended(chat, nil, "closed")
      assert closed.status == :finished

      {:ok, other} = Conversations.open(Projects.get!(chat.project_id), "another")
      {:ok, dormant} = Conversations.ended(other, nil, "worker_lost")
      assert dormant.status == :hibernated
    end

    # A workflow job's completion revokes its credential and gives the worker's memory back. A
    # conversation's ending has to do the same, or the machine stays busy for ever and takes no
    # more work — which is invisible until the next thing that never gets scheduled. The
    # end-to-end run is what caught this; the earlier run passed it by luck, because a ticket's
    # job happened to release the same worker.
    test "ending it gives the machine back and revokes its credential", %{chat: chat} do
      {:ok, worker, _token} = Forge.Workers.create(%{provider: "fake"})
      {:ok, worker} = Forge.Workers.ready(worker, 8_000_000_000)
      {:ok, worker} = Forge.Workers.busy(worker)

      {:ok, running} =
        chat
        |> Jobs.Job.progress_changeset(%{status: :running, worker_id: worker.id})
        |> Repo.update()

      {:ok, _ended} = Conversations.ended(running, nil, "closed")

      assert Forge.Workers.get!(worker.id).status == :idle
    end

    # The machine is gone, so there is nothing for the message to reach. Recording it anyway put
    # a message in the transcript that was never delivered and never would be — a real chat on
    # the dev node lost a tapped answer exactly this way, and the page said nothing.
    test "a conversation that has stopped refuses a message rather than losing it", %{chat: chat} do
      {:ok, dormant} = Conversations.ended(chat, nil, "worker_lost")
      before = length(Conversations.messages(dormant.id))

      assert {:error, :not_live} = Conversations.send(dormant, "leave-to-ticket")

      # Refused *and* not written: a rejected send that still appeared in the transcript would
      # be the same silent drop wearing an error message.
      assert length(Conversations.messages(dormant.id)) == before
    end

    # The caller holds whatever the page rendered with, which may be minutes old. Trusting that
    # struct is how the guard and the operation end up disagreeing.
    test "a stale struct saying running does not get through", %{chat: chat} do
      {:ok, _dormant} = Conversations.ended(chat, nil, "worker_lost")

      assert chat.status == :pending
      assert {:error, :not_live} = Conversations.send(chat, "still here?")
    end

    test "reopening takes messages again", %{chat: chat} do
      {:ok, dormant} = Conversations.ended(chat, nil, "worker_lost")
      assert {:error, :not_live} = Conversations.send(dormant, "hello?")

      {:ok, reopened} = Conversations.reopen(dormant)

      assert {:ok, _event} = Conversations.send(reopened, "hello?")
    end

    test "a dormant conversation can be reopened, cold", %{chat: chat} do
      {:ok, chat} = Conversations.ended(chat, nil, "worker_lost")
      {:ok, chat} = Conversations.reopen(chat)

      assert chat.status == :pending
      # The session is gone with the machine: `--resume` cannot find one whose worktree no
      # longer exists, so the next run replays the transcript instead.
      assert is_nil(chat.harness_session_id)
      assert is_nil(chat.worker_id)
      assert chat.id in (Jobs.pending(10) |> Enum.map(& &1.id))
    end

    test "its messages survive it", %{chat: chat} do
      text(chat, "a reply")
      {:ok, _} = Conversations.record_turn(chat, turn(1, 0.01))
      {:ok, chat} = Conversations.ended(chat, nil, "closed")

      assert length(Conversations.messages(chat.id)) == 2
    end
  end

  defp turn_with_proposals(index, proposals, invalid \\ %{}) do
    index
    |> turn(0.01)
    |> Map.merge(%{"proposals" => proposals, "invalid_proposals" => invalid})
  end

  defp turn(index, cost) do
    %{
      "turn" => index,
      "commit" => String.duplicate("a", 40),
      "harness" => %{
        "turns" => 1,
        "cost_usd" => cost,
        "session_id" => "sess-1",
        "subtype" => "success"
      }
    }
  end

  defp text(chat, text),
    do:
      :ok =
        Jobs.record_harness_event(chat.id, %{type: "job.harness.text", payload: %{text: text}})

  defp delivered(chat, message_id) do
    :ok =
      Jobs.record_harness_event(chat.id, %{
        type: "job.harness.delivered",
        payload: %{text: "…", message_id: message_id}
      })
  end
end
