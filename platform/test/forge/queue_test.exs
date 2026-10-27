defmodule Forge.QueueTest do
  @moduledoc """
  Non-blocking questions in the queue: served as a kind of their own, after every decision, and
  answerable without moving any job — `docs/design/job-prompt.md` § Non-blocking questions and
  `docs/design/ui.md` § Not waiting on you.

  Every reader of `Forge.Queue` — the page, the JSON API, the CLI, the digest push — decides what
  is waiting from the kind, so the kind and the order are what is tested here.
  """

  use Forge.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Forge.AccountsFixtures
  import Forge.ForgeFixtures

  alias Forge.{Artifacts, Events, Jobs, Operator, Queue}
  alias Forge.Artifacts.Question

  # A document as an agent leaves one, carrying the question blocks it wrote.
  defp ask(ticket, job, blocks) do
    {:ok, version} =
      Artifacts.record_version(ticket.id, "refinement.md", :document, {:job, job.id}, %{
        content: "---\noutcome: done\n---\n# Refinement\n\n" <> Enum.join(blocks, "\n")
      })

    version
  end

  defp blocking(key) do
    """
    ```question
    key: #{key}
    text: Which #{key}?
    options: [{label: a, detail: About a, recommended: true}, {label: b, detail: About b}]
    blocking: true
    ```
    """
  end

  defp non_blocking(key, assumption \\ "went with a") do
    """
    ```question
    key: #{key}
    text: Which #{key}?
    options: [{label: a, detail: About a, recommended: true}, {label: b, detail: About b}]
    blocking: false
    assumption: #{assumption}
    ```
    """
  end

  defp aged(version, seconds) do
    Repo.update_all(
      from(q in Question, where: q.artifact_version_id == ^version.id),
      set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -seconds, :second)]
    )
  end

  defp of(ticket), do: Enum.filter(Queue.items(), &(&1.ticket && &1.ticket.id == ticket.id))

  # **What makes a decision a merge decision is the state it enters**, not the names it pins: the
  # queue holds `reviewable` so every reader offers the diff first, and a merging transition that
  # approves something else was offered without it (`Forge.Engine.merge_decision?/2`).
  test "a resting ticket whose way out merges is reviewable, whatever it approves" do
    ticket = ticket_fixture()

    transitions =
      Enum.map(ticket.workflow["transitions"], fn
        %{"from" => "review_ready", "to" => "merged"} = transition ->
          %{transition | "approve" => ["refinement.md"]}

        transition ->
          transition
      end)

    merging = Map.put(ticket.workflow, "transitions", transitions)

    ticket =
      ticket
      |> Ecto.Changeset.change(state: "review_ready", status: :active, workflow: merging)
      |> Repo.update!()

    assert [%{kind: :review, detail: %{reviewable: true}}] = of(ticket)
  end

  test "a non-blocking question is an assumption, never a question" do
    ticket = ticket_fixture()
    job = job_fixture(%{ticket: ticket})
    ask(ticket, job, [blocking("backend"), non_blocking("naming", "scores")])

    assert [
             %{kind: :question, question: %{key: "backend"}},
             %{kind: :assumption, question: %{key: "naming"}, detail: detail}
           ] = of(ticket)

    assert detail.assumption == "scores"
    refute Queue.waiting?(%{kind: :assumption})
    assert Queue.waiting?(%{kind: :question})
  end

  # A ticket's own page counts what is waiting on it from this, so it has to be the queue's
  # reading of that ticket and not a second one.
  test "a ticket's items are the queue's items for it" do
    ticket = ticket_fixture()
    job = job_fixture(%{ticket: ticket})
    ask(ticket, job, [blocking("backend"), non_blocking("naming")])

    assert Enum.map(Queue.for_ticket(ticket), &{&1.kind, &1.question.key}) ==
             Enum.map(of(ticket), &{&1.kind, &1.question.key})

    # A finished ticket is in no queue, whatever it still holds.
    assert Queue.for_ticket(%{ticket | status: :done}) == []
  end

  # Oldest first is the queue's order, and an assumption does not take part in it: an age sorted
  # in beside a held job would compete with it for the same glance. They follow the decisions,
  # oldest first among themselves.
  test "assumptions follow every decision, whatever their age, oldest first" do
    older = ticket_fixture()
    newer = ticket_fixture()
    asking = ticket_fixture()

    oldest_assumption = ask(older, job_fixture(%{ticket: older}), [non_blocking("naming")])
    newest_assumption = ask(newer, job_fixture(%{ticket: newer}), [non_blocking("format")])
    decision = ask(asking, job_fixture(%{ticket: asking}), [blocking("backend")])

    aged(oldest_assumption, 7200)
    aged(newest_assumption, 3600)
    aged(decision, 60)

    keys =
      Queue.items()
      |> Enum.filter(&(&1.ticket.id in [older.id, newer.id, asking.id]))
      |> Enum.map(&{&1.kind, &1.question.key})

    assert keys == [{:question, "backend"}, {:assumption, "naming"}, {:assumption, "format"}]
  end

  # The decisions themselves are oldest first. The page sorts again as it groups, so a queue that
  # served them newest first looked right there — but the CLI and `GET /queue` print this order
  # as it comes, and the operator who reaches the end of either should have met the oldest first.
  test "decisions are oldest first, as served" do
    earlier = ticket_fixture()
    later = ticket_fixture()

    first = ask(earlier, job_fixture(%{ticket: earlier}), [blocking("backend")])
    second = ask(later, job_fixture(%{ticket: later}), [blocking("format")])

    aged(first, 7200)
    aged(second, 60)

    keys =
      Queue.items()
      |> Enum.filter(&(&1.ticket.id in [earlier.id, later.id]))
      |> Enum.map(& &1.question.key)

    assert keys == ["backend", "format"]
  end

  describe "answering one" do
    # `Operator.answer/4` resumes the waiting job once no blocking question is open. A
    # non-blocking answer closes none, so a job held by a blocking question stays held — and the
    # answer still reaches the next run, through `answers.md`.
    test "leaves a job waiting on a blocking question waiting" do
      user = user_fixture()
      ticket = ticket_fixture() |> join_ticket!(user)
      job = job_fixture(%{ticket: ticket, status: :waiting})
      ask(ticket, job, [blocking("backend"), non_blocking("naming")])

      assert {:ok, _ticket} = Operator.answer(ticket, user, "naming", %{choice: "b"})

      assert Jobs.get!(job.id).status == :waiting
      refute "job.resumed" in event_types(ticket)
      assert Artifacts.latest(ticket.id, "answers.md").content =~ "## naming"
      assert [%{kind: :question, question: %{key: "backend"}}] = of(ticket)

      # The other half, so the test can tell the two apart: the blocking answer does resume it.
      assert {:ok, _ticket} = Operator.answer(ticket, user, "backend", %{choice: "a"})
      assert Jobs.get!(job.id).status == :pending
      assert "job.resumed" in event_types(ticket)
    end
  end

  # `Operator.answer_all/4` is what the pages send: a document's answers together, written in one
  # transaction and resumed once (`docs/design/job-prompt.md` § Answering a document's questions at
  # once). Each refusal writes nothing, which is what "refused whole" means.
  describe "answering a document at once" do
    setup do
      user = user_fixture()
      ticket = ticket_fixture() |> join_ticket!(user)
      job = job_fixture(%{ticket: ticket, status: :waiting})

      version =
        ask(ticket, job, [blocking("backend"), blocking("format"), non_blocking("naming")])

      %{user: user, ticket: ticket, job: job, version: version}
    end

    test "writes every answer in one version and resumes the job once", %{
      user: user,
      ticket: ticket,
      job: job,
      version: version
    } do
      assert {:ok, _ticket} =
               Operator.answer_all(ticket, user, version.id, %{
                 "backend" => %{choice: "a", text: nil},
                 "format" => %{choice: "b", text: "but keep it small"}
               })

      assert %{version: 1, content: content} = Artifacts.latest(ticket.id, "answers.md")
      assert content =~ "## backend"
      assert content =~ "A: b — but keep it small"
      assert Jobs.get!(job.id).status == :pending
      assert Enum.count(event_types(ticket), &(&1 == "job.resumed")) == 1
      assert Enum.count(event_types(ticket), &(&1 == "question.answered")) == 2

      # The assumption was optional and left out, so it is still open.
      assert [%{key: "naming"}] = Artifacts.open_questions(ticket.id)
    end

    test "refuses a batch missing a blocking answer", %{
      user: user,
      ticket: ticket,
      job: job,
      version: version
    } do
      assert {:error, {:unanswered, ["format"]}} =
               Operator.answer_all(ticket, user, version.id, %{
                 "backend" => %{choice: "a", text: nil},
                 "naming" => %{choice: "b", text: nil}
               })

      assert_nothing_written(ticket, job)
    end

    test "refuses a choice that is no label, and the rest of the batch with it", %{
      user: user,
      ticket: ticket,
      job: job,
      version: version
    } do
      assert {:error, {:not_an_option, "format", "c"}} =
               Operator.answer_all(ticket, user, version.id, %{
                 "backend" => %{choice: "a", text: nil},
                 "format" => %{choice: "c", text: nil}
               })

      assert_nothing_written(ticket, job)
    end

    test "refuses a stale form: a newer version, or a question answered meanwhile", %{
      user: user,
      ticket: ticket,
      job: job,
      version: version
    } do
      answers = %{"backend" => %{choice: "a", text: nil}, "format" => %{choice: "a", text: nil}}

      assert {:error, :stale} =
               Operator.answer_all(
                 ticket,
                 user,
                 version.id,
                 Map.put(answers, "other", %{choice: "a", text: nil})
               )

      # Answered by someone else while the form was open: its key is no longer open.
      {:ok, _ticket} = Operator.answer(ticket, user, "naming", %{choice: "a"})

      assert {:error, :stale} =
               Operator.answer_all(
                 ticket,
                 user,
                 version.id,
                 Map.put(answers, "naming", %{choice: "b", text: nil})
               )

      # The document written again: the form's version is not the latest, so nothing on it is open.
      ask(ticket, job, [blocking("backend"), blocking("format")])
      assert {:error, :stale} = Operator.answer_all(ticket, user, version.id, answers)

      assert Jobs.get!(job.id).status == :waiting
      assert [%{question: %{key: "naming"}}] = Artifacts.answered(ticket.id)
    end

    # The pages send `""` for a cleared choice; a blank choice beside text is the text, whichever
    # surface sends it.
    test "reads a blank choice as none", %{user: user, ticket: ticket, version: version} do
      assert {:ok, _ticket} =
               Operator.answer_all(ticket, user, version.id, %{
                 "backend" => %{choice: "", text: "neither, use JSON"},
                 "format" => %{choice: "a", text: " "}
               })

      answers = Map.new(Artifacts.answered(ticket.id), &{&1.question.key, &1.answer})
      assert %{choice: nil, text: "neither, use JSON"} = answers["backend"]
      assert %{choice: "a", text: nil} = answers["format"]
    end

    # `answers.md` lists a batch in the order the document asked, not the order the keys arrived
    # in — here the reverse, and the reverse of the alphabet too.
    test "records a batch in the order it was asked", %{user: user, ticket: ticket, job: job} do
      version = ask(ticket, job, [blocking("zeta"), blocking("alpha")])

      assert {:ok, _ticket} =
               Operator.answer_all(ticket, user, version.id, %{
                 "alpha" => %{choice: "a", text: nil},
                 "zeta" => %{choice: "b", text: nil}
               })

      content = Artifacts.latest(ticket.id, "answers.md").content
      assert :binary.match(content, "## zeta") < :binary.match(content, "## alpha")
    end

    test "refuses an empty batch", %{user: user, ticket: ticket, job: job, version: version} do
      assert {:error, :no_answers} = Operator.answer_all(ticket, user, version.id, %{})
      assert_nothing_written(ticket, job)
    end

    defp assert_nothing_written(ticket, job) do
      assert Artifacts.latest(ticket.id, "answers.md") == nil
      assert Artifacts.answered(ticket.id) == []
      assert Jobs.get!(job.id).status == :waiting
    end
  end

  # `docs/design/job-prompt.md` § Non-blocking questions: the document written on an assumption
  # does not change when the answer comes, so the answer says which document it amends and
  # whether it overturns what that document assumed. Ten jobs on one ticket each re-derived it.
  describe "an answer to an assumed question" do
    setup do
      user = user_fixture()
      ticket = ticket_fixture() |> join_ticket!(user)
      %{user: user, ticket: ticket, job: job_fixture(%{ticket: ticket})}
    end

    defp answers(ticket), do: Artifacts.latest(ticket.id, "answers.md").content

    test "that picks another option says it overturns the assumption, and where", context do
      block = """
      ```question
      key: schema
      anchor: A new drill is one file under core
      text: Where are a drill's settings declared?
      options:
        - {label: declared-in-core, detail: Settings are declared in core, recommended: true}
        - {label: own-composable, detail: Each drill composes its own settings}
      blocking: false
      assumption: declared-in-core
      ```
      """

      ask(context.ticket, context.job, [block])

      {:ok, _} =
        Operator.answer(context.ticket, context.user, "schema", %{choice: "own-composable"})

      assert answers(context.ticket) =~
               "**This overturns an assumption.** `refinement.md` version 1 was written assuming " <>
                 "`declared-in-core`, at the passage beginning \"A new drill is one file under core\". " <>
                 "Where it says otherwise, this answer holds, not the document."
    end

    test "that picks the assumed option confirms it", context do
      ask(context.ticket, context.job, [non_blocking("naming", "a")])
      {:ok, _} = Operator.answer(context.ticket, context.user, "naming", %{choice: "a"})

      assert answers(context.ticket) =~
               "`refinement.md` version 1 assumed `a` and carried on; this confirms it."

      refute answers(context.ticket) =~ "overturns"
    end

    # The version the question was asked in, not the first: a refinement that asked on its second
    # round is amended there — as it is answered, and when a later answer renders it again.
    test "names the version of the document that assumed it", context do
      ask(context.ticket, context.job, [])
      ask(context.ticket, context.job, [non_blocking("naming", "a"), blocking("backend")])
      {:ok, _} = Operator.answer(context.ticket, context.user, "naming", %{choice: "b"})

      assert answers(context.ticket) =~ "`refinement.md` version 2 was written assuming `a`"

      {:ok, _} = Operator.answer(context.ticket, context.user, "backend", %{choice: "a"})

      assert answers(context.ticket) =~ "## backend"
      assert answers(context.ticket) =~ "`refinement.md` version 2 was written assuming `a`"
    end

    # Prose cannot be compared with a choice, so the entry names the assumption and leaves the
    # comparison to the reader rather than guessing.
    test "on an assumption in prose names it without claiming either way", context do
      ask(context.ticket, context.job, [non_blocking("naming", "went with a")])
      {:ok, _} = Operator.answer(context.ticket, context.user, "naming", %{choice: "b"})

      assert answers(context.ticket) =~
               "`refinement.md` version 1 was written assuming: went with a. " <>
                 "Where this answer differs, the answer holds, not the document."

      refute answers(context.ticket) =~ "overturns"
    end

    # Rendered again from the rows on every later answer, so an earlier entry keeps what it said.
    test "keeps saying it when a later answer rewrites the document", context do
      ask(context.ticket, context.job, [non_blocking("naming", "a"), blocking("backend")])
      {:ok, _} = Operator.answer(context.ticket, context.user, "naming", %{choice: "b"})
      {:ok, _} = Operator.answer(context.ticket, context.user, "backend", %{choice: "a"})

      assert answers(context.ticket) =~ "## backend"
      assert answers(context.ticket) =~ "`refinement.md` version 1 was written assuming `a`"
    end

    test "a blocking question's answer says nothing of an assumption", context do
      ask(context.ticket, context.job, [blocking("backend")])
      {:ok, _} = Operator.answer(context.ticket, context.user, "backend", %{choice: "b"})

      refute answers(context.ticket) =~ "assum"
    end
  end

  # `worker_status/1`: the second list, for the Queue page alone — a ticket whose current job is
  # running on a worker, or still pending. Not a decision and in no count, so what is tested here
  # is which tickets are in it and which are deliberately not: a stuck one, a finished one, and
  # another project's (`docs/design/ui.md` § A job waiting for a machine).
  describe "work under way" do
    setup do
      project = project_fixture()
      %{project: project, user: member_fixture(project)}
    end

    defp worker! do
      {:ok, worker, _token} = Forge.Workers.create(%{provider: "fake"})
      worker
    end

    defp under_way(user, ticket),
      do: Enum.filter(Queue.worker_status(user), &(&1.ticket.id == ticket.id))

    defp activate!(ticket) do
      {:ok, ticket} =
        Repo.update(
          Forge.Tickets.Ticket.progress_changeset(ticket, %{
            state: ticket.state,
            status: :active,
            cost_usd: ticket.cost_usd
          })
        )

      ticket
    end

    test "a job running on an assigned worker is on worker", context do
      ticket = ticket_fixture(%{project: context.project})
      job = job_fixture(%{ticket: ticket, worker_id: worker!().id, status: :running})

      assert [%{kind: :on_worker, detail: %{job_id: job_id}}] = under_way(context.user, ticket)
      assert job_id == job.id
    end

    # The age beside *Running on a worker* is the run's, not the row's. A job made at 09:00 and
    # held for room until 19:00 reads "10h" five minutes into its run if `inserted_at` is used
    # for both kinds, and one column then means two different things on two adjacent lines.
    # The *current* run's start, which is the run ledger's and not `jobs.started_at`:
    # `Jobs.mark_started/3` writes that column `job.started_at || now` and nothing rewrites it, so
    # from the second run on it holds the first run's start. A job answered at 19:00 after
    # stopping on a question at 09:10 read ten hours old a minute into its second run.
    test "a running job is aged from the run it is in, not the run it first had", context do
      ticket = ticket_fixture(%{project: context.project})
      worker = worker!()
      job = job_fixture(%{ticket: ticket, worker_id: worker.id, status: :running})
      first = DateTime.add(DateTime.utc_now(:second), -36_000, :second)
      now = DateTime.add(DateTime.utc_now(:second), -60, :second)
      {:ok, job} = Repo.update(Ecto.Changeset.change(job, started_at: first))

      # The run that ended, and the one it is in. The ledger keeps both; the column keeps one.
      Repo.insert!(%Forge.Jobs.Run{
        job_id: job.id,
        worker_id: worker.id,
        started_at: first,
        finished_at: DateTime.add(first, 600, :second)
      })

      Repo.insert!(%Forge.Jobs.Run{job_id: job.id, worker_id: worker.id, started_at: now})

      assert [%{since: ^now}] = under_way(context.user, ticket)
    end

    # The first fallback: a running row whose run the ledger does not have — which production
    # cannot produce, since `Runs.open/5` is in the transaction that marks a job running, but a
    # changeset written by hand can and the suite does.
    test "a running job with no open run falls back to its own start", context do
      ticket = ticket_fixture(%{project: context.project})
      job = job_fixture(%{ticket: ticket, worker_id: worker!().id, status: :running})
      started = DateTime.add(DateTime.utc_now(:second), -60, :second)
      {:ok, job} = Repo.update(Ecto.Changeset.change(job, started_at: started))

      refute DateTime.compare(job.inserted_at, started) == :eq
      assert [%{since: ^started}] = under_way(context.user, ticket)
    end

    # The fallback under that rule. `Jobs.mark_started/3` writes `started_at` in the same update
    # as the status, so production has no `:running` row without one — but a changeset written by
    # hand does, and a `since` of nil takes the sort and the page down rather than losing a line.
    test "a running row with no start time is aged from its creation", context do
      ticket = ticket_fixture(%{project: context.project})
      job = job_fixture(%{ticket: ticket, worker_id: worker!().id, status: :running})

      assert is_nil(job.started_at)
      assert [%{since: since}] = under_way(context.user, ticket)
      assert since == job.inserted_at
    end

    # A pending job is aged from its creation — how long the ticket has been held, the number the
    # operator came to the queue for. A job that ran, stopped and was resumed is pending *with* a
    # `started_at`, and that is a run that has ended: aging the line from it would say the ticket
    # had been waiting since a run that is over.
    test "a pending job is aged from when it was created, even once it has run", context do
      ticket = ticket_fixture(%{project: context.project})
      job = job_fixture(%{ticket: ticket, worker_id: worker!().id, status: :waiting})
      started = DateTime.add(DateTime.utc_now(:second), -60, :second)
      {:ok, job} = Repo.update(Ecto.Changeset.change(job, started_at: started))
      {:ok, job} = Jobs.resume(job)

      assert job.status == :pending
      refute is_nil(job.started_at)
      assert [%{since: since}] = under_way(context.user, ticket)
      assert since == job.inserted_at
    end

    # The whole distinction the ticket asks for: this one is not on a machine, and the operator
    # should be able to tell without opening it.
    test "a pending job is awaiting a worker", context do
      ticket = ticket_fixture(%{project: context.project})
      job_fixture(%{ticket: ticket})

      assert [%{kind: :awaiting_worker}] = under_way(context.user, ticket)
    end

    # `worker_id` records where the job's last run was, not a reservation: `Jobs.resume/1` leaves
    # it on the row. A job a person has just unblocked is waiting for a machine like any other.
    test "a resumed job still awaits a worker, stale worker and all", context do
      ticket = ticket_fixture(%{project: context.project})
      job = job_fixture(%{ticket: ticket, worker_id: worker!().id, status: :waiting})

      {:ok, resumed} = Jobs.resume(job)
      assert resumed.status == :pending
      refute is_nil(resumed.worker_id)

      assert [%{kind: :awaiting_worker}] = under_way(context.user, ticket)
    end

    # A running job carries the worker it was started on, written in the same update as the
    # status (`Jobs.mark_started/3`). A row saying it runs on nothing is not something to label
    # "running on a worker".
    test "a running job with no worker is neither", context do
      ticket = ticket_fixture(%{project: context.project})
      job_fixture(%{ticket: ticket, status: :running})

      assert under_way(context.user, ticket) == []
    end

    # Criterion 5, which the read keeps by construction: a job that is not live is never loaded,
    # so nothing a ticket once did can be mistaken for what it is doing. Widen the status filter
    # and the ticket is reported as running on a worker forever.
    #
    # **One job in every status that is not live, each carrying the `worker_id` it ran on**, which
    # is what makes each one catchable: `live_job/1` rejects a row with no worker whatever the
    # status filter says, so a defanged row in the fixture defends nothing. `:finished` is where
    # every completed job stops, `:hibernated` where one that will be resumed waits, `:waiting`
    # where one stopped on a blocking question sits, and `:parked` where an agent waits for the
    # commands it invoked. This fixture was extended one status at a time as each was found
    # undefended; it is all four now, so the claim at `live_job/1` holds for every status rather
    # than for the two that had been looked at.
    test "a job that has finished is never the ticket's work, however it ended", context do
      ticket = ticket_fixture(%{project: context.project})
      done = job_fixture(%{ticket: ticket, worker_id: worker!().id})

      {:ok, _finished} =
        Repo.update(
          Forge.Jobs.Job.progress_changeset(done, %{status: :finished, outcome: :converged})
        )

      job_fixture(%{ticket: ticket, worker_id: worker!().id, status: :hibernated, attempt: 2})
      job_fixture(%{ticket: ticket, worker_id: worker!().id, status: :waiting, attempt: 3})
      job_fixture(%{ticket: ticket, worker_id: worker!().id, status: :parked, attempt: 4})

      assert under_way(context.user, ticket) == []
    end

    # A conversation is not the ticket's work. It is already in the queue above, as a `:chat`
    # decision for as long as it waits on a person (`docs/design/conversations.md` § In the
    # queue), and a second line down here would draw one ticket twice — once as something waiting
    # on you and once as work on a machine.
    test "a conversation on the ticket is not its work", context do
      ticket = ticket_fixture(%{project: context.project})

      chat =
        chat_fixture(%{
          ticket_id: ticket.id,
          project: context.project,
          worker_id: worker!().id,
          status: :running
        })

      # Spoken last by the agent, which is what puts it in the queue above as a decision. Both
      # halves are asserted here, because "the ticket would be drawn twice" is the reason for
      # the exclusion and is worth showing rather than claiming.
      :ok =
        Jobs.record_harness_event(chat.id, %{type: "job.harness.text", payload: %{text: "well?"}})

      {:ok, _chat} =
        Forge.Conversations.record_turn(chat, %{
          "turn" => 1,
          "harness" => %{"turns" => 1, "cost_usd" => 0.01, "subtype" => "success"}
        })

      assert [%{kind: :chat}] =
               Enum.filter(Queue.items(context.user), &(&1.ticket && &1.ticket.id == ticket.id))

      assert under_way(context.user, ticket) == []

      # The chat carries a worker, which is what the mutation-sensitivity of this test rests on:
      # with a nil one, dropping the kind filter would answer `:none` rather than `:on_worker`
      # and the assertion above would pass against the broken code.
      assert Repo.get(Forge.Jobs.Job, chat.id).worker_id

      # And the ticket is otherwise in range: give it a workflow job on a worker and it appears,
      # so the absence above is the kind filter and not the ticket being out of reach.
      job_fixture(%{ticket: ticket, worker_id: worker!().id, status: :running})
      assert [%{kind: :on_worker}] = under_way(context.user, ticket)
    end

    # Finding A of the second review. A command is created *after* the agent that invoked it, so
    # the newest row is the command — and once that command finished and the agent resumed, the
    # newest row was a finished command and the ticket left the group for the rest of its state.
    # `implementing` in this repository may invoke ten of them.
    test "an agent resumed after its command finished is back on its worker", context do
      ticket = ticket_fixture(%{project: context.project})
      agent = job_fixture(%{ticket: ticket, worker_id: worker!().id, status: :parked})
      command = job_fixture(%{ticket: ticket, kind: :command, state: "check"})

      {:ok, _done} =
        Repo.update(
          Forge.Jobs.Job.progress_changeset(command, %{status: :finished, outcome: :converged})
        )

      {:ok, _running} =
        Repo.update(Forge.Jobs.Job.progress_changeset(agent, %{status: :running}))

      assert [%{kind: :on_worker, detail: %{job_id: id}}] = under_way(context.user, ticket)
      assert id == agent.id
    end

    # Finding D, the half that drew a false line. A batch is inserted in declared order, so the
    # newest row of `invoke: [lint, build]` is `build` — and with machines scarce `lint` runs
    # while `build` is still pending. Reading the newest row said *not yet on a worker* for a
    # ticket that was on one.
    test "a batch running one command and waiting on another is on a worker", context do
      ticket = ticket_fixture(%{project: context.project})
      job_fixture(%{ticket: ticket, status: :parked})

      running =
        job_fixture(%{
          ticket: ticket,
          kind: :command,
          state: "lint",
          worker_id: worker!().id,
          status: :running
        })

      job_fixture(%{ticket: ticket, kind: :command, state: "build"})

      assert [%{kind: :on_worker, detail: %{job_id: id}}] = under_way(context.user, ticket)
      assert id == running.id
    end

    # Finding D, the half that drew no line: `build` exits in five seconds while `lint` runs for
    # twenty minutes, and the finished one is the newest row.
    test "a batch whose newest command has finished is still on a worker", context do
      ticket = ticket_fixture(%{project: context.project})
      job_fixture(%{ticket: ticket, status: :parked})

      job_fixture(%{
        ticket: ticket,
        kind: :command,
        state: "lint",
        worker_id: worker!().id,
        status: :running
      })

      done = job_fixture(%{ticket: ticket, kind: :command, state: "build"})

      {:ok, _} =
        Repo.update(
          Forge.Jobs.Job.progress_changeset(done, %{status: :finished, outcome: :converged})
        )

      assert [%{kind: :on_worker}] = under_way(context.user, ticket)
    end

    # Within the winning class the newest is the one the line describes: of two commands waiting
    # for room, the line is about the later. Not a rule anybody can act on, but the age beside it
    # is read, so which row it comes from is not arbitrary.
    test "the newest of the waiting jobs is the one described", context do
      ticket = ticket_fixture(%{project: context.project})
      job_fixture(%{ticket: ticket, status: :parked})
      job_fixture(%{ticket: ticket, kind: :command, state: "lint"})
      newer = job_fixture(%{ticket: ticket, kind: :command, state: "build"})

      assert [%{kind: :awaiting_worker, detail: %{job_id: id}}] = under_way(context.user, ticket)
      assert id == newer.id
    end

    # A command state creates no workflow job at all, and an agent that invoked a command parks
    # while it runs, so a read of workflow jobs alone left the group empty — and the page saying
    # "Nothing needs you" — while a build was on a machine. The ticket's own page gets this right
    # from the same two reads, which is the pair this follows.
    test "a command running on a worker puts its ticket on a worker", context do
      ticket = ticket_fixture(%{project: context.project})
      job_fixture(%{ticket: ticket, status: :hibernated})

      job_fixture(%{
        ticket: ticket,
        kind: :command,
        state: "check",
        worker_id: worker!().id,
        status: :running
      })

      assert [%{kind: :on_worker}] = under_way(context.user, ticket)
    end

    test "a command still waiting for a machine leaves its ticket waiting", context do
      ticket = ticket_fixture(%{project: context.project})
      job_fixture(%{ticket: ticket, status: :parked})
      job_fixture(%{ticket: ticket, kind: :command, state: "check"})

      assert [%{kind: :awaiting_worker}] = under_way(context.user, ticket)
    end

    test "a ticket with no jobs at all is in neither", context do
      ticket = ticket_fixture(%{project: context.project})

      assert under_way(context.user, ticket) == []
    end

    # Criterion 6. A placement stick leaves the pending job on the row (`Engine.stick/3`, and
    # `Engine.resume_placement/2`'s doc says so), so this ticket matches the pending clause on
    # everything but its status — and
    # it already has an accent flag saying it needs a person. A second, quieter line saying it is
    # merely waiting for a machine would contradict it.
    test "a stuck ticket keeps its flag instead of a quiet line", context do
      ticket = ticket_fixture(%{project: context.project})
      job_fixture(%{ticket: ticket})
      {:ok, _stuck} = Forge.Engine.stick(ticket, "no template could hold it", :placement)

      assert under_way(context.user, ticket) == []

      # And it is in the queue proper, as the accent item: the ticket is visible, just not here.
      assert [%{kind: :stuck}] =
               Enum.filter(Queue.items(context.user), &(&1.ticket.id == ticket.id))
    end

    # `docs/design/capacity.md` keeps a paused ticket **out of the queue entirely**: it is drawn
    # `PAUSED · SPEND` where it lives, and an item in the queue the operator cannot act on is the
    # failure that note is written against. The cap is node-wide, so without this every active
    # ticket on the node arrives in the group at once, under a sentence about workers, with the
    # workers idle.
    test "the daily spend cap keeps a waiting ticket out of the group", context do
      ticket = ticket_fixture(%{project: context.project})
      job_fixture(%{ticket: ticket})
      assert [%{kind: :awaiting_worker}] = under_way(context.user, ticket)

      pause_spend!()
      assert Forge.Spend.paused?()
      assert under_way(context.user, ticket) == []
    end

    # The cap stops the *next* job from starting; it does not stop the one already on a machine,
    # and a line saying so is not an item anybody is being asked to act on.
    test "the daily spend cap leaves a running ticket alone", context do
      ticket = ticket_fixture(%{project: context.project})
      job_fixture(%{ticket: ticket, worker_id: worker!().id, status: :running})

      # A second ticket with a pending job, so that there is something for the cap to drop. The
      # version of this test without it could not fail: with nothing pending the page never asked
      # whether it was capped, and dropping the rule that spares a running ticket changed nothing.
      held = ticket_fixture(%{project: context.project})
      job_fixture(%{ticket: held})

      pause_spend!()

      assert [%{kind: :on_worker}] = under_way(context.user, ticket)
      assert under_way(context.user, held) == []
    end

    # **A command takes no spend gate.** `Jobs.assign_command/2` says so in as many words and
    # never calls `spend_gate/2`, so the scheduler places a pending command at the next pass
    # whatever the cap says. Dropping one would hide a ticket that is only waiting for room, for
    # as long as the cap lasts.
    test "the daily spend cap does not hide a ticket waiting on a command", context do
      ticket = ticket_fixture(%{project: context.project})
      job_fixture(%{ticket: ticket, status: :parked})
      job_fixture(%{ticket: ticket, kind: :command, state: "check"})

      pause_spend!()

      assert [%{kind: :awaiting_worker}] = under_way(context.user, ticket)
    end

    # The other pause `capacity.md` keeps out of the queue, and the one that is per project
    # rather than node-wide: the scheduler records it on the job, and that record is what is read
    # — the same one the ticket's own timeline prints.
    test "a rate-limited credential pool keeps a waiting ticket out of the group", context do
      ticket = ticket_fixture(%{project: context.project})
      job = job_fixture(%{ticket: ticket})
      assert [%{kind: :awaiting_worker}] = under_way(context.user, ticket)

      :ok = Jobs.record_wait(job, "limited", "Waiting for a limit to reset: ...")
      assert under_way(context.user, ticket) == []
    end

    # Only the pauses. A job held for want of room is exactly what this group is for, and a
    # denylist that swallowed every recorded reason would empty it.
    test "a wait for room is still in the group", context do
      ticket = ticket_fixture(%{project: context.project})
      job = job_fixture(%{ticket: ticket})
      :ok = Jobs.record_wait(job, "at_capacity", "Waiting for room: ...")

      assert [%{kind: :awaiting_worker}] = under_way(context.user, ticket)
    end

    # The *latest* reason, not the first: a job passed over for a limit and then, once the limit
    # reset, for want of room is waiting for room.
    test "the reason read is the last one recorded", context do
      ticket = ticket_fixture(%{project: context.project})
      job = job_fixture(%{ticket: ticket})
      :ok = Jobs.record_wait(job, "limited", "Waiting for a limit to reset: ...")
      :ok = Jobs.record_wait(job, "at_capacity", "Waiting for room: ...")

      assert [%{kind: :awaiting_worker}] = under_way(context.user, ticket)
    end

    defp pause_spend! do
      previous = Application.get_env(:forge, Forge.Spend, [])
      Application.put_env(:forge, Forge.Spend, daily_cost_usd: 0.0)
      ExUnit.Callbacks.on_exit(fn -> Application.put_env(:forge, Forge.Spend, previous) end)
    end

    test "a finished ticket is in neither, whatever its last job says", context do
      ticket = ticket_fixture(%{project: context.project})
      job_fixture(%{ticket: ticket, worker_id: worker!().id, status: :running})

      {:ok, _done} =
        Repo.update(
          Forge.Tickets.Ticket.progress_changeset(ticket, %{
            state: ticket.state,
            status: :done,
            cost_usd: ticket.cost_usd
          })
        )

      assert under_way(context.user, ticket) == []
    end

    # The read that leaks most easily, the same way `items/1` leaks it
    # (`docs/design/identity.md` § Read scoping is the half that leaks).
    test "another project's ticket is never in it", context do
      elsewhere = ticket_fixture()
      job_fixture(%{ticket: elsewhere})

      assert under_way(context.user, elsewhere) == []

      # Visible to one of its own members, so the absence above is the scoping and not the shape.
      assert [%{kind: :awaiting_worker}] =
               under_way(member_fixture(Forge.Projects.get!(elsewhere.project_id)), elsewhere)
    end

    test "oldest first", context do
      older = activate!(ticket_fixture(%{project: context.project}))
      newer = activate!(ticket_fixture(%{project: context.project}))
      job_fixture(%{ticket: older})
      job_fixture(%{ticket: newer})

      age(older, 3600)

      assert [older.id, newer.id] ==
               context.user |> Queue.worker_status() |> Enum.map(& &1.ticket.id)
    end

    defp age(ticket, seconds) do
      Repo.update_all(
        from(j in Forge.Jobs.Job, where: j.ticket_id == ^ticket.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -seconds, :second)]
      )
    end
  end

  # Neither kind waits on a person, so nothing that counts what is waiting may count them: the
  # push gate and the page's header are both `waiting?/1`, and the clause is what keeps a running
  # job off somebody's phone.
  test "neither kind of work under way is waiting on a person" do
    refute Queue.waiting?(%{kind: :on_worker})
    refute Queue.waiting?(%{kind: :awaiting_worker})

    # The catch-all still says yes for a kind that is a decision, so the two clauses above are
    # doing the work and not a blanket `false`.
    assert Queue.waiting?(%{kind: :stuck})
  end

  # The boundary the design rests on: `items/1` is what the JSON API, the CLI and the push digest
  # read, and `Forge.CLI.queue_line/1` has no catch-all clause. A later change that folded the two
  # functions together would reach all three, and should trip this instead.
  test "items/1 carries neither kind, even for a ticket that is in worker_status/1" do
    project = project_fixture()
    user = member_fixture(project)
    ticket = ticket_fixture(%{project: project})

    job_fixture(%{
      ticket: ticket,
      worker_id: elem(Forge.Workers.create(%{provider: "fake"}), 1).id,
      status: :running
    })

    assert [%{kind: :on_worker}] = Queue.worker_status(user)
    assert Enum.filter(Queue.items(user), &(&1.kind in [:on_worker, :awaiting_worker])) == []
  end

  defp event_types(ticket), do: ticket.id |> Events.for_ticket() |> Enum.map(& &1.type)
end
