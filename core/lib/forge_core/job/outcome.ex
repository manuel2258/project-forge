defmodule ForgeCore.Job.Outcome do
  @moduledoc """
  Decides how a job ended, in the order `docs/design/claude-code-events.md` fixes. Pure:
  the worker collects what happened and asks; the platform records the answer.
  """

  alias ForgeCore.Document
  alias ForgeCore.Document.Question
  alias ForgeCore.Job.Spec

  @typedoc """
  What the worker observed.

    * `killed` - whether the platform killed the process, and why.
    * `exit_status` - the process exit status, nil if it never started.
    * `result` - the harness's final result message, normalised to `subtype` and `is_error`.
    * `documents` - declared documents that parsed, by name.
    * `invalid` - declared documents that did not parse, by name.
    * `missing` - declared documents not written.
    * `undeclared` - files written that were not declared.
  """
  @type run :: %{
          killed: nil | :operator | :wall_clock,
          exit_status: integer() | nil,
          result: %{subtype: String.t() | nil, is_error: boolean()} | nil,
          documents: %{String.t() => Document.t()},
          invalid: %{String.t() => term()},
          missing: [String.t()],
          undeclared: [String.t()]
        }

  @type outcome :: :converged | :did_not_converge | :budget_exhausted | :error | :cancelled

  @type decision ::
          {:waiting, [Question.t()]}
          | {:finished, outcome(), String.t() | nil, String.t()}

  @spec decide(Spec.t(), run()) :: decision()
  def decide(%Spec{} = spec, run) do
    case blocking_questions(run) do
      [] -> {:finished, finished(spec, run)}
      questions -> {:waiting, questions}
    end
    |> flatten()
  end

  defp flatten({:finished, {outcome, declared, reason}}),
    do: {:finished, outcome, declared, reason}

  defp flatten(other), do: other

  defp blocking_questions(%{documents: documents}) do
    documents
    |> Enum.sort()
    |> Enum.flat_map(fn {_name, document} -> Document.blocking_questions(document) end)
  end

  defp finished(_spec, %{killed: :operator}), do: {:cancelled, nil, "cancelled by the operator"}

  defp finished(_spec, %{killed: :wall_clock}),
    do: {:budget_exhausted, nil, "wall-clock limit reached"}

  defp finished(_spec, %{result: nil}), do: {:error, nil, "harness produced no result message"}

  defp finished(spec, %{result: result} = run) do
    cond do
      budget_stop?(result, run.exit_status) ->
        {:budget_exhausted, nil, "harness stopped: #{result.subtype}"}

      result.subtype != "success" or result.is_error ->
        {:error, nil, "harness result: #{result.subtype || "unknown"}"}

      run.missing != [] ->
        {:error, nil, "missing outputs: #{Enum.join(run.missing, ", ")}"}

      run.undeclared != [] ->
        {:error, nil, "undeclared outputs: #{Enum.join(run.undeclared, ", ")}"}

      map_size(run.invalid) > 0 ->
        {:error, nil, "invalid documents: #{run.invalid |> Map.keys() |> Enum.join(", ")}"}

      true ->
        declared(spec, run.documents)
    end
  end

  # Exit status 2 is documented as the cost ceiling (or an authentication failure before the
  # first turn, which yields no result message and is caught earlier).
  defp budget_stop?(%{subtype: subtype}, exit_status) do
    subtype == "error_max_turns" or String.starts_with?(subtype || "", "error_max_budget") or
      exit_status == 2
  end

  defp declared(%Spec{} = spec, documents) do
    case Spec.outcome_document(spec) do
      nil -> {:converged, "done", "no outcome document; done by definition"}
      name -> declared_in(spec, Map.fetch!(documents, name), name)
    end
  end

  defp declared_in(%Spec{outcomes: outcomes}, %Document{outcome: outcome}, name) do
    cond do
      outcome == nil -> {:error, nil, "#{name} has no outcome in its front matter"}
      outcome == "did_not_converge" -> {:did_not_converge, nil, "agent reported did_not_converge"}
      outcome in outcomes -> {:converged, outcome, "agent declared #{outcome}"}
      true -> {:error, nil, "#{name} declares unknown outcome #{inspect(outcome)}"}
    end
  end
end
