defmodule Forge.EventsTest do
  use Forge.DataCase, async: true

  import Forge.ForgeFixtures

  alias Ecto.Multi
  alias Forge.Events
  alias Forge.Events.Event

  test "append/3 writes an ordered, typed event" do
    ticket = ticket_fixture()

    {:ok, first} =
      Events.append("ticket.admitted", :system, %{
        ticket_id: ticket.id,
        payload: %{"state" => "refined"}
      })

    {:ok, second} =
      Events.append("ticket.noted", {:user, Ecto.UUID.generate()}, %{ticket_id: ticket.id})

    assert first.seq < second.seq
    assert first.actor == %{"kind" => "system", "id" => nil}

    assert [%Event{type: "ticket.admitted"}, %Event{type: "ticket.noted"}] =
             Events.for_ticket(ticket.id)
  end

  test "log/5 inserts inside a multi and may read earlier changes" do
    ticket = ticket_fixture()

    {:ok, %{job: job, event: event}} =
      Multi.new()
      |> Multi.insert(
        :job,
        Forge.Jobs.Job.create_changeset(%Forge.Jobs.Job{}, %{
          ticket_id: ticket.id,
          state: "refined",
          attempt: 1,
          spec: %{}
        })
      )
      |> Events.log(:event, "job.created", :system, fn %{job: job} ->
        %{ticket_id: ticket.id, job_id: job.id}
      end)
      |> Repo.transaction()

    assert event.job_id == job.id
    assert [%Event{type: "job.created"}] = Events.for_job(job.id)
  end

  test "rejects malformed types and actors" do
    assert {:error, changeset} = Events.append("nodots", :system)
    assert %{type: [_]} = errors_on(changeset)

    assert %{actor: [_]} =
             errors_on(Event.changeset(%Event{}, %{type: "a.b", actor: %{"kind" => "ghost"}}))
  end

  test "events can never be updated or deleted" do
    {:ok, event} = Events.append("ticket.noted", :system)

    assert_raise Postgrex.Error, ~r/events is append-only/, fn ->
      Repo.update!(Ecto.Changeset.change(event, type: "tampered.type"))
    end

    assert_raise Postgrex.Error, ~r/events is append-only/, fn -> Repo.delete!(event) end
  end
end
