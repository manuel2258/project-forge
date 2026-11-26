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
  alias Forge.Git.{Tokens, Url}

  setup do
    {:ok, project} =
      register_owned!(%{
        name: "chat-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo()
      })

    %{project: project}
  end

  # **Who ended it, and who brought it back.** Both events recorded `:system` while the caller
  # that authorised the person was holding them — the same shape `project.model_set` had, and the
  # same module already showed the fix in `chat.opened`. A member can end another member's
  # conversation, so a log that cannot say whose hand it was cannot answer the one question
  # anybody would ask of it.
  describe "attribution" do
    # A plain member, not an admin: closing and reopening need `:use`, which is what the finding
    # this describe exists for is about — one member ending another's conversation. The setup used
    # to take `join!/3`'s `:admin` default and so proved less than the comment claimed.
    setup %{project: project} do
      person = Forge.AccountsFixtures.user_fixture()
      join!(project, person, :member)

      %{person: person}
    end

    test "ending one by hand names the person who did it", context do
      %{project: project, person: person} = context
      chat = chat_fixture(%{project: project})

      assert :ok = Forge.Operator.close_chat(chat, person)

      events = Events.for_job(chat.id)

      assert [ended] = Enum.filter(events, &(&1.type == "chat.ended"))
      assert ended.actor == %{"kind" => "user", "id" => person.id}

      # One event on this path, which is what the note claims: asking and ending are the same
      # step when there is no machine to tell. Appending the request here too would pass every
      # other assertion and make that false.
      assert Enum.filter(events, &(&1.type == "chat.close_requested")) == []
    end

    # Sending is how a conversation with no machine is started again, and it is logged as a reopen
    # by the sender, so who restarted it — and spent from its credential pool — can be found.
    test "starting one again by sending names the person who sent", context do
      %{project: project, person: person} = context
      chat = chat_fixture(%{project: project})
      {:ok, _ended} = Conversations.ended(chat, nil, "idle")

      assert {:ok, _event} = Forge.Operator.send_chat(chat, person, "carry on")

      assert [reopened] = Enum.filter(Events.for_job(chat.id), &(&1.type == "chat.reopened"))
      assert reopened.actor == %{"kind" => "user", "id" => person.id}
    end

    # **The common case, and the one the last round missed.** `mark_started/3` sets `:running` and
    # a `worker_id` in one changeset, so every conversation anybody is actually talking to has a
    # machine — and on that path the platform cannot write `chat.ended` at all: it asks the
    # worker, which reports later, and that report is the machine's act. The person's act is the
    # asking, and `chat.close_requested` is where the log keeps it. The earlier test used a
    # `:pending` fixture and so only ever exercised the branch with no machine.
    test "asking a running conversation to end names the person who asked", context do
      %{project: project, person: person} = context
      {:ok, worker, _token} = Forge.Workers.create(%{provider: "fake"})
      chat = chat_fixture(%{project: project, status: :running, worker_id: worker.id})

      assert :ok = Forge.Operator.close_chat(chat, person)

      events = Events.for_job(chat.id)

      assert [requested] = Enum.filter(events, &(&1.type == "chat.close_requested"))
      assert requested.actor == %{"kind" => "user", "id" => person.id}
      assert requested.payload == %{"reason" => "closed"}

      # And the ending itself is still the worker's to report: nothing here pretends it happened.
      assert Enum.filter(events, &(&1.type == "chat.ended")) == []
    end

    # The default is not a shortcut: a worker reporting that its conversation stopped, and the
    # platform ending one whose machine is gone, are the platform's own acts and say so.
    test "a machine's own report is still the system's", %{project: project} do
      chat = chat_fixture(%{project: project})

      {:ok, _ended} = Conversations.ended(chat, nil, "machine_lost")

      assert [ended] = Enum.filter(Events.for_job(chat.id), &(&1.type == "chat.ended"))
      assert ended.actor == %{"kind" => "system", "id" => nil}
    end

    # **Answering a question is the other half, and it was threaded without being shown.** The
    # one existing test that reaches `answer_chat/4` stops at its `{:error, :stale}` return and
    # never gets to the send, so reverting that line failed nothing: round four of this ticket's
    # review ran 284 tests across six files against the revert and got none.
    test "an answer to a question names whoever answered it", context do
      %{project: project, person: person} = context
      {:ok, chat} = Conversations.open(project, "which?")
      chat_started!(chat)

      text(chat, "```question\nkey: rows\ntext: How many rows?\n```\n")
      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.01))
      reply = chat.id |> Conversations.messages() |> Conversations.reply_ref()

      assert {:ok, _sent} =
               Forge.Operator.answer_chat(chat, person, reply, %{"rows" => %{text: "ten"}})

      answered =
        Events.for_job(chat.id) |> Enum.filter(&(&1.type == "chat.message")) |> List.last()

      assert answered.actor == %{"kind" => "user", "id" => person.id}
      assert answered.payload["text"] =~ "ten"
    end

    # Every message after the first recorded `:system` while `Operator` held the person who typed
    # it. No page changes — `fold/2` hard-codes `role: :user` whatever the actor — but the JSON
    # API's event endpoints emit it, and it is the only thing that lets the log say which of two
    # members said what.
    test "a message names whoever typed it", context do
      %{project: project, person: person} = context
      chat = chat_fixture(%{project: project})

      {:ok, _sent} = Forge.Operator.send_chat(chat, person, "and another thing")

      # One, not two: `chat_fixture/1` inserts the row rather than going through `open/3`, so
      # there is no opening message here — this is the second-message path, which is the one
      # that recorded `:system`.
      assert [typed] = Events.for_job(chat.id) |> Enum.filter(&(&1.type == "chat.message"))

      assert typed.actor == %{"kind" => "user", "id" => person.id}
      assert typed.payload == %{"text" => "and another thing"}
    end
  end

  describe "opening one" do
    test "a project chat gets a branch off the default branch", %{project: project} do
      assert {:ok, chat} = Conversations.open(project, "what is this repository?")

      assert chat.kind == :chat
      assert chat.status == :pending
      assert is_nil(chat.ticket_id)
      assert Git.branch_exists?(Projects.repo_path(project), "chat/" <> chat.id)
    end

    # A chat has no workflow state and so no `resources` to resolve, and for a while that meant
    # it was admitted with `slice_bytes/0` — M3's *cold build* peak — to run an agent that
    # talks. 2210 MiB put a 2 GiB machine out of reach of a conversation for no reason anybody
    # had decided (`docs/design/provisioning.md` § What a job asks for).
    test "a chat reserves an agent's memory and not a build's", %{project: project} do
      assert {:ok, chat} = Conversations.open(project, "what is this repository?")

      assert chat.memory_max == Forge.Workers.chat_slice_bytes()
      assert chat.memory_max < Forge.Workers.slice_bytes()
      # Cores stay whole, because the gate counts whole ones and `CPUWeight` — a share, not a
      # quota — is what the unit actually runs at.
      assert chat.cores == Forge.Workers.default_cores()
    end

    # And it is the node's to set, so an operator whose chats do more than talk can raise it
    # without touching what a workflow job gets.
    test "the chat's memory is what the node configures", %{project: project} do
      previous = Application.get_env(:forge, Forge.Workers, [])
      on_exit(fn -> Application.put_env(:forge, Forge.Workers, previous) end)

      Application.put_env(
        :forge,
        Forge.Workers,
        Keyword.put(previous, :chat_slice_bytes, 700 * 1024 * 1024)
      )

      assert {:ok, chat} = Conversations.open(project, "what is this repository?")
      assert chat.memory_max == 700 * 1024 * 1024
    end

    # What the person said is used, and what is not a figure is refused rather than replaced:
    # a conversation opened on the default because a zero was passed is one nobody asked for
    # (`docs/design/conversations.md` § What it asks for).
    test "a figure is used as given, and one that is not a figure is refused", %{
      project: project
    } do
      assert {:ok, chat} = Conversations.open(project, "hi", memory: 3_000_000_000, cores: 3)
      assert {chat.memory_max, chat.cores} == {3_000_000_000, 3}

      before = Repo.aggregate(Jobs.Job, :count)

      for {key, value} <- [memory: 0, memory: -1, memory: "2 gigs", cores: 0, cores: 1.5] do
        assert Conversations.open(project, "hi", [{key, value}]) == {:error, {:invalid, key}}
      end

      assert Repo.aggregate(Jobs.Job, :count) == before
    end

    # **The ceiling of 2026-09-29**, two bytes, reached the machine through the form and would
    # through any caller that bypasses it. Refused by name, not as "not a figure" — it is one —
    # and on both sides of the minimum.
    test "a memory below the minimum is refused, and the minimum itself is not", %{
      project: project
    } do
      before = Repo.aggregate(Jobs.Job, :count)

      for bytes <- [2, 536_870_911] do
        assert Conversations.open(project, "hi", memory: bytes) ==
                 {:error, {:too_little_memory, bytes}}
      end

      assert Repo.aggregate(Jobs.Job, :count) == before

      assert {:ok, chat} = Conversations.open(project, "hi", memory: 536_870_912)
      assert chat.memory_max == 536_870_912
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
    # Started, as a conversation is by the time a turn arrives: `Forge.Jobs.assign/2` opened the
    # run its turns are costed on.
    setup %{project: project} do
      {:ok, chat} = Conversations.open(project, "hello")
      run!(chat)
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

    # A turn's memory is kept on its `chat.turn` and nowhere else
    # (`docs/design/claude-code-events.md` § Memory): it is what the strip reads when no event
    # saw the kill.
    test "the memory a turn ended with is kept on the turn", %{chat: chat} do
      memory = %{"ceiling" => 2_147_483_648, "peak" => 2_147_483_648, "oom_kills" => 1}

      {:ok, _chat} =
        Conversations.record_turn(chat, put_in(turn(1, 0.01), ["harness", "memory"], memory))

      assert %{payload: %{"memory" => ^memory}} = Events.latest_for_job(chat.id, "chat.turn")
    end

    # The turn carries the process's own `cost_usd` beside the session's total (`session_cost_usd`,
    # which a reopen's process starts from). What is charged — the run, and the job that reads its
    # runs — is the first; charging the second is this ticket's bug.
    test "is charged what the process spent, not its session's total", %{chat: chat} do
      {:ok, _chat} =
        Conversations.record_turn(
          chat,
          put_in(turn(1, 0.01), ["harness", "session_cost_usd"], 0.51)
        )

      assert Forge.Jobs.Runs.total(chat.id) == 2_000
      assert Forge.Jobs.get!(chat.id).usage == 2_000
    end

    # The harness reports total_cost_usd cumulatively across the session and num_turns per turn —
    # measured by `bin/measure streaming`. Adding the cost, as a job's is added, would count turn
    # one's in every later turn: by turn five the conversation reports several times what it
    # spent, and the daily cap trips early on money nobody spent. The figures stay plausible and
    # monotonic the whole way, which is exactly why this is pinned.
    test "usage is set from the cumulative figure, and turns accumulate", %{chat: chat} do
      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.01))
      assert chat.usage == 2_000
      assert chat.turns == 1

      {:ok, chat} = Conversations.record_turn(chat, turn(2, 0.02))
      assert chat.usage == 4_000
      assert chat.turns == 2

      {:ok, chat} = Conversations.record_turn(chat, turn(3, 0.03))
      assert chat.usage == 6_000
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

      assert Spend.day_total() > before
    end

    # A reopened conversation is a new process, whose running total starts again from nothing. Its
    # figure is set on the run it belongs to — the latest — and the conversation's cost is every
    # run's; set on the job alone, as it was, a reopening forgot everything spent before it.
    test "a turn is costed on its run, and the conversation's cost is every run's", %{chat: chat} do
      [current] = Repo.all(from r in Forge.Jobs.Run, where: r.job_id == ^chat.id)
      earlier = DateTime.add(current.started_at, -3600)

      Repo.update_all(from(r in Forge.Jobs.Run, where: r.id == ^current.id),
        set: [started_at: DateTime.add(current.started_at, 60)]
      )

      run!(chat, usage: 60_000, started_at: earlier, finished_at: earlier)

      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.1))
      assert chat.usage == 80_000

      assert Repo.all(
               from r in Forge.Jobs.Run,
                 where: r.job_id == ^chat.id,
                 order_by: r.started_at,
                 select: r.usage
             ) == [60_000, 20_000]
    end

    # Its run ends with it, whichever way it ended; a reopening is a new run.
    test "a conversation's ending closes its run", %{chat: chat} do
      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.1))
      {:ok, _} = Conversations.ended(chat, nil, "machine_lost")

      assert [%{finished_at: %DateTime{}}] =
               Repo.all(from r in Forge.Jobs.Run, where: r.job_id == ^chat.id)
    end

    # A reopened conversation is a new process: its turns are numbered from one again, and its run
    # is a new one. Keyed on the turn alone, the new process's first turns read as re-sends of the
    # old one's and were dropped — commit, proposals and push with them. **Keyed on the session as
    # well, it still failed for Codex**, which resumes the same thread on a reopen: the session is
    # the same and the turns are not repeats. What they cost is the run's (`Forge.Jobs.Runs`),
    # which the test above pins.
    test "a new process's turns are its own, even on the same session, and a re-send is one",
         %{chat: chat} do
      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.10))
      {:ok, chat} = Conversations.record_turn(chat, turn(2, 0.30))

      reopen!(chat)
      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.05))
      {:ok, chat} = Conversations.record_turn(chat, turn(2, 0.08))
      assert chat.turns == 4

      # A re-send within the new process is still recorded once.
      {:ok, chat} = Conversations.record_turn(chat, turn(2, 0.08))
      assert chat.turns == 4

      turns = chat.id |> Events.for_job() |> Enum.count(&(&1.type == "chat.turn"))
      assert turns == 4
    end

    # A re-sent turn is a repeat whatever session it reports, as long as it is the same process's.
    test "turns with no session are one process's", %{chat: chat} do
      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.10, nil))
      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.10, nil))
      assert chat.turns == 1

      reopen!(chat)
      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.05, "sess-2"))
      assert chat.turns == 2
    end

    test "a session that reported no cost adds nothing, and breaks nothing", %{chat: chat} do
      {:ok, chat} = Conversations.record_turn(chat, turn(1, nil))
      reopen!(chat)
      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.05, "sess-2"))

      assert chat.usage == 10_000
    end

    # A new process: a run that started after the last, which is what a reopen's `Runs.open` makes.
    defp reopen!(chat) do
      latest =
        Repo.one!(
          from r in Forge.Jobs.Run,
            where: r.job_id == ^chat.id,
            order_by: [desc: r.started_at],
            limit: 1
        )

      run!(chat, started_at: DateTime.add(latest.started_at, 60))
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

  # A conversation declares nothing, so every file it leaves in `out/` is a document it means to
  # keep. `docs/design/conversations.md` § Commits.
  describe "what a turn wrote" do
    setup %{project: project} do
      {:ok, chat} = Conversations.open(project, "write it down")

      chat_started!(chat)
      %{chat: chat}
    end

    defp turn_with_documents(index, documents, invalid \\ %{}) do
      index
      |> turn(0.01 * index)
      |> Map.merge(%{"documents" => documents, "invalid_documents" => invalid})
    end

    defp last_turn_payload(chat) do
      chat.id
      |> Events.for_job()
      |> Enum.filter(&(&1.type == "chat.turn"))
      |> List.last()
      |> Map.fetch!(:payload)
    end

    test "a project chat's document is a version of its own, written by it", %{chat: chat} do
      {:ok, _chat} =
        Conversations.record_turn(chat, turn_with_documents(1, %{"notes.md" => "# Notes\n"}))

      assert %{kind: :document, job_id: job_id, ticket_id: nil} =
               Forge.Artifacts.find({:job, chat.id}, "notes.md")

      assert job_id == chat.id

      assert [{_artifact, version}] = Forge.Artifacts.written_by(chat.id)
      assert version.content == "# Notes\n"
      assert version.version == 1
    end

    # A ticket chat writes against its ticket, because that is the work it is about: the version
    # is the ticket's, which is what its next job reads.
    test "a ticket chat's document is a version of the ticket's", %{project: project} do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
      {:ok, chat} = Conversations.open(project, "rewrite the plan", ticket: ticket)

      {:ok, _chat} =
        Conversations.record_turn(chat, turn_with_documents(1, %{"plan.md" => "# Plan\n"}))

      assert [%{content: "# Plan\n", author: %{"kind" => "job", "id" => author}}] =
               Forge.Artifacts.versions(ticket.id, "plan.md")

      assert author == chat.id
      assert Forge.Artifacts.find({:job, chat.id}, "plan.md") == nil
    end

    # Except `commit-message`, which is what a merge of *this branch* will say and so is the
    # conversation's own even on a ticket (`docs/design/conversations.md` § Commits). One turn
    # writing both is what tells the rule from the scope it is an exception to.
    test "a ticket chat's commit message is its own, not the ticket's", %{project: project} do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
      {:ok, chat} = Conversations.open(project, "rewrite the plan", ticket: ticket)

      {:ok, _chat} =
        Conversations.record_turn(
          chat,
          turn_with_documents(1, %{
            "plan.md" => "# Plan\n",
            "commit-message" => "Write the notes down\n"
          })
        )

      assert [%{content: "Write the notes down\n"}] =
               Forge.Artifacts.versions({:job, chat.id}, "commit-message")

      assert Forge.Artifacts.versions(ticket.id, "commit-message") == []
      assert [%{content: "# Plan\n"}] = Forge.Artifacts.versions(ticket.id, "plan.md")
    end

    # `out/` accumulates, so every turn re-reports every file. A version per turn would be a
    # version per sentence, and each would be the one an approval had to attach to.
    test "the same file every turn is one version, and a changed one is the next", %{
      chat: chat
    } do
      {:ok, chat} =
        Conversations.record_turn(chat, turn_with_documents(1, %{"notes.md" => "# Notes\n"}))

      {:ok, chat} =
        Conversations.record_turn(chat, turn_with_documents(2, %{"notes.md" => "# Notes\n"}))

      assert [%{version: 1}] = Forge.Artifacts.versions({:job, chat.id}, "notes.md")

      {:ok, chat} =
        Conversations.record_turn(chat, turn_with_documents(3, %{"notes.md" => "# More\n"}))

      assert [%{version: 1}, %{version: 2, content: "# More\n"}] =
               Forge.Artifacts.versions({:job, chat.id}, "notes.md")

      # Compared with the *newest* version it wrote, not the first: the same file again is
      # still nothing new, and going back to the first text is a change like any other.
      {:ok, chat} =
        Conversations.record_turn(chat, turn_with_documents(4, %{"notes.md" => "# More\n"}))

      assert length(Forge.Artifacts.versions({:job, chat.id}, "notes.md")) == 2

      {:ok, _chat} =
        Conversations.record_turn(chat, turn_with_documents(5, %{"notes.md" => "# Notes\n"}))

      assert [_one, _two, %{version: 3, content: "# Notes\n"}] =
               Forge.Artifacts.versions({:job, chat.id}, "notes.md")
    end

    # Compared against what this conversation last wrote, not against the latest version: on a
    # ticket the latest may be a job's or a person's since, and comparing against it would write
    # the conversation's stale copy back over theirs on every turn.
    test "a newer version by someone else is not overwritten by the same file again", %{
      project: project
    } do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
      {:ok, chat} = Conversations.open(project, "draft the plan", ticket: ticket)

      {:ok, chat} =
        Conversations.record_turn(chat, turn_with_documents(1, %{"plan.md" => "# Draft\n"}))

      # The ticket's own job, since, and then a person. Another job is the case that tells "what
      # this conversation wrote" from "what any job wrote".
      [job] = Jobs.for_ticket(ticket.id)

      {:ok, _theirs} =
        Forge.Artifacts.record_version(ticket.id, "plan.md", :document, {:job, job.id}, %{
          content: "# The job's\n"
        })

      {:ok, chat} =
        Conversations.record_turn(chat, turn_with_documents(2, %{"plan.md" => "# Draft\n"}))

      {:ok, _theirs} =
        Forge.Artifacts.record_version(ticket.id, "plan.md", :document, :system, %{
          content: "# Someone else's\n"
        })

      {:ok, _chat} =
        Conversations.record_turn(chat, turn_with_documents(3, %{"plan.md" => "# Draft\n"}))

      assert ["# Draft\n", "# The job's\n", "# Someone else's\n"] =
               ticket.id |> Forge.Artifacts.versions("plan.md") |> Enum.map(& &1.content)
    end

    # Each would fail inside the turn's transaction — the name the platform keeps, text the
    # database cannot store, a document that does not parse, a name that is already a blob here —
    # and take the turn's cost and commit down with it, for ever, since the worker re-sends an
    # unacked turn. Refused before the transaction instead, and the turn is recorded.
    test "what cannot be a document is refused, with why, and the turn is still recorded", %{
      project: project
    } do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
      {:ok, chat} = Conversations.open(project, "look", ticket: ticket)

      {:ok, _blob} =
        Forge.Artifacts.record_version(ticket.id, "build.log", :blob, :system, %{
          blob_uri: "store:job/x/build.log"
        })

      documents = %{
        "notes.md" => "# Fine\n",
        "ticket" => "# A new ticket body\n",
        "nul.md" => "# Nul\n" <> <<0>>,
        "broken.md" => "---\noutcome: done\n",
        "build.log" => "# Not a log\n",
        # A transcript's name before the transcript exists: the job would find it taken when it
        # finished, and be unable to record its result.
        "transcript-refining-1.jsonl" => "# Mine\n",
        # No NUL byte in the text, so `text?/1` passes it — the YAML escape makes one, and the
        # `jsonb` front matter refused it inside the turn's transaction, with an exception: the
        # turn's cost went unrecorded and the channel crashed on every re-send.
        "escaped.md" => "---\ntitle: \"a\\0b\"\n---\n# Escaped\n",
        "huge.md" => "# Huge\n" <> String.duplicate("a", 1024 * 1024)
      }

      {:ok, chat} =
        Conversations.record_turn(
          chat,
          turn_with_documents(1, documents, %{"image.png" => "must be UTF-8 text"})
        )

      assert chat.turns == 1
      assert [{%{name: "notes.md"}, _version}] = Forge.Artifacts.written_by(chat.id)

      refused = last_turn_payload(chat)["refused_documents"]

      assert refused["ticket"] =~ "reserved"
      assert refused["nul.md"] =~ "UTF-8 text"
      assert refused["broken.md"] =~ "does not parse"
      assert refused["build.log"] =~ "is a blob here"
      assert refused["transcript-refining-1.jsonl"] =~ "reserved for job transcripts"
      assert refused["escaped.md"] =~ "NUL"
      assert refused["huge.md"] =~ "no larger than"
      # What the worker refused comes through beside what the platform did.
      assert refused["image.png"] =~ "UTF-8 text"
      refute Map.has_key?(refused, "notes.md")

      assert Conversations.unrecorded(chat.id) == refused
    end

    # The page reads the newest turn's, so a file the agent fixed stops being listed as refused.
    test "a later turn that refuses nothing clears what was refused", %{chat: chat} do
      {:ok, chat} =
        Conversations.record_turn(chat, turn_with_documents(1, %{"ticket" => "# No\n"}))

      assert %{"ticket" => _why} = Conversations.unrecorded(chat.id)

      {:ok, _chat} = Conversations.record_turn(chat, turn_with_documents(2, %{}))

      assert Conversations.unrecorded(chat.id) == %{}
    end

    # A conversation asks in its reply, where the person is. A block in a document it wrote
    # became a blocking question on the ticket and reached the queue, holding the ticket's work
    # on a question nobody had been asked (`conversations.md` § Commits).
    test "a question in a chat's document is not a question on the ticket", %{project: project} do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
      {:ok, chat} = Conversations.open(project, "sketch a plan", ticket: ticket)

      {:ok, _chat} =
        Conversations.record_turn(chat, turn_with_documents(1, %{"plan.md" => asking("backend")}))

      # Written, front matter and all — only the question is not extracted from it.
      assert [%{content: content, meta: %{"title" => "Plan"}}] =
               Forge.Artifacts.versions(ticket.id, "plan.md")

      assert content =~ "```question"
      assert Forge.Artifacts.open_questions(ticket.id) == []
      refute Enum.any?(Forge.Queue.items(), &(&1.kind in [:question, :assumption]))
    end

    # The review reproduced it: a job stopped on a question in `refinement.md`, a ticket chat
    # wrote `refinement.md` without the block, and — a question counting only on the latest
    # version — the job sat `:waiting` with nothing open, nothing in the queue and nothing that
    # could resume it. The chat's version is refused, the question stays open, and answering it
    # both resumes the job and lets the next turn write the file.
    test "a ticket chat may not rewrite the document a waiting job stopped on", %{
      project: project
    } do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
      [job] = Jobs.for_ticket(ticket.id)

      {:ok, _asked} =
        Forge.Artifacts.record_version(ticket.id, "refinement.md", :document, {:job, job.id}, %{
          content: asking("backend")
        })

      {:ok, _waiting} = job |> Jobs.Job.progress_changeset(%{status: :waiting}) |> Repo.update()
      {:ok, chat} = Conversations.open(project, "tidy the refinement", ticket: ticket)
      rewrite = %{"refinement.md" => "# Refinement\n\nNo question now.\n", "notes.md" => "# N\n"}

      {:ok, chat} = Conversations.record_turn(chat, turn_with_documents(1, rewrite))

      assert [%{version: 1}] = Forge.Artifacts.versions(ticket.id, "refinement.md")
      assert last_turn_payload(chat)["refused_documents"]["refinement.md"] =~ "waiting job"
      assert last_turn_payload(chat)["refused_documents"]["refinement.md"] =~ "`backend`"
      assert [%{key: "backend"}] = Forge.Artifacts.open_blocking_questions(ticket.id)
      assert Enum.any?(Forge.Queue.items(), &(&1.kind == :question))

      # Only the document the question is on: the rest of what the turn wrote is the ticket's.
      assert [%{content: "# N\n"}] = Forge.Artifacts.versions(ticket.id, "notes.md")

      user = Forge.ForgeFixtures.member_fixture(project)
      {:ok, _ticket} = Forge.Operator.answer(ticket, user, "backend", %{choice: "sqlite"})
      assert Jobs.get!(job.id).status == :pending

      {:ok, _chat} = Conversations.record_turn(chat, turn_with_documents(2, rewrite))

      assert [%{version: 1}, %{version: 2, author: %{"id" => author}}] =
               Forge.Artifacts.versions(ticket.id, "refinement.md")

      assert author == chat.id
    end

    # The hold is the question *and* the waiting job, as it is for `Operator.answer/4`: a
    # blocking question nobody is stopped on holds nothing, and a chat may rewrite its document
    # like any other.
    test "a blocking question with no job waiting on it holds nothing", %{project: project} do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
      [job] = Jobs.for_ticket(ticket.id)
      assert job.status == :pending

      {:ok, _asked} =
        Forge.Artifacts.record_version(ticket.id, "refinement.md", :document, {:job, job.id}, %{
          content: asking("backend")
        })

      {:ok, chat} = Conversations.open(project, "tidy the refinement", ticket: ticket)

      {:ok, chat} =
        Conversations.record_turn(
          chat,
          turn_with_documents(1, %{"refinement.md" => "# Refinement\n"})
        )

      assert [_asked, %{content: "# Refinement\n"}] =
               Forge.Artifacts.versions(ticket.id, "refinement.md")

      assert last_turn_payload(chat)["refused_documents"] == %{}
    end

    # The review's second reproduction: an approval pending on `refinement.md`, a ticket chat
    # writing `refinement.md`, and `Engine.decide/4` approving the latest version — the chat's,
    # which the operator never saw. Refused until the decision is made, and the approval lands
    # on the version that was shown.
    test "a ticket chat may not rewrite a document waiting for approval", %{project: project} do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
      [job] = Jobs.for_ticket(ticket.id)

      {:ok, shown} =
        Forge.Artifacts.record_version(ticket.id, "refinement.md", :document, {:job, job.id}, %{
          content: "---\noutcome: done\n---\n# Refinement\n"
        })

      {:ok, ticket} = Forge.Engine.after_job(ticket, job, "done")
      assert ticket.pending_transition["approve"] == ["refinement.md"]

      {:ok, chat} = Conversations.open(project, "tighten the refinement", ticket: ticket)
      rewrite = %{"refinement.md" => "# Refinement, tightened\n"}

      {:ok, chat} = Conversations.record_turn(chat, turn_with_documents(1, rewrite))

      assert [%{id: id}] = Forge.Artifacts.versions(ticket.id, "refinement.md")
      assert id == shown.id
      assert last_turn_payload(chat)["refused_documents"]["refinement.md"] =~ "approve"

      user = Forge.ForgeFixtures.member_fixture(project)
      {:ok, ticket} = Forge.Engine.decide(ticket, user.id, :approved, nil)
      assert ticket.state == "planning"
      assert Forge.Artifacts.approved?(shown)

      {:ok, _chat} = Conversations.record_turn(chat, turn_with_documents(2, rewrite))

      assert [_shown, %{content: "# Refinement, tightened\n"}] =
               Forge.Artifacts.versions(ticket.id, "refinement.md")
    end
  end

  # A document with a blocking question in it, the way a job writes one.
  defp asking(key) do
    """
    ---
    title: Plan
    ---
    # Plan

    ```question
    key: #{key}
    text: Local file or SQLite?
    options: [{label: local-file, detail: About local-file}, {label: sqlite, detail: About sqlite}]
    blocking: true
    ```
    """
  end

  # The message a chat's question form sends (`docs/design/conversations.md` § Asking a
  # question): every answer under its question, in the order asked, or nothing at all.
  describe "answering a reply's questions" do
    setup do
      {:ok, %{questions: questions}} =
        ForgeCore.Document.parse(
          """
          ```question
          key: store
          text: Which backend?
          options: [{label: Postgres, detail: Where the data is.}, {label: SQLite, detail: A file.}]
          ```

          ```question
          key: rows
          text: How many rows?
          ```
          """,
          blocking: :always
        )

      %{questions: questions}
    end

    # `store` is asked before `rows` and sorts after it, so an answer in any order but the
    # asking one reads differently.
    test "is every answer under its question, in the order asked", %{questions: questions} do
      assert {:ok, text} =
               Conversations.answer_text(questions, %{
                 "rows" => %{choice: nil, text: "a thousand"},
                 "store" => %{choice: "SQLite", text: "for now"}
               })

      assert text == "**Which backend?**\nSQLite — for now\n\n**How many rows?**\na thousand"
    end

    test "refuses a question left unanswered, blank text included", %{questions: questions} do
      assert {:error, {:unanswered, ["rows"]}} =
               Conversations.answer_text(questions, %{
                 "store" => %{choice: "Postgres", text: nil},
                 "rows" => %{choice: nil, text: "   "}
               })
    end

    # What the page sends for a question left empty is no key at all — the form drops it — so
    # that is the case the rule has to hold for, or a forced Send posts half the answers.
    test "refuses a question the answers leave out", %{questions: questions} do
      assert {:error, {:unanswered, ["rows"]}} =
               Conversations.answer_text(questions, %{"store" => %{choice: "Postgres", text: nil}})
    end

    test "refuses a choice that is no label", %{questions: questions} do
      assert {:error, {:not_an_option, "store", "MySQL"}} =
               Conversations.answer_text(questions, %{
                 "store" => %{choice: "MySQL", text: nil},
                 "rows" => %{choice: nil, text: "ten"}
               })
    end

    test "refuses an answer to a question the reply did not ask", %{questions: questions} do
      answers = %{
        "store" => %{choice: "Postgres", text: nil},
        "rows" => %{choice: nil, text: "ten"}
      }

      assert {:error, :stale} =
               Conversations.answer_text(questions, Map.put(answers, "other", %{text: "x"}))

      assert {:error, :stale} = Conversations.answer_text([], %{})
    end

    # A reply's name holds while it is still arriving, or a form drawn over its first block would
    # be stale by its second; and a later reply is named apart even within the same second.
    test "a reply keeps its name while it arrives, and the next is named apart", %{
      project: project
    } do
      {:ok, chat} = Conversations.open(project, "which?")
      chat_started!(chat)
      text(chat, "```question\nkey: rows\ntext: How many rows?\n```\n")
      first = chat.id |> Conversations.messages() |> Conversations.reply_ref()

      text(chat, "And one more thing.")
      assert chat.id |> Conversations.messages() |> Conversations.reply_ref() == first

      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.01))
      assert chat.id |> Conversations.messages() |> Conversations.reply_ref() == first

      {:ok, event} = Conversations.send(chat, "ten")
      assert chat.id |> Conversations.messages() |> Conversations.reply_ref() == nil

      delivered(chat, to_string(event.seq))
      text(chat, "```question\nkey: rows\ntext: How many rows, again?\n```\n")
      second = chat.id |> Conversations.messages() |> Conversations.reply_ref()
      refute second in [nil, first]
    end

    # The form carries the reply it was drawn for. When the last thing said is the person's own,
    # there is no reply waiting, and nothing is sent in its name.
    test "is refused once the person has spoken since", %{project: project} do
      {:ok, chat} = Conversations.open(project, "which?")
      user = member_fixture(project, :member)

      text(chat, "```question\nkey: rows\ntext: How many rows?\n```\n")
      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.01))
      reply = chat.id |> Conversations.messages() |> Conversations.reply_ref()

      {:ok, _event} = Conversations.send(chat, "never mind")

      assert {:error, :stale} =
               Forge.Operator.answer_chat(chat, user, reply, %{"rows" => %{text: "ten"}})

      assert [_opening, _reply, %{text: "never mind"}] = Conversations.messages(chat.id)
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
      {:ok, worker} = Forge.Workers.ready(worker, %{"memory_budget" => 8_000_000_000})
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

  describe "a message with files" do
    # `docs/design/attachments.md` § Delivery, `conversations.md` § The wire: the files of a
    # message are named in the push, and the pool as it is now rides with it with a token for each,
    # so the worker's folder is brought up to date before the turn that reads the message begins.
    test "is pushed with its files named and the whole pool with a token for each", %{
      project: project
    } do
      user = Forge.AccountsFixtures.user_fixture()
      Forge.ForgeFixtures.join!(project, user)
      store = Application.get_env(:forge, Forge.Storage, [])
      Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
      on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

      {:ok, opened} = Conversations.open(project, "hello")
      {:ok, worker, _token} = Forge.Workers.create(%{provider: "fake"})
      {:ok, worker} = Forge.Workers.ready(worker, %{"memory_budget" => 8_000_000_000})
      :ok = Forge.Workers.connected(worker.id)

      {:ok, _running} =
        opened
        |> Jobs.Job.progress_changeset(%{status: :running, worker_id: worker.id})
        |> Repo.update()

      path = Path.join(tmp_dir("src"), "shot")
      File.write!(path, "pixels")
      {:ok, upload} = Forge.Attachments.stage(project, user, {:file, path}, "Shot 1.png")

      batch = %Forge.Attachments.Batch{
        uploads: [%{id: upload.id, name: "Shot 1.png"}],
        not_received: ["big.mov"]
      }

      {:ok, _event} =
        Conversations.send(opened, "look", actor: {:user, user.id}, attachments: batch)

      assert_receive {"message", payload}
      assert payload["files"] == [%{"file" => "Shot-1.png", "size" => 6}]
      assert payload["not_received"] == ["big.mov"]

      assert [%{"file" => "Shot-1.png", "key" => "upload/" <> _, "token" => token, "size" => 6}] =
               payload["attachments"]

      assert is_binary(token)

      # A message with none names none, and the pool is still the whole of it.
      {:ok, _event} = Conversations.send(opened, "and again", actor: {:user, user.id})
      assert_receive {"message", %{"files" => [], "attachments" => [%{"file" => "Shot-1.png"}]}}
    end
  end

  # **Where a message stands until the agent takes it** (`docs/design/conversations.md` § The
  # page): last, queued, whatever is being said, and then where it was taken. The worker says it
  # was taken when it writes it (`job.harness.delivered`), and a new process takes every message
  # that was waiting for it.
  describe "a message nobody has taken" do
    setup %{project: project} do
      {:ok, chat} = Conversations.open(project, "first")
      chat_started!(chat)
      %{chat: chat}
    end

    test "trails the reply being spoken, and does not split it", %{chat: chat} do
      text(chat, "Working.")
      {:ok, _event} = Conversations.send(chat, "also this")
      tool_use(chat, "t1", "Bash", %{"command" => "mix test"})
      text(chat, "Done.")

      assert [%{role: :user, text: "first"}, reply, %{text: "also this", delivered: false}] =
               Conversations.transcript(chat.id)

      # One reply, not two: the message was not placed where it was sent.
      assert [{:text, "Working."}, {:action, %{id: "t1"}}, {:text, "Done."}] = reply.items
    end

    test "is placed after the closed turn when the agent takes it", %{chat: chat} do
      text(chat, "Working.")
      {:ok, event} = Conversations.send(chat, "also this")
      text(chat, "Done.")
      {:ok, _chat} = Conversations.record_turn(chat, turn(1, 0.01))
      delivered(chat, to_string(event.seq))
      text(chat, "And this.")

      assert [
               %{text: "first"},
               %{role: :assistant, turn: 1, text: "Working.\n\nDone."},
               %{text: "also this", delivered: true},
               %{role: :assistant, turn: nil, text: "And this."}
             ] = Conversations.transcript(chat.id)
    end

    test "a delivery names one message and leaves the others queued", %{chat: chat} do
      {:ok, first} = Conversations.send(chat, "one")
      {:ok, _second} = Conversations.send(chat, "two")
      delivered(chat, to_string(first.seq))

      assert [_opening, %{text: "one", delivered: true}, %{text: "two", delivered: false}] =
               Conversations.transcript(chat.id)

      # An id that is nobody's is nothing.
      delivered(chat, "999999999")
      assert [_, _, %{delivered: false}] = Conversations.transcript(chat.id)
    end

    test "is taken, with every other, by the process that starts after it", %{project: project} do
      {:ok, chat} = Conversations.open(project, "opening")
      assert [%{text: "opening", delivered: false}] = Conversations.transcript(chat.id)

      {:ok, _event} = Conversations.send(chat, "and another")
      chat_started!(chat)
      text(chat, "Hello.")

      assert [
               %{text: "opening", delivered: true},
               %{text: "and another", delivered: true},
               %{role: :assistant}
             ] = Conversations.transcript(chat.id)
    end

    test "is not a turn in flight, and the oldest one is the button's", %{chat: chat} do
      text(chat, "Working.")
      {:ok, one} = Conversations.send(chat, "one")
      {:ok, _two} = Conversations.send(chat, "two")
      messages = Conversations.transcript(chat.id)

      # The reply being spoken is the turn; the queued messages are not the agent having the ball.
      assert Conversations.turn_open?(messages)
      assert Conversations.oldest_queued(messages) == to_string(one.seq)

      {:ok, _chat} = Conversations.record_turn(chat, turn(1, 0.01))
      messages = Conversations.transcript(chat.id)
      refute Conversations.turn_open?(messages)
      assert Conversations.oldest_queued(messages) == to_string(one.seq)

      delivered(chat, to_string(one.seq))
      assert Conversations.turn_open?(Conversations.transcript(chat.id))
      assert Conversations.oldest_queued([]) == nil
    end

    # Several messages taken in one chat: the newest delivery is the one that says the agent is
    # working. Read from the oldest, the chat would read as waiting while the agent answers the last.
    test "a chat that has taken one message before is still working when it takes the next", %{
      chat: chat,
      project: project
    } do
      chat = chat |> Jobs.Job.progress_changeset(%{status: :running}) |> Repo.update!()

      text(chat, "Looking into it.")
      {:ok, first} = Conversations.send(chat, "the lexer")
      delivered(chat, to_string(first.seq))
      text(chat, "The lexer then.")
      {:ok, second} = Conversations.send(chat, "and the parser")
      text(chat, "Both, in turn.")
      {:ok, _chat} = Conversations.record_turn(chat, turn(1, 0.01))
      delivered(chat, to_string(second.seq))

      assert [%{waiting: false}] = Conversations.summaries(project_id: project.id)
    end

    # The proposal *a message sent mid-turn leaves the conversation reading as waiting while the
    # agent works*: a message sent mid-turn, words, the turn's end, the message taken, a turn that
    # runs tools and says nothing yet. The agent is working, not waiting on its person.
    test "taken after a turn's end is the agent working, not waiting", %{
      chat: chat,
      project: project
    } do
      user = member_fixture(project)
      chat = chat |> Jobs.Job.progress_changeset(%{status: :running}) |> Repo.update!()

      text(chat, "Looking into it.")
      {:ok, event} = Conversations.send(chat, "and the lexer too")
      text(chat, "The parser first.")
      {:ok, _chat} = Conversations.record_turn(chat, turn(1, 0.01))

      # The turn ended with words, but the person has spoken since and the agent has not taken
      # it yet: the conversation is not waiting on them.
      refute Conversations.waiting?(Conversations.messages(chat.id))

      # Then the agent takes the message and runs a tool, saying nothing yet.
      delivered(chat, to_string(event.seq))
      tool_use(chat, "t1", "Bash", %{"command" => "mix test"})

      refute Conversations.waiting?(Conversations.messages(chat.id))
      assert Conversations.in_flight?(Jobs.get!(chat.id))
      assert Forge.Queue.for_chat(Jobs.get!(chat.id)) == []
      assert Forge.Queue.count(user) == 0
      assert [%{waiting: false}] = Conversations.summaries(project_id: project.id)
      assert Conversations.counts(user) == %{live: 1, total: 1}
    end

    test "taken, it is in flight before the agent has said anything", %{chat: chat} do
      text(chat, "Working.")
      {:ok, event} = Conversations.send(chat, "also this")
      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.01))
      chat = chat |> Jobs.Job.progress_changeset(%{status: :running}) |> Repo.update!()
      refute Conversations.in_flight?(chat)

      delivered(chat, to_string(event.seq))
      assert Conversations.in_flight?(chat)
    end
  end

  describe "interrupting for a queued message" do
    setup %{project: project} do
      {:ok, worker, _token} = Forge.Workers.create(%{provider: "fake"})
      {:ok, worker} = Forge.Workers.ready(worker, %{"memory_budget" => 8_000_000_000})
      :ok = Forge.Workers.connected(worker.id)

      {:ok, chat} = Conversations.open(project, "first")

      chat =
        chat
        |> Jobs.Job.progress_changeset(%{status: :running, worker_id: worker.id})
        |> Repo.update!()

      chat_started!(chat)
      text(chat, "Working.")
      {:ok, event} = Conversations.send(chat, "next")
      assert_receive {"message", _payload}
      %{chat: chat, event: event, id: to_string(event.seq), project: project}
    end

    test "is pushed with the message's id when it is still queued", %{chat: chat, id: id} do
      chat_id = chat.id
      assert :ok = Conversations.interrupt(chat, id)
      assert_receive {"interrupt", %{"job_id" => ^chat_id, "message_id" => ^id}}
    end

    test "is refused once the message has been delivered", %{chat: chat, id: id} do
      delivered(chat, id)
      assert {:error, :not_queued} = Conversations.interrupt(chat, id)
      refute_received {"interrupt", _payload}
    end

    # Each message is its own: the delivery of one is not the delivery of the next. Every message
    # of the log still queued behind a taken one keeps its button.
    test "a message is queued whatever was delivered before it", %{chat: chat, id: id} do
      {:ok, later} = Conversations.send(chat, "and another")
      delivered(chat, id)

      assert {:error, :not_queued} = Conversations.interrupt(chat, id)
      assert :ok = Conversations.interrupt(chat, to_string(later.seq))
    end

    # An event of the log that is not a message is refused by its type; the opening is refused by
    # the later process anyway, so a harness event, which no process follows, is what tells.
    test "is refused for an event that is not a message, though nothing has taken it",
         %{chat: chat} do
      %{seq: seq} = Enum.find(Events.for_job(chat.id), &(&1.type == "job.harness.text"))

      assert {:error, :not_queued} = Conversations.interrupt(chat, to_string(seq))
      refute_received {"interrupt", _payload}
    end

    test "is refused for a number no event could have, and for a spelling of one that has", %{
      chat: chat,
      id: id
    } do
      assert {:error, :not_queued} = Conversations.interrupt(chat, "99999999999999999999999")
      assert {:error, :not_queued} = Conversations.interrupt(chat, "0" <> id)
      assert {:error, :not_queued} = Conversations.interrupt(chat, "+" <> id)
      refute_received {"interrupt", _payload}
    end

    test "is refused once a later process has started", %{chat: chat, id: id} do
      chat_started!(chat)
      assert {:error, :not_queued} = Conversations.interrupt(chat, id)
      refute_received {"interrupt", _payload}
    end

    test "is refused for another conversation's message, an event that is not one, or nonsense",
         %{chat: chat, project: project} do
      {:ok, other} = Conversations.open(project, "elsewhere")
      {:ok, theirs} = Conversations.send(other, "queued there")
      [opened | _] = Events.for_job(chat.id)

      assert {:error, :not_queued} = Conversations.interrupt(chat, to_string(theirs.seq))
      assert {:error, :not_queued} = Conversations.interrupt(chat, to_string(opened.seq))
      assert {:error, :not_queued} = Conversations.interrupt(chat, "12abc")
      assert {:error, :not_queued} = Conversations.interrupt(chat, "")
      refute_received {"interrupt", _payload}
    end

    test "is refused for a conversation that is not running", %{chat: chat, id: id} do
      {:ok, released} = Conversations.ended(chat, nil, "idle")
      assert {:error, :not_queued} = Conversations.interrupt(released, id)
      refute_received {"interrupt", _payload}
    end
  end

  # A message may be files alone (`docs/design/ui.md` § Attaching files): words or files, and
  # nothing is not a message. One rule behind every caller.
  describe "words or files" do
    setup %{project: project} do
      user = member_fixture(project)
      store = Application.get_env(:forge, Forge.Storage, [])
      Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
      on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)
      %{user: user}
    end

    defp upload(project, user, name) do
      path = Path.join(tmp_dir("src"), "#{System.unique_integer([:positive])}")
      File.write!(path, "pixels")
      {:ok, staged} = Forge.Attachments.stage(project, user, {:file, path}, name)
      %{id: staged.id, name: name}
    end

    test "nothing typed and nothing attached sends nothing, and starts nothing", context do
      %{project: project} = context
      {:ok, chat} = Conversations.open(project, "first")
      before = length(Events.for_job(chat.id))

      assert {:error, :empty} = Conversations.send(chat, "")
      assert {:error, :empty} = Conversations.send(chat, "  \n ")
      assert {:error, :empty} = Conversations.send(chat, nil)

      assert {:error, :empty} =
               Conversations.send(chat, "", attachments: %Forge.Attachments.Batch{})

      assert length(Events.for_job(chat.id)) == before

      chats = length(Jobs.chats_for_project(project.id))
      assert {:error, :empty} = Conversations.open(project, " ")
      assert length(Jobs.chats_for_project(project.id)) == chats
    end

    test "files that all failed send nothing, and start nothing", context do
      %{project: project} = context
      {:ok, chat} = Conversations.open(project, "first")
      batch = %Forge.Attachments.Batch{not_received: ["big.mov"]}
      before = length(Events.for_job(chat.id))

      assert {:error, :empty} = Conversations.send(chat, "", attachments: batch)
      assert {:error, :empty} = Conversations.open(project, "", attachments: batch)
      assert length(Events.for_job(chat.id)) == before
    end

    # The check before the transaction sees only the client's batch. An upload the claim then
    # refuses (gone, or past its staging life) leaves a message of no words and no file, which wakes
    # an agent with nothing but *[Attached but not received …]*.
    test "files the claim refused leave nothing sent and nothing started", context do
      %{project: project, user: user} = context
      {:ok, chat} = Conversations.open(project, "first")
      gone = %{id: Ecto.UUID.generate(), name: "gone.png"}
      batch = %Forge.Attachments.Batch{uploads: [gone]}
      before = length(Events.for_job(chat.id))
      chats = length(Jobs.chats_for_project(project.id))

      assert {:error, :empty} =
               Conversations.send(chat, "", actor: {:user, user.id}, attachments: batch)

      assert length(Events.for_job(chat.id)) == before

      assert {:error, :empty} =
               Conversations.open(project, " ", actor: {:user, user.id}, attachments: batch)

      assert length(Jobs.chats_for_project(project.id)) == chats

      # With words, the same refused file is only named as not received.
      assert {:ok, _event} =
               Conversations.send(chat, "still here", actor: {:user, user.id}, attachments: batch)
    end

    test "files alone are a message, whose prompt names them with no blank lines before",
         context do
      %{project: project, user: user} = context
      {:ok, chat} = Conversations.open(project, "first")
      chat_started!(chat)
      text(chat, "Hello.")
      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.01))
      {:ok, chat} = Conversations.ended(chat, nil, "idle")
      batch = %Forge.Attachments.Batch{uploads: [upload(project, user, "Shot 1.png")]}

      assert {:ok, event} =
               Conversations.send(chat, "", actor: {:user, user.id}, attachments: batch)

      assert event.payload["text"] == ""

      assert [%{role: :user, text: ""}] =
               Enum.filter(Conversations.messages(chat.id), &(&1.text == ""))

      # What the next process answers is the line that names the file, and nothing before it.
      assert %{prompt: "[Files attached with this message" <> _} = Conversations.opening(chat.id)
    end

    test "files alone open a conversation, named after the first file", context do
      %{project: project, user: user} = context

      batch = %Forge.Attachments.Batch{
        uploads: [upload(project, user, "Screenshot one.png"), upload(project, user, "b.png")]
      }

      assert {:ok, chat} =
               Conversations.open(project, "", actor: {:user, user.id}, attachments: batch)

      assert Conversations.opening_words([chat.id]) == %{chat.id => "Screenshot-one.png"}

      assert Conversations.title(chat, nil, Conversations.opening_words([chat.id])[chat.id]) ==
               "Screenshot-one.png"

      assert [%{first: "Screenshot-one.png"}] = Conversations.summaries(project_id: project.id)

      # The project page's Chats list and the proposals page name it by `Proposals.openings/1`: the
      # file, not the empty text the first message carries.
      assert Forge.Proposals.openings([chat.id]) == %{chat.id => "Screenshot-one.png"}
    end

    test "words are what a conversation is called by, when there are some", context do
      %{project: project, user: user} = context
      batch = %Forge.Attachments.Batch{uploads: [upload(project, user, "shot.png")]}

      {:ok, chat} =
        Conversations.open(project, "Why is this red?",
          actor: {:user, user.id},
          attachments: batch
        )

      assert Conversations.opening_words([chat.id]) == %{chat.id => "Why is this red?"}
    end
  end

  describe "history" do
    # Any id will do where nothing verifies a token; the test below that does makes a real chat.
    @holder "00000000-0000-0000-0000-000000000001"

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

      assert [entry] = Conversations.history(ticket, @holder)

      # Nested, so a state retried three times reads as three attempts of one thing.
      assert entry["dir"] == "#{job.state}/#{job.attempt}"
      assert entry["metadata"] =~ job.state
      assert entry["metadata"] =~ job.id
      assert entry["transcript"]["key"] == "job/#{job.id}/transcript-1.jsonl"
      assert is_binary(entry["transcript"]["token"])

      # Fetched only once the conversation's worktree is prepared, so the token outlives the
      # preparation margin, an hour, as well as the store's own fifteen minutes.
      assert store_token_lifetime(entry["transcript"]["token"]) == 3600 + 15 * 60

      # The bytes are not here, and that is the point.
      refute entry["metadata"] =~ "\"type\":"
    end

    # A refused document is not kept, and the transcript is too large to read to find out why: a
    # chat reconstructing a job that ended `error` was left guessing at a rule it could not see.
    test "a job's refused documents and its last words are in its metadata", %{project: project} do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
      [job] = Jobs.for_ticket(ticket.id)

      for text <- ["Reading the ticket.", "Written; the job now parks.\nFour questions."] do
        Forge.Events.append("job.harness.text", :system, %{
          ticket_id: ticket.id,
          job_id: job.id,
          payload: %{"text" => text}
        })
      end

      Forge.Events.append("job.finished", :system, %{
        ticket_id: ticket.id,
        job_id: job.id,
        payload: %{"invalid" => %{"refinement.md" => "question[1].assumption: not allowed"}}
      })

      assert [%{"metadata" => metadata}] = Conversations.history(ticket, @holder)
      assert metadata =~ "## What was refused\n\n- `refinement.md`, not kept:\n  question[1]"

      assert metadata =~
               "## What it said last\n\n> Written; the job now parks.\n> Four questions."

      refute metadata =~ "Reading the ticket."
    end

    # Its last words are for knowing how it ended, and a job that ended by pasting a log into
    # its reply would otherwise put all of it into every conversation's history.
    test "a job's last words are cut to their first four thousand characters", %{
      project: project
    } do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
      [job] = Jobs.for_ticket(ticket.id)

      Forge.Events.append("job.harness.text", :system, %{
        ticket_id: ticket.id,
        job_id: job.id,
        payload: %{"text" => String.duplicate("x", 4000) <> "BEYOND"}
      })

      assert [%{"metadata" => metadata}] = Conversations.history(ticket, @holder)
      assert metadata =~ "> " <> String.duplicate("x", 4000)
      refute metadata =~ "BEYOND"
    end

    # **Tied to the conversation it is handed to, and not to the job whose transcript it reads**
    # (`docs/design/storage.md` § Serving): the transcripts are of finished jobs, and a token that
    # named their owner would be refused the moment it was minted.
    test "a transcript's token names the conversation it was handed to", %{project: project} do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
      [job] = Jobs.for_ticket(ticket.id)

      {:ok, finished} =
        Repo.update(Jobs.Job.progress_changeset(job, %{status: :finished, outcome: :converged}))

      {:ok, chat} = Conversations.open(project, "about this", ticket: ticket)

      {:ok, _version} =
        Forge.Artifacts.record_version(
          ticket.id,
          "transcript-#{job.state}-1.jsonl",
          :blob,
          {:job, job.id},
          %{blob_uri: "store:job/#{job.id}/transcript-1.jsonl"}
        )

      assert [%{"transcript" => %{"key" => key, "token" => token}}] =
               Conversations.history(ticket, chat.id)

      # The job it reads is finished, and the token works: it is not that job's.
      assert finished.status == :finished
      assert Forge.Storage.Token.verify(token, :get, key) == :ok

      {:ok, _chat} = Repo.update(Jobs.Job.progress_changeset(chat, %{status: :finished}))
      assert Forge.Storage.Token.verify(token, :get, key) == {:error, :expired}
    end

    test "a job with nothing refused and nothing said has neither section", %{project: project} do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)

      assert [%{"metadata" => metadata}] = Conversations.history(ticket, @holder)
      refute metadata =~ "What was refused"
      refute metadata =~ "What it said last"
    end

    test "a job that never uploaded a transcript still gets its metadata", %{project: project} do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)

      assert [entry] = Conversations.history(ticket, @holder)
      assert entry["transcript"] == nil
      assert entry["metadata"] =~ "Not kept."
    end

    test "conversations are not history; only the workflow is", %{project: project} do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
      {:ok, _chat} = Conversations.open(project, "about this", ticket: ticket)

      assert length(Conversations.history(ticket, @holder)) == 1
    end

    test "a project chat has no ticket and so no history" do
      assert Conversations.history(nil, @holder) == []
    end
  end

  # A conversation is the one job kind whose agent fetches and merges the default branch on its
  # own initiative, and nothing used to tell it to fetch one: its squash kept no merge, so every
  # turn flattened the agent's merge and the next one found the same conflict (ticket 11,
  # `docs/design/conversations.md` § Commits).
  describe "the default branch" do
    test "a conversation is assigned it", %{project: project} do
      {:ok, chat} = Conversations.open(project, "merge main for me")

      assignment = Jobs.assignment(Jobs.get!(chat.id), nil, project, "token")

      assert assignment["git"]["default_branch"] == project.default_branch
    end

    # Read, yes. Write, no: the token's scope is its own ref and nothing else, so fetching the
    # default branch is all that was added. The same guard as an integrating job's
    # (`Forge.IntegratingJobTest`), because this is where a wider token would have been handed out.
    test "its token reads the default branch and cannot write it", %{project: project} do
      {:ok, chat} = Conversations.open(project, "merge main for me")
      repo = Projects.repo_path(project)
      {:ok, main} = Git.resolve(repo, "refs/heads/main")
      {:ok, token, _row} = Tokens.issue_for_job(Jobs.get!(chat.id), nil, project)
      url = Url.with_token(project, token)
      work = Path.join(tmp_dir("chat-token"), "clone")

      {_out, 0} =
        job_git(Path.dirname(work), ["clone", "-q", "--branch", "chat/" <> chat.id, url, work])

      {_out, 0} = job_git(work, ["fetch", "-q", url, "+refs/heads/main:refs/remotes/origin/main"])

      # A commit of its own, so the push is a change and not a no-op the hook has nothing to
      # refuse: the chat branch is cut from the default branch and starts out identical to it.
      File.write!(Path.join(work, "README.md"), "the chat's\n")
      {_out, 0} = job_git(work, ["commit", "-qam", "the chat's work"])

      assert {out, code} = job_git(work, ["push", "-q", url, "HEAD:refs/heads/main"])
      assert code != 0
      assert out =~ "main"
      assert {:ok, ^main} = Git.resolve(repo, "refs/heads/main")

      assert {_out, 0} = job_git(work, ["push", "-q", url, "HEAD:refs/heads/chat/" <> chat.id])
    end
  end

  # A turn whose work did not reach the branch used to be indistinguishable, from the
  # conversation, from one that committed: `commit` was simply nil, and why was a line in the
  # machine's log that its person never reads (ticket 11).
  describe "a turn that could not commit" do
    setup %{project: project} do
      {:ok, chat} = Conversations.open(project, "merge main for me")

      chat_started!(chat)
      %{chat: chat}
    end

    defp uncommitted_turn(chat, index, uncommitted) do
      {:ok, _chat} =
        Conversations.record_turn(
          chat,
          turn(index, 0.01) |> Map.put("commit", nil) |> Map.put("uncommitted", uncommitted)
        )
    end

    # A reply's references are pinned to the record of its turn (`conversations.md` § References
    # in messages), so the record is the `chat.turn` event's own clock and place in the log.
    test "a reply closed by a turn carries that turn's record; one still open carries none",
         %{chat: chat} do
      text(chat, "Done.")
      {:ok, _chat} = Conversations.record_turn(chat, turn(1, 0.01))
      text(chat, "And more, still being said.")

      [turn_event] = for %{type: "chat.turn"} = e <- Forge.Events.for_job(chat.id), do: e

      assert [%{role: :user}, %{recorded: recorded}, %{recorded: nil}] =
               Conversations.transcript(chat.id)

      assert recorded == %{at: turn_event.inserted_at, seq: turn_event.seq}
    end

    test "is a line of the platform's own, after the turn it is about", %{chat: chat} do
      text(chat, "Merging main.")
      uncommitted_turn(chat, 1, %{"reason" => "merge_unresolved", "paths" => ["README.md"]})

      assert [%{role: :user}, %{role: :assistant}, notice] = Conversations.transcript(chat.id)
      assert notice.role == :notice
      assert notice.turn == 1
      assert notice.text =~ "Nothing from this turn reached the branch"
      assert notice.text =~ "README.md"
    end

    # The notice is nobody's reply: the queue, the replay a reopened process reads and the push
    # all ask what was *said* (`said/1`), and a platform line there would be answered as though
    # the agent had spoken it.
    test "is not something either side said", %{chat: chat} do
      text(chat, "Merging main.")
      uncommitted_turn(chat, 1, %{"reason" => "merge_unresolved", "paths" => ["README.md"]})

      assert [%{role: :user}, %{role: :assistant}] = Conversations.messages(chat.id)
    end

    # The case the notice exists for: a turn that merged and said nothing has no reply to hang it
    # on, and it is the one whose work is lost. It is also why the notice is its own entry.
    test "is there even when the turn said nothing", %{chat: chat} do
      uncommitted_turn(chat, 1, %{"reason" => "merge_unresolved", "paths" => ["README.md"]})

      assert [%{role: :user}, %{role: :notice} = notice] = Conversations.transcript(chat.id)
      assert notice.text =~ "a conflict is unresolved in README.md"
    end

    # Every path, read as a list a person can scan, and no promise that the work is safe: the
    # tree only lasts as long as this machine does, and a sentence saying otherwise would sit in
    # the transcript going stale.
    test "names every conflicted path, and promises nothing about the work", %{chat: chat} do
      text(chat, "Merging main.")

      uncommitted_turn(chat, 1, %{
        "reason" => "merge_unresolved",
        "paths" => ["README.md", "lib/game.ex"]
      })

      assert [_said, _reply, notice] = Conversations.transcript(chat.id)
      assert notice.text =~ "unresolved in README.md, lib/game.ex."
      assert notice.text =~ "while this conversation is still on its machine"
      refute notice.text =~ "commits it"
    end

    # Once, for a turn a message taken in the middle of it split in two — which is what a log from
    # before protocol 15 holds, the harness having echoed it then: both halves are the same turn,
    # and two warnings for one turn read as two failures.
    test "is drawn once for a turn split by a message", %{chat: chat} do
      text(chat, "Merging main.")
      {:ok, event} = Conversations.send(chat, "hurry up")
      delivered(chat, to_string(event.seq))
      text(chat, "Still merging.")
      uncommitted_turn(chat, 1, %{"reason" => "merge_unresolved", "paths" => ["README.md"]})

      assert [%{role: :notice}] =
               chat.id |> Conversations.transcript() |> Enum.filter(&(&1.role == :notice))
    end

    # Every other way a push fails — a credential refused, a hook, a platform that is not
    # there — is the common one, and says the part that matters without naming a conflict.
    test "says plainly that the work did not reach the branch, whatever stopped it", %{chat: chat} do
      text(chat, "Pushing.")
      uncommitted_turn(chat, 1, %{"reason" => "not_committed"})

      assert [_said, _reply, notice] = Conversations.transcript(chat.id)
      assert notice.text == "Nothing from this turn reached the branch."
    end

    # A file the worker could not put where the agent reads it is named to the agent as not
    # received, and the person is told here (ticket 75).
    test "names the files the agent could not read, and why", %{chat: chat} do
      text(chat, "Looking.")

      {:ok, _chat} =
        Conversations.record_turn(
          chat,
          Map.put(turn(1, 0.01), "files_lost", [
            %{"file" => "shot.png", "why" => "it could not be put in the folder on this machine"}
          ])
        )

      assert [%{role: :user}, %{role: :assistant}, notice] = Conversations.transcript(chat.id)
      assert notice.role == :notice
      assert notice.turn == 1

      assert notice.text ==
               "A file sent with a message could not be put where the agent reads it: " <>
                 "shot.png (it could not be put in the folder on this machine)."
    end

    test "cuts a long list of lost files and ignores what is not an entry", %{chat: chat} do
      lost = for n <- 1..7, do: %{"file" => "f#{n}.png"}

      {:ok, _chat} =
        Conversations.record_turn(
          chat,
          Map.put(turn(1, 0.01), "files_lost", lost ++ [%{"why" => "no name"}, "junk"])
        )

      assert [%{role: :user}, notice] = Conversations.transcript(chat.id)
      assert notice.text =~ "7 files"
      assert notice.text =~ "f1.png; f2.png; f3.png; f4.png; f5.png; and 2 more."
      refute notice.text =~ "f6.png"
    end

    test "cuts a file's name and reason to 200 characters", %{chat: chat} do
      long = String.duplicate("x", 300)

      {:ok, _chat} =
        Conversations.record_turn(
          chat,
          Map.put(turn(1, 0.01), "files_lost", [%{"file" => long, "why" => long}])
        )

      assert [%{role: :user}, notice] = Conversations.transcript(chat.id)
      cut = String.duplicate("x", 200)

      assert notice.text ==
               "A file sent with a message could not be put where the agent reads it: " <>
                 cut <> " (" <> cut <> ")."
    end

    # A worker's entry is not trusted to hold text: a `file` or a `why` that is not a string is
    # left out, and does not raise where the transcript and Activity draw it.
    test "leaves out a name that is not text and a reason that is not text", %{chat: chat} do
      {:ok, _chat} =
        Conversations.record_turn(
          chat,
          Map.put(turn(1, 0.01), "files_lost", [
            %{"file" => 5},
            %{"file" => "g.png", "why" => 5}
          ])
        )

      assert [%{role: :user}, notice] = Conversations.transcript(chat.id)

      assert notice.text ==
               "A file sent with a message could not be put where the agent reads it: g.png."
    end

    test "draws no line for a turn with no lost files, or only entries that are not files",
         %{chat: chat} do
      {:ok, _chat} = Conversations.record_turn(chat, Map.put(turn(1, 0.01), "files_lost", []))

      {:ok, _chat} =
        Conversations.record_turn(chat, Map.put(turn(2, 0.01), "files_lost", ["junk"]))

      assert [%{role: :user}] = Conversations.transcript(chat.id)
    end

    test "a turn that committed draws no notice", %{chat: chat} do
      text(chat, "Done.")
      {:ok, _chat} = Conversations.record_turn(chat, turn(1, 0.01))

      assert [%{role: :user}, %{role: :assistant}] = Conversations.transcript(chat.id)
    end
  end

  # A turn the harness ended on an error, which a Codex turn that could run no command is: it
  # completed, and every tool call in it failed. The person in the chat has to be told, in the
  # transcript, because the reply alone reads as a turn that went well.
  describe "a turn the harness ended on an error" do
    setup %{project: project} do
      {:ok, chat} = Conversations.open(project, "bring this up to date")

      chat_started!(chat)
      %{chat: chat}
    end

    defp failed_turn(chat, harness, extra \\ %{}) do
      base = turn(1, 0.01)

      {:ok, _chat} =
        Conversations.record_turn(
          chat,
          base |> Map.merge(extra) |> Map.update!("harness", &Map.merge(&1, harness))
        )
    end

    test "says so in the transcript, with the reason", %{chat: chat} do
      text(chat, "I could not run it.")

      failed_turn(chat, %{
        "subtype" => "error_during_execution",
        "is_error" => true,
        "result" => "Code Mode is unavailable because failed to spawn code-mode host"
      })

      assert [%{role: :user}, %{role: :assistant}, notice] = Conversations.transcript(chat.id)
      assert notice.role == :notice
      assert notice.turn == 1

      assert notice.text ==
               "This turn failed: Code Mode is unavailable because failed to spawn code-mode host"
    end

    test "says so without a reason when the harness gave none", %{chat: chat} do
      failed_turn(chat, %{"subtype" => "error_max_turns", "is_error" => true})

      assert [%{role: :user}, %{role: :notice, text: "This turn failed."}] =
               Conversations.transcript(chat.id)
    end

    # A reason that is an empty string is no reason: "This turn failed: " with nothing after it
    # reads as a line cut off.
    test "says so without a reason when the harness's was empty", %{chat: chat} do
      failed_turn(chat, %{"is_error" => true, "result" => ""})

      assert [%{role: :user}, %{role: :notice, text: "This turn failed."}] =
               Conversations.transcript(chat.id)
    end

    test "keeps no more of the reason than a line's worth, and none of a good turn's reply", %{
      chat: chat
    } do
      failed_turn(chat, %{"is_error" => true, "result" => String.duplicate("x", 5_000)})

      assert %{payload: %{"error" => error}} = Forge.Events.latest_for_job(chat.id, "chat.turn")
      assert String.length(error) == 500

      {:ok, other} = Conversations.open(Repo.get!(Forge.Projects.Project, chat.project_id), "x")
      failed_turn(other, %{"is_error" => false, "result" => "Done, and here is the whole reply."})

      assert %{payload: %{"error" => nil, "is_error" => false}} =
               Forge.Events.latest_for_job(other.id, "chat.turn")
    end

    # An operator's Stop reports the same subtype as a failure, and is not one
    # (`docs/design/conversations.md` § Turns).
    test "is not said of a turn the operator stopped", %{chat: chat} do
      text(chat, "Working on")

      failed_turn(
        chat,
        %{"subtype" => "error_during_execution", "is_error" => true, "result" => "stopped"},
        %{"interrupted" => true}
      )

      assert [%{role: :user}, %{role: :assistant}] = Conversations.transcript(chat.id)
    end

    test "a turn that went well draws no notice", %{chat: chat} do
      failed_turn(chat, %{"is_error" => false, "result" => "Done."})

      assert [%{role: :user}] = Conversations.transcript(chat.id)
    end

    test "sits beside the line for a turn that also did not commit, once each", %{chat: chat} do
      failed_turn(
        chat,
        %{"is_error" => true, "result" => "nope"},
        %{"commit" => nil, "uncommitted" => %{"reason" => "not_committed"}}
      )

      assert [%{role: :user}, one, two] = Conversations.transcript(chat.id)

      assert Enum.sort([one.text, two.text]) ==
               ["Nothing from this turn reached the branch.", "This turn failed: nope"]
    end
  end

  describe "the projection" do
    setup %{project: project} do
      {:ok, chat} = Conversations.open(project, "first")

      chat_started!(chat)
      %{chat: chat}
    end

    # Each `text` event is one content block of the agent's reply — the harness emits one per
    # block, not one per streamed fragment (`claude-code-events.md` § Emitted events). Joined
    # with nothing between them, the sentence before a tool call ran into the one after it:
    # "…the parser.Found it". The blocks stay apart in the turn's items, and the text a reader
    # of the whole reply gets — the replay, the queue, a question's parse — has a blank line
    # between them.
    test "a turn's text blocks stay apart", %{chat: chat} do
      text(chat, "Let me look at the parser.")
      text(chat, "Found it.")
      {:ok, _} = Conversations.record_turn(chat, turn(1, 0.01))

      assert [%{role: :user}, %{role: :assistant} = reply] = Conversations.messages(chat.id)
      assert reply.text == "Let me look at the parser.\n\nFound it."
      assert reply.items == [{:text, "Let me look at the parser."}, {:text, "Found it."}]
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

    # The turn in the order it happened: what it said, what it did, what it said next. The text
    # of the reply is still only what it said — the actions are items between the blocks.
    test "a turn is its text blocks with the actions between them, in order", %{chat: chat} do
      text(chat, "Reading the parser.")
      tool_use(chat, "t1", "Read", %{"file_path" => "lib/parser.ex"})
      tool_result(chat, "t1", false, "defmodule Parser")
      tool_use(chat, "t2", "Bash", %{"command" => "mix test"})
      tool_result(chat, "t2", true, "1 failure")
      text(chat, "One test fails.")
      {:ok, _} = Conversations.record_turn(chat, turn(1, 0.01))

      # The calls are the transcript's: `messages/1` reads the words and not the harness's calls.
      assert [%{role: :user}, %{role: :assistant, text: text, items: items}] =
               chat.id |> Conversations.transcript() |> Conversations.said()

      assert text == "Reading the parser.\n\nOne test fails."

      assert [
               {:text, "Reading the parser."},
               {:action, %{id: "t1", name: "Read", result: %{is_error: false}}},
               {:action,
                %{id: "t2", name: "Bash", result: %{is_error: true, excerpt: "1 failure"}}},
               {:text, "One test fails."}
             ] = items
    end

    # A call whose result has not arrived is the call the agent is in the middle of: it is what
    # the now line says, and it has no result to show yet.
    test "a call with no result yet is open", %{chat: chat} do
      tool_use(chat, "t1", "Bash", %{"command" => "mix test"})

      assert [%{role: :user}, %{role: :assistant, turn: nil, items: [{:action, action}]}] =
               Conversations.transcript(chat.id)

      assert action.result == nil
    end

    # A subagent's calls carry the `Task` that started them as their parent, and fold under it
    # rather than interleaving with the agent's own. Its words are not the agent's reply.
    test "a subagent's calls fold under the task that started them", %{chat: chat} do
      tool_use(chat, "task", "Task", %{"description" => "find the lexer"})
      tool_use(chat, "sub", "Grep", %{"pattern" => "lex"}, "task")
      text(chat, "subagent musing", "task")
      tool_result(chat, "sub", false, "lib/lexer.ex", "task")
      tool_result(chat, "task", false, "It is in lib/lexer.ex")
      text(chat, "The lexer is in lib/lexer.ex.")
      {:ok, _} = Conversations.record_turn(chat, turn(1, 0.01))

      [_user, reply] = chat.id |> Conversations.transcript() |> Conversations.said()

      assert [{:action, task}, {:text, "The lexer is in lib/lexer.ex."}] = reply.items
      assert task.name == "Task"
      assert [%{id: "sub", name: "Grep", result: %{is_error: false}}] = task.children
      refute reply.text =~ "subagent musing"
    end

    # The page draws a turn that has only acted so far — that is what live lines are — but a
    # reply that said nothing is not a reply to anyone reading the conversation as words: the
    # queue, the replay and the push read `messages/1`, which is what it was before.
    test "a turn that only acted is in the transcript and not in the messages", %{chat: chat} do
      tool_use(chat, "t1", "Read", %{"file_path" => "README.md"})
      tool_result(chat, "t1", false, "# readme")
      {:ok, _} = Conversations.record_turn(chat, turn(1, 0.01))

      assert [%{role: :user}, %{role: :assistant, text: ""}] = Conversations.transcript(chat.id)
      assert [%{role: :user}] = Conversations.messages(chat.id)
    end

    # A message *taken* in the middle of a turn — which is where a log from before protocol 15 has
    # its delivery, the harness having echoed it then — splits the reply on the page, but the turn
    # is still one turn: the call made before it gets its result after it, and the turn's end
    # closes both halves.
    test "a turn split by a message taken mid-turn is still one turn", %{chat: chat} do
      text(chat, "Running the tests.")
      tool_use(chat, "k1", "Task", %{"description" => "find the lexer"})
      tool_use(chat, "t1", "Bash", %{"command" => "mix test"})
      {:ok, event} = Conversations.send(chat, "also check the lexer")
      delivered(chat, to_string(event.seq))
      tool_use(chat, "k1a", "Grep", %{"pattern" => "lex"}, "k1")
      tool_result(chat, "t1", true, "1 failure")
      tool_result(chat, "k1", false, "found it")
      text(chat, "One failure.")
      {:ok, _} = Conversations.record_turn(chat, turn(1, 0.01))

      assert [_first, before, %{role: :user}, later] = Conversations.transcript(chat.id)

      assert [
               {:text, "Running the tests."},
               {:action, %{id: "k1", result: %{}, children: [%{id: "k1a"}]}},
               {:action, %{id: "t1", result: %{is_error: true, excerpt: "1 failure"}}}
             ] = before.items

      assert [{:text, "One failure."}] = later.items
      assert before.turn == 1
      assert later.turn == 1
    end

    # Tool ids are unique, so a result pairs with its call wherever the call is — here one that
    # arrives after the turn it belongs to was closed.
    test "a result pairs with its call in an earlier turn", %{chat: chat} do
      tool_use(chat, "t1", "Bash", %{"command" => "mix test"})
      text(chat, "Started it.")
      {:ok, _} = Conversations.record_turn(chat, turn(1, 0.01))
      tool_result(chat, "t1", false, "ok")

      assert [_user, %{items: [{:action, %{id: "t1", result: %{excerpt: "ok"}}}, _text]}] =
               Conversations.transcript(chat.id)
    end

    # A reply cut off when its process stopped is closed by the next process starting: what
    # the new one says is its own, and the cut-off one stays unfinished.
    test "a new process closes the reply the last one was cut off in", %{chat: chat} do
      text(chat, "I was say")

      {:ok, _started} =
        Events.append("job.started", :system, %{job_id: chat.id, payload: %{}})

      text(chat, "Back again.")
      {:ok, _} = Conversations.record_turn(chat, turn(1, 0.01))

      assert [_user, cut_off, reply] = Conversations.transcript(chat.id)
      assert %{text: "I was say", turn: nil} = cut_off
      assert %{text: "Back again.", turn: 1} = reply
    end

    # The agent wrote the input, and a model sometimes sends a field in the wrong type — the
    # harness answers with an error, but the call is in the log for ever. The fold gives each
    # field the type the page reads it as, rather than a page that raises on every mount.
    test "takes a call whose fields have the wrong types", %{chat: chat} do
      harness(chat, "job.harness.tool_use", %{
        id: "x1",
        name: %{"not" => "a name"},
        input: "a string"
      })

      harness(chat, "job.harness.tool_result", %{tool_use_id: "x1", is_error: true, excerpt: 42})
      harness(chat, "job.harness.text", %{text: 7})

      assert [_user, %{items: [{:action, action}, {:text, ""}]}] =
               Conversations.transcript(chat.id)

      assert %{name: nil, input: %{}, result: %{excerpt: ""}} = action
    end

    # Calls made together come back together, and each result is its own call's, whichever of
    # them it arrives after.
    test "calls made at once each pair with their own result", %{chat: chat} do
      tool_use(chat, "a", "Bash", %{"command" => "mix test"})
      tool_use(chat, "b", "Bash", %{"command" => "mix format"})
      tool_result(chat, "a", true, "a failed")
      tool_result(chat, "b", false, "b ok")

      assert [
               _user,
               %{
                 items: [
                   {:action, %{id: "a", result: %{excerpt: "a failed"}}},
                   {:action, %{id: "b", result: %{excerpt: "b ok"}}}
                 ]
               }
             ] = Conversations.transcript(chat.id)
    end

    test "a subagent's calls stay in the order it made them", %{chat: chat} do
      tool_use(chat, "task", "Task", %{"description" => "find the lexer"})
      tool_use(chat, "s1", "Grep", %{"pattern" => "lex"}, "task")
      tool_use(chat, "s2", "Read", %{"file_path" => "lib/lexer.ex"}, "task")
      tool_use(chat, "s3", "Bash", %{"command" => "mix compile"}, "task")

      assert [_user, %{items: [{:action, %{children: children}}]}] =
               Conversations.transcript(chat.id)

      assert Enum.map(children, & &1.id) == ~w(s1 s2 s3)
    end

    # The log was written out of order, or the task's own call was lost: the child is still a
    # call the agent made, and drawn where it can be seen.
    test "a subagent's call whose task is nowhere is drawn at the top level", %{chat: chat} do
      tool_use(chat, "orphan", "Grep", %{"pattern" => "lex"}, "missing")

      assert [_user, %{items: [{:action, %{id: "orphan"}}]}] = Conversations.transcript(chat.id)
    end

    # The words of a reply, as the queue and the replay read them: each block trimmed, and a
    # block that is only whitespace — a model's trailing newline — not a paragraph.
    test "a reply's text is its blocks trimmed, without the empty ones", %{chat: chat} do
      text(chat, "  Hello.  \n")
      text(chat, "   \n ")
      text(chat, "World.")
      {:ok, _} = Conversations.record_turn(chat, turn(1, 0.01))

      assert [_user, %{text: "Hello.\n\nWorld."}] = Conversations.messages(chat.id)
    end

    test "notices and the harness's bookkeeping stay out of the conversation", %{chat: chat} do
      :ok =
        Jobs.record_harness_event(chat.id, %{
          type: "job.harness.notice",
          payload: %{subtype: "plugin_install"}
        })

      text(chat, "done")
      {:ok, _} = Conversations.record_turn(chat, turn(1, 0.01))

      assert [%{role: :user}, %{role: :assistant, text: "done", items: [{:text, "done"}]}] =
               Conversations.messages(chat.id)
    end
  end

  describe "the now line" do
    setup %{project: project} do
      {:ok, chat} = Conversations.open(project, "first")

      chat_started!(chat)
      %{chat: chat}
    end

    test "is the call that has no result yet", %{chat: chat} do
      tool_use(chat, "t1", "Read", %{"file_path" => "lib/router.ex"})
      tool_result(chat, "t1", false, "ok")
      tool_use(chat, "t2", "Bash", %{"command" => "mix test"})

      assert {:action, %{id: "t2"}} = Conversations.now(Events.for_job(chat.id))
    end

    # Calls made at once are all open; the one made last is what the agent is waiting on now.
    test "is the last call made, of several with no result", %{chat: chat} do
      tool_use(chat, "t1", "Read", %{"file_path" => "lib/router.ex"})
      tool_use(chat, "t2", "Bash", %{"command" => "mix test"})

      assert {:action, %{id: "t2"}} = Conversations.now(Events.for_job(chat.id))
    end

    test "is a subagent's latest call, of several with no result", %{chat: chat} do
      tool_use(chat, "task", "Task", %{"description" => "find the lexer"})
      tool_use(chat, "s1", "Grep", %{"pattern" => "lex"}, "task")
      tool_use(chat, "s2", "Read", %{"file_path" => "lib/lexer.ex"}, "task")

      assert {:action, %{id: "s2"}} = Conversations.now(Events.for_job(chat.id))
    end

    # A `Task` is open for as long as its subagent works, so it is always the outer answer.
    # What the subagent is doing inside it is the one worth saying.
    test "is the subagent's call, inside a task that is waiting on it", %{chat: chat} do
      tool_use(chat, "task", "Task", %{"description" => "find the lexer"})
      tool_use(chat, "sub", "Grep", %{"pattern" => "lex"}, "task")

      assert {:action, %{id: "sub"}} = Conversations.now(Events.for_job(chat.id))
    end

    # A message sent mid-turn is queued behind the call in flight; the call is still what the
    # agent is doing.
    test "is still the call in flight after a message is sent mid-turn", %{chat: chat} do
      tool_use(chat, "t1", "Bash", %{"command" => "mix test"})
      {:ok, _event} = Conversations.send(chat, "also check the lexer")

      assert {:action, %{id: "t1"}} = Conversations.now(Events.for_job(chat.id))
    end

    test "is a retry, while the harness is retrying", %{chat: chat} do
      tool_use(chat, "t1", "Bash", %{"command" => "mix test"})
      harness(chat, "job.harness.retry", %{attempt: 2, max_retries: 10})

      assert {:retrying, 2, 10} = Conversations.now(Events.for_job(chat.id))
    end

    test "is a limit that stopped it, with when it resumes", %{chat: chat} do
      harness(chat, "job.harness.rate_limit", %{status: "rejected", resets_at: 1_790_000_000})

      assert {:rate_limited, %DateTime{}} = Conversations.now(Events.for_job(chat.id))
    end

    # A reset outside the calendar — a milliseconds value — is a limit without a time, not a
    # page that cannot mount.
    test "is a limit without a time when its reset cannot be read", %{chat: chat} do
      harness(chat, "job.harness.rate_limit", %{status: "rejected", resets_at: 1_790_000_000_000})

      assert {:rate_limited, nil} = Conversations.now(Events.for_job(chat.id))
    end

    # Once its result has arrived, a call split from the rest of its turn by a message is not
    # what the agent is doing any more.
    test "is not a call whose result arrived after a message was sent", %{chat: chat} do
      tool_use(chat, "t1", "Bash", %{"command" => "mix test"})
      {:ok, _event} = Conversations.send(chat, "also")
      tool_result(chat, "t1", false, "ok")

      assert Conversations.now(Events.for_job(chat.id)) == nil
    end

    test "is what memory did, until the agent does something else", %{chat: chat} do
      tool_use(chat, "t1", "Bash", %{"command" => "gradle build"})
      harness(chat, "job.harness.memory", %{what: "oom_kill", oom_kills: 1})

      assert {:memory, %{"what" => "oom_kill", "oom_kills" => 1}} =
               Conversations.now(Events.for_job(chat.id))

      tool_use(chat, "t2", "Bash", %{"command" => "gradle build --max-workers=1"})
      assert {:action, %{id: "t2"}} = Conversations.now(Events.for_job(chat.id))
    end

    # A limit that did not stop anything is the provider saying how full the window is. It is
    # not what the agent is doing.
    test "is not a limit that allowed the request", %{chat: chat} do
      harness(chat, "job.harness.rate_limit", %{status: "allowed", resets_at: 1_790_000_000})

      assert Conversations.now(Events.for_job(chat.id)) == nil
    end

    # Once something has come back since, the retry is over — the now line says what is
    # happening, not the last thing that went wrong.
    test "is no longer a retry once the turn has moved on", %{chat: chat} do
      harness(chat, "job.harness.retry", %{attempt: 1, max_retries: 10})
      text(chat, "Back.")

      assert Conversations.now(Events.for_job(chat.id)) == nil
    end

    test "is the call made after a retry, not the retry", %{chat: chat} do
      harness(chat, "job.harness.retry", %{attempt: 1, max_retries: 10})
      tool_use(chat, "t1", "Bash", %{"command" => "mix test"})

      assert {:action, %{id: "t1"}} = Conversations.now(Events.for_job(chat.id))
    end

    test "is nothing once the turn has ended", %{chat: chat} do
      tool_use(chat, "t1", "Bash", %{"command" => "mix test"})
      {:ok, _} = Conversations.record_turn(chat, turn(1, 0.01))

      assert Conversations.now(Events.for_job(chat.id)) == nil
    end
  end

  describe "what the next process starts with" do
    setup %{project: project} do
      {:ok, chat} = Conversations.open(project, "hello")

      chat_started!(chat)
      %{chat: chat}
    end

    defp assigned_spec(chat) do
      chat = Jobs.get!(chat.id)
      Jobs.assignment(chat, nil, Projects.get!(chat.project_id), "token")["spec"]
    end

    test "a first start opens with what the person said, and has nothing to replay", %{
      chat: chat
    } do
      spec = assigned_spec(chat)

      assert spec["prompt"] == "hello"
      assert spec["replay"] == nil
    end

    # Pushed to a conversation with no worker, a message was logged as undelivered and went
    # nowhere. It is after the last reply like any unanswered message, so it is answered.
    test "what was said while it waited for a machine is part of its opening", %{chat: chat} do
      {:ok, _event} = Conversations.send(chat, "and one more thing")

      assert assigned_spec(chat)["prompt"] == "hello\n\nand one more thing"
    end

    # The defect this exists for. A reopen was handed the first `chat.message` as its prompt, so
    # the new process answered the opening message a second time, as though new, and knew
    # nothing said after it. Two exchanges, so that a split at the *first* reply would leave the
    # second question looking unanswered and be caught.
    test "a conversation carried on is given what was said, and only the new message to answer",
         %{
           chat: chat
         } do
      text(chat, "It is a game.")
      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.01))
      {:ok, event} = Conversations.send(chat, "which engine?")
      delivered(chat, to_string(event.seq))
      text(chat, "Its own.")
      {:ok, chat} = Conversations.record_turn(chat, turn(2, 0.02))
      {:ok, chat} = Conversations.ended(chat, nil, "idle")
      {:ok, _event} = Conversations.send(chat, "and the lexer?")
      chat = Jobs.get!(chat.id)

      spec = assigned_spec(chat)

      # The message that started it again is what it answers, and is not in the replay.
      assert spec["prompt"] == "and the lexer?"

      # All four, in the order they were said, each saying who said it.
      replay = spec["replay"]

      positions =
        Enum.map(
          ["## The person", "hello", "## You", "It is a game.", "which engine?", "Its own."],
          fn needle -> :binary.match(replay, needle) |> elem(0) end
        )

      assert positions == Enum.sort(positions)
      assert replay =~ ~r/## The person[^\n]*\n\nwhich engine\?/
      assert replay =~ ~r/## You[^\n]*\n\nIts own\./
      refute replay =~ "and the lexer?"
    end

    test "what the person says after the machine is released is what it answers, not replayed", %{
      chat: chat
    } do
      text(chat, "It is a game.")
      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.01))
      {:ok, chat} = Conversations.ended(chat, nil, "idle")
      {:ok, _event} = Conversations.send(chat, "does it still build?")
      chat = Jobs.get!(chat.id)

      spec = assigned_spec(chat)

      assert spec["prompt"] == "does it still build?"
      assert spec["replay"] =~ "It is a game."
      refute spec["replay"] =~ "does it still build?"
    end

    # Every reopen clears `out/`, resumed or cold, so a project chat's own documents
    # were gone from its view — while a ticket chat's came back as the ticket's. Now it is handed
    # what it last wrote of each, and not its proposals, which are backlog and not documents.
    test "a project chat carried on is handed what it wrote, at its latest", %{chat: chat} do
      {:ok, chat} =
        Conversations.record_turn(
          chat,
          Map.merge(turn(1, 0.01), %{
            "documents" => %{"notes.md" => "# One\n"},
            "proposals" => %{
              "later.md" => %{"title" => "Later", "body" => "b", "raw" => "# Later\n\nb\n"}
            }
          })
        )

      {:ok, chat} =
        Conversations.record_turn(
          chat,
          Map.put(turn(2, 0.02), "documents", %{"notes.md" => "# Two\n"})
        )

      {:ok, chat} = Conversations.ended(chat, nil, "idle")
      {:ok, _event} = Conversations.send(chat, "go on")
      chat = Jobs.get!(chat.id)

      assert [%{"name" => "notes.md", "version" => 2, "content" => "# Two\n"}] =
               assigned_spec(chat)["inputs"]
    end

    # The other half, so the two cannot be swapped: a ticket chat's inputs are the ticket's.
    test "a ticket chat is handed the ticket's documents, not its own scope", %{project: project} do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
      {:ok, chat} = Conversations.open(project, "about this", ticket: ticket)

      {:ok, _chat} =
        Conversations.record_turn(
          chat,
          Map.put(turn(1, 0.01), "documents", %{"notes.md" => "# N\n"})
        )

      chat = Jobs.get!(chat.id)
      spec = Jobs.assignment(chat, ticket, project, "token")["spec"]

      assert spec["inputs"] |> Enum.map(& &1["name"]) |> Enum.sort() == ["notes.md", "ticket"]
    end

    # Except the message: a ticket chat is handed the one *it* wrote, because that is what a
    # merge of its branch would say, and never the ticket's, which is about the whole changeset
    # (`docs/design/conversations.md` § Commits). Both exist here, so the two cannot be confused.
    test "a ticket chat is handed its own commit message and not the ticket's", %{
      project: project
    } do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
      {:ok, chat} = Conversations.open(project, "about this", ticket: ticket)

      {:ok, _version} =
        Forge.Artifacts.record_version(ticket.id, "commit-message", :document, :system, %{
          content: "The ticket's whole change\n"
        })

      {:ok, _chat} =
        Conversations.record_turn(
          chat,
          Map.put(turn(1, 0.01), "documents", %{"commit-message" => "Just the note\n"})
        )

      chat = Jobs.get!(chat.id)
      spec = Jobs.assignment(chat, ticket, project, "token")["spec"]

      assert [%{"content" => "Just the note\n"}] =
               Enum.filter(spec["inputs"], &(&1["name"] == "commit-message"))
    end

    # And nothing of the ticket's where the conversation wrote none: there is no message for this
    # branch yet, which is what the page says and what a merge of it is refused for.
    test "a ticket chat that wrote no commit message is handed none", %{project: project} do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
      {:ok, chat} = Conversations.open(project, "about this", ticket: ticket)

      {:ok, _version} =
        Forge.Artifacts.record_version(ticket.id, "commit-message", :document, :system, %{
          content: "The ticket's whole change\n"
        })

      chat = Jobs.get!(chat.id)
      spec = Jobs.assignment(chat, ticket, project, "token")["spec"]

      assert Enum.filter(spec["inputs"], &(&1["name"] == "commit-message")) == []
    end

    # `docs/design/conversations.md` § Taking a transition: what the chat is told it may ask for
    # is the same set a person is offered, with each edge's `approve` list attached, and whether
    # a job of the state was live when the process started.
    test "a ticket chat's spec carries the transitions, the pending decision and the live job",
         %{project: project} do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
      {:ok, chat} = Conversations.open(project, "about this", ticket: ticket)

      # `refining` declares one edge, to `planning`, approving `refinement.md` — which has no
      # version yet, so a person is offered nothing and neither is the chat.
      spec = Jobs.assignment(chat, ticket, project, "token")["spec"]
      assert spec["moving"]["transitions"] == []
      assert spec["moving"]["pending"] == nil
      # The admission's own job is pending for `refining`, which is a live job.
      assert spec["moving"]["job_live"] == true

      {:ok, _version} =
        Forge.Artifacts.record_version(ticket.id, "refinement.md", :document, :system, %{
          content: "---\noutcome: done\n---\n# R\n"
        })

      spec = Jobs.assignment(chat, Tickets.get!(ticket.id), project, "token")["spec"]

      assert spec["moving"]["transitions"] == [
               %{"to" => "planning", "approve" => ["refinement.md"]}
             ]

      # Every other state is a jump, with what its job still lacks: `implementing` reads `plan.md`,
      # and `merged` needs a changeset and a commit message; the arrow's target is not among them.
      jumps = Map.new(spec["moving"]["jumps"], &{&1["to"], &1})
      assert jumps["implementing"]["missing"] == ["plan.md"]
      assert jumps["merged"]["merges"] == true
      assert "changeset" in jumps["merged"]["missing"]
      refute Map.has_key?(jumps, "planning")

      # And `job_live` is the state's own answer rather than a constant: with the admission's
      # job put to rest, a conversation starting now is told nothing is in its way.
      finish_jobs(Tickets.get!(ticket.id))
      spec = Jobs.assignment(chat, Tickets.get!(ticket.id), project, "token")["spec"]
      assert spec["moving"]["job_live"] == false
    end

    # **Two edges, one target, only one offerable.** The filter is per edge, so a manifest built
    # by intersecting on the *target* carries the dead edge's `approve` list too — telling the
    # agent a transition approves a document that has no version, which taking it is refused
    # for. `Engine.offered_edges/2` is the one walk both halves read
    # (`docs/design/conversations.md` § Taking a transition).
    test "a target reached by two edges carries only the offerable edge's approvals", %{
      project: project
    } do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)

      # A second way from `refining` to `planning`, approving a document nothing has written.
      ticket = second_edge!(ticket, "notes.md")

      {:ok, version} =
        Forge.Artifacts.record_version(ticket.id, "refinement.md", :document, :system, %{
          content: "---\noutcome: done\n---\n# R\n"
        })

      assert version
      {:ok, chat} = Conversations.open(project, "about this", ticket: ticket)
      finish_jobs(ticket)

      spec = Jobs.assignment(chat, Tickets.get!(ticket.id), project, "token")["spec"]

      # `approve` carries only the surviving edge's names: the dead edge is not offered, so it is
      # neither taken nor named.
      assert spec["moving"]["transitions"] == [
               %{"to" => "planning", "approve" => ["refinement.md"]}
             ]

      # The page is offered the same target, which is what makes the two agree.
      assert Forge.Engine.offered_transitions(
               Tickets.get!(ticket.id),
               Tickets.workflow(Tickets.get!(ticket.id))
             ) == ["planning"]
    end

    # The pinning stopped parsing. `moving/1` runs for every ticket chat assignment, inside
    # `assign/2` after the row is already `:running`, so `Tickets.workflow/1` — which raises —
    # would fail the job on exactly the broken ticket a conversation is the way to rescue.
    test "a ticket whose workflow no longer parses still gets a spec, with nothing offered", %{
      project: project
    } do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
      {:ok, chat} = Conversations.open(project, "about this", ticket: ticket)
      ticket = ticket |> Ecto.Changeset.change(%{workflow: %{}}) |> Repo.update!()

      spec = Jobs.assignment(chat, ticket, project, "token")["spec"]

      assert spec["moving"]["transitions"] == []
      assert spec["moving"]["workflow_broken"] == true
    end

    # **A chat's project and its ticket's must be the same one.** Nothing crossed them before, so
    # this was tidy rather than load-bearing; a transition request guards membership of the
    # *ticket's* project while `send_chat/4` guards the *chat's*, so a mismatched pair would let
    # a member of one project move another's ticket.
    test "a conversation cannot be opened on another project's ticket", %{project: project} do
      theirs = ticket_fixture(%{project: project_fixture()})

      assert Conversations.open(project, "move it", ticket: theirs) ==
               {:error, :ticket_not_in_project}

      # Its own project's ticket is unaffected, so the guard is the pairing and not the ticket.
      {:ok, ours} = Tickets.admit(project, %{title: "Ours"}, :system)
      assert {:ok, _chat} = Conversations.open(project, "move it", ticket: ours)
    end

    # Two offered edges to one target, one of them the bare edge: the request is the bare edge,
    # and the manifest lists the target once, as a transition (`ForgeCore.Engine.route/4`).
    test "a target two edges reach is a transition when one of them is the bare edge", %{
      project: project
    } do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
      ticket = second_edge!(ticket, "refinement.md")

      {:ok, _version} =
        Forge.Artifacts.record_version(ticket.id, "refinement.md", :document, :system, %{
          content: "---\noutcome: done\n---\n# R\n"
        })

      {:ok, chat} = Conversations.open(project, "about this", ticket: ticket)
      finish_jobs(ticket)

      spec = Jobs.assignment(chat, Tickets.get!(ticket.id), project, "token")["spec"]

      assert [%{"to" => "planning"}] = spec["moving"]["transitions"]
      refute "planning" in Enum.map(spec["moving"]["jumps"], & &1["to"])
    end

    # Two edges to one target and no bare one among them used to be refused every time as
    # ambiguous; the target is a jump now, listed as one and not among the transitions.
    test "a target two edges reach with no bare edge is listed as a jump", %{project: project} do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)

      ticket = no_bare_edge!(ticket)

      {:ok, _version} =
        Forge.Artifacts.record_version(ticket.id, "refinement.md", :document, :system, %{
          content: "---\noutcome: done\n---\n# R\n"
        })

      {:ok, chat} = Conversations.open(project, "about this", ticket: ticket)
      finish_jobs(ticket)

      spec = Jobs.assignment(chat, Tickets.get!(ticket.id), project, "token")["spec"]

      assert spec["moving"]["transitions"] == []
      assert Enum.find(spec["moving"]["jumps"], &(&1["to"] == "planning"))
    end

    # The edge the person would be offered when its document is unversioned is not offered, and
    # the one that is offered is the one a request takes.
    test "a target with one of its two edges filtered out is the surviving edge", %{
      project: project
    } do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)

      # Two edges to `planning`: the original approving `refinement.md`, and a second approving
      # `notes.md`, which nothing ever writes — so `offered_edges/2` returns only the first.
      ticket = second_edge!(ticket, "notes.md")

      {:ok, _version} =
        Forge.Artifacts.record_version(ticket.id, "refinement.md", :document, :system, %{
          content: "---\noutcome: done\n---\n# R\n"
        })

      {:ok, chat} = Conversations.open(project, "about this", ticket: ticket)
      finish_jobs(ticket)
      ticket = Tickets.get!(ticket.id)

      spec = Jobs.assignment(chat, ticket, project, "token")["spec"]

      assert [%{"to" => "planning", "approve" => ["refinement.md"]}] =
               spec["moving"]["transitions"]
    end

    test "a project chat's spec carries no transitions and no decision", %{project: project} do
      {:ok, chat} = Conversations.open(project, "about the repository")

      spec = Jobs.assignment(chat, nil, project, "token")["spec"]

      # Nil, not an empty map: a project chat has no ticket, and `if spec.moving` must be false.
      assert spec["moving"] == nil
    end

    # No `chat.turn` closed it: the machine went while the agent was still speaking. A reply
    # that stops mid-sentence would otherwise read as a finished one that trailed off.
    test "a reply the process never finished is replayed as cut off", %{chat: chat} do
      text(chat, "Let me look at the")
      {:ok, chat} = Conversations.ended(chat, nil, "worker_lost")
      {:ok, _event} = Conversations.send(chat, "are you there?")
      chat = Jobs.get!(chat.id)

      replay = assigned_spec(chat)["replay"]

      assert replay =~ ~r/## You[^\n]*cut off[^\n]*\n\nLet me look at the/
    end
  end

  describe "summaries" do
    # `waiting` is what paints a row with the accent, and `docs/design/ui.md` is explicit that the
    # accent means exactly one thing: a human is being waited on. A live conversation whose last
    # line is the person's own is waiting on the *machine*, not on them — dropping the agent-last
    # half of `turn_ended?/3` leaves every live conversation accented, and the product's one colour
    # stops meaning anything. The agent has to have spoken last *and* its turn to have ended.
    test "waiting is the agent's turn having ended, not merely being live", %{project: project} do
      {:ok, chat} = Conversations.open(project, "what is this repository?")

      assert [summary] = Conversations.summaries(project_id: project.id)
      assert summary.live
      assert summary.said == {:user, "what is this repository?"}
      refute summary.waiting

      text(chat, "It is a workflow engine.")

      # Said, but its turn has not ended: the agent is still working (`Conversations.waiting?/1`).
      assert [summary] = Conversations.summaries(project_id: project.id)
      assert summary.said == {:agent, "It is a workflow engine."}
      refute summary.waiting

      {:ok, _chat} = Conversations.record_turn(chat, turn(1, 0.01))

      assert [summary] = Conversations.summaries(project_id: project.id)
      assert summary.said == {:agent, "It is a workflow engine."}
      assert summary.waiting
    end

    # The person speaks last, and the turn that follows only acted: the last word is not the
    # agent's, so a turn after the old words is no reason to draw the conversation as waiting.
    test "a turn that only acted after the person spoke is not waiting", %{project: project} do
      {:ok, chat} = Conversations.open(project, "first")
      text(chat, "One.")
      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.01))
      {:ok, _event} = Conversations.send(chat, "second")
      {:ok, _chat} = Conversations.record_turn(Jobs.get!(chat.id), turn(2, 0.01))

      assert [%{said: {:user, "second"}} = summary] =
               Conversations.summaries(project_id: project.id)

      refute summary.waiting
      refute Conversations.waiting?(Conversations.messages(chat.id))
    end

    # The turn must be the one *after* the words: the reply of a turn the person's message began
    # is not waiting because an earlier turn ended.
    test "a turn that ended before the words did not end them", %{project: project} do
      {:ok, chat} = Conversations.open(project, "first")
      chat_started!(chat)
      text(chat, "One.")
      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.01))
      {:ok, event} = Conversations.send(chat, "second")
      delivered(chat, to_string(event.seq))
      text(chat, "Two, so far.")

      assert [summary] = Conversations.summaries(project_id: project.id)
      assert summary.said == {:agent, "Two, so far."}
      refute summary.waiting
      refute Conversations.waiting?(Conversations.messages(chat.id))

      {:ok, _chat} = Conversations.record_turn(Jobs.get!(chat.id), turn(2, 0.01))
      assert [%{waiting: true}] = Conversations.summaries(project_id: project.id)
      assert Conversations.waiting?(Conversations.messages(chat.id))
    end

    # A subagent's text is its report to the agent, not the agent speaking: the list says what
    # the agent last said, as the transcript does.
    test "what was said last is not a subagent's report", %{project: project} do
      {:ok, chat} = Conversations.open(project, "find the lexer")
      text(chat, "Looking.")
      text(chat, "found it in lib/lexer.ex", "task-1")

      assert [%{said: {:agent, "Looking."}}] = Conversations.summaries(project_id: project.id)
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

    # Last, the id: two chats used in the same second and started in the same instant are ordered
    # by it, so the list is the same list each time it is read and does not shuffle on a redraw.
    test "chats tied on use and on start are ordered by id", %{project: project} do
      {:ok, one} = Conversations.open(project, "one")
      {:ok, two} = Conversations.open(project, "two")
      at = ago(60)
      said_at(one, "x", at)
      said_at(two, "x", at)
      started(one, at)
      started(two, at)

      assert Enum.sort([one.id, two.id], :desc) ==
               Enum.map(Conversations.summaries(project_id: project.id), & &1.chat.id)
    end

    # The order is when each was last used, and not whether it is live: the split into a Live
    # section is the list's (`ForgeWeb.Conversations.list/1`), so that one rule orders every
    # caller. A finished chat used more recently sits above a live one left alone.
    test "a conversation used more recently sorts above a live one left alone", %{
      project: project
    } do
      {:ok, left_alone} = Conversations.open(project, "still running, not touched")
      {:ok, used} = Conversations.open(project, "closed, but used since")
      {:ok, _closed} = Conversations.ended(used, nil, "closed")
      said_at(left_alone, "old", ago(3600))

      assert [first, second] = Conversations.summaries(project_id: project.id)
      assert first.chat.id == used.id
      assert second.chat.id == left_alone.id
      assert second.live
    end

    # Criterion 1: used recently beats started recently. The old sort was on the start.
    test "a chat started long ago and used now sits above one started later and left alone", %{
      project: project
    } do
      {:ok, old_used} = Conversations.open(project, "started last week")
      {:ok, newer_idle} = Conversations.open(project, "started yesterday")
      started(old_used, ago(7 * 86_400))
      started(newer_idle, ago(86_400))
      said_at(newer_idle, "left alone", ago(80_000))

      assert [first, second] = Conversations.summaries(project_id: project.id)
      assert first.chat.id == old_used.id
      assert second.chat.id == newer_idle.id
      assert DateTime.compare(first.at, second.at) == :gt
    end

    # `DateTime` is a struct, so `>=` on two of them compares its fields in key order: the day
    # before the month. 31 October read as later than 1 November, and 12:05:00.9 as later than
    # 12:30:00.0 in the fraction of a second. Both are `:lt` to `DateTime.compare/2`.
    test "times are compared as times, not as structs", %{project: project} do
      {:ok, oct} = Conversations.open(project, "the thirty-first")
      {:ok, nov} = Conversations.open(project, "the first")
      said_at(oct, "a", ~U[2026-10-31 09:00:00Z])
      said_at(nov, "b", ~U[2026-11-01 09:00:00Z])

      assert [nov.id, oct.id] ==
               Enum.map(Conversations.summaries(project_id: project.id), & &1.chat.id)
    end

    # Criterion 2: nothing in the order depends on the project.
    test "chats from different projects interleave by time", %{project: project} do
      {:ok, other} =
        register_owned!(%{
          name: "other-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo()
        })

      {:ok, a1} = Conversations.open(project, "first")
      {:ok, b1} = Conversations.open(other, "second")
      {:ok, a2} = Conversations.open(project, "third")
      said_at(a1, "x", ago(300))
      said_at(b1, "x", ago(200))
      said_at(a2, "x", ago(100))

      ids = Enum.map(Conversations.summaries(), & &1.chat.id)
      assert [a2.id, b1.id, a1.id] == ids
    end

    # Criterion 3: nothing said yet is placed by the start. A workflow step's chat waiting for a
    # machine has no message, because its agent speaks first.
    test "a chat with nothing said is placed by when it started", %{project: project} do
      {:ok, newest} = Conversations.open(project, "newest")
      {:ok, oldest} = Conversations.open(project, "oldest")
      said_at(newest, "x", ago(10))
      said_at(oldest, "x", ago(1000))
      # A chat row with no event at all, as a workflow step's is before its agent speaks.
      silent =
        Repo.insert!(%Jobs.Job{project_id: project.id, kind: :chat, status: :pending, attempt: 1})

      started(silent, ago(500))

      summaries = Conversations.summaries(project_id: project.id)
      assert [newest.id, silent.id, oldest.id] == Enum.map(summaries, & &1.chat.id)
      silent_summary = Enum.find(summaries, &(&1.chat.id == silent.id))
      assert silent_summary.said == nil
      assert silent_summary.at == Jobs.get(silent.id).inserted_at
    end

    # Events are stamped to the second, so two chats used in the same second tie: the later start
    # first, and the id after that, not whatever the query returned. The starts are 12:05:00.9 and
    # 12:30:00.0, which a struct comparison reads the other way round — the fraction of a second
    # comes before the minute in the struct's key order.
    test "a tie on the time of use goes to the later start", %{project: project} do
      {:ok, early} = Conversations.open(project, "started earlier")
      {:ok, late} = Conversations.open(project, "started later")
      at = ago(60)
      said_at(early, "x", at)
      said_at(late, "x", at)
      started(early, ~U[2027-01-01 12:05:00.900000Z])
      started(late, ~U[2027-01-01 12:30:00.000000Z])

      assert [late.id, early.id] ==
               Enum.map(Conversations.summaries(project_id: project.id), & &1.chat.id)
    end
  end

  # **The lists of conversations are told, by id, what changed** (`Events.subscribe_chats/0`): the
  # message carries the project and ticket so that a list decides from its head whether it shows
  # the chat before it reads anything.
  describe "being told" do
    setup %{project: project} do
      {:ok, chat} = Conversations.open(project, "hello")
      :ok = Events.subscribe_chats()
      # `open/3` told everyone already.
      flush_chat_changes()
      %{chat: chat}
    end

    defp flush_chat_changes do
      receive do
        {:chat_changed, _, _, _} -> flush_chat_changes()
      after
        0 -> :ok
      end
    end

    test "the agent saying something names the chat, its project and its ticket", %{
      chat: chat,
      project: project
    } do
      text(chat, "Hello.")

      project_id = project.id
      chat_id = chat.id
      assert_receive {:chat_changed, ^chat_id, ^project_id, nil}
    end

    # A subagent's text is not the agent speaking, and is no row's preview: waking every open
    # list for it would redraw what has not changed, many times a turn.
    test "a subagent's report wakes nothing", %{chat: chat} do
      text(chat, "found it in lib/lexer.ex", "task-1")

      refute_receive {:chat_changed, _, _, _}, 50
    end

    # Tool calls and usage arrive many times a turn and are on no row.
    test "a tool call wakes nothing", %{chat: chat} do
      tool_use(chat, "t1", "Read", %{})

      refute_receive {:chat_changed, _, _, _}, 50
    end

    test "a workflow job's text is no conversation's" do
      job = job_fixture(%{ticket: ticket_fixture()})

      :ok =
        Jobs.record_harness_event(job.id, %{type: "job.harness.text", payload: %{text: "hi"}})

      refute_receive {:chat_changed, _, _, _}, 50
    end

    test "the person saying something wakes the lists", %{chat: chat} do
      {:ok, _event} = Conversations.send(chat, "and another thing")

      chat_id = chat.id
      assert_receive {:chat_changed, ^chat_id, _, _}
    end

    # What moves a row between the two sections is a chat starting, ending, coming back and its
    # turn finishing, and each is told on the chats topic: a ticketless chat has no ticket for
    # the ticket topic to name.
    test "starting, a turn, ending and carrying on each tell the lists", %{
      project: project,
      chat: chat
    } do
      {:ok, started} = Conversations.open(project, "another")
      started_id = started.id
      assert_receive {:chat_changed, ^started_id, _, nil}

      chat_id = chat.id
      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.01))
      assert_receive {:chat_changed, ^chat_id, _, nil}

      {:ok, chat} = Conversations.ended(chat, nil, "idle")
      assert_receive {:chat_changed, ^chat_id, _, nil}

      {:ok, _event} = Conversations.send(chat, "again")
      assert_receive {:chat_changed, ^chat_id, _, nil}
    end

    # `requeue/2` and `fail/2` are job-level, and a ticketless conversation has no ticket for the
    # ticket topic to name: it is told on the chats topic or not at all.
    test "a ticketless conversation being interrupted or failed is told", %{chat: chat} do
      {:ok, _job} = Jobs.requeue(chat.id, :worker_lost)
      chat_id = chat.id
      assert_receive {:chat_changed, ^chat_id, _, nil}

      {:ok, _job} = Jobs.fail(chat.id, :boom)
      assert_receive {:chat_changed, ^chat_id, _, nil}
    end
  end

  describe "ending" do
    setup %{project: project} do
      {:ok, chat} = Conversations.open(project, "hello")

      chat_started!(chat)
      %{chat: chat}
    end

    test "closing it finishes it; losing the machine only releases it", %{chat: chat} do
      {:ok, closed} = Conversations.ended(chat, nil, "closed")
      assert closed.status == :finished

      {:ok, other} = Conversations.open(Projects.get!(chat.project_id), "another")
      {:ok, released} = Conversations.ended(other, nil, "worker_lost")
      assert released.status == :hibernated
    end

    # Found on a running node: three conversations the gate could never place sat `pending` for
    # ever, and nothing could end them. `live?/1` counts `:pending`, so every surface offered to
    # end them — and `close/2` was a push, which for a chat with no worker logs that it was not
    # delivered and returns `:ok`. Closing has to be something the platform can do alone.
    test "a conversation that never got a machine can still be ended", %{chat: chat} do
      assert is_nil(chat.worker_id)
      assert Conversations.live?(chat)

      assert :ok = Conversations.close(chat)

      assert Jobs.get(chat.id).status == :finished
      refute Conversations.live?(Jobs.get(chat.id))
    end

    # A workflow job's completion revokes its credential and gives the worker's memory back. A
    # conversation's ending has to do the same, or the machine stays busy for ever and takes no
    # more work — which is invisible until the next thing that never gets scheduled. The
    # end-to-end run is what caught this; the earlier run passed it by luck, because a ticket's
    # job happened to release the same worker.
    test "ending it gives the machine back and revokes its credential", %{chat: chat} do
      {:ok, worker, _token} = Forge.Workers.create(%{provider: "fake"})
      {:ok, worker} = Forge.Workers.ready(worker, %{"memory_budget" => 8_000_000_000})
      {:ok, worker} = Forge.Workers.busy(worker)

      {:ok, running} =
        chat
        |> Jobs.Job.progress_changeset(%{status: :running, worker_id: worker.id})
        |> Repo.update()

      {:ok, _ended} = Conversations.ended(running, nil, "closed")

      assert Forge.Workers.get!(worker.id).status == :idle
    end

    # The machine is gone, so there is nothing for the message to reach — and a message recorded
    # with nothing to answer it is the silent drop, so sending starts the conversation again: the
    # row goes back to waiting for a machine, and the message is what the new process answers.
    test "a message to a conversation with no machine starts it again", %{chat: chat} do
      {:ok, released} = Conversations.ended(chat, nil, "worker_lost")

      assert {:ok, event} = Conversations.send(released, "leave-to-ticket")

      assert %{status: :pending, worker_id: nil, finished_at: nil} =
               restarted = Jobs.get!(chat.id)

      # The session is gone with the machine, and none was ever carried here, so the next run
      # replays the transcript instead (cold).
      assert is_nil(restarted.harness_session_id)
      assert chat.id in (Jobs.pending(10) |> Enum.map(& &1.id))
      assert event.payload == %{"text" => "leave-to-ticket"}
      assert List.last(Conversations.messages(chat.id)).text == "leave-to-ticket"
    end

    # Logged as a reopen by the sender: who restarted it, and spent from its credential pool.
    test "starting it again is one chat.reopened, and the message follows it", %{chat: chat} do
      {:ok, _released} = Conversations.ended(chat, nil, "idle")
      {:ok, message} = Conversations.send(chat, "again", actor: {:user, "someone"})

      assert [reopened] = Enum.filter(Events.for_job(chat.id), &(&1.type == "chat.reopened"))
      assert reopened.actor == %{"kind" => "user", "id" => "someone"}
      assert reopened.seq < message.seq
    end

    # Two messages at once start it once: the second finds the row already `pending`, locked, and
    # only records its message. The race itself is out of the sandbox's reach; what the second
    # finds is not.
    test "a second message to a pending row adds no second restart", %{chat: chat} do
      {:ok, _released} = Conversations.ended(chat, nil, "idle")

      {:ok, _first} = Conversations.send(chat, "one")
      {:ok, _second} = Conversations.send(chat, "two")

      events = Events.for_job(chat.id)
      assert [_once] = Enum.filter(events, &(&1.type == "chat.reopened"))
      assert Enum.count(events, &(&1.type == "chat.message")) == 3
    end

    # The caller holds whatever the page rendered with, which may be minutes old. Trusting that
    # struct is how the guard and the operation end up disagreeing: this one says `pending`, and
    # the row says its machine is gone.
    test "a stale struct saying live does not push to a machine that is gone", %{chat: chat} do
      {:ok, _released} = Conversations.ended(chat, nil, "worker_lost")

      assert chat.status == :pending
      assert {:ok, _event} = Conversations.send(chat, "still here?")
      assert [_] = Enum.filter(Events.for_job(chat.id), &(&1.type == "chat.reopened"))
    end

    # A send to one that is live is a send. Restarting a running conversation cleared the
    # `worker_id` its worker reports under — every later turn failed the channel's ownership
    # check — and queued it to be placed a second time.
    test "a message to a live conversation does not restart it", %{chat: chat, project: project} do
      {:ok, worker, _token} = Forge.Workers.create(%{provider: "fake"})

      {:ok, running} =
        chat
        |> Jobs.Job.progress_changeset(%{status: :running, worker_id: worker.id})
        |> Repo.update()

      assert {:ok, _event} = Conversations.send(running, "go on")
      # The row is asked, not the struct: one rendered after it was released says nothing now.
      assert {:ok, _event} = Conversations.send(%{running | status: :hibernated}, "and on")

      assert %{status: :running, worker_id: worker_id} = Jobs.get!(chat.id)
      assert worker_id == worker.id
      refute Enum.any?(Events.for_job(chat.id), &(&1.type == "chat.reopened"))

      # Waiting for a machine is live too.
      {:ok, waiting} = Conversations.open(project, "another")
      assert {:ok, _event} = Conversations.send(waiting, "hello")
      refute Enum.any?(Events.for_job(waiting.id), &(&1.type == "chat.reopened"))
    end

    # An idle conversation keeps its branch; a person ending it afterwards is a decision, and is
    # recorded as one — once. Ending it again, from a stale page or a crafted event, is refused
    # before anything is written.
    test "a released conversation can be ended, once", %{chat: chat, project: project} do
      {:ok, idle} = Conversations.ended(chat, nil, "idle")
      assert Git.branch_exists?(Projects.repo_path(project), "chat/" <> chat.id)

      assert :ok = Conversations.close(idle, actor: {:user, "someone"})

      refute Git.branch_exists?(Projects.repo_path(project), "chat/" <> chat.id)
      assert Conversations.ended?(chat)

      assert {:error, :ended} = Conversations.close(idle)
      # The struct the caller holds is from before; a second ending is told from the events.
      assert {:error, :ended} = Conversations.close(chat)

      assert [_idle, _closed] = Enum.filter(Events.for_job(chat.id), &(&1.type == "chat.ended"))
    end

    test "a conversation a person ended takes no message, and records nothing", %{chat: chat} do
      :ok = Conversations.close(chat)
      before = length(Events.for_job(chat.id))

      assert {:error, :ended} = Conversations.send(chat, "hello?")

      assert length(Events.for_job(chat.id)) == before
      assert Jobs.get!(chat.id).status == :finished
    end

    # Told from the events, not the status: `finished` is what the idle timeout writes too, and
    # the *newest* of ended and reopened decides, because a conversation closed before an ending
    # was final, then reopened, then lost, still carries its old `closed`.
    test "ended? reads the newest of ended and reopened, and not the status", %{chat: chat} do
      refute Conversations.ended?(chat)

      {:ok, _idle} = Conversations.ended(chat, nil, "idle")
      assert Jobs.get!(chat.id).status == :finished
      refute Conversations.ended?(chat)

      {:ok, _closed} = Conversations.ended(Jobs.get!(chat.id), nil, "closed")
      assert Conversations.ended?(chat)
      assert Conversations.ended?(chat.id)
      assert Conversations.ended_ids([chat.id]) == MapSet.new([chat.id])

      # The old ending, then a restart, then a lost machine — which writes no `chat.ended` of its
      # own, only `job.interrupted` — so the old `closed` is still the newest `chat.ended`, and the
      # restart after it is what says it is not ended any more.
      {:ok, _event} =
        Events.append("chat.reopened", :system, %{job_id: chat.id, payload: %{"branch" => "kept"}})

      refute Conversations.ended?(chat)

      {:ok, _lost} = Jobs.requeue(chat.id, :worker_lost)
      assert [_] = Enum.filter(Events.for_job(chat.id), &(&1.type == "chat.reopened"))
      refute Conversations.ended?(chat)
      assert Conversations.ended_ids([chat.id]) == MapSet.new()
    end

    test "Accept's ending is final and a cancelled ticket's is not", %{
      chat: chat,
      project: project
    } do
      {:ok, accepted} = Conversations.ended(chat, nil, "accepted")
      assert Conversations.ended?(accepted)

      {:ok, other} = Conversations.open(project, "another")
      {:ok, cancelled} = Conversations.ended(other, nil, "cancelled")
      refute Conversations.ended?(cancelled)
    end

    test "the ending says who ended it and what became of the branch", %{chat: chat} do
      assert Conversations.ending(chat) == nil

      assert :ok = Conversations.close(chat, actor: {:user, "someone"})

      assert %{by: %{"kind" => "user", "id" => "someone"}, branch: branch, at: %DateTime{}} =
               Conversations.ending(chat)

      # Nothing was pushed to it, so it is on the default branch already and goes with a pin.
      assert branch == :deleted
    end

    # A message to a released conversation is refused for exactly the reasons Reopen was.
    test "a conversation whose machine was released is not carried on once it is ended", %{
      chat: chat
    } do
      {:ok, _released} = Conversations.ended(chat, nil, "idle")
      assert Conversations.sendable(Repo, Jobs.get!(chat.id)) == :ok
      assert Conversations.sendable?(Jobs.get!(chat.id))

      :ok = Conversations.close(chat)

      assert Conversations.sendable(Repo, Jobs.get!(chat.id)) == {:error, :ended}
      refute Conversations.sendable?(Jobs.get!(chat.id))
    end

    test "a release that is lost, or has said nothing, reads as a lost reply", %{chat: chat} do
      {:ok, event} = Conversations.send(chat, "anyone there?")
      {:ok, released} = Conversations.ended(Jobs.get!(chat.id), nil, "worker_lost")

      assert Conversations.lost?(released, Conversations.messages(chat.id))

      delivered(chat, to_string(event.seq))
      text(chat, "yes")
      {:ok, _chat} = Conversations.record_turn(Jobs.get!(chat.id), turn(1, 0.01))
      refute Conversations.lost?(released, Conversations.messages(chat.id))
      # A live one is working, not lost.
      refute Conversations.lost?(chat, [%{role: :user}])
    end

    # `Jobs.assign/2` puts a row back to pending when the assignment cannot be pushed, and leaves
    # the worker it chose on it. Asked whether the row named a worker, a close went to a machine
    # that never had the conversation, and the row stayed pending with nobody to end it.
    test "a pending conversation that still names a worker is ended here", %{chat: chat} do
      {:ok, worker, _token} = Forge.Workers.create(%{provider: "fake"})
      {:ok, worker} = Forge.Workers.ready(worker, %{"memory_budget" => 8_000_000_000})
      :ok = Forge.Workers.connected(worker.id)

      {:ok, pending} =
        chat |> Jobs.Job.progress_changeset(%{worker_id: worker.id}) |> Repo.update()

      assert pending.status == :pending

      assert :ok = Conversations.close(pending)

      refute_received {"close", _payload}
      assert Jobs.get!(chat.id).status == :finished
    end

    # A scheduling pass holds the rows it read for as long as it runs. A close in the meantime
    # ended the row and deleted the branch, and the pass then marked it running from the struct
    # it held and sent it to a machine.
    test "a conversation closed during a scheduling pass is not started by it", %{
      chat: chat,
      project: project
    } do
      funded!(project)
      worker = Forge.FakeWorker.connect(project: project)
      read_by_the_pass = chat

      assert :ok = Conversations.close(chat)

      assert {:error, {:changed, :finished}} = Jobs.assign(read_by_the_pass, worker)
      assert Jobs.get!(chat.id).status == :finished
      refute_received {"assign", _payload}
      assert Git.Tokens.revoke_for_job(chat.id) == 0
    end

    # The other order: the pass got there first, so there is a process to tell, and the ending
    # recorded here for a conversation with none would leave that process running unrecorded.
    test "an ending expected of a pending row does not end one that has since started", %{
      chat: chat,
      project: project
    } do
      read_by_the_close = chat

      {:ok, _running} =
        chat |> Jobs.Job.progress_changeset(%{status: :running}) |> Repo.update()

      assert {:error, {:row, {:changed, :running}}} =
               Conversations.ended(read_by_the_close, nil, "closed", expect: :pending)

      assert Jobs.get!(chat.id).status == :running
      assert Git.branch_exists?(Projects.repo_path(project), "chat/" <> chat.id)
    end

    test "its messages survive it", %{chat: chat} do
      text(chat, "a reply")
      {:ok, _} = Conversations.record_turn(chat, turn(1, 0.01))
      {:ok, chat} = Conversations.ended(chat, nil, "closed")

      assert length(Conversations.messages(chat.id)) == 2
    end
  end

  describe "its branch, when it ends" do
    setup %{project: project} do
      {:ok, chat} = Conversations.open(project, "tidy the readme")

      chat_started!(chat)
      %{chat: chat, repo: Projects.repo_path(project)}
    end

    # What a worker's push is, without a worker: a clone of the branch, a commit, and a push by
    # path — `FORGE_INTERNAL` because the hook refuses an uncredentialed push, which is its job.
    defp push_to(repo, branch, path, content),
      do: commit_to(repo, branch, %{path => content}, "change #{path}")

    defp branch_events(chat, type),
      do: chat.id |> Events.for_job() |> Enum.filter(&(&1.type == type))

    # The abandon. The person had a merge that worked and ended the conversation instead, so the
    # work goes — and nothing is pinned, because a pin would keep exactly what closing reclaims.
    test "closing deletes a branch that was not merged, and pins nothing", %{
      chat: chat,
      repo: repo
    } do
      head = push_to(repo, "chat/" <> chat.id, "NOTES.md", "a note\n")

      assert :ok = Conversations.close(chat)

      refute Git.branch_exists?(repo, "chat/" <> chat.id)
      assert {:error, _} = Git.resolve(repo, "refs/forge/chat/#{chat.id}")

      # Its head is in the log, which is where the sha of discarded work can still be found.
      assert [event] = branch_events(chat, "chat.branch_deleted")
      assert event.payload["head"] == head
      assert event.payload["merged"] == false
    end

    # § Commits' order: the pin first, then the branch, so the merged commit is never only
    # reachable through a ref that is about to go. A chat that committed nothing has its head on
    # the default branch already, which is the same case.
    test "closing one whose work is on the default branch pins it before the branch goes", %{
      chat: chat,
      repo: repo
    } do
      {:ok, head} = Git.resolve(repo, "refs/heads/chat/" <> chat.id)

      assert :ok = Conversations.close(chat)

      refute Git.branch_exists?(repo, "chat/" <> chat.id)
      assert {:ok, ^head} = Git.resolve(repo, "refs/forge/chat/#{chat.id}")
      assert [%{payload: %{"merged" => true}}] = branch_events(chat, "chat.branch_deleted")
    end

    # A merge that conflicted deletes nothing, and neither does an ending: the branch is where the
    # work still is, and taking it by hand — what the page says to do about a conflict — needs
    # it. Asked of the merge itself, so a branch nobody tried to merge is kept the same way.
    test "a branch that would not merge cleanly survives the close", %{chat: chat, repo: repo} do
      head = push_to(repo, "chat/" <> chat.id, "README.md", "the conversation's version\n")
      push_to(repo, "main", "README.md", "someone else's version\n")

      assert :ok = Conversations.close(chat)

      assert {:ok, ^head} = Git.resolve(repo, "refs/heads/chat/" <> chat.id)
      assert [event] = branch_events(chat, "chat.branch_kept")
      assert event.payload["reason"] == "conflict"
    end

    # Nobody decided anything, so nothing is abandoned: these only release the machine, and a
    # message carries the conversation on with the work that is on its branch.
    test "going idle or losing the machine keeps the branch", %{chat: chat, repo: repo} do
      head = push_to(repo, "chat/" <> chat.id, "NOTES.md", "a note\n")

      for reason <- ["idle", "worker_lost", "ended"] do
        {:ok, chat} = Conversations.ended(chat, nil, reason)
        assert {:ok, ^head} = Git.resolve(repo, "refs/heads/chat/" <> chat.id), reason
        {:ok, _event} = Conversations.send(chat, "carry on, " <> reason)
      end

      assert branch_events(chat, "chat.branch_deleted") == []
    end

    # A conversation with a machine finishes its last turn and pushes it before the worker
    # reports. Deleted when the person asked, the branch would be pushed straight back by that
    # last turn — so it waits for the report, when nothing can push to it any more.
    test "with a machine, the branch goes when the worker reports the ending, not before", %{
      chat: chat,
      repo: repo
    } do
      {:ok, worker, _token} = Forge.Workers.create(%{provider: "fake"})
      {:ok, worker} = Forge.Workers.ready(worker, %{"memory_budget" => 8_000_000_000})
      :ok = Forge.Workers.connected(worker.id)

      {:ok, running} =
        chat
        |> Jobs.Job.progress_changeset(%{status: :running, worker_id: worker.id})
        |> Repo.update()

      :ok = Conversations.close(running)
      assert_receive {"close", %{"reason" => "closed"}}
      assert Git.branch_exists?(repo, "chat/" <> chat.id)

      head = push_to(repo, "chat/" <> chat.id, "LAST.md", "the last turn\n")
      {:ok, _ended} = Conversations.ended(running, head, "closed")

      refute Git.branch_exists?(repo, "chat/" <> chat.id)
    end

    # A branch that is gone — a merge deletes it — is made again where opening would make it when
    # a message carries the conversation on, or the worker refuses it minutes later for a branch
    # that does not exist.
    test "carrying on after the branch was deleted starts it again from the default branch", %{
      chat: chat,
      repo: repo
    } do
      push_to(repo, "chat/" <> chat.id, "NOTES.md", "abandoned\n")
      {:ok, _idle} = Conversations.ended(chat, nil, "idle")
      :ok = Git.delete_branch(repo, "chat/" <> chat.id)
      moved = push_to(repo, "main", "LATER.md", "the default branch moved on\n")

      {:ok, _event} = Conversations.send(Jobs.get!(chat.id), "carry on")

      assert {:ok, ^moved} = Git.resolve(repo, "refs/heads/chat/" <> chat.id)
      assert [%{payload: %{"branch" => "recreated"}}] = branch_events(chat, "chat.reopened")
    end

    test "a ticket chat's branch comes back from the ticket's, as opening makes it", %{
      project: project,
      repo: repo
    } do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
      {:ok, chat} = Conversations.open(project, "about this", ticket: ticket)
      push_to(repo, "chat/" <> chat.id, "NOTES.md", "abandoned\n")
      {:ok, _idle} = Conversations.ended(chat, nil, "idle")
      :ok = Git.delete_branch(repo, "chat/" <> chat.id)
      push_to(repo, "main", "LATER.md", "the default branch moved on\n")
      ticket_head = push_to(repo, ticket.branch, "WORK.md", "the ticket's work\n")

      {:ok, _event} = Conversations.send(Jobs.get!(chat.id), "carry on")

      assert {:ok, ^ticket_head} = Git.resolve(repo, "refs/heads/chat/" <> chat.id)
    end

    # Made in the send's own transaction, so a branch that cannot be made is a send that did not
    # happen — not a pending row the worker will refuse for a branch that is not there, and not a
    # message in the transcript that nothing will answer.
    test "a branch that cannot be made again leaves the conversation where it was", %{
      project: project,
      repo: repo
    } do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
      {:ok, chat} = Conversations.open(project, "about this", ticket: ticket)
      {:ok, _idle} = Conversations.ended(chat, nil, "idle")
      :ok = Git.delete_branch(repo, "chat/" <> chat.id)
      :ok = Git.delete_branch(repo, ticket.branch)
      before = length(Conversations.messages(chat.id))

      assert {:error, {:branch, _reason}} = Conversations.send(Jobs.get!(chat.id), "carry on")

      assert Jobs.get!(chat.id).status == :finished
      assert branch_events(chat, "chat.reopened") == []
      assert length(Conversations.messages(chat.id)) == before
    end

    test "carrying on one whose branch is still there leaves it as it stands", %{
      chat: chat,
      repo: repo
    } do
      head = push_to(repo, "chat/" <> chat.id, "NOTES.md", "kept\n")
      {:ok, chat} = Conversations.ended(chat, nil, "idle")

      {:ok, _event} = Conversations.send(chat, "carry on")

      assert {:ok, ^head} = Git.resolve(repo, "refs/heads/chat/" <> chat.id)
      assert [%{payload: %{"branch" => "kept"}}] = branch_events(chat, "chat.reopened")
    end
  end

  # `docs/design/conversations.md` § Taking a transition. The acceptance criteria of ticket 6 are
  # here: the same two operations a person reaches by hand, attributed to whoever opened the
  # conversation, refused for exactly the reasons a person's click is refused.
  describe "a transition a turn asked for" do
    setup %{project: project} do
      opener = member_fixture(project)
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, opener.id})

      # The admission's own job is put to rest: a live job of the ticket's state refuses every
      # transition, which is a test of its own below rather than the background of all of them.
      finish_jobs(ticket)

      {:ok, chat} =
        Conversations.open(project, "the plan went wrong",
          ticket: ticket,
          actor: {:user, opener.id}
        )

      %{ticket: Tickets.get!(ticket.id), chat: chat, opener: opener}
    end

    # AC1 and AC4. The transition moves the ticket and records exactly what a person's by-hand
    # choice records — and it is attributed to the *opener*, with someone else's message the
    # thing that triggered the turn. Switch the attribution to "whoever is typing" and this is
    # the test that notices.
    test "it moves the ticket, attributed to whoever opened the conversation", %{
      project: project,
      ticket: ticket,
      chat: chat,
      opener: opener
    } do
      refinement!(ticket, opener)
      someone_else = member_fixture(project)
      {:ok, _sent} = Forge.Operator.send_chat(chat, someone_else, "put it back on planning")

      {:ok, _chat} = Conversations.record_turn(chat, turn_asking(1, %{"to" => "planning"}))

      assert Tickets.get!(ticket.id).state == "planning"

      assert %{actor: %{"kind" => "user", "id" => actor_id}, payload: %{"to" => "planning"}} =
               Events.latest_for_ticket(ticket.id, "transition.taken")

      assert actor_id == opener.id
      refute actor_id == someone_else.id

      # The approval the choice records, against the latest version, as a person's does — and
      # no second chat-flavoured event beside it.
      assert [%{decision: :approved, comment: "as asked"}] =
               Forge.Artifacts.approvals(Forge.Artifacts.latest(ticket.id, "refinement.md").id)

      assert refusals(chat) == []
    end

    # AC2. The same request against a transition whose `approve` list names a document with no
    # version: refused for the reason a person's choice is refused, and the artifact is named.
    test "a transition approving a document with no version is refused", %{
      ticket: ticket,
      chat: chat
    } do
      assert Forge.Artifacts.latest(ticket.id, "refinement.md") == nil

      {:ok, _chat} = Conversations.record_turn(chat, turn_asking(1, %{"to" => "planning"}))

      assert Tickets.get!(ticket.id).state == "refining"
      assert [reason] = refusals(chat)
      assert reason =~ "refinement.md"
      assert reason =~ "no version"
    end

    # Ticket 56: any state of the workflow, by a jump, attributed to the opener like any move, with
    # no approval of the transition it did not take (`docs/design/conversations.md`).
    test "it jumps to a state no transition leads to", %{
      ticket: ticket,
      chat: chat,
      opener: opener
    } do
      {:ok, _chat} = Conversations.record_turn(chat, turn_asking(1, %{"to" => "review_ready"}))

      assert Tickets.get!(ticket.id).state == "review_ready"

      assert %{actor: %{"id" => actor_id}, payload: %{"jump" => true, "comment" => "as asked"}} =
               Events.latest_for_ticket(ticket.id, "transition.taken")

      assert actor_id == opener.id
      assert refusals(chat) == []
    end

    # Criterion 21: a refusal that carries another ticket is said by its number, not as the row.
    test "a release reopened beside another is refused by the other's number", %{
      ticket: ticket,
      chat: chat,
      project: project,
      opener: opener
    } do
      release = fn t ->
        t
        |> Ecto.Changeset.change(workflow: Map.put(t.workflow, "release", true))
        |> Repo.update!()
      end

      {:ok, other} =
        Forge.Tickets.admit(project, %{title: "Other", body: "."}, {:user, opener.id})

      other = release.(other)
      release.(ticket) |> Ecto.Changeset.change(status: :done) |> Repo.update!()

      {:ok, _chat} = Conversations.record_turn(chat, turn_asking(1, %{"to" => "review_ready"}))

      assert [reason] = refusals(chat)

      assert reason ==
               "a release is already open: ##{other.number}; this one cannot be reopened beside it"

      assert Tickets.get!(ticket.id).status == :done
    end

    # Criterion 3: what the target's job needs is written in the turn that asks for it, and is
    # recorded before the request is read.
    test "a document written in the same turn makes the jump possible", %{
      ticket: ticket,
      chat: chat
    } do
      {:ok, _chat} =
        Conversations.record_turn(chat, turn_asking(1, %{"to" => "implementing"}))

      assert Tickets.get!(ticket.id).state == "refining"
      assert [reason] = refusals(chat)
      assert reason =~ "plan.md"

      turn =
        2
        |> turn_asking(%{"to" => "implementing"})
        |> Map.put("documents", %{"plan.md" => "---\noutcome: done\n---\n# Plan\n"})

      {:ok, _chat} = Conversations.record_turn(chat, turn)

      assert Tickets.get!(ticket.id).state == "implementing"

      assert [%{version: version}] =
               Enum.filter(Forge.Jobs.for_ticket(ticket.id), &(&1.state == "implementing"))
               |> Enum.flat_map(&(&1 |> Forge.Jobs.spec() |> Map.fetch!(:inputs)))
               |> Enum.filter(&(&1.name == "plan.md"))

      assert version == Forge.Artifacts.latest(ticket.id, "plan.md").version
    end

    # AC3, approving. The pending decision is the ticket's, whoever asked for it; deciding it
    # takes the transition and records the approval against the latest version at that moment.
    test "it decides a pending transition, and approving takes it", %{
      ticket: ticket,
      chat: chat,
      opener: opener
    } do
      version = refinement!(ticket, opener)
      pending!(ticket)

      {:ok, _chat} = Conversations.record_turn(chat, turn_asking(1, %{"decision" => "approved"}))

      ticket = Tickets.get!(ticket.id)
      assert ticket.state == "planning"
      assert ticket.pending_transition == nil
      assert [%{decision: :approved}] = Forge.Artifacts.approvals(version.id)
      assert refusals(chat) == []
    end

    # AC3, rejecting: the ticket stays where it is and the decision is cleared, which is what a
    # person's rejection already does.
    test "rejecting leaves the ticket where it is and clears the decision", %{
      ticket: ticket,
      chat: chat,
      opener: opener
    } do
      version = refinement!(ticket, opener)
      pending!(ticket)

      {:ok, _chat} = Conversations.record_turn(chat, turn_asking(1, %{"decision" => "rejected"}))

      ticket = Tickets.get!(ticket.id)
      assert ticket.state == "refining"
      assert ticket.pending_transition == nil
      assert [%{decision: :rejected}] = Forge.Artifacts.approvals(version.id)
      assert Events.latest_for_ticket(ticket.id, "transition.taken") == nil
    end

    # A reject needs a note, for a conversation's request as for a person's press
    # (`docs/design/ui.md` § The decision row): refused, in words the agent can act on.
    test "a rejection without a comment is refused and decides nothing", %{
      ticket: ticket,
      chat: chat,
      opener: opener
    } do
      version = refinement!(ticket, opener)
      pending!(ticket)

      {:ok, _chat} =
        Conversations.record_turn(
          chat,
          turn_asking(1, %{"decision" => "rejected", "comment" => nil})
        )

      assert Tickets.get!(ticket.id).pending_transition != nil
      assert Forge.Artifacts.approvals(version.id) == []
      assert [reason] = refusals(chat)
      assert reason =~ "a rejection needs a comment saying why"
    end

    # AC5. The chat does not stop a job, and it does not get past one either: cancelling the
    # ticket and restoring it is what a person already has, and it is theirs to do.
    test "it is refused while a job of the ticket's state is live", %{
      ticket: ticket,
      chat: chat,
      opener: opener
    } do
      refinement!(ticket, opener)
      # A second attempt of the state, running: the setup finished the first.
      job = job_fixture(%{ticket: ticket, status: :running, attempt: 2})

      {:ok, _chat} = Conversations.record_turn(chat, turn_asking(1, %{"to" => "planning"}))

      assert Tickets.get!(ticket.id).state == "refining"
      assert Jobs.get!(job.id).status == :running
      assert [reason] = refusals(chat)
      assert reason =~ "refining"
      assert reason =~ "cancelled and restored"
    end

    # While a decision is pending, no other transition may be taken — the guard this ticket
    # moved from the ticket page's `:if` to `Engine.choose/4` itself.
    test "a transition is refused while a decision is pending", %{
      ticket: ticket,
      chat: chat,
      opener: opener
    } do
      refinement!(ticket, opener)
      pending!(ticket)

      {:ok, _chat} = Conversations.record_turn(chat, turn_asking(1, %{"to" => "planning"}))

      assert Tickets.get!(ticket.id).state == "refining"
      assert Tickets.get!(ticket.id).pending_transition["to"] == "planning"
      assert [reason] = refusals(chat)
      assert reason =~ "already pending"
    end

    # Well-formed and still wrong: the agent names a state the workflow does not go to from
    # here. Refused by the engine's own grammar, not by anything copied into the chat.
    test "a transition the workflow does not declare is refused", %{
      ticket: ticket,
      chat: chat,
      opener: opener
    } do
      refinement!(ticket, opener)

      {:ok, _chat} = Conversations.record_turn(chat, turn_asking(1, %{"to" => "shipping"}))

      assert Tickets.get!(ticket.id).state == "refining"
      assert [reason] = refusals(chat)
      assert reason =~ "no state called"
    end

    test "a decision with nothing pending is refused", %{ticket: ticket, chat: chat} do
      {:ok, _chat} = Conversations.record_turn(chat, turn_asking(1, %{"decision" => "approved"}))

      assert Tickets.get!(ticket.id).state == "refining"
      assert [reason] = refusals(chat)
      assert reason =~ "waiting for a decision"
    end

    # A project chat has no ticket, which is the refinement's own out-of-scope list made
    # concrete: refused here, before the engine is asked anything at all. Opened by a person,
    # so that this guard is the only thing in the way — with no opener the request would be
    # refused for *that* instead, and the test would pass with the ticket check gone.
    test "a project chat's request is refused and reaches no ticket", %{
      project: project,
      opener: opener
    } do
      {:ok, chat} =
        Conversations.open(project, "about the repository", actor: {:user, opener.id})

      {:ok, _chat} = Conversations.record_turn(chat, turn_asking(1, %{"to" => "planning"}))

      assert [reason] = refusals(chat)
      assert reason =~ "no ticket"
    end

    # The membership guard is `Forge.Operator`'s, and a chat reaching the engine directly would
    # walk straight past it: the opener's standing is checked when the request is applied, not
    # when the conversation was opened, so a person removed from the project since cannot still
    # move its tickets through a conversation they left behind
    # (`docs/design/identity.md` § Where the guard lives).
    test "the opener who has since left the project cannot move anything", %{
      project: project,
      ticket: ticket,
      chat: chat,
      opener: opener
    } do
      refinement!(ticket, opener)

      Repo.delete_all(
        from m in Projects.Member, where: m.project_id == ^project.id and m.user_id == ^opener.id
      )

      {:ok, _chat} = Conversations.record_turn(chat, turn_asking(1, %{"to" => "planning"}))

      assert Tickets.get!(ticket.id).state == "refining"
      assert [reason] = refusals(chat)
      assert reason =~ "no longer a member"

      # Deciding is guarded the same way and at a call site of its own, so it is asked
      # separately: both go through `Forge.Operator`, and neither reaches `Forge.Engine` direct.
      pending!(ticket)

      {:ok, _chat} = Conversations.record_turn(chat, turn_asking(2, %{"decision" => "approved"}))

      assert Tickets.get!(ticket.id).state == "refining"
      assert Tickets.get!(ticket.id).pending_transition["to"] == "planning"
      assert List.last(refusals(chat)) =~ "no longer a member"
    end

    # Attribution has nowhere to point: a conversation a Mix task opened would make a
    # `transition.taken` that claims nobody took it.
    test "a conversation nobody opened cannot move anything", %{project: project, ticket: ticket} do
      {:ok, chat} = Conversations.open(project, "from the command line", ticket: ticket)

      {:ok, _chat} = Conversations.record_turn(chat, turn_asking(1, %{"to" => "planning"}))

      assert Tickets.get!(ticket.id).state == "refining"
      assert [reason] = refusals(chat)
      assert reason =~ "nobody opened this conversation"
    end

    # The worker checks the shape, and the platform asks again: what crosses the channel is not
    # a guard. Each of these is refused with why, and none of them crashes the turn.
    test "a request that is not one shape or the other is refused", %{ticket: ticket, chat: chat} do
      requests = [
        {%{"to" => "planning", "decision" => "approved"}, "both"},
        {%{}, "must be one JSON object"},
        {%{"to" => ""}, "must be one JSON object"},
        {%{"to" => 3}, "must be one JSON object"},
        {%{"decision" => "maybe"}, "not `approved` or `rejected`"}
      ]

      for {{request, why}, index} <- Enum.with_index(requests, 1) do
        assert {:ok, _chat} = Conversations.record_turn(chat, turn_asking(index, request))
        assert Tickets.get!(ticket.id).state == "refining"
        assert List.last(refusals(chat)) =~ why
      end

      # Every one of them was recorded as a turn: a malformed request must not cost the turn
      # its cost, its commit or its documents.
      assert length(turn_events(chat)) == length(requests)
    end

    # The worker could not decode the file, and says so instead of sending a request. The agent
    # still hears why nothing moved.
    test "a file the worker refused is reported as a refusal", %{chat: chat} do
      payload =
        1
        |> turn(0.01)
        |> Map.put("invalid_transition_request", "transition.json is not valid JSON")

      {:ok, _chat} = Conversations.record_turn(chat, payload)

      assert [reason] = refusals(chat)
      assert reason =~ "not valid JSON"
    end

    # **The one that cannot be got right by accident.** The worker re-sends an unacked turn for
    # ever, and a transition asked for twice is not the same thing twice: the second attempt
    # meets a ticket that has already left the state. Wire the request in beside the
    # idempotency gate rather than inside it and this is what notices.
    test "a re-sent turn does not ask for the transition again", %{
      ticket: ticket,
      chat: chat,
      opener: opener
    } do
      refinement!(ticket, opener)
      request = turn_asking(1, %{"to" => "planning"})

      {:ok, _chat} = Conversations.record_turn(chat, request)
      assert Tickets.get!(ticket.id).state == "planning"

      {:ok, _chat} = Conversations.record_turn(Jobs.get!(chat.id), request)

      assert Tickets.get!(ticket.id).state == "planning"
      # Had it been attempted again it would have been refused — `planning` declares no edge to
      # itself — and a refusal is the trace that attempt leaves.
      assert refusals(chat) == []
      assert length(turn_events(chat)) == 1
    end

    # **Finding 1.** The pinning a ticket was admitted with can stop building as the grammar
    # moves on, and that ticket is exactly the one a conversation exists to rescue. The apply
    # path runs after the turn's transaction has committed, so a raise here kills the channel's
    # handler, the worker re-sends, `recorded?/2` says the turn is recorded, and the request is
    # gone with nothing said to anybody. Refused instead.
    test "a ticket whose pinned workflow no longer parses is refused, not raised on", %{
      ticket: ticket,
      chat: chat
    } do
      unparseable!(ticket)

      {:ok, _chat} = Conversations.record_turn(chat, turn_asking(1, %{"to" => "planning"}))

      assert Tickets.get!(ticket.id).state == "refining"
      assert [reason] = refusals(chat)
      assert reason =~ "no longer parses"
      # The validator's own complaint, so a person knows what to repin.
      assert reason =~ "is required"
    end

    # **Finding 3.** Membership is caught by the operator; standing is this path's to ask.
    # A conversation outlives the standing of whoever opened it and any member may type into
    # it, so without this an account suspended since would have tickets moved in its name by
    # somebody else's message.
    test "an opener suspended or un-approved since cannot move anything", %{
      project: project,
      ticket: ticket,
      chat: chat,
      opener: opener
    } do
      refinement!(ticket, opener)

      suspend!(opener)
      {:ok, _chat} = Conversations.record_turn(chat, turn_asking(1, %{"to" => "planning"}))

      assert Tickets.get!(ticket.id).state == "refining"
      assert List.last(refusals(chat)) =~ "suspended"

      # Un-approval is the other half of `User.active?/1`, and reads as its own word.
      reinstate!(opener)
      unapprove!(opener)
      {:ok, _chat} = Conversations.record_turn(chat, turn_asking(2, %{"to" => "planning"}))

      assert Tickets.get!(ticket.id).state == "refining"
      assert List.last(refusals(chat)) =~ "not an approved account"

      # Standing restored, the same request goes through: it was the standing and nothing else.
      approve!(opener)
      {:ok, _chat} = Conversations.record_turn(chat, turn_asking(3, %{"to" => "planning"}))

      assert Tickets.get!(ticket.id).state == "planning"
      assert Projects.role(project, opener) != nil
    end

    # **Finding 4.** `apply_request/4` dispatches on the key being present, with no type guard,
    # so the both-keys refusal must not carry one either: a `to` of the wrong type beside a
    # `decision` validated as a decision and then dispatched as a transition, and the decision
    # was silently not made.
    test "both keys are refused whatever the types are", %{
      ticket: ticket,
      chat: chat,
      opener: opener
    } do
      refinement!(ticket, opener)
      pending!(ticket)

      for {request, index} <- Enum.with_index([%{"to" => 5}, %{"to" => nil}], 1) do
        asked = Map.put(request, "decision", "approved")
        {:ok, _chat} = Conversations.record_turn(chat, turn_asking(index, asked))

        assert List.last(refusals(chat)) =~ "both"
        # Neither taken nor decided: the pending decision is still the ticket's.
        assert Tickets.get!(ticket.id).state == "refining"
        assert Tickets.get!(ticket.id).pending_transition["to"] == "planning"
      end
    end

    # **A refusal is recorded and says nothing into the conversation.** An earlier attempt sent
    # it back with `send/3` and a `:system` actor, which `fold/2` projects as `role: :user` —
    # the person read themselves saying it, `Forge.Queue` dropped the chat back out of their
    # queue, and `opening/1` made it the next process's prompt. A message is also a turn, so it
    # would bill one and reset the idle timer § Lifetime measures from the last human message.
    # This is the test that fails if any of that comes back.
    test "a refusal is recorded without putting words in the conversation", %{chat: chat} do
      {:ok, _chat} = Conversations.record_turn(chat, turn_asking(1, %{"decision" => "approved"}))

      assert [_reason] = refusals(chat)

      # The opening message and nothing since: no message of the platform's, and in particular
      # none projected as the person's.
      assert [%{role: :user, text: "the plan went wrong"}] = Conversations.transcript(chat.id)

      assert for(%{type: "chat.message", payload: p} <- Events.for_job(chat.id), do: p["text"]) ==
               ["the plan went wrong"]
    end

    # **Finding 6.** The branch an earlier comment excused as an equivalent mutant. `events.actor`
    # is a JSON column with no reference and `open/3` writes the actor straight through, so an id
    # that never named an account reaches `get_user/1`'s nil in one line — and
    # `Accounts.delete_unapproved_user/2` can make it happen for real.
    test "an opener whose account is gone cannot move anything", %{
      project: project,
      ticket: ticket
    } do
      {:ok, chat} =
        Conversations.open(project, "who am i",
          ticket: ticket,
          actor: {:user, Ecto.UUID.generate()}
        )

      {:ok, _chat} = Conversations.record_turn(chat, turn_asking(1, %{"to" => "planning"}))

      assert Tickets.get!(ticket.id).state == "refining"
      assert [reason] = refusals(chat)
      assert reason =~ "no longer has an account"
    end

    # **Finding 11.** A frame the worker never sends. Answering it with `:none` answered it with
    # silence, where every other malformed request is answered with a reason.
    test "a forged request of the wrong shape is refused, not ignored", %{chat: chat} do
      for {payload, index} <-
            Enum.with_index(
              [
                %{"transition_request" => "hello"},
                %{"invalid_transition_request" => 7}
              ],
              1
            ) do
        turn = Map.merge(turn(index, 0.01), payload)
        {:ok, _chat} = Conversations.record_turn(chat, turn)
      end

      assert [first, second] = refusals(chat)
      assert first =~ "not a JSON object"
      assert second =~ "was not text"
    end

    # **Finding 11.** `Dir.transition/1` refuses a non-string comment, so this must too: a frame
    # the worker would have refused must not be applied here with the comment quietly dropped.
    test "a comment that is not text is refused, as the worker refuses it", %{
      ticket: ticket,
      chat: chat,
      opener: opener
    } do
      refinement!(ticket, opener)

      turn =
        Map.put(turn(1, 0.01), "transition_request", %{"to" => "planning", "comment" => 7})

      {:ok, _chat} = Conversations.record_turn(chat, turn)

      assert Tickets.get!(ticket.id).state == "refining"
      assert [reason] = refusals(chat)
      assert reason =~ "comment that is not text"
    end

    # **Finding 9.** The worker removes the file unread on a turn that did not end cleanly, where
    # `subtype` and `is_error` are known. `interrupted` is on the payload the platform already
    # reads, so the rule does not live on one side of the channel alone.
    test "an interrupted turn's request is not applied even if it arrives", %{
      ticket: ticket,
      chat: chat,
      opener: opener
    } do
      refinement!(ticket, opener)

      turn = Map.put(turn_asking(1, %{"to" => "planning"}), "interrupted", true)
      {:ok, _chat} = Conversations.record_turn(chat, turn)

      assert Tickets.get!(ticket.id).state == "refining"
      # Dropped, not refused: nobody asked for it, so there is nothing to tell anyone about.
      assert refusals(chat) == []
    end

    # **Finding 9.** The request is echoed into a log § Lifetime keeps for ever, and it arrived
    # as a file the agent wrote — a mebibyte of it, per refused turn, uncapped.
    test "a huge request is cut down before it reaches the log", %{chat: chat} do
      # **Multi-byte, not ASCII.** A byte offset through this text lands inside a character about
      # as often as not: the result fails `String.valid?/1`, `Jason` refuses it, and the insert
      # raises *after* the turn's transaction has committed — so the worker re-sends, the turn is
      # already recorded, and the request vanishes with nothing said to anyone. An ASCII string
      # cannot see any of that.
      long = String.duplicate("—", 5_000)

      turn =
        Map.put(turn(1, 0.01), "transition_request", %{
          "to" => long,
          "comment" => long,
          "padding" => long
        })

      {:ok, _chat} = Conversations.record_turn(chat, turn)

      assert [%{payload: %{"request" => request}}] =
               for(
                 event <- Events.for_job(chat.id),
                 event.type == "chat.transition_refused",
                 do: event
               )

      # Still valid text, which is the whole point: an invalid binary never reaches the column.
      assert String.valid?(request["to"])
      assert String.valid?(request["comment"])
      assert String.length(request["to"]) < 250
      assert String.length(request["comment"]) < 250
      # Only the keys the platform reads travel; a key it never looks at is not kept at all.
      refute Map.has_key?(request, "padding")
    end

    defp turn_asking(index, request) do
      index
      |> turn(0.01 * index)
      |> Map.put("transition_request", Map.put_new(request, "comment", "as asked"))
    end

    defp refusals(chat) do
      for %{type: "chat.transition_refused", payload: payload} <- Events.for_job(chat.id),
          do: payload["reason"]
    end

    defp turn_events(chat),
      do: for(%{type: "chat.turn"} = event <- Events.for_job(chat.id), do: event)

    # A version of the document the `refining` -> `planning` edge approves, so that the edge can
    # be taken at all.
    defp refinement!(ticket, user) do
      {:ok, version} =
        Forge.Artifacts.record_version(ticket.id, "refinement.md", :document, {:user, user.id}, %{
          content: "---\noutcome: done\n---\n# Refinement\n"
        })

      version
    end

    # The ticket as the engine leaves it when a job's transition needs approving
    # (`Engine.put_pending_approval/4`). Written here rather than reached through a job run,
    # which `Forge.FlowTest` already covers end to end.
    defp pending!(ticket) do
      ticket
      |> Forge.Tickets.Ticket.progress_changeset(%{
        state: ticket.state,
        status: :active,
        usage: ticket.usage,
        pending_transition: %{
          "from" => "refining",
          "to" => "planning",
          "outcome" => nil,
          "approve" => ["refinement.md"]
        }
      })
      |> Repo.update!()
    end

    # A pinning that no longer parses: validated at admission, and `%{}` is not a definition
    # the grammar can build at all.
    defp unparseable!(ticket) do
      ticket
      |> Ecto.Changeset.change(%{workflow: %{}})
      |> Repo.update!()
    end

    defp suspend!(user), do: stamp!(user, :suspended_at, DateTime.utc_now(:second))
    defp reinstate!(user), do: stamp!(user, :suspended_at, nil)
    defp unapprove!(user), do: stamp!(user, :approved_at, nil)
    defp approve!(user), do: stamp!(user, :approved_at, DateTime.utc_now(:second))

    defp stamp!(user, field, value) do
      Forge.Accounts.User
      |> Repo.get!(user.id)
      |> Ecto.Changeset.change(%{field => value})
      |> Repo.update!()
    end

    defp finish_jobs(ticket) do
      for job <- Jobs.for_ticket(ticket.id) do
        job
        |> Forge.Jobs.Job.progress_changeset(%{status: :finished, outcome: :converged})
        |> Repo.update!()
      end
    end
  end

  # A second `refining -> planning` edge in the ticket's own pinning, approving `name`, told
  # apart from the first by its `when`.
  defp second_edge!(ticket, name) do
    extra = %{"from" => "refining", "to" => "planning", "approve" => [name], "when" => "redo"}

    workflow =
      ticket.workflow
      |> Map.update!("transitions", &(&1 ++ [extra]))
      |> put_in(["states", "refining", "outcomes"], ["done", "redo"])
      # The validator wants an approved name produced by that state or an earlier one, so the
      # dead edge's document is declared and simply never written — which is the case.
      |> update_in(["states", "refining", "produces"], &(&1 ++ [name]))

    ticket |> Ecto.Changeset.change(%{workflow: workflow}) |> Repo.update!()
  end

  # Two `refining -> planning` edges and no bare one among them: `done` is renamed `fine`, so the
  # request for `planning` names a target and cannot say which.
  defp no_bare_edge!(ticket) do
    ticket = second_edge!(ticket, "refinement.md")

    workflow =
      update_in(ticket.workflow, ["transitions"], fn transitions ->
        Enum.map(transitions, fn
          %{"from" => "refining", "to" => "planning", "when" => nil} = edge ->
            Map.put(edge, "when", "fine")

          %{"from" => "refining", "to" => "planning"} = edge when not is_map_key(edge, "when") ->
            Map.put(edge, "when", "fine")

          other ->
            other
        end)
      end)
      |> put_in(["states", "refining", "outcomes"], ["fine", "redo"])

    ticket |> Ecto.Changeset.change(%{workflow: workflow}) |> Repo.update!()
  end

  defp turn_with_proposals(index, proposals, invalid \\ %{}) do
    index
    |> turn(0.01)
    |> Map.merge(%{"proposals" => proposals, "invalid_proposals" => invalid})
  end

  defp turn(index, cost, session \\ "sess-1") do
    %{
      "turn" => index,
      "commit" => String.duplicate("a", 40),
      "harness" => %{
        "turns" => 1,
        "usage" => cost && round(cost * 200_000),
        "cost_usd" => cost,
        "session_id" => session,
        "subtype" => "success"
      }
    }
  end

  # A message at a chosen time. Events are append-only, so a time is chosen by inserting one with
  # it, later in the log than any before, which is what `summaries/1` reads as the last said.
  defp said_at(chat, text, at) do
    Repo.insert!(%Forge.Events.Event{
      actor: %{"kind" => "system", "id" => nil},
      type: "chat.message",
      payload: %{"text" => text},
      job_id: chat.id,
      project_id: chat.project_id,
      inserted_at: DateTime.truncate(at, :second)
    })
  end

  defp started(chat, at),
    do: Repo.update_all(from(j in Jobs.Job, where: j.id == ^chat.id), set: [inserted_at: at])

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(:second), -seconds, :second)

  defp text(chat, text, parent \\ nil),
    do: harness(chat, "job.harness.text", %{text: text, parent_tool_use_id: parent})

  defp tool_use(chat, id, name, input, parent \\ nil),
    do:
      harness(chat, "job.harness.tool_use", %{
        id: id,
        name: name,
        input: input,
        parent_tool_use_id: parent
      })

  defp tool_result(chat, id, error?, excerpt, parent \\ nil),
    do:
      harness(chat, "job.harness.tool_result", %{
        tool_use_id: id,
        is_error: error?,
        bytes: byte_size(excerpt),
        excerpt: excerpt,
        parent_tool_use_id: parent
      })

  defp harness(chat, type, payload),
    do: :ok = Jobs.record_harness_event(chat.id, %{type: type, payload: payload})

  defp delivered(chat, message_id) do
    :ok =
      Jobs.record_harness_event(chat.id, %{
        type: "job.harness.delivered",
        payload: %{text: "…", message_id: message_id}
      })
  end

  describe "as a list counts and names them" do
    # The title menu's Chats line: a stopped one is counted, and is not live.
    test "counts the live ones apart from the rest" do
      user = Forge.AccountsFixtures.user_fixture()
      project = project_fixture()
      join!(project, user, :member)
      chat_fixture(%{project: project, status: :running})

      chat_fixture(%{project: project})
      |> Ecto.Changeset.change(status: :finished, outcome: :converged)
      |> Forge.Repo.update!()

      assert Conversations.counts(user) == %{live: 1, total: 2}
    end

    # Its name in a list is what it was opened with, not what was said in it since.
    test "names a conversation by its first message, not its latest" do
      project = project_fixture()
      chat = chat_fixture(%{project: project})

      for text <- ["What it was opened with", "What was said since"] do
        {:ok, _} =
          Events.append("chat.message", :system, %{job_id: chat.id, payload: %{"text" => text}})
      end

      assert [%{first: "What it was opened with"}] =
               Conversations.summaries(project_id: project.id)
    end
  end
end
