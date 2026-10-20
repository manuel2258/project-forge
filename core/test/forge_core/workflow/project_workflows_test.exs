defmodule ForgeCore.Workflow.ProjectWorkflowsTest do
  @moduledoc """
  The parser run over this repository's own `.forge/` workflows, which nothing else in the gate
  reads. Forge runs its own tickets through these files, and the platform parses them only when a
  ticket is admitted or moved — so until this file existed, a definition the validator refuses was
  found by a ticket stuck before a job rather than by a commit.

  The three shape assertions are ticket 13's: a reviewing run that exhausts its budget must land
  where a person reads its report rather than back in `reviewing` to spend the same money on the
  same fan-out, its budget must be above the dearest review measured reaching a report at all, and
  its `did_not_converge` retry must survive both edits. Each is config, which is where that
  failure lived and which nothing here read before.
  """

  use ExUnit.Case, async: true

  alias ForgeCore.Workflow
  alias ForgeCore.Workflow.{Parser, Transition}

  @root Path.expand("../../../..", __DIR__)
  @forge Path.join(@root, ".forge")

  defp opts do
    [
      prompt_exists: &File.exists?(Path.join(@forge, &1)),
      file_exists: &File.exists?(Path.join(@root, &1)),
      read_library: fn path ->
        case File.read(Path.join(@forge, path)) do
          {:ok, text} -> {:ok, text}
          {:error, _reason} -> :error
        end
      end
    ]
  end

  defp workflow_files do
    @forge |> Path.join("workflows/*.yml") |> Path.wildcard() |> Enum.sort()
  end

  defp load!(path) do
    case Parser.parse(File.read!(path), opts()) do
      {:ok, workflow} ->
        workflow

      {:error, errors} ->
        flunk("#{Path.relative_to(path, @root)} is not a valid workflow:\n" <> inspect(errors))
    end
  end

  # `{to, max}` per edge rather than the structs: it is what the assertions are about, and a
  # mismatch then fails as a comparison carrying the workflow's name instead of as a MatchError
  # that drops it.
  defp edges(%Workflow{} = workflow, from, outcome) do
    workflow
    |> Workflow.transitions_from(from)
    |> Enum.filter(&(Transition.outcome(&1) == outcome))
    |> Enum.map(&{&1.to, &1.max})
  end

  # `release.yml` has no `reviewing` state and never did, so the list is filtered — and then
  # pinned to the two workflows that do have one, because every test below says "for each" and a
  # filter that matched nothing would leave all three passing while asserting nothing. Pinned by
  # name rather than counted so that a fourth workflow with a `reviewing` state fails here, where
  # the fix is to say what its edges should be, rather than being skipped in silence.
  defp reviewing_workflows do
    found =
      for path <- workflow_files(),
          workflow = load!(path),
          Workflow.state(workflow, "reviewing") != nil,
          do: {Path.basename(path), workflow}

    assert Enum.map(found, &elem(&1, 0)) == ["bug.yml", "dev.yml"]
    found
  end

  test "every workflow this repository ships parses and validates" do
    assert workflow_files() != []

    for path <- workflow_files() do
      assert %Workflow{} = load!(path)
    end
  end

  test "a reviewing run that exhausts its budget goes to review_ready, never back to reviewing" do
    for {name, workflow} <- reviewing_workflows() do
      assert edges(workflow, "reviewing", "budget_exhausted") == [{"review_ready", nil}],
             "#{name}: budget_exhausted must leave reviewing for review_ready, with no retry"
    end
  end

  test "reviewing still retries itself once when it did not converge" do
    for {name, workflow} <- reviewing_workflows() do
      assert edges(workflow, "reviewing", "did_not_converge") == [{"reviewing", 1}],
             "#{name}: did_not_converge keeps its one fresh retry"
    end
  end

  # $19.53 is the most expensive review observed reporting at all (forge#10 attempt 1, 2026-10-20),
  # and it got there only because the cap is read between top-level turns and a subagent fan-out
  # runs inside one. A budget at or under that figure is a budget the measured work does not fit.
  test "reviewing's cost budget is above the dearest review measured reaching a report" do
    for {name, workflow} <- reviewing_workflows() do
      budget = Workflow.state(workflow, "reviewing").budget

      assert budget.cost > 19.53, "#{name}: reviewing has #{budget.cost}"
    end
  end
end
