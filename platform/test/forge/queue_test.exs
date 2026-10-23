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

  defp event_types(ticket), do: ticket.id |> Events.for_ticket() |> Enum.map(& &1.type)
end
