defmodule ForgeCore.Job.Outcome do
  @moduledoc """
  Decides how a job ended, in the order `docs/design/claude-code-events.md` fixes: a kill
  by the platform first, then open blocking questions, then the harness result, then the
  outputs. Pure: the worker collects what happened and asks; the platform records the answer.
  """

  alias ForgeCore.Document
  alias ForgeCore.Document.Question
  alias ForgeCore.Job.Spec

  @typedoc """
  What the worker observed.

    * `killed` - whether the platform killed the process, and why.
    * `exit_status` - the process exit status, nil if it never started.
    * `result` - the harness's final result message, normalised to `subtype`, `is_error` and
      `text` (its own closing words, which are the only field that ever names a cause).
    * `documents` - declared documents that parsed, by name.
    * `invalid` - declared documents that did not parse, by name.
    * `missing` - declared documents not written.
    * `undeclared` - files written that were not declared.
  """
  @type run :: %{
          killed: nil | :operator | :wall_clock,
          exit_status: integer() | nil,
          result: %{subtype: String.t() | nil, is_error: boolean(), text: String.t() | nil} | nil,
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
  def decide(%Spec{} = spec, %{killed: killed} = run) when killed != nil do
    {outcome, declared, reason} = finished(spec, run)
    {:finished, outcome, declared, reason}
  end

  def decide(%Spec{} = spec, run) do
    case blocking_questions(spec, run) do
      [] ->
        {outcome, declared, reason} = finished(spec, run)
        {:finished, outcome, declared, reason}

      questions ->
        {:waiting, questions}
    end
  end

  # Blocking questions whose key a person already answered are not open: the agent may keep
  # the block in the document after resuming.
  defp blocking_questions(%Spec{answered_keys: answered}, %{documents: documents}) do
    documents
    |> Enum.sort()
    |> Enum.flat_map(fn {_name, document} -> Document.blocking_questions(document) end)
    |> Enum.reject(&(&1.key in answered))
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
        {:error, nil, "harness error: #{detail(result)}"}

      run.missing != [] ->
        {:error, nil, "missing outputs: #{Enum.join(run.missing, ", ")}"}

      run.undeclared != [] ->
        {:error, nil, "undeclared outputs: #{Enum.join(run.undeclared, ", ")}"}

      map_size(run.invalid) > 0 ->
        {:error, nil, "invalid documents: #{invalid(run.invalid)}"}

      true ->
        declared(spec, run.documents)
    end
  end

  # What to call the failure, per `docs/design/claude-code-events.md` § Naming the failure. The
  # harness's own closing words come first: `subtype` is not a diagnosis, and on a machine whose
  # credential is missing it is the outright lie `"success"` on a result that sets `is_error`.
  # That case used to be reported as "harness result: success" — the opposite of what happened,
  # while the sentence naming the cause sat unread in the same message.
  defp detail(result) do
    case {text(result), result.subtype} do
      {nil, nil} -> "no message"
      {nil, subtype} -> subtype
      {text, subtype} when subtype in [nil, "success"] -> text
      {text, subtype} -> "#{subtype}: #{text}"
    end
  end

  # One line of it. The reason sits in a timeline row and a queue line, and a harness that ends
  # by printing a stack trace must not push everything else off the screen.
  defp text(result) do
    case result |> Map.get(:text) |> to_line() do
      "" -> nil
      line -> line
    end
  end

  defp to_line(text) when is_binary(text) do
    text
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.trim()
    |> String.slice(0, 200)
  end

  defp to_line(_other), do: ""

  # **Each document with what is wrong with it**, not only its name. The name alone was the whole
  # record of two failed refinements in production: the documents were dropped, the machines
  # destroyed, and why they did not parse had to be recovered by rebuilding them from transcripts.
  defp invalid(invalid) do
    # Sorted so the reason reads the same every time. No test can see it: a map of 32 keys or
    # fewer already iterates in key order, and 33 invalid documents is a fixture nobody writes.
    invalid
    |> Enum.sort()
    |> Enum.map_join("; ", fn {name, why} ->
      "#{name} (#{why |> ForgeCore.Error.to_text() |> String.replace("\n", "; ")})"
    end)
  end

  # Exit status 2 is documented as the cost ceiling. It does not also cover an authentication
  # failure: that exits 1 and does produce a result message, so it never reaches here.
  defp budget_stop?(%{subtype: subtype, is_error: is_error}, exit_status) do
    subtype == "error_max_turns" or String.starts_with?(subtype || "", "error_max_budget") or
      (exit_status == 2 and is_error)
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
