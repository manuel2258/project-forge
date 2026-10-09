defmodule ForgeCore.Workflow.Keys do
  @moduledoc """
  Refuses a mapping key that is not a name, anywhere in a decoded workflow or library.

  YAML allows a mapping or a sequence as a key (`? {a: 1}`), and the parser turns every key it
  walks into a string. A key that cannot be one raised there instead of being reported, which on
  the platform reached every job of the project once each job's backlog came to read the project's
  ticket types. Checked once, on the decoded document, before anything reads it: the rest of the
  parser may then assume every key is a string, a number or an atom (YAML's `true`, `null`).
  """

  alias ForgeCore.Error

  @doc "One error for every key in `value` that is a mapping or a sequence."
  @spec errors(term(), String.t()) :: [Error.t()]
  def errors(value, path \\ "")

  def errors(map, path) when is_map(map) do
    Enum.flat_map(map, fn {key, value} ->
      # Which of the two is not worth saying: `yaml_elixir` hands a mapping key back as a list.
      if is_map(key) or is_list(key),
        do: [Error.new(path, "a key must be a name, not a mapping or a sequence")],
        else: errors(value, Error.join(path, to_string(key)))
    end)
  end

  def errors(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} -> errors(value, Error.join(path, index)) end)
  end

  def errors(_scalar, _path), do: []
end
