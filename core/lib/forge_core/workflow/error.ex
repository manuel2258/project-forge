defmodule ForgeCore.Workflow.Error do
  @moduledoc "A parse or validation error, located by a dotted path into the definition."

  @enforce_keys [:path, :message]
  defstruct [:path, :message]

  @type t :: %__MODULE__{path: String.t(), message: String.t()}

  @spec new(String.t(), String.t()) :: t()
  def new(path, message), do: %__MODULE__{path: path, message: message}

  @doc "Joins a parent path and a child segment, omitting the dot at the root."
  @spec join(String.t(), String.t() | integer()) :: String.t()
  def join("", segment), do: to_string(segment)
  def join(path, segment) when is_integer(segment), do: "#{path}[#{segment}]"
  def join(path, segment), do: "#{path}.#{segment}"

  @doc "One line per error, for messages and exceptions."
  @spec format([t()]) :: String.t()
  def format(errors) do
    Enum.map_join(errors, "\n", fn
      %__MODULE__{path: "", message: message} -> message
      %__MODULE__{path: path, message: message} -> "#{path}: #{message}"
    end)
  end
end
