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

    # A reopened conversation is a new process, whose running total starts again from nothing. Its
    # figure is set on the run it belongs to — the latest — and the conversation's cost is every
    # run's; set on the job alone, as it was, a reopening forgot everything spent before it.
    test "a turn is costed on its run, and the conversation's cost is every run's", %{chat: chat} do
      [current] = Repo.all(from r in Forge.Jobs.Run, where: r.job_id == ^chat.id)
      earlier = DateTime.add(current.started_at, -3600)

      Repo.update_all(from(r in Forge.Jobs.Run, where: r.id == ^current.id),
        set: [started_at: DateTime.add(current.started_at, 60)]
      )

      run!(chat, cost: "0.30", started_at: earlier, finished_at: earlier)

      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.1))
      assert Decimal.equal?(chat.cost_usd, Decimal.new("0.4"))

      assert Repo.all(
               from r in Forge.Jobs.Run,
                 where: r.job_id == ^chat.id,
                 order_by: r.started_at,
                 select: r.cost_usd
             )
             |> Enum.map(&Decimal.to_float/1) == [0.3, 0.1]
    end

    # Its run ends with it, whichever way it ended; a reopening is a new run.
    test "a conversation's ending closes its run", %{chat: chat} do
      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.1))
      {:ok, _} = Conversations.ended(chat, nil, "machine_lost")

      assert [%{finished_at: %DateTime{}}] =
               Repo.all(from r in Forge.Jobs.Run, where: r.job_id == ^chat.id)
    end

    # A reopened conversation is a new process: its turns are numbered from one again. Keyed on
    # the turn alone, the new session's first turns read as re-sends of the old one's and were
    # dropped — commit, proposals and push with them. What they cost is the run's
    # (`Forge.Jobs.Runs`), which the test above pins.
    test "a new session's turns are its own, and a re-send is still one", %{chat: chat} do
      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.10))
      {:ok, chat} = Conversations.record_turn(chat, turn(2, 0.30))

      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.05, "sess-2"))
      {:ok, chat} = Conversations.record_turn(chat, turn(2, 0.08, "sess-2"))
      assert chat.turns == 4

      # A re-send within the new session is still recorded once.
      {:ok, chat} = Conversations.record_turn(chat, turn(2, 0.08, "sess-2"))
      assert chat.turns == 4

      turns = chat.id |> Events.for_job() |> Enum.count(&(&1.type == "chat.turn"))
      assert turns == 4
    end

    # A harness that reports no session is one session as far as this can tell: its re-sent
    # turn is recorded once, and the first session that does report is another one.
    test "turns with no session are one session", %{chat: chat} do
      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.10, nil))
      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.10, nil))
      assert chat.turns == 1

      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.05, "sess-2"))
      assert chat.turns == 2
    end

    test "a session that reported no cost adds nothing, and breaks nothing", %{chat: chat} do
      {:ok, chat} = Conversations.record_turn(chat, turn(1, nil))
      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.05, "sess-2"))

      assert Decimal.equal?(chat.cost_usd, Decimal.new("0.05"))
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
      text(chat, "```question\nkey: rows\ntext: How many rows?\n```\n")
      first = chat.id |> Conversations.messages() |> Conversations.reply_ref()

      text(chat, "And one more thing.")
      assert chat.id |> Conversations.messages() |> Conversations.reply_ref() == first

      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.01))
      assert chat.id |> Conversations.messages() |> Conversations.reply_ref() == first

      {:ok, _event} = Conversations.send(chat, "ten")
      assert chat.id |> Conversations.messages() |> Conversations.reply_ref() == nil

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

      assert [%{"metadata" => metadata}] = Conversations.history(ticket)
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

      assert [%{"metadata" => metadata}] = Conversations.history(ticket)
      assert metadata =~ "> " <> String.duplicate("x", 4000)
      refute metadata =~ "BEYOND"
    end

    test "a job with nothing refused and nothing said has neither section", %{project: project} do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)

      assert [%{"metadata" => metadata}] = Conversations.history(ticket)
      refute metadata =~ "What was refused"
      refute metadata =~ "What it said last"
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

      assert [%{role: :user}, %{role: :assistant, text: text, items: items}] =
               Conversations.messages(chat.id)

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

      [_user, reply] = Conversations.messages(chat.id)

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

    # A message sent mid-turn is recorded at once and splits the reply on the page, but the turn
    # is still one turn: the call made before it gets its result after it, and the turn's end
    # closes both halves.
    test "a turn split by a message sent mid-turn is still one turn", %{chat: chat} do
      text(chat, "Running the tests.")
      tool_use(chat, "k1", "Task", %{"description" => "find the lexer"})
      tool_use(chat, "t1", "Bash", %{"command" => "mix test"})
      {:ok, _event} = Conversations.send(chat, "also check the lexer")
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
          payload: %{subtype: "thinking_tokens"}
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
    test "a reopened conversation is given what was said, and nothing to answer again", %{
      chat: chat
    } do
      text(chat, "It is a game.")
      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.01))
      {:ok, _event} = Conversations.send(chat, "which engine?")
      text(chat, "Its own.")
      {:ok, chat} = Conversations.record_turn(chat, turn(2, 0.02))
      {:ok, chat} = Conversations.ended(chat, nil, "idle")
      {:ok, chat} = Conversations.reopen(chat)

      spec = assigned_spec(chat)

      assert spec["prompt"] == nil

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
    end

    test "what the person says after a reopen is what it answers, and not replayed", %{
      chat: chat
    } do
      text(chat, "It is a game.")
      {:ok, chat} = Conversations.record_turn(chat, turn(1, 0.01))
      {:ok, chat} = Conversations.ended(chat, nil, "idle")
      {:ok, chat} = Conversations.reopen(chat)
      {:ok, _event} = Conversations.send(chat, "does it still build?")

      spec = assigned_spec(chat)

      assert spec["prompt"] == "does it still build?"
      assert spec["replay"] =~ "It is a game."
      refute spec["replay"] =~ "does it still build?"
    end

    # Every reopen clears `out/`, resumed or cold, so a project chat's own documents
    # were gone from its view — while a ticket chat's came back as the ticket's. Now it is handed
    # what it last wrote of each, and not its proposals, which are backlog and not documents.
    test "a reopened project chat is handed what it wrote, at its latest", %{chat: chat} do
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
      {:ok, chat} = Conversations.reopen(chat)

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

    # No `chat.turn` closed it: the machine went while the agent was still speaking. A reply
    # that stops mid-sentence would otherwise read as a finished one that trailed off.
    test "a reply the process never finished is replayed as cut off", %{chat: chat} do
      text(chat, "Let me look at the")
      {:ok, chat} = Conversations.ended(chat, nil, "worker_lost")
      {:ok, chat} = Conversations.reopen(chat)

      replay = assigned_spec(chat)["replay"]

      assert replay =~ ~r/## You[^\n]*cut off[^\n]*\n\nLet me look at the/
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

    # A `reopen` is anything the socket sends, and the page draws the button only when the
    # conversation is not live. On a running one it cleared the `worker_id` its worker reports
    # under — every later turn failed the channel's ownership check — and queued it to be placed
    # a second time.
    test "a live conversation is not reopened", %{chat: chat, project: project} do
      {:ok, worker, _token} = Forge.Workers.create(%{provider: "fake"})

      {:ok, running} =
        chat
        |> Jobs.Job.progress_changeset(%{status: :running, worker_id: worker.id})
        |> Repo.update()

      assert {:error, :live} = Conversations.reopen(running)
      # The row is asked, not the struct: one rendered after it stopped says nothing now.
      assert {:error, :live} = Conversations.reopen(%{running | status: :hibernated})

      assert %{status: :running, worker_id: worker_id} = Jobs.get!(chat.id)
      assert worker_id == worker.id
      refute Enum.any?(Events.for_job(chat.id), &(&1.type == "chat.reopened"))

      # Waiting for a machine is live too.
      {:ok, waiting} = Conversations.open(project, "another")
      assert {:error, :live} = Conversations.reopen(waiting)
    end

    # The same line from the other side. An idle conversation keeps its branch; a close arriving
    # afterwards — a stale page, a crafted event — recorded a second ending, as `closed`, and
    # dealt with the branch as though a person had abandoned it.
    test "a conversation that has stopped is not closed again", %{chat: chat, project: project} do
      {:ok, idle} = Conversations.ended(chat, nil, "idle")

      assert {:error, :not_live} = Conversations.close(idle)
      # The struct the caller holds still says pending; the row says otherwise.
      assert {:error, :not_live} = Conversations.close(chat)

      assert Git.branch_exists?(Projects.repo_path(project), "chat/" <> chat.id)
      assert [_once] = Enum.filter(Events.for_job(chat.id), &(&1.type == "chat.ended"))
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

    # Nobody decided anything, so nothing is abandoned: these are dormancy, and a dormant
    # conversation is reopened to carry on with the work that is on its branch.
    test "going idle or losing the machine keeps the branch", %{chat: chat, repo: repo} do
      head = push_to(repo, "chat/" <> chat.id, "NOTES.md", "a note\n")

      for reason <- ["idle", "worker_lost", "ended"] do
        {:ok, chat} = Conversations.ended(chat, nil, reason)
        assert {:ok, ^head} = Git.resolve(repo, "refs/heads/chat/" <> chat.id), reason
        {:ok, _chat} = Conversations.reopen(chat)
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

    # Closing is not terminal: every conversation that is not live can be reopened. A branch that
    # is gone is made again where opening would make it, or the worker refuses the conversation
    # minutes later for a branch that does not exist.
    test "reopening after a close starts the branch again from the default branch", %{
      chat: chat,
      repo: repo
    } do
      push_to(repo, "chat/" <> chat.id, "NOTES.md", "abandoned\n")
      :ok = Conversations.close(chat)
      moved = push_to(repo, "main", "LATER.md", "the default branch moved on\n")

      {:ok, _reopened} = Conversations.reopen(Jobs.get!(chat.id))

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
      :ok = Conversations.close(chat)
      push_to(repo, "main", "LATER.md", "the default branch moved on\n")
      ticket_head = push_to(repo, ticket.branch, "WORK.md", "the ticket's work\n")

      {:ok, _reopened} = Conversations.reopen(Jobs.get!(chat.id))

      assert {:ok, ^ticket_head} = Git.resolve(repo, "refs/heads/chat/" <> chat.id)
    end

    # Made in the reopen's own transaction, so a branch that cannot be made is a reopen that did
    # not happen — not a pending row the worker will refuse for a branch that is not there.
    test "a branch that cannot be made again leaves the conversation where it was", %{
      project: project,
      repo: repo
    } do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
      {:ok, chat} = Conversations.open(project, "about this", ticket: ticket)
      :ok = Conversations.close(chat)
      :ok = Git.delete_branch(repo, ticket.branch)

      assert {:error, {:branch, _reason}} = Conversations.reopen(Jobs.get!(chat.id))

      assert Jobs.get!(chat.id).status == :finished
      assert branch_events(chat, "chat.reopened") == []
    end

    test "reopening one whose branch is still there leaves it as it stands", %{
      chat: chat,
      repo: repo
    } do
      head = push_to(repo, "chat/" <> chat.id, "NOTES.md", "kept\n")
      {:ok, chat} = Conversations.ended(chat, nil, "idle")

      {:ok, _reopened} = Conversations.reopen(chat)

      assert {:ok, ^head} = Git.resolve(repo, "refs/heads/chat/" <> chat.id)
      assert [%{payload: %{"branch" => "kept"}}] = branch_events(chat, "chat.reopened")
    end
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
        "cost_usd" => cost,
        "session_id" => session,
        "subtype" => "success"
      }
    }
  end

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
end
