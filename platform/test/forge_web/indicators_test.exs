defmodule ForgeWeb.IndicatorsTest do
  @moduledoc """
  A workflow state is drawn in the design's StateLabel classes (`docs/design/ui.md` § Marks) with
  `ForgeWeb.Topology.mark/1`'s mark: a job state as running, a person's state as a workflow step,
  and a terminal one muted with `○`, never `✓`, which would say *done* of a state that need not be.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ForgeWeb.Indicators

  defp draw(topology),
    do:
      render_component(&Indicators.state/1, name: "refining", topology: topology)
      |> Floki.parse_fragment!()

  defp mark(doc), do: doc |> Floki.find(".ui-state-mark") |> Floki.text() |> String.trim()

  test "a job state is StateLabel's running, a person's its step" do
    job = draw(:job)
    assert Floki.find(job, ".ui-state.ui-state--running") != []
    assert mark(job) == "▸"
    assert Floki.text(job) =~ "refining"

    human = draw(:human)
    assert Floki.find(human, ".ui-state.ui-state--step") != []
    assert mark(human) == "●"
  end

  test "a terminal state is muted and never done, and an unknown one says nothing of itself" do
    terminal = draw(:terminal)
    assert Floki.find(terminal, ".ui-state.ui-state--idle") != []
    assert mark(terminal) == "○"

    unknown = draw(:unknown)
    assert Floki.find(unknown, ".ui-state.ui-state--idle") != []
    assert mark(unknown) == "·"
  end

  test "a state a person is waited on in is amber, with its own topology's mark" do
    waiting =
      render_component(&Indicators.state/1, name: "build", topology: :job, waiting: true)
      |> Floki.parse_fragment!()

    assert Floki.find(waiting, ".ui-state.ui-state--waiting") != []
    assert mark(waiting) == "▸"
  end

  test "a status is a word beside the state: nothing while active, stuck in warning" do
    assert render_component(&Indicators.status/1, status: :active) == ""

    stuck = render_component(&Indicators.status/1, status: :stuck) |> Floki.parse_fragment!()
    assert Floki.find(stuck, ".ui-status.ui-status--stuck") != []

    cancelled =
      render_component(&Indicators.status/1, status: :cancelled) |> Floki.parse_fragment!()

    assert Floki.find(cancelled, ".ui-status--stuck") == []
    assert Floki.text(cancelled) =~ "cancelled"
  end
end
