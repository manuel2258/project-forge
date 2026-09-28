defmodule ForgeCore.Job.Correction do
  @moduledoc """
  Whether a finished run failed on something the agent can put right by editing its outputs, and
  what to tell it. `docs/design/claude-code-events.md` § Correcting the outputs is the standard.

  A run whose harness ended cleanly can still end in `error`: a document that does not parse, a
  declared output it never wrote, a file in `out/` nobody declared, or an outcome the state does
  not accept. Each of those is a sentence away from fixed, and the session that made the mistake
  is the one that knows what it meant. So the worker resumes that session with the problems
  listed, a bounded number of times, before it reports anything.

  Pure: the worker's runner asks and acts; this decides.
  """

  alias ForgeCore.Document
  alias ForgeCore.Error
  alias ForgeCore.Job.{Result, Spec}

  @typedoc "One line naming a file and what is wrong with it."
  @type problem :: String.t()

  @doc """
  `{:correct, problems}` when `result` ended in `error` for reasons the agent can fix in `out/`,
  and `:none` otherwise — a run that was killed, that the harness stopped or failed, that is
  waiting or parked, or that failed for any reason outside its outputs.
  """
  @spec needed(Spec.t(), Result.t()) :: {:correct, [problem()]} | :none
  def needed(%Spec{} = spec, %Result{status: :finished, outcome: :error, killed: nil} = result) do
    with true <- clean_harness?(result.harness),
         [_ | _] = problems <- problems(spec, result) do
      {:correct, problems}
    else
      _ -> :none
    end
  end

  def needed(%Spec{}, %Result{}), do: :none

  # The harness has to have finished its turn and said it succeeded. A run it stopped for its
  # budget, or one that errored, is not a run whose outputs are the problem.
  defp clean_harness?(harness) do
    harness["subtype"] == "success" and harness["is_error"] != true
  end

  defp problems(spec, result) do
    missing =
      Enum.map(result.missing, &"#{&1}: was not written; write it to $FORGE_JOB/out/#{&1}")

    undeclared =
      Enum.map(
        result.undeclared,
        &"#{&1}: is not a declared output; remove it from $FORGE_JOB/out/"
      )

    # Sorted for a stable prompt; unobservable under 33 documents, as in `Outcome`.
    invalid =
      result.invalid
      |> Enum.sort()
      |> Enum.flat_map(fn {name, why} ->
        why |> Error.to_text() |> String.split("\n", trim: true) |> Enum.map(&"#{name}: #{&1}")
      end)

    case missing ++ undeclared ++ invalid do
      [] -> outcome_problems(spec, result)
      problems -> problems
    end
  end

  # Every file parsed and nothing is missing, so what is left is the outcome the document declares.
  defp outcome_problems(spec, result) do
    with name when is_binary(name) <- Spec.outcome_document(spec),
         %Document{outcome: outcome} <- Map.get(result.documents, name),
         false <- outcome == "did_not_converge" or outcome in spec.outcomes do
      accepted = Enum.map_join(spec.outcomes ++ ["did_not_converge"], ", ", &"`#{&1}`")

      what =
        if outcome == nil,
          do: "has no `outcome` in its front matter",
          else: "declares the outcome #{inspect(outcome)}, which this state does not accept"

      ["#{name}: #{what}; use one of #{accepted}"]
    else
      _ -> []
    end
  end

  @doc """
  What the resumed session is told: the problems, one per line, and that fixing them is the whole
  task. `round` counts from one; `of` is how many the runner will make.
  """
  @spec prompt([problem()], pos_integer(), pos_integer()) :: String.t()
  def prompt(problems, round, of) do
    """
    Your run has ended, but the platform could not accept what you wrote to `$FORGE_JOB/out/`:

    #{Enum.map_join(problems, "\n", &"- #{&1}")}

    Fix exactly these, in the files named, and end your run again. The work itself stands: do not
    redo it, and do not change anything that is not listed. A `question` block is YAML: put `text`,
    `anchor` and `assumption` in double quotes.

    This is correction #{round} of #{of}. If the outputs still cannot be accepted after the last
    one, the job ends in error, and a document that still does not parse is not kept.
    """
  end

  @doc """
  What is left of `spec`'s budget once `spent` has gone — turns and cost — or `:exhausted` when
  too little remains for a correction to be worth starting.
  """
  @spec remaining(Spec.t(), %{turns: non_neg_integer(), cost: number()}) ::
          {:ok, %{turns: pos_integer(), cost: number()}} | :exhausted
  def remaining(%Spec{budget: %{turns: turns, cost: cost}}, %{turns: used, cost: spent}) do
    # Whole cents, rounded down: the harness is handed the figure to two places, and rounding
    # $0.996 to `1.00` would let a correction spend past what the job was given, while $0.004
    # would reach it as `0.00`.
    left = %{turns: turns - used, cost: Float.floor((cost - spent) * 1.0, 2)}

    if left.turns >= 1 and left.cost >= 0.01, do: {:ok, left}, else: :exhausted
  end

  def remaining(%Spec{}, _spent), do: :exhausted
end
