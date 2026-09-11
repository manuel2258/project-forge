defmodule ForgeCore.Document do
  @moduledoc """
  A document artifact as agents write it: optional YAML front matter, a Markdown body, and
  fenced `question` blocks next to the passages they concern.

  See `docs/design/job-prompt.md`. Parsing is pure and never raises on bad input; every
  problem is returned as a `ForgeCore.Error` with a path such as `front_matter.outcome` or
  `question[1].default`.
  """

  alias ForgeCore.Document.Question
  alias ForgeCore.Error

  defstruct front_matter: %{}, outcome: nil, body: "", questions: [], raw: ""

  @type t :: %__MODULE__{
          front_matter: map(),
          outcome: String.t() | nil,
          body: String.t(),
          questions: [Question.t()],
          raw: String.t()
        }

  @front_matter_delimiter "---"
  @question_info "question"
  @fence ~r/^(`{3,})(.*)$/

  @spec parse(String.t()) :: {:ok, t()} | {:error, [Error.t()]}
  def parse(text) when is_binary(text) do
    {front_matter, body, offset, front_errors} = split_front_matter(text)
    {outcome, outcome_errors} = outcome(front_matter)
    {questions, question_errors} = questions(body, offset)

    case front_errors ++ outcome_errors ++ question_errors do
      [] ->
        {:ok,
         %__MODULE__{
           front_matter: front_matter,
           outcome: outcome,
           body: body,
           questions: questions,
           raw: text
         }}

      errors ->
        {:error, errors}
    end
  end

  @spec parse!(String.t()) :: t()
  def parse!(text) do
    case parse(text) do
      {:ok, document} -> document
      {:error, errors} -> raise ArgumentError, "invalid document:\n" <> Error.format(errors)
    end
  end

  @doc "Questions that stop the job until answered."
  @spec blocking_questions(t()) :: [Question.t()]
  def blocking_questions(%__MODULE__{questions: questions}) do
    Enum.filter(questions, & &1.blocking)
  end

  @spec blocking?(t()) :: boolean()
  def blocking?(document), do: blocking_questions(document) != []

  # -- front matter -------------------------------------------------------------------------

  defp split_front_matter(text) do
    lines = String.split(text, ~r/\r?\n/)

    case lines do
      [@front_matter_delimiter | rest] -> close_front_matter(rest)
      _ -> {%{}, text, 0, []}
    end
  end

  defp close_front_matter(lines) do
    case Enum.find_index(lines, &(&1 == @front_matter_delimiter)) do
      nil ->
        {%{}, "", 0, [Error.new("front_matter", "is not closed by a --- line")]}

      index ->
        {yaml_lines, [_delimiter | body_lines]} = Enum.split(lines, index)
        {front_matter, errors} = decode_front_matter(Enum.join(yaml_lines, "\n"))
        # Body line 1 is file line index + 3: two delimiters plus the YAML lines.
        {front_matter, Enum.join(body_lines, "\n"), index + 2, errors}
    end
  end

  defp decode_front_matter(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, map} when is_map(map) ->
        {map, []}

      {:ok, nil} ->
        {%{}, []}

      {:ok, _other} ->
        {%{}, [Error.new("front_matter", "must be a mapping")]}

      {:error, %{message: message}} ->
        {%{}, [Error.new("front_matter", "invalid YAML: #{message}")]}
    end
  end

  defp outcome(front_matter) do
    case Map.get(front_matter, "outcome") do
      nil -> {nil, []}
      value when is_binary(value) and value != "" -> {value, []}
      _ -> {nil, [Error.new("front_matter.outcome", "must be a non-empty string")]}
    end
  end

  # -- question blocks ----------------------------------------------------------------------

  # Walks the body line by line, tracking fenced code blocks so a ```question inside another
  # code block is not mistaken for a real one. Line numbers are file lines, hence `offset`.
  defp questions(body, offset) do
    body
    |> String.split(~r/\r?\n/)
    |> Enum.with_index(offset + 1)
    |> Enum.reduce({:outside, [], []}, &scan_line/2)
    |> finish_scan()
  end

  defp scan_line({line, number}, {:outside, blocks, errors}) do
    case Regex.run(@fence, line) do
      [_, ticks, info] when info == @question_info ->
        {{:question, String.length(ticks), number, []}, blocks, errors}

      [_, ticks, _info] ->
        {{:code, String.length(ticks)}, blocks, errors}

      nil ->
        {:outside, blocks, errors}
    end
  end

  defp scan_line({line, _number}, {{:code, width}, blocks, errors}) do
    if closing_fence?(line, width),
      do: {:outside, blocks, errors},
      else: {{:code, width}, blocks, errors}
  end

  defp scan_line({line, _number}, {{:question, width, start, acc}, blocks, errors}) do
    if closing_fence?(line, width) do
      yaml = acc |> Enum.reverse() |> Enum.join("\n")
      {:outside, [{start, yaml} | blocks], errors}
    else
      {{:question, width, start, [line | acc]}, blocks, errors}
    end
  end

  defp closing_fence?(line, width) do
    case Regex.run(~r/^(`{3,})\s*$/, line) do
      [_, ticks] -> String.length(ticks) >= width
      nil -> false
    end
  end

  defp finish_scan({{:question, _width, start, _acc}, blocks, errors}) do
    finish_scan(
      {:outside, blocks,
       [
         Error.new("question[#{length(blocks)}]", "block starting at line #{start} is not closed")
         | errors
       ]}
    )
  end

  defp finish_scan({_state, blocks, errors}) do
    {questions, build_errors} =
      blocks
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.map(fn {{line, yaml}, index} ->
        Question.build(yaml, line, "question[#{index}]")
      end)
      |> Enum.reduce({[], []}, fn
        {:ok, question}, {questions, errs} -> {[question | questions], errs}
        {:error, more}, {questions, errs} -> {questions, errs ++ more}
      end)

    questions = Enum.reverse(questions)
    {questions, Enum.reverse(errors) ++ build_errors ++ duplicate_keys(questions)}
  end

  defp duplicate_keys(questions) do
    questions
    |> Enum.with_index()
    |> Enum.group_by(fn {question, _index} -> question.key end)
    |> Enum.filter(fn {_key, group} -> length(group) > 1 end)
    |> Enum.sort()
    |> Enum.flat_map(fn {key, group} ->
      Enum.map(group, fn {_question, index} ->
        Error.new("question[#{index}].key", "#{inspect(key)} is used by more than one question")
      end)
    end)
  end
end
