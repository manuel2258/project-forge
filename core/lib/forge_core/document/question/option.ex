defmodule ForgeCore.Document.Question.Option do
  @moduledoc """
  One answer a question offers: a headline a person taps and a sentence saying what choosing it
  means. `recommended` marks the one the agent would pick; a question has at most one.

  Built by `ForgeCore.Document.Question`, which holds the rules. `detail` is nil only on an option
  read back from a question recorded before options had one (`docs/design/job-prompt.md`
  § Output format); the parser never makes one.
  """

  @enforce_keys [:label]
  defstruct [:label, :detail, recommended: false]

  @type t :: %__MODULE__{
          label: String.t(),
          detail: String.t() | nil,
          recommended: boolean()
        }

  @doc "String keys, for the wire, where a struct's atom keys do not survive JSON."
  @spec to_map(t()) :: %{String.t() => term()}
  def to_map(%__MODULE__{} = option),
    do: %{"label" => option.label, "detail" => option.detail, "recommended" => option.recommended}

  @doc """
  Reads an option back from `to_map/1`'s shape, with string or atom keys.

  A bare string is read as a label with no detail, and anything else as its `inspect/1`. This is
  the wire, not the agent's format — the agent's block is refused a bare string by the parser
  before anything is sent — and the platform reads nothing from a result's questions but their
  keys (it parses the document itself), so a strict read here would only turn a malformed option
  into a crashed channel.
  """
  @spec from_map(term()) :: t()
  def from_map(label) when is_binary(label), do: %__MODULE__{label: label}

  # String or atom keys, as `ForgeCore.Job.Result`'s other readers take — though only string
  # keys reach it today, since `to_map/1` writes those, so the atom half is an equivalent mutant.
  # So is `== true` against a plain truthiness test: `to_map/1` writes a boolean.
  def from_map(map) when is_map(map) do
    get = fn key -> Map.get(map, to_string(key), Map.get(map, key)) end

    %__MODULE__{
      label: get.(:label),
      detail: get.(:detail),
      recommended: get.(:recommended) == true
    }
  end

  def from_map(other), do: %__MODULE__{label: inspect(other)}
end
