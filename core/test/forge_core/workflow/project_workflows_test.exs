defmodule ForgeCore.Workflow.ProjectWorkflowsTest do
  @moduledoc """
  The parser and the engine run over this repository's own `.forge/` workflows, which nothing else
  in the gate reads. Forge runs its own tickets through these files, and the platform parses them
  only when a ticket is admitted or moved — so until this file existed, a definition the validator
  refuses was found by a ticket stuck before a job rather than by a commit.

  What it asserts beyond "it parses" is the behaviour of `reviewing`, whose budget and edges are
  ticket 13's: an exhausted review goes to `review_ready` and not round again, its
  `did_not_converge` retry survives that edit, its budget is the figure the comment in
  `common.yml` derives, the review round-trips it declares fit inside `limits.ticket_cost`, and
  every state a person may be offered can actually be moved to by hand. Each of those is config,
  which is where ticket 13's failure lived and which nothing here read before.

  Ticket 7 added `presenting` between `reviewing` and `review_ready` and the assertions that say
  so, folding in the file it had added for them: both tickets wanted the same test file, and one
  of them is enough.

  The port to 0.17.0 added the rest: `refining` is a chat step whose Accept is the approval, every
  merge goes through the merge queue, a conflict goes to `rebasing`, whose `done` merges with no
  second approval, and `release.yml` is the project's release, which concludes on its own once its
  notes are approved and its publish went as planned. The journey priced against the cap
  now includes the conversation and the rebases, because both spend under it.
  """

  use ExUnit.Case, async: true

  alias ForgeCore.{Engine, Workflow}
  alias ForgeCore.Workflow.{Parser, State, Transition}

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

  defp edges_between(%Workflow{} = workflow, from, to),
    do: Enum.filter(Workflow.transitions_from(workflow, from), &(&1.to == to))

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

  # Forward and not round again, which is ticket 13's rule; `presenting` and not `review_ready`
  # directly, which is ticket 7's — every way to `review_ready` goes through the presentation, and
  # an exhausted review is exactly the diff a person needs narrated.
  test "a reviewing run that exhausts its budget goes forward to presenting, never back" do
    for {name, workflow} <- reviewing_workflows() do
      assert edges(workflow, "reviewing", "budget_exhausted") == [{"presenting", nil}],
             "#{name}: budget_exhausted must leave reviewing for presenting, with no retry"
    end
  end

  # From `forge_workflows_test.exs`, which this file replaced: a presentation is written before
  # the person deciding sees the page, so `presenting` is on the way to `review_ready` and not
  # beside it. An edge reaching `review_ready` from anywhere else would route past it in silence.
  test "a ticket reaches review only through presenting, which writes a presentation" do
    for {name, workflow} <- reviewing_workflows() do
      assert for(t <- workflow.transitions, t.to == "review_ready", do: t.from) == ["presenting"],
             "#{name}: review_ready is reachable without a presentation"

      presenting = Workflow.state(workflow, "presenting")
      assert Enum.any?(presenting.produces, &Workflow.presentation?/1), name
      assert State.optional?(presenting, "presentation.md"), name
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

  # **Every cycle carries a `max` somewhere, which is what makes a ticket's cost finite.**
  # `limits.ticket_cost` is the outer backstop and not the only one: a loop with no bound spends
  # to the cap and stops there with nothing to show, which is what `implementing → planning` on
  # `plan_invalid` did until it was given `max: 2`. The property is per *cycle* and not per edge —
  # one bounded edge is enough, and `planning → implementing` is deliberately unbounded — so what
  # is asserted is that the graph of unbounded edges alone is acyclic. A new loop whose every edge
  # is unbounded fails here, which is cheaper than finding it on a ticket.
  #
  # Every workflow, not only the two with a `reviewing` state: `release.yml` has the property too
  # and a fourth workflow would have to.
  test "every loop in every workflow is bounded somewhere" do
    for path <- workflow_files() do
      workflow = load!(path)

      unbounded =
        Enum.group_by(
          Enum.filter(workflow.transitions, &(&1.max == nil)),
          & &1.from,
          & &1.to
        )

      cycles =
        for state <- Enum.sort(Map.keys(workflow.states)),
            reaches?(unbounded, state, state),
            do: state

      assert cycles == [],
             "#{Path.basename(path)}: #{inspect(cycles)} sit on a cycle of unbounded edges"
    end
  end

  # Can `to` be reached from `from` over **one or more** edges of `graph`? One or more, so a state
  # counts as reachable from itself only when it genuinely sits on a cycle — which is why the walk
  # starts from `from`'s successors rather than from `from`.
  defp reaches?(graph, from, to), do: walk(graph, Map.get(graph, from, []), MapSet.new(), to)

  defp walk(_graph, [], _seen, _to), do: false

  defp walk(graph, [state | rest], seen, to) do
    cond do
      state == to -> true
      MapSet.member?(seen, state) -> walk(graph, rest, seen, to)
      true -> walk(graph, Map.get(graph, state, []) ++ rest, MapSet.put(seen, state), to)
    end
  end

  # **The bound and the prose that states it, asserted together.** `agents/review.md` § The bar
  # rises each round tells the reviewer it has five rounds and that reaching the bound is a
  # failure of the state, and it reasons from that number: which findings a later round may raise
  # at all depends on there being a late round. A bound changed in the workflow and not in the
  # prompt is `CLAUDE.md` § Rules' defect exactly — a claim nothing checks — and it is invisible,
  # because both files still parse and the reviewer simply counts against a number that is no
  # longer there. So the number is read out of the workflow and looked for in the prompt.
  test "the review loop's bound is five rounds, and agents/review.md says so" do
    for {name, workflow} <- reviewing_workflows() do
      assert edges(workflow, "reviewing", "issues_found") == [{"implementing", 5}],
             "#{name}: issues_found must send the ticket back to implementing, five times at most"
    end

    prompt = File.read!(Path.join(@forge, "agents/review.md"))

    assert prompt =~ "at most five times",
           "agents/review.md no longer states the bound the workflows declare"
  end

  # The check ticket 13 was asked for and a plan got wrong by doing it on end totals.
  # `within_ticket_budget?/2` is asked *before* a job starts, against what the ticket has spent
  # already, so a journey fits only if every one of its running totals is under the cap — and the
  # journey is priced out of the workflow itself, so the cap and the budgets cannot drift apart.
  #
  # **The journey priced here is the review loop these workflows declare, and not the worst one
  # they allow**, which has no useful price: it adds the re-plan laps, every retry, a refinement
  # conversation that talked past its allowance, and a `needs_review` rebase that sends the ticket
  # round the review loop again. That is what a cap is for, and it is why this asserts the
  # ordinary journey — the conversation, five `issues_found` round-trips at the review budget,
  # the presentation and the rebases after the approval — rather than a maximum nobody would set.
  test "the review round-trips these workflows declare fit inside the ticket cost cap" do
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
  # outcome, then the `issues_found` round-trip as many times as its `max` allows, then the way
  # out — and after the approval, as many rebases as the platform will send the ticket to by
  # itself, because a queued ticket's conflicts are the engine's and each rebase spends under the
  # same cap.
  defp journey(workflow, loop) do
    List.flatten([
      default_path(workflow, workflow.initial),
      List.duplicate(default_path(workflow, loop.to), loop.max),
      after_review(workflow),
      rebases(workflow)
    ])
  end

  # Read off the platform rather than written down: `ForgeCore.Engine.conflict/5` routes an
  # engine's conflict to `on_conflict` while fewer than its bound have gone before, and sticks the
  # ticket after. So the count is how many rounds it routes, asked of it one by one.
  defp rebases(workflow) do
    approval = Enum.find(workflow.transitions, &Workflow.merges_on_enter?(workflow, &1.to))
    target = Workflow.on_conflict(workflow, approval.to)

    rounds =
      Enum.take_while(0..10, fn rounds ->
        match?(
          {:route, _},
          Engine.conflict(workflow, approval.from, approval.to, :engine, rounds)
        )
      end)

    List.duplicate(target, length(rounds))
  end

  # The last review is not the last job to spend: the state its default edge leads to runs once,
  # after every total above it. Read off the edge rather than named, so a state inserted between
  # `reviewing` and `review_ready` is priced against the cap here instead of being left out of it.
  defp after_review(workflow), do: [default_edge(workflow, "reviewing").to]

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

  # A command state and a human state both cost no inference, and declare no budget to read. A
  # chat step costs whatever the conversation does and may declare no budget either, so it is
  # priced at what `.forge/common.yml` allows it — a figure that file states and this one repeats,
  # because nothing in the workflow can carry it.
  @chat_allowance 30.00

  defp cost(workflow, state) do
    case Workflow.state(workflow, state) do
      %State{chat: true} -> @chat_allowance
      %State{budget: nil} -> 0.0
      %State{budget: %{cost: cost}} -> cost
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

      assert {:ok, %Transition{when: nil}} = Engine.choose(workflow, "reviewing", "presenting"),
             "#{name}: a person's move out of reviewing takes the bare edge"
    end
  end

  # A second review that cannot read its own last report re-derives the whole diff at full price:
  # ticket 7's second round cost $21.96 doing that, and its fifth, scoped to what had changed,
  # cost $4.13. Optional by construction — `reviewing` is its own producer, reached on a first
  # pass from `checking` with nothing written — so this asserts the input is declared, which is
  # the half a workflow controls, and the parse test above asserts the validator accepts it.
  test "a reviewing run is handed the report its last round wrote" do
    for {name, workflow} <- reviewing_workflows() do
      assert "report.md" in Workflow.state(workflow, "reviewing").inputs,
             "#{name}: reviewing cannot read what it already found"
    end
  end

  # A review after a rebase reads the rebase and not the change a person already approved
  # (`agents/review.md` § After a rebase, review the rebase): what it is scoped to is `rebase.md`
  # and the rebase's own commit, so the document has to reach it — and the presentation, which
  # tells the person approving again what the rebase did.
  test "a review and a presentation after a rebase are handed what the rebase did" do
    for {name, workflow} <- reviewing_workflows(), state <- ["reviewing", "presenting"] do
      assert "rebase.md" in Workflow.state(workflow, state).inputs,
             "#{name}: #{state} cannot read what the rebase did"
    end

    prompt = File.read!(Path.join(@forge, "agents/review.md"))

    assert prompt =~ "git show --remerge-diff HEAD",
           "agents/review.md no longer scopes a review after a rebase to the rebase's own commit"
  end

  # **On a state costing a few dollars the cost ceiling is the one meant to bind.** A turn buys no
  # inference, and a job its turn ceiling stops throws away every dollar it had already spent —
  # ticket 7's `planning` died at turn 51 of 50 with $1.11 of its $4.00 unspent, and `publishing`
  # has no retry at all, so for it the same ceiling sticks a ticket that has already written to
  # GHCR. 60 is the repository's floor for that, and this asserts the rule rather than each
  # figure: a state may give more turns, and `reviewing` at 120 and `implementing` at 200 do.
  test "a job state costing a few dollars is not stopped by its turn ceiling first" do
    budgets =
      for path <- workflow_files(),
          workflow = load!(path),
          {state, %State{budget: %{cost: cost, turns: turns}} = declared} <- workflow.states,
          State.job?(declared),
          cost <= 5.00,
          do: {Path.basename(path), state, cost, turns}

    assert budgets != [], "no cheap job state found: the filter no longer matches the workflows"

    for {name, state, cost, turns} <- budgets do
      assert turns >= 60, "#{name}: #{state} costs $#{cost} but gives only #{turns} turns"
    end
  end

  # **Accept is the approval, and nothing else leaves the step.** `planning` and `diagnosing` start
  # from `refinement.md` as the person last saw it, which holds only while the one edge out of
  # `refining` approves it. An edge on an engine outcome is not refused by the validator, and never
  # fires from a chat step — nothing in it ends without a person — so one here would be a dead edge
  # that reads like a retry.
  test "refining is a conversation that ends on the person's approval of refinement.md" do
    for {name, workflow} <- reviewing_workflows() do
      refining = Workflow.state(workflow, workflow.initial)

      assert refining.name == "refining", name
      assert State.chat?(refining), "#{name}: refining is not a chat step"
      assert refining.produces == ["refinement.md"], name

      assert [%Transition{approve: ["refinement.md"], when: nil}] =
               Workflow.transitions_from(workflow, "refining"),
             "#{name}: refining must leave on one edge, approving refinement.md"
    end
  end

  # Wherever the key is declared it is in force, and an edge without it merges at once and skips
  # the line (`docs/design/workflow-grammar-v1.md` § The merge queue) — so a merging edge added
  # without it would merge out of turn, in silence.
  test "every edge into a merging state queues" do
    for path <- workflow_files() do
      workflow = load!(path)

      merging = Enum.filter(workflow.transitions, &Workflow.merges_on_enter?(workflow, &1.to))
      assert merging != [], "#{Path.basename(path)} has no edge into a merging state"

      for transition <- merging do
        assert Transition.queues?(transition),
               "#{Path.basename(path)}: #{transition.from} -> #{transition.to} does not queue"
      end
    end
  end

  # **Approved once, merged after a rebase without a second approval** — and only on `done`, which
  # `agents/rebase.md` holds to rules. `needs_review` is the way back to a person, through the
  # gate. The approval edge still asks for `changeset`: that is the "once".
  test "a conflict goes to rebasing, whose done merges in turn and needs_review goes to a person" do
    for {name, workflow} <- reviewing_workflows() do
      assert Workflow.on_conflict(workflow, "merged") == "rebasing", name

      assert [%Transition{approve: ["changeset"]}] =
               edges_between(workflow, "review_ready", "merged"),
             "#{name}: the approval of the changeset is what lets a rebase merge on its own"

      assert edges(workflow, "rebasing", "done") == [{"merged", nil}],
             "#{name}: a rebase that is done goes straight back to the merge"

      assert [%Transition{approve: []}] = edges_between(workflow, "rebasing", "merged"),
             "#{name}: the edge out of a rebase asks for no second approval"

      assert edges(workflow, "rebasing", "needs_review") == [{"checking", nil}],
             "#{name}: a rebase that needs a person goes back through the gate"

      assert Map.has_key?(Workflow.state(workflow, "rebasing").may_invoke, "check"),
             "#{name}: nothing runs the gate on a rebase that merges on its own unless it does"
    end
  end

  # The rules for choosing between the two outcomes are prose, so the outcomes the workflow
  # declares are looked for in it: an outcome renamed in `common.yml` and not in the prompt leaves
  # the agent writing one the state does not declare, which is `error` and a stuck ticket.
  test "agents/rebase.md names every outcome rebasing declares" do
    prompt = File.read!(Path.join(@forge, "agents/rebase.md"))

    for {name, workflow} <- reviewing_workflows(),
        outcome <- Workflow.state(workflow, "rebasing").outcomes do
      assert prompt =~ "`outcome: #{outcome}`",
             "#{name}: agents/rebase.md does not say how to end on #{outcome}"
    end
  end

  # Two flagged files mean the project has no release at all (`docs/design/ticket-types.md`
  # § Releases), and the same reading of the file the platform uses is asked here.
  test "release.yml is the project's release, and the only one" do
    releases =
      for path <- workflow_files(),
          Parser.declares_release?(File.read!(path)),
          do: Path.basename(path)

    assert releases == ["release.yml"]
  end

  # **A release is approved once, on its notes**, before anything is built; by the end of
  # `publishing` the image is out, so the merge of `VERSION` follows on its own. The exception is
  # a release half done — image published, snapshot not made — which has to reach a person before
  # the ticket ends. `agents/publish.md` says which is which, so its outcomes are looked for there.
  test "a published release merges with no second approval, unless its snapshot failed" do
    workflow = load!(Path.join(@forge, "workflows/release.yml"))

    assert [%Transition{when: nil, approve: []}] =
             edges_between(workflow, "publishing", "merged"),
           "a release that published as planned merges with no approval after its notes"

    assert edges(workflow, "publishing", "snapshot_failed") == [{"release_ready", nil}],
           "a release whose snapshot failed waits for a person"

    assert [%Transition{approve: ["changeset"]}] =
             edges_between(workflow, "release_ready", "merged"),
           "the person who hears about a failed snapshot is the one who approves the merge"

    prompt = File.read!(Path.join(@forge, "agents/publish.md"))

    for outcome <- Workflow.state(workflow, "publishing").outcomes do
      assert prompt =~ "`outcome: #{outcome}`",
             "agents/publish.md does not say how to end on #{outcome}"
    end
  end
end
