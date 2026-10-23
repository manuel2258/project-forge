defmodule ForgeCore.Document do
  @moduledoc """
  A document artifact as agents write it: optional YAML front matter, a Markdown body, and
  fenced `question` blocks next to the passages they concern.

  See `docs/design/job-prompt.md`. Parsing is pure and never raises on bad input; every
  problem is returned as a `ForgeCore.Error` with a path such as `front_matter.outcome` or
  `question[1].options[0].label`.
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
  # CommonMark: up to three spaces of indentation; the info string is trimmed.
  @fence ~r/^ {0,3}(`{3,})(.*)$/

  @typedoc """
  `blocking: :always` reads every question as blocking whatever its flag says, and ignores an
  assumption rather than refusing one.

  It is for conversations. In a workflow a blocking question is what stops a job, and a
  non-blocking one must say what the job proceeded with instead — that is what an assumption is.
  A conversation has already stopped: the turn ended and the agent is waiting either way, and
  there is nothing for it to have proceeded with. Without this the rule does not merely mislead,
  it refuses the whole message: one question missing an assumption fails the parse, and the
  question disappears rather than being shown without its form.
  See `docs/design/conversations.md` § Asking a question.
  """
  @type opts :: [blocking: :always | :declared]

  @doc """
  Whether `raw` can be a document's text at all: valid UTF-8, with no NUL byte.

  Not a parse rule — the parser reads bytes and would accept either — but the two places a
  document goes refuse them: JSON cannot encode a string that is not UTF-8, so a worker's message
  carrying one fails whole, and Postgres cannot store a NUL in text, so the transaction writing
  one fails whole. Checked where a document is read and again where it is written, with this.
  """
  @spec text?(term()) :: boolean()
  def text?(raw), do: is_binary(raw) and String.valid?(raw) and not String.contains?(raw, <<0>>)

  @max_bytes 1024 * 1024

  @doc """
  The largest a document may be, in bytes. A document is markdown a person reads; a mebibyte of
  it is already more than anybody will. The bound exists because a conversation re-sends every
  file it wrote on every turn, over a socket, into a transaction, and nothing else limited that.
  """
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  Why `raw` cannot be a document's text, or nil. `text?/1` and `max_bytes/0` together, with the
  sentence that says which: the one definition the worker reads `out/` with and the platform
  checks what arrives with.
  """
  @spec text_error(term()) :: String.t() | nil
  def text_error(raw) do
    cond do
      not text?(raw) -> "must be UTF-8 text with no NUL byte"
      byte_size(raw) > @max_bytes -> "must be no larger than #{div(@max_bytes, 1024)} KiB"
      true -> nil
    end
  end

  @doc """
  `text` less its front matter, for the places that need the prose and not the declaration.

  Shared because what a `commit-message` version *says* must be the same string wherever it is
  read: the merge writes it to the commit, and the review page and the API show it. Reading it
  two ways is how a person approves one text and git records another.

  Text that does not parse comes back as it stands. That is reachable only for a version recorded
  with `parse: false` — a conversation's documents are (`Forge.Conversations`) — and using it
  whole is the honest answer: there is no front matter to strip if the delimiters never closed.
  """
  @spec body(String.t()) :: String.t()
  def body(text) when is_binary(text) do
    case parse(text) do
      {:ok, document} -> document.body
      {:error, _errors} -> text
    end
  end

  @spec parse(String.t(), opts()) :: {:ok, t()} | {:error, [Error.t()]}
  def parse(text, opts \\ []) when is_binary(text) do
    text = String.replace_prefix(text, "\uFEFF", "")
    {front_matter, body, offset, front_errors} = split_front_matter(text)
    {outcome, outcome_errors} = outcome(front_matter)
    {questions, question_errors} = questions(body, offset, opts)

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

  @spec parse!(String.t(), opts()) :: t()
  def parse!(text, opts \\ []) do
    case parse(text, opts) do
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

  # A NUL can arrive through YAML even when the raw text has none — `title: "a\0b"` is an escape
  # — and the front matter is stored as `jsonb`, which refuses one with an exception inside the
  # transaction that writes it, so every check before the write passed and the write still
  # failed. Refused here, where the value is made, so every writer of a document is covered.
  defp decode_front_matter(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, map} when is_map(map) ->
        cond do
          nul?(map) ->
            {%{}, [Error.new("front_matter", "must not contain a NUL character")]}

          not text_keys?(map) ->
            {%{}, [Error.new("front_matter", "keys must be text")]}

          true ->
            {map, []}
        end

      {:ok, nil} ->
        {%{}, []}

      {:ok, _other} ->
        {%{}, [Error.new("front_matter", "must be a mapping")]}

      {:error, %{message: message}} ->
        {%{}, [Error.new("front_matter", "invalid YAML: #{message}")]}
    end
  end

  # The same trap by another road: `? {a: 1}` is a mapping key, which YAML allows and arrives as
  # yamerl's tuples, and the JSON encoder that stores the front matter raises on one — inside the
  # transaction, after every check. A key must be something JSON can name: text, a number or a
  # flag, at every depth.
  defp text_keys?(map) when is_map(map),
    do: Enum.all?(map, fn {k, v} -> json_key?(k) and text_keys?(v) end)

  defp text_keys?(list) when is_list(list), do: Enum.all?(list, &text_keys?/1)
  defp text_keys?(_value), do: true

  defp json_key?(key), do: is_binary(key) or is_number(key) or is_boolean(key)

  defp nul?(value) when is_binary(value), do: String.contains?(value, <<0>>)
  defp nul?(value) when is_list(value), do: Enum.any?(value, &nul?/1)
  defp nul?(value) when is_map(value), do: Enum.any?(value, fn {k, v} -> nul?(k) or nul?(v) end)
  defp nul?(_value), do: false

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
  defp questions(body, offset, opts) do
    body
    |> String.split(~r/\r?\n/)
    |> Enum.with_index(offset + 1)
    |> Enum.reduce({:outside, [], []}, &scan_line/2)
    |> finish_scan(opts)
  end

  defp scan_line({line, number}, {:outside, blocks, errors}) do
    case Regex.run(@fence, line) do
      [_, ticks, info] ->
        if String.trim(info) == @question_info,
          do: {{:question, String.length(ticks), number, []}, blocks, errors},
          else: {{:code, String.length(ticks)}, blocks, errors}

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
    case Regex.run(~r/^ {0,3}(`{3,})\s*$/, line) do
      [_, ticks] -> String.length(ticks) >= width
      nil -> false
    end
  end

  defp finish_scan({{:question, _width, start, _acc}, blocks, errors}, opts) do
    finish_scan(
      {:outside, blocks,
       [
         Error.new("question[#{length(blocks)}]", "block starting at line #{start} is not closed")
         | errors
       ]},
      opts
    )
  end

  defp finish_scan({_state, blocks, errors}, opts) do
    {questions, build_errors} =
      blocks
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.map(fn {{line, yaml}, index} ->
        Question.build(yaml, line, "question[#{index}]", opts)
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
