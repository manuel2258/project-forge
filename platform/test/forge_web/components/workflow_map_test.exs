defmodule ForgeWeb.WorkflowMapTest do
  @moduledoc """
  The workflow drawn for reading (`docs/design/ui.md` § Workflow): the order its states are drawn
  in, the vertical flow and the map — which edge is an arc above, which below, which is in the
  link colour, and which state's box a ticket's dot sits on.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ForgeCore.Workflow.Parser
  alias ForgeWeb.WorkflowMap

  @example Path.expand("../../../../core/test/fixtures/workflow_example.yml", __DIR__)

  defp example do
    {:ok, workflow} = Parser.parse(File.read!(@example))
    workflow
  end

  test "states are drawn in the order the workflow reaches them, not the alphabet's" do
    assert ForgeWeb.Topology.order(example()) ==
             ["refining", "planning", "implementing", "verifying", "review_ready", "merged"]
  end

  # An integrating state is reached by a conflict and nothing else, so a walk of the declared
  # transitions alone would leave it off the map.
  test "a state only a conflict reaches is in the order, after the merge" do
    {:ok, workflow} = Parser.parse(Forge.GitFixtures.conflict_workflow(:b))

    assert ForgeWeb.Topology.order(workflow) == [
             "implementing",
             "review_ready",
             "merged",
             "integrating"
           ]
  end

  test "the flow says each state's job, budget and where it goes, approvals in the link colour" do
    html =
      render_component(&WorkflowMap.flow/1,
        id: "flow",
        workflow: example(),
        counts: %{"planning" => 2}
      )

    # In words, not the map's `refine.md → refinement.md`.
    assert html =~ "runs refine.md · writes refinement.md"
    # The open tickets per state, which the phone has nowhere else to see.
    assert html =~ ~r/class="wf-step-count"[^>]*>\s*2 open/
    assert length(Regex.scan(~r/wf-step-count/, html)) == 1
    assert html =~ "20 turns"
    assert html =~ "on plan_invalid"
    assert html =~ ~r/class="wf-step-link"[^>]*>\s*· approves refinement.md/
    assert html =~ "initial"
    assert html =~ "no job"
  end

  test "a loop back is an arc below, labelled; a forward step is not labelled" do
    html = render_component(&WorkflowMap.map/1, id: "m", workflow: example())

    assert html =~ "on plan_invalid, back"
    assert html =~ "on tests_failed, back"
    refute html =~ "skips"
    # The approvals are the link colour, the rest are not.
    assert length(Regex.scan(~r/wf-map-edge wf-map-edge--link/, html)) == 2
  end

  test "a skip forward is an arc above" do
    {:ok, workflow} =
      Parser.parse("""
      version: 1
      initial: a
      states:
        a:
          prompt: agents/a.md
          inputs: [ticket]
          produces: [a.md]
          outcomes: [done, trivial]
          budget: { turns: 5, tokens: 20k }
        b: { prompt: agents/b.md, inputs: [a.md], produces: [b.md], budget: { turns: 5, tokens: 20k } }
        c: {}
      transitions:
        - { from: a, to: b }
        - { from: a, to: c, when: trivial }
        - { from: b, to: c }
      limits: { ticket_tokens: 200k }
      """)

    html = render_component(&WorkflowMap.map/1, id: "m", workflow: workflow)
    assert html =~ "on trivial, skips"
  end

  test "a ticket's dot is on its state's box, and a state links to the tickets in it" do
    html =
      render_component(&WorkflowMap.map/1,
        id: "m",
        workflow: example(),
        dots: %{"planning" => [:waiting, :running]},
        selected: "planning",
        filter: &"/projects/p?state=#{&1}"
      )

    assert length(Regex.scan(~r/wf-map-dot wf-map-dot--waiting/, html)) == 1
    assert length(Regex.scan(~r/wf-map-dot wf-map-dot--running/, html)) == 1
    # The box says how many in figures, and a dot says what it is on hover.
    assert html =~ ~r/class="wf-map-count"[^>]*>\s*2\s*</
    assert length(Regex.scan(~r/wf-map-count/, html)) == 1
    assert html =~ "<title>waiting on you</title>"
    assert html =~ ~s(href="/projects/p?state=planning")
    assert html =~ "wf-map-rect--selected"
  end
end
