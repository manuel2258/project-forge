defmodule ForgeCore.Document.Question do
  @moduledoc """
  A question an agent embedded in a document. Blocking questions stop the job; non-blocking
  ones record the assumption the agent proceeded with.

  Each option is a headline and a sentence (`ForgeCore.Document.Question.Option`), and the
  lengths are limited, because the form a question is drawn in is read on a phone by someone who
  did not write the plan. See `docs/design/job-prompt.md` § Output format.
  """

  alias ForgeCore.Document.Question.Option
  alias ForgeCore.Error

  @enforce_keys [:key, :text, :line]
  defstruct [:key, :text, :anchor, :assumption, :line, options: [], blocking: false]

  @type t :: %__MODULE__{
          key: String.t(),
          text: String.t(),
          anchor: String.t() | nil,
          options: [Option.t()],
          blocking: boolean(),
          assumption: String.t() | nil,
          line: pos_integer()
        }

  @keys ~w(key anchor text options blocking assumption)
  @option_keys ~w(label detail recommended)
  @key_format ~r/\A[a-z0-9][a-z0-9_-]*\z/

  # Characters, not bytes: what a person reads. Ceilings, not targets — the preamble asks for
  # shorter.
  @max_text 200
  @max_label 40
  @max_detail 140

  @doc "The limits on `text`, `label` and `detail`, in characters."
  @spec limits() :: %{text: pos_integer(), label: pos_integer(), detail: pos_integer()}
  def limits, do: %{text: @max_text, label: @max_label, detail: @max_detail}

  @doc """
  The option the agent recommends, or nil. Takes anything with `options` whose entries carry
  `recommended`, so a stored question answers it the same way a parsed one does.
  """
  @spec recommended(%{options: [%{recommended: boolean()}]}) :: map() | nil
  def recommended(%{options: options}), do: Enum.find(options, & &1.recommended)

  @doc """
  Whether `label` is one of the question's options — the one rule a `choice` answers to, whether
  it answers a stored question or a chat's parsed one.
  """
  @spec offers?(%{options: [%{label: String.t()}]}, String.t()) :: boolean()
  def offers?(%{options: options}, label), do: Enum.any?(options, &(&1.label == label))

  @doc "Builds a question from the YAML inside a block that starts at `line`."
  @spec build(String.t(), pos_integer(), String.t()) :: {:ok, t()} | {:error, [Error.t()]}
  def build(yaml, line, path, opts \\ []) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, map} when is_map(map) ->
        from_map(map, line, path, opts)

      {:ok, _other} ->
        {:error, [Error.new(path, "block at line #{line} must be a YAML mapping")]}

      {:error, %{message: message}} ->
        {:error, [Error.new(path, "block at line #{line}: invalid YAML: #{message}")]}
    end
  end

  defp from_map(map, line, path, opts) do
    {key, e1} = key(map, path)
    {text, e2} = string(map, "text", path, required: true, max: @max_text)
    {anchor, e3} = string(map, "anchor", path, required: false)
    {options, e4} = options(map, path)
    {blocking, e5} = blocking(map, path)
    {blocking, assumption, e6} = resolve_blocking(map, blocking, path, opts)

    case unknown_keys(map, @keys, path) ++ e1 ++ e2 ++ e3 ++ e4 ++ e5 ++ e6 do
      [] ->
        {:ok,
         %__MODULE__{
           key: key,
           text: text,
           anchor: anchor,
           options: options,
           blocking: blocking,
           assumption: assumption,
           line: line
         }}

      errors ->
        {:error, errors}
    end
  end

  # **A scalar where text was meant is read as the text it was written as.** YAML types an unquoted
  # `10` as a number and `true` as a boolean, and an agent writing `label: 10` meant the label,
  # not an integer. Refusing that failed a whole refinement in production — the
  # document was dropped with its questions — over a quoting rule nobody reading the file would
  # notice. Numbers and booleans are turned back into the words; anything else (a list, a
  # mapping, `null`) is passed through, and the field's own check refuses it as it always did.
  # The one loss is a number YAML normalises while reading: `1e3` comes back as `1000.0`, and
  # `0x1F` as `31`.
  defp as_text(value) when is_boolean(value), do: to_string(value)
  defp as_text(value) when is_integer(value), do: Integer.to_string(value)
  defp as_text(value) when is_float(value), do: Float.to_string(value)
  defp as_text(value), do: value

  defp key(map, path) do
    case map |> Map.get("key") |> as_text() do
      value when is_binary(value) ->
        if Regex.match?(@key_format, value),
          do: {value, []},
          else:
            {nil,
             [Error.new(Error.join(path, "key"), "must be lowercase letters, digits, - or _")]}

      nil ->
        {nil, [Error.new(Error.join(path, "key"), "is required")]}

      _ ->
        {nil, [Error.new(Error.join(path, "key"), "must be a string")]}
    end
  end

  defp string(map, field, path, opts) do
    field_path = Error.join(path, field)

    case map |> Map.get(field) |> as_text() do
      nil ->
        if opts[:required], do: {nil, [Error.new(field_path, "is required")]}, else: {nil, []}

      value ->
        with {value, []} <- text(value, field_path), do: within(value, opts[:max], field_path)
    end
  end

  # What every text field must be, whatever else its own rule adds:
  #
  # - **Not blank.** A label of spaces is an option nobody can choose — the form reads a blank
  #   choice as none — and a question of spaces asks nothing.
  # - **No NUL.** YAML can write one as an escape (`"a\0b"`) where the raw text has none, and
  #   Postgres refuses it in `text` and `jsonb` with an exception inside the transaction that
  #   records the document: every check before the write passes and the write still fails. The
  #   front matter is refused one for the same reason (`ForgeCore.Document`).
  defp text(value, path) when is_binary(value) do
    cond do
      String.trim(value) == "" ->
        {nil, [Error.new(path, "must be a non-empty string")]}

      String.contains?(value, <<0>>) ->
        {nil, [Error.new(path, "must not contain a NUL character")]}

      true ->
        {value, []}
    end
  end

  defp text(_value, path), do: {nil, [Error.new(path, "must be a non-empty string")]}

  # Refused rather than cut: a truncated sentence can say the opposite of the whole one.
  defp within(value, nil, _path), do: {value, []}

  defp within(value, max, path) do
    case String.length(value) do
      length when length > max ->
        {value, [Error.new(path, "must be at most #{max} characters, not #{length}")]}

      _length ->
        {value, []}
    end
  end

  defp options(map, path) do
    field_path = Error.join(path, "options")

    case Map.get(map, "options") do
      nil ->
        {[], []}

      [_ | _] = values ->
        {options, errors} =
          values
          |> Enum.with_index()
          |> Enum.map(fn {value, index} -> option(value, Error.join(field_path, index)) end)
          |> Enum.reduce({[], []}, fn
            {:ok, option}, {options, errs} -> {[option | options], errs}
            {:error, more}, {options, errs} -> {options, errs ++ more}
          end)

        options = Enum.reverse(options)

        {options,
         errors ++ repeated_labels(options, field_path) ++ recommendations(options, field_path)}

      _ ->
        {[], [Error.new(field_path, "must be a non-empty list of options")]}
    end
  end

  # The bare string is the format this replaced, and the one an agent reaches for from habit, so
  # it gets the sentence that says what to write instead.
  defp option(value, path) when is_binary(value) or is_number(value) or is_boolean(value),
    do:
      {:error,
       [Error.new(path, "must be a mapping with a `label` and a `detail`, not a bare value")]}

  defp option(map, path) when is_map(map) do
    {label, e1} = string(map, "label", path, required: true, max: @max_label)
    {detail, e2} = string(map, "detail", path, required: true, max: @max_detail)
    {recommended, e3} = flag(map, "recommended", path)

    case unknown_keys(map, @option_keys, path) ++ e1 ++ e2 ++ e3 do
      [] -> {:ok, %Option{label: label, detail: detail, recommended: recommended}}
      errors -> {:error, errors}
    end
  end

  defp option(_value, path),
    do: {:error, [Error.new(path, "must be a mapping with a `label` and a `detail`")]}

  # The label is what the answer records, so two alike would be one answer.
  defp repeated_labels(options, path) do
    labels = Enum.map(options, & &1.label)

    if Enum.uniq(labels) == labels,
      do: [],
      else: [Error.new(path, "must not repeat a label")]
  end

  defp recommendations(options, path) do
    case Enum.count(options, & &1.recommended) do
      count when count > 1 ->
        [Error.new(path, "may mark one option recommended, not #{count}")]

      _count ->
        []
    end
  end

  defp flag(map, field, path) do
    case Map.get(map, field) do
      nil -> {false, []}
      value when is_boolean(value) -> {value, []}
      _ -> {false, [Error.new(Error.join(path, field), "must be true or false")]}
    end
  end

  defp blocking(map, path), do: flag(map, "blocking", path)

  # In a conversation every question is blocking, because the turn has ended and the agent is
  # waiting whichever way the flag was written. An assumption is what a job proceeded with
  # instead, and there is no instead here — so one is ignored rather than refused, which matters
  # because refusing it fails the whole message and the question vanishes with it.
  defp resolve_blocking(_map, _blocking, _path, blocking: :always), do: {true, nil, []}

  defp resolve_blocking(map, blocking, path, _opts) do
    {assumption, errors} = assumption(map, blocking, path)
    {blocking, assumption, errors}
  end

  defp assumption(map, blocking, path) do
    field_path = Error.join(path, "assumption")

    case {map |> Map.get("assumption") |> as_text(), blocking} do
      {nil, false} ->
        {nil, [Error.new(field_path, "is required on a non-blocking question")]}

      {nil, true} ->
        {nil, []}

      {value, true} when is_binary(value) ->
        {nil, [Error.new(field_path, "not allowed on a blocking question")]}

      {value, false} ->
        text(value, field_path)
    end
  end

  defp unknown_keys(map, known, path) do
    map
    |> Map.keys()
    |> Enum.map(&key_name/1)
    |> Enum.reject(&(&1 in known))
    |> Enum.sort()
    |> Enum.map(&Error.new(Error.join(path, &1), unknown(&1)))
  end

  # A YAML key need not be a string: `? {z: 1}` is a mapping key, and it arrives as yamerl's
  # tuples, which `to_string/1` raises on. The parser never raises on what an agent wrote, so a
  # key that is not text is refused as unknown like any other, under a name that says so.
  defp key_name(key) when is_binary(key), do: key
  defp key_name(key) when is_atom(key) or is_number(key), do: to_string(key)
  defp key_name(_key), do: "(a key that is not text)"

  # `default` was a key until the recommendation moved onto its option, and an agent that learned
  # the old block will write it; the correction says where it went.
  defp unknown("default"),
    do: "is not a key: mark the recommended option with `recommended: true`"

  defp unknown(_key), do: "unknown key"
end
