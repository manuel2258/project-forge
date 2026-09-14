defmodule ForgeWeb.Operator.BoardTest do
  @moduledoc """
  The arrangement both boards share.

  The cap is the one documented difference between `/board` and `/projects/:name`, and until
  this file nothing exercised it: no test built more tickets than the cap, so capped and
  uncapped were indistinguishable in the suite.
  """

  use Forge.DataCase, async: true

  import Forge.ForgeFixtures

  alias ForgeWeb.Operator.Board

  defp tickets(project, states) do
    for state <- states, do: ticket_fixture(%{project: project, state: state})
  end

  defp column(columns, name), do: Enum.find(columns, &(&1.name == name))

  test "a capped column shows the cap and says how many remain" do
    project = project_fixture()
    tickets(project, List.duplicate("refining", 5))
    workflow = Board.workflow(Forge.Tickets.list(project))

    capped = Board.columns(Forge.Tickets.list(project), workflow, cap: 4) |> column("refining")

    assert length(capped.tickets) == 5
    assert length(capped.shown) == 4
    assert capped.more == 1
  end

  test "an uncapped column shows all of them and claims nothing remains" do
    project = project_fixture()
    tickets(project, List.duplicate("refining", 5))
    workflow = Board.workflow(Forge.Tickets.list(project))

    uncapped = Board.columns(Forge.Tickets.list(project), workflow) |> column("refining")

    assert length(uncapped.shown) == 5
    assert uncapped.more == 0
  end

  test "exactly at the cap, nothing is said to remain" do
    project = project_fixture()
    tickets(project, List.duplicate("refining", 4))
    workflow = Board.workflow(Forge.Tickets.list(project))

    at_cap = Board.columns(Forge.Tickets.list(project), workflow, cap: 4) |> column("refining")

    assert length(at_cap.shown) == 4
    assert at_cap.more == 0
  end

  test "columns follow the workflow from its initial state, not the alphabet" do
    project = project_fixture()
    tickets(project, ["refining"])
    workflow = Board.workflow(Forge.Tickets.list(project))

    names = Board.columns(Forge.Tickets.list(project), workflow) |> Enum.map(& &1.name)

    assert hd(names) == "refining"

    assert Enum.find_index(names, &(&1 == "planning")) <
             Enum.find_index(names, &(&1 == "implementing"))

    assert Board.order(workflow) == names
  end

  test "a state only a ticket knows is appended rather than dropped" do
    project = project_fixture()
    tickets(project, ["refining"])
    # A state left behind by an older pinned workflow: no longer in the workflow, still occupied.
    ticket_fixture(%{project: project, state: "ghost_state"})
    all = Forge.Tickets.list(project)

    names = Board.columns(all, Board.workflow(all)) |> Enum.map(& &1.name)

    assert "ghost_state" in names
    assert List.last(names) == "ghost_state"
    assert column(Board.columns(all, Board.workflow(all)), "ghost_state").topology == :unknown
  end

  test "with no tickets there are no columns" do
    assert Board.columns([], nil) == []
    assert Board.workflow([]) == nil
  end
end
