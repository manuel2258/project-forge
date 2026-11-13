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
