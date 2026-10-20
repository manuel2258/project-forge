defmodule ForgeCore.Workflow.ProjectWorkflowsTest do
  @moduledoc """
  The parser and the engine run over this repository's own `.forge/` workflows, which nothing else
  in the gate reads. Forge runs its own tickets through these files, and the platform parses them
  only when a ticket is admitted or moved — so until this file existed, a definition the validator
  refuses was found by a ticket stuck before a job rather than by a commit.

  What it asserts beyond "it parses" is the behaviour of `reviewing`, whose budget and edges are
  ticket 13's: an exhausted review goes to `review_ready` and not round again, its
  `did_not_converge` retry survives that edit, its budget is the figure the comment in
  `common.yml` derives, the loops the transitions allow fit inside `limits.ticket_cost`, and every
  state a person may be offered can actually be moved to by hand. Each of those is config, which
  is where ticket 13's failure lived and which nothing here read before.
  """

  use ExUnit.Case, async: true

  alias ForgeCore.{Engine, Workflow}
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
      # An equivalent mutant: no change to a workflow file can make this assertion fail, because
      # `load!/1` has already flunked by then. The test is `load!/1` being reached for every file
      # the wildcard finds; the match is here to say what it returns.
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

  # Pinned to the figure a person chose, not to a floor: `common.yml`'s comment derives $35 from
  # the production runs, and a floor of "above the $19.53 that did report" would let a regression
  # to $20 through while that comment still said $35. Changing it means changing both, and the
  # ticket cap below.
  test "reviewing's cost budget is the figure common.yml derives" do
    for {name, workflow} <- reviewing_workflows() do
      budget = Workflow.state(workflow, "reviewing").budget

      assert budget.cost == 35.00, "#{name}: reviewing has #{budget.cost}"
      assert budget.turns == 120, "#{name}: reviewing has #{budget.turns} turns"
    end
  end

  # The check ticket 13 was asked for and a plan got wrong by doing it on end totals.
  # `within_ticket_budget?/2` is asked *before* a job starts, against what the ticket has spent
  # already, so a journey fits only if every one of its running totals is under the cap — and the
  # journey is priced out of the workflow itself, so the cap and the budgets cannot drift apart.
  test "the review round-trips the transitions allow fit inside the ticket cost cap" do
    for {name, workflow} <- reviewing_workflows() do
      loop =
        Enum.find(Workflow.transitions_from(workflow, "reviewing"), &(&1.when == "issues_found"))

      jobs = journey(workflow, loop)
      costs = Enum.map(jobs, &cost(workflow, &1))

      spent_before = [0.0 | Enum.drop(Enum.scan(costs, &(&1 + &2)), -1)]

      stopped =
        for {state, spent} <- Enum.zip(jobs, spent_before),
            not Engine.within_ticket_budget?(workflow, spent),
            do: "#{state} at $#{spent}"

      assert stopped == [], "#{name}: the cap stops the journey at #{Enum.join(stopped, ", ")}"
    end
  end

  # Every job the worst journey runs, in order: the way in on nothing but each state's ordinary
  # outcome, then the `issues_found` round-trip as many times as its `max` allows.
  defp journey(workflow, loop) do
    List.flatten([
      default_path(workflow, workflow.initial),
      List.duplicate(default_path(workflow, loop.to), loop.max)
    ])
  end

  # The states a ticket passes through going forward from `from` on each one's default outcome,
  # ending at `reviewing`. Raises rather than loops if a state on the way has no default edge,
  # which would mean the workflow no longer has the shape this test prices.
  defp default_path(workflow, from) do
    Enum.to_list(
      Stream.unfold(from, fn
        nil -> nil
        "reviewing" -> {"reviewing", nil}
        state -> {state, default_edge(workflow, state).to}
      end)
    )
  end

  defp default_edge(workflow, from),
    do: workflow |> Workflow.transitions_from(from) |> Enum.find(&(&1.when == nil))

  # A command state and a human state both cost no inference, and declare no budget to read.
  defp cost(workflow, state) do
    case Workflow.state(workflow, state).budget do
      nil -> 0.0
      %{cost: cost} -> cost
    end
  end

  # `Engine.choose/4` is what a person's move goes through, and the operator surface offers each
  # target once and sends no outcome with it (`Forge.Engine.offered_transitions/2`). So a target
  # reached by two edges is one a person cannot move to unless the engine resolves it — which is
  # what `reviewing → review_ready` became when the budget edge was added beside the bare one.
  test "a person can move a ticket to any state it has an edge to, bar a state's own retry" do
    for {name, workflow} <- reviewing_workflows() do
      refusals =
        for state <- Enum.sort(Map.keys(workflow.states)),
            to <- Enum.uniq(Enum.map(Workflow.transitions_from(workflow, state), & &1.to)),
            match?({:error, {:ambiguous, _}}, Engine.choose(workflow, state, to, nil)),
            do: {state, to}

      assert Enum.all?(refusals, fn {from, to} -> from == to end),
             "#{name}: cannot be moved by hand: #{inspect(refusals)}"

      assert {:ok, %Transition{when: nil}} = Engine.choose(workflow, "reviewing", "review_ready"),
             "#{name}: a person's move to review_ready takes the bare edge"
    end
  end
end
