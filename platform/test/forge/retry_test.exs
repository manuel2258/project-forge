defmodule Forge.RetryTest do
  @moduledoc """
  Running a ticket's state again, and the transitions a person is offered while it rests there
  (`docs/design/workflow-grammar-v1.md` § Running a state again).

  Two refinements failed in production and left their tickets stuck in `refining`, offering only
  `planning` — which approves a refinement that was never written, and failed when taken. There
  was no way to run the refinement again short of admitting the ticket a second time.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Engine, Events, FakeWorker, Jobs, Queue, Tickets}
  alias Forge.Jobs.Job

  setup do
    {:ok, project} =
      register_owned!(%{
        name: "again-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo()
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

    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})

    %{project: project, user: user, ticket: ticket, worker: FakeWorker.connect()}
  end

  defp run(job, worker, scenario, doc), do: FakeWorker.run(job, worker, scenario, doc: doc)

  defp only_pending(ticket) do
    assert [%Job{status: :pending} = job] =
             Enum.filter(Jobs.for_ticket(ticket.id), &(&1.status == :pending))

    job
  end

  defp offered(ticket) do
    ticket = Tickets.get!(ticket.id)
    Engine.offered_transitions(ticket, Tickets.workflow(ticket))
  end

  describe "a state whose job failed" do
    setup %{ticket: ticket, worker: worker} do
      {:ok, _job} = run(only_pending(ticket), worker, "invalid_document", "refinement.md")
      assert %{status: :stuck, state: "refining"} = Tickets.get!(ticket.id)
      :ok
    end

    test "offers no transition that would approve a document it never wrote", %{ticket: ticket} do
      assert offered(ticket) == []
    end

    test "refuses that transition with the name of what has no version", %{
      ticket: ticket,
      user: user
    } do
      assert {:error, {:no_version, "refinement.md"}} =
               Engine.choose(Tickets.get!(ticket.id), user.id, "planning")
    end

    test "is run again: the next attempt, the ticket unstuck, and the retry recorded", %{
      ticket: ticket,
      user: user
    } do
      ticket = Tickets.get!(ticket.id)
      assert Engine.retryable?(ticket)

      {:ok, ticket} = Engine.retry(ticket, user.id)

      assert %{status: :active, state: "refining", pending_transition: nil} = ticket
      assert %Job{state: "refining", attempt: 2} = only_pending(ticket)

      assert [%{payload: %{"state" => "refining"}, actor: %{"kind" => "user"}}] =
               Enum.filter(Events.for_ticket(ticket.id), &(&1.type == "ticket.retried"))
    end

    test "is offered on the stuck card in the queue", %{ticket: ticket} do
      assert [%{kind: :stuck, detail: %{retry: true, transitions: []}}] =
               Enum.filter(Queue.items(), &(&1.ticket.id == ticket.id))
    end
  end

  # A refinement a person wants done afresh before approving it. The approval that was pending
  # was of the version about to be replaced, so it goes.
  test "a state whose job succeeded is run again too, and the pending approval goes", %{
    ticket: ticket,
    user: user,
    worker: worker
  } do
    {:ok, _job} = run(only_pending(ticket), worker, "success", "refinement.md")
    ticket = Tickets.get!(ticket.id)
    assert ticket.pending_transition["to"] == "planning"
    assert offered(ticket) == ["planning"]

    {:ok, ticket} = Engine.retry(ticket, user.id)

    assert ticket.pending_transition == nil
    assert %Job{attempt: 2} = only_pending(ticket)
  end

  # How the job arrived is what a tester's comment reaches it through. A second attempt of the
  # same state arrived the same way, and is told so.
  test "the next attempt is told how the state was entered, as the last one was", %{
    ticket: ticket,
    user: user,
    worker: worker
  } do
    {:ok, _job} = run(only_pending(ticket), worker, "success", "refinement.md")
    {:ok, ticket} = Engine.decide(Tickets.get!(ticket.id), user.id, :approved, "keep it local")

    first = only_pending(ticket)
    assert %{"comment" => "keep it local"} = entered = Jobs.spec(first).entered

    {:ok, _job} = run(first, worker, "invalid_document", "plan.md")
    {:ok, ticket} = Engine.retry(Tickets.get!(ticket.id), user.id)

    assert Jobs.spec(only_pending(ticket)).entered == entered
  end

  # A state entered twice arrived differently each time; a retry is told the latest arrival, not
  # the first. Here `planning` was entered from `refining` with a comment, and then again from
  # `implementing` when the plan did not work.
  test "the next attempt is told the latest arrival, not the first", %{
    ticket: ticket,
    user: user,
    worker: worker
  } do
    {:ok, _job} = run(only_pending(ticket), worker, "success", "refinement.md")
    {:ok, ticket} = Engine.decide(Tickets.get!(ticket.id), user.id, :approved, "keep it local")
    {:ok, _job} = run(only_pending(ticket), worker, "success", "plan.md")

    {:ok, _job} =
      run(only_pending(Tickets.get!(ticket.id)), worker, "plan_invalid", "implementation.md")

    ticket = Tickets.get!(ticket.id)
    assert ticket.state == "planning"
    second = only_pending(ticket)
    assert %{"from" => "implementing"} = Jobs.spec(second).entered

    {:ok, _job} = run(second, worker, "invalid_document", "plan.md")
    {:ok, ticket} = Engine.retry(Tickets.get!(ticket.id), user.id)

    assert %Job{attempt: 3} = third = only_pending(ticket)
    assert %{"from" => "implementing"} = Jobs.spec(third).entered
  end

  test "is refused while a job in the state is live", %{ticket: ticket, user: user} do
    refute Engine.retryable?(ticket)
    assert {:error, {:job_live, "refining"}} = Engine.retry(ticket, user.id)
    assert [%Job{attempt: 1}] = Jobs.for_ticket(ticket.id)
  end

  test "is refused in a state no job runs in, and on a ticket that is done", %{
    ticket: ticket,
    user: user,
    worker: worker
  } do
    {:ok, _job} = run(only_pending(ticket), worker, "invalid_document", "refinement.md")

    {:ok, human} =
      ticket.id |> Tickets.get!() |> Ecto.Changeset.change(state: "nowhere") |> Repo.update()

    refute Engine.retryable?(human)
    assert {:error, {:no_job_in, "nowhere"}} = Engine.retry(human, user.id)

    {:ok, done} =
      ticket.id
      |> Tickets.get!()
      |> Ecto.Changeset.change(state: "refining", status: :done)
      |> Repo.update()

    refute Engine.retryable?(done)
    assert {:error, {:not_retryable, :done}} = Engine.retry(done, user.id)
  end
end
