defmodule Forge.Attachments.Batch do
  @moduledoc """
  What came with one act: the staged uploads a person finished (`uploads`, each `%{id:, name:}`,
  the name as uploaded — what is said of the file if its id is not one the person may claim), and
  the names of files that failed or were cut off (`not_received`).

  `whole?` is the API's: a request is kept whole or refused whole, where a page sends the text and
  the files that finished and names the rest.
  """

  defstruct uploads: [], not_received: [], whole?: false

  @type upload :: %{id: String.t(), name: String.t()}
  @type t :: %__MODULE__{uploads: [upload()], not_received: [String.t()], whole?: boolean()}

  @doc "Whether there is nothing to claim and nothing to say: the act is as it was before files."
  @spec empty?(t() | nil) :: boolean()
  def empty?(nil), do: true
  def empty?(%__MODULE__{uploads: [], not_received: []}), do: true
  def empty?(%__MODULE__{}), do: false
end
