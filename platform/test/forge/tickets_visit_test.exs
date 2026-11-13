defmodule Forge.TicketsVisitTest do
  @moduledoc """
  Which time a ticket is in its state (`Forge.Tickets.visit/1`), as the queue draws it:
  *review · visit 2*.
  """

  use Forge.DataCase, async: true

  import Forge.ForgeFixtures

  alias Forge.{Repo, Tickets}

  defp taken!(ticket, from, to) do
    Repo.insert!(%Forge.Events.Event{
      type: "transition.taken",
      actor: %{"kind" => "system", "id" => nil},
      ticket_id: ticket.id,
      project_id: ticket.project_id,
      payload: %{"from" => from, "to" => to}
    })
  end

  test "is 1 for a ticket still in the state it was admitted into" do
    assert Tickets.visit(ticket_fixture()) == 1
  end

  test "counts the transitions into the state it is in, and no other" do
    ticket = ticket_fixture()
    taken!(ticket, ticket.state, "review")
    taken!(ticket, "review", ticket.state)
    taken!(ticket, ticket.state, "review")
    taken!(ticket, "review", "elsewhere")

    assert Tickets.visit(%{ticket | state: "review"}) == 2
    assert Tickets.visit(%{ticket | state: "elsewhere"}) == 1
  end
end
