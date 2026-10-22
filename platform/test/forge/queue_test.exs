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

      assert [%{kind: :on_worker, since: since, detail: %{job_id: job_id}}] =
               under_way(context.user, ticket)

      assert job_id == job.id
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

    # Criterion 5, and the mutation that matters most: read the first job instead of the last and
    # this ticket is reported as running on a worker forever.
    test "only the current job counts, not an earlier one", context do
      ticket = ticket_fixture(%{project: context.project})
      job_fixture(%{ticket: ticket, worker_id: worker!().id, status: :running})
      job_fixture(%{ticket: ticket, status: :waiting, attempt: 2})

      assert under_way(context.user, ticket) == []
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
