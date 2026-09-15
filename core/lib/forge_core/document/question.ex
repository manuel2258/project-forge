defmodule ForgeCore.Document.Question do
  @moduledoc """
  A question an agent embedded in a document. Blocking questions stop the job; non-blocking
  ones record the assumption the agent proceeded with.
  """

  alias ForgeCore.Error

  @enforce_keys [:key, :text, :line]
  defstruct [:key, :text, :anchor, :default, :assumption, :line, options: [], blocking: false]

  @type t :: %__MODULE__{
          key: String.t(),
          text: String.t(),
          anchor: String.t() | nil,
          options: [String.t()],
          default: String.t() | nil,
          blocking: boolean(),
          assumption: String.t() | nil,
          line: pos_integer()
        }

  @keys ~w(key anchor text options default blocking assumption)
  @key_format ~r/^[a-z0-9][a-z0-9_-]*$/

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
    {text, e2} = string(map, "text", path, required: true)
    {anchor, e3} = string(map, "anchor", path, required: false)
    {options, e4} = options(map, path)
    {blocking, e5} = blocking(map, path)
    {default, e6} = default(map, options, path)
    {blocking, assumption, e7} = resolve_blocking(map, blocking, path, opts)

    case unknown_keys(map, path) ++ e1 ++ e2 ++ e3 ++ e4 ++ e5 ++ e6 ++ e7 do
      [] ->
        {:ok,
         %__MODULE__{
           key: key,
           text: text,
           anchor: anchor,
           options: options,
           default: default,
           blocking: blocking,
           assumption: assumption,
           line: line
         }}

      errors ->
        {:error, errors}
    end
  end

  defp key(map, path) do
    case Map.get(map, "key") do
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

  defp string(map, field, path, required: required) do
    case Map.get(map, field) do
      value when is_binary(value) and value != "" -> {value, []}
      nil when required -> {nil, [Error.new(Error.join(path, field), "is required")]}
      nil -> {nil, []}
      _ -> {nil, [Error.new(Error.join(path, field), "must be a non-empty string")]}
    end
  end

  defp options(map, path) do
    value = Map.get(map, "options")

    cond do
      is_nil(value) ->
        {[], []}

      is_list(value) and value != [] and Enum.all?(value, &(is_binary(&1) and &1 != "")) ->
        if Enum.uniq(value) == value,
          do: {value, []},
          else: {value, [Error.new(Error.join(path, "options"), "must not repeat an option")]}

      true ->
        {[], [Error.new(Error.join(path, "options"), "must be a non-empty list of strings")]}
    end
  end

  defp blocking(map, path) do
    case Map.get(map, "blocking") do
      nil -> {false, []}
      value when is_boolean(value) -> {value, []}
      _ -> {false, [Error.new(Error.join(path, "blocking"), "must be true or false")]}
    end
  end

  defp default(map, options, path) do
    field_path = Error.join(path, "default")
    value = Map.get(map, "default")

    cond do
      is_nil(value) -> {nil, []}
      not is_binary(value) -> {nil, [Error.new(field_path, "must be a string")]}
      options == [] -> {value, [Error.new(field_path, "requires options")]}
      value in options -> {value, []}
      true -> {value, [Error.new(field_path, "#{inspect(value)} is not one of the options")]}
    end
  end

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

    case {Map.get(map, "assumption"), blocking} do
      {nil, false} ->
        {nil, [Error.new(field_path, "is required on a non-blocking question")]}

      {nil, true} ->
        {nil, []}

      {value, true} when is_binary(value) ->
        {nil, [Error.new(field_path, "not allowed on a blocking question")]}

      {value, false} when is_binary(value) and value != "" ->
        {value, []}

      _ ->
        {nil, [Error.new(field_path, "must be a non-empty string")]}
    end
  end

  defp unknown_keys(map, path) do
    map
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 in @keys))
    |> Enum.sort()
    |> Enum.map(&Error.new(Error.join(path, &1), "unknown key"))
  end
end
