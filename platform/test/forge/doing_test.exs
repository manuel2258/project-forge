defmodule Forge.Tickets.DoingTest do
  @moduledoc """
  What a project's open tickets are doing (`Forge.Tickets.Doing`): the live job of each, the last
  thing its agent said, and the project's recent merges — each a rule the project page draws and
  no page test can tell apart from a near miss.
  """

  use Forge.DataCase, async: true

  import Forge.ForgeFixtures

  alias Forge.Events.Event
  alias Forge.Repo
  alias Forge.Tickets.Doing

  defp event!(ticket, type, payload, at \\ nil) do
    Repo.insert!(%Event{
      actor: %{"kind" => "system"},
      type: type,
      payload: payload,
      ticket_id: ticket.id,
      project_id: ticket.project_id,
      inserted_at: at
    })
  end

  describe "live" do
    # A ticket whose only live work is its chat step is the conversation, not the ticket running;
    # finished work is not live at all.
    test "is a workflow job or a command, running or pending" do
      ticket = ticket_fixture()
      chat_fixture(%{ticket: ticket, ticket_id: ticket.id, status: :running})

      for {status, attempt} <- Enum.with_index([:waiting, :parked, :hibernated], 1),
          do: job_fixture(%{ticket: ticket, attempt: attempt, status: status})

      job_fixture(%{ticket: ticket, attempt: 4})
      |> Ecto.Changeset.change(status: :finished, outcome: :converged)
      |> Repo.update!()

      assert Doing.live([ticket.id]) == %{}

      job_fixture(%{ticket: ticket, attempt: 5, kind: :command, status: :pending})
      assert %{status: :pending} = Doing.live([ticket.id])[ticket.id]
    end

    test "is the newest of its class" do
      ticket = ticket_fixture()
      old = ~U[2026-11-10 09:00:00.000000Z]
      new = ~U[2026-11-10 10:00:00.000000Z]

      for {attempt, at} <- [{1, old}, {2, new}] do
        job_fixture(%{ticket: ticket, attempt: attempt, status: :pending})
        |> Ecto.Changeset.change(inserted_at: at)
        |> Repo.update!()
      end

      assert %{attempt: 2, inserted_at: ^new} = Doing.live([ticket.id])[ticket.id]
    end
  end

  describe "live, for the queue's rows as well as the project's" do
    # The two rules the old under-way group had and the list lacked, now carried by the one read
    # both pages share: a running row's age is the current run's, from the run ledger.
    test "a running job is aged from the run it is in, not the run it first had" do
      ticket = ticket_fixture()
      {:ok, worker, _token} = Forge.Workers.create(%{provider: "fake"})
      first = DateTime.add(DateTime.utc_now(:second), -36_000, :second)
      current = DateTime.add(DateTime.utc_now(:second), -60, :second)

      job = job_fixture(%{ticket: ticket, worker_id: worker.id, status: :running})
      Repo.update!(Ecto.Changeset.change(job, started_at: first))

      Repo.insert!(%Forge.Jobs.Run{
        job_id: job.id,
        worker_id: worker.id,
        started_at: first,
        finished_at: DateTime.add(first, 600, :second)
      })

      Repo.insert!(%Forge.Jobs.Run{job_id: job.id, worker_id: worker.id, started_at: current})

      assert %{status: :running, started_at: ^current} = Doing.live([ticket.id])[ticket.id]
    end

    test "a running job with no open run keeps its own start" do
      ticket = ticket_fixture()
      {:ok, worker, _token} = Forge.Workers.create(%{provider: "fake"})
      started = DateTime.add(DateTime.utc_now(:second), -60, :second)

      job_fixture(%{ticket: ticket, worker_id: worker.id, status: :running})
      |> Ecto.Changeset.change(started_at: started)
      |> Repo.update!()

      assert %{started_at: ^started} = Doing.live([ticket.id])[ticket.id]
    end

    # A pending job carries a `started_at` from a run that is over, and is not aged from it.
    test "a pending job's started_at is left as it is" do
      ticket = ticket_fixture()
      started = DateTime.add(DateTime.utc_now(:second), -60, :second)

      job_fixture(%{ticket: ticket})
      |> Ecto.Changeset.change(started_at: started)
      |> Repo.update!()

      assert %{status: :pending, started_at: ^started} = Doing.live([ticket.id])[ticket.id]
    end

    # `kind` is what says whether the spend cap gates it: a workflow job is, a command is not.
    test "carries the kind and the id of the job it picked" do
      ticket = ticket_fixture()
      job_fixture(%{ticket: ticket, status: :parked})
      command = job_fixture(%{ticket: ticket, kind: :command, state: "check", attempt: 2})

      assert %{id: id, kind: :command} = Doing.live([ticket.id])[ticket.id]
      assert id == command.id
    end
  end

  describe "facts" do
    test "are the live work, the last lines, the pause and the merge queue's places" do
      ticket = ticket_fixture()
      job_fixture(%{ticket: ticket})
      event!(ticket, "job.harness.text", %{"text" => "On it."})

      facts = Doing.facts([ticket])

      assert %{status: :pending} = facts.live[ticket.id]
      assert {"On it.", _at} = facts.said[ticket.id]
      assert facts.paused == false
      assert facts.places == %{}
      assert facts.milestones == %{}

      assert %{places: %{"x" => :given}} = Doing.facts([ticket], places: %{"x" => :given})
    end
  end

  describe "said" do
    test "is the agent's newest line, not its first" do
      ticket = ticket_fixture()
      event!(ticket, "job.harness.text", %{"text" => "The first line."})
      event!(ticket, "job.harness.text", %{"text" => "The latest line.\nand more"})

      assert {"The latest line.", _at} = Doing.said([ticket.id])[ticket.id]
    end
  end

  describe "merged" do
    test "is this project's merges, newest first, as many as asked" do
      ticket = ticket_fixture()
      later = ticket_fixture(%{project: Forge.Projects.get!(ticket.project_id)})
      elsewhere = ticket_fixture()

      event!(ticket, "ticket.merged", %{"sha" => "aaa"})
      event!(elsewhere, "ticket.merged", %{"sha" => "zzz"})
      event!(later, "ticket.merged", %{"sha" => "bbb"})
      event!(later, "ticket.transitioned", %{})

      assert [%{sha: "bbb"}, %{sha: "aaa"}] = Doing.merged(ticket.project_id, 5)
      assert [%{sha: "bbb", ticket: %{id: id}}] = Doing.merged(ticket.project_id, 1)
      assert id == later.id
    end
  end
end
