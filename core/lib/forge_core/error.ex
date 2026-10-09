defmodule ForgeCore.Error do
  @moduledoc """
  A parse or validation error, located by a dotted path into the definition — and, when the part
  of the definition it is about came from a library a ticket type imports, by that library's
  file (`docs/design/ticket-types.md` § Imports). Nil `file` is the file being read.
  """

  @enforce_keys [:path, :message]
  defstruct [:path, :message, file: nil]

  @type t :: %__MODULE__{path: String.t(), message: String.t(), file: String.t() | nil}

  @spec new(String.t(), String.t()) :: t()
  def new(path, message), do: %__MODULE__{path: path, message: message}

  @doc "Joins a parent path and a child segment, omitting the dot at the root."
  @spec join(String.t(), String.t() | integer()) :: String.t()
  def join("", segment), do: to_string(segment)
  def join(path, segment) when is_integer(segment), do: "#{path}[#{segment}]"
  def join(path, segment), do: "#{path}.#{segment}"

  @doc """
  One line per error, for messages and exceptions. An error from a library names the library
  first, because the path that follows is into it and not into the file the reader opened.
  """
  @spec format([t()]) :: String.t()
  def format(errors), do: Enum.map_join(errors, "\n", &line/1)

  defp line(%__MODULE__{file: nil} = error), do: located(error)
  defp line(%__MODULE__{file: file} = error), do: "#{file}: " <> located(error)

  defp located(%__MODULE__{path: "", message: message}), do: message
  defp located(%__MODULE__{path: path, message: message}), do: "#{path}: #{message}"

  @doc """
  What went wrong, as text, whatever shape it arrived in: a list of errors is `format/1`'s lines,
  text is itself, and anything else is inspected. For a reason that has to cross the wire or sit
  in a timeline row, where a struct cannot.
  """
  @spec to_text(term()) :: String.t()
  def to_text([%__MODULE__{} | _] = errors), do: format(errors)
  def to_text(text) when is_binary(text), do: text
  def to_text(other), do: inspect(other)
end
