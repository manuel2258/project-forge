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
    options: [a, b]
    default: a
    blocking: true
    ```
    """
  end

  defp non_blocking(key, assumption \\ "went with a") do
    """
    ```question
    key: #{key}
    text: Which #{key}?
    options: [a, b]
    default: a
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

  defp event_types(ticket), do: ticket.id |> Events.for_ticket() |> Enum.map(& &1.type)
end
