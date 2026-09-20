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
        payload: %{"state" => "refining"}
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
          project_id: ticket.project_id,
          state: "refining",
          attempt: 1,
          spec: %{},
          memory_max: Forge.Jobs.default_resources().memory,
          cores: Forge.Jobs.default_resources().cores
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

  describe "summary/1" do
    # The clause order is the whole design of this function: the typed clauses render the events
    # a reader actually follows, the empty-payload clause keeps a bare event from rendering as
    # `%{}`, and the general clause is the fallback that inspects whatever is left. Nothing else
    # in the platform calls it, so `Forge.CLI`'s event log is the only place a wrong clause shows,
    # and there it reads as an event that says nothing rather than as an error.

    test "an event with nothing to say says nothing" do
      assert Events.summary(%Event{type: "ticket.noted", payload: %{}}) == ""
    end

    test "an event with a payload says what is in it" do
      summary = Events.summary(%Event{type: "job.interrupted", payload: %{"reason" => "drained"}})

      assert summary =~ "reason="
      assert summary =~ "drained"
    end

    # A conversation's own words. Without the `chat.message` clause they would reach the log as
    # an inspected map — the line a person typed, rendered as data. See
    # `docs/design/conversations.md`.
    test "a chat message is the text, and a chat turn is its number" do
      assert Events.summary(%Event{type: "chat.message", payload: %{"text" => "are you there?"}}) ==
               "are you there?"

      assert Events.summary(%Event{type: "chat.turn", payload: %{"turn" => 3}}) == "turn 3"
    end

    test "a long message is bounded rather than filling the line" do
      text = String.duplicate("x", 500)

      assert Events.summary(%Event{type: "chat.message", payload: %{"text" => text}}) ==
               String.duplicate("x", 200)
    end
  end

  test "events can never be updated or deleted" do
    {:ok, event} = Events.append("ticket.noted", :system)

    assert_raise Postgrex.Error, ~r/events is append-only/, fn ->
      Repo.update!(Ecto.Changeset.change(event, type: "tampered.type"))
    end

    assert_raise Postgrex.Error, ~r/events is append-only/, fn -> Repo.delete!(event) end
  end
end
