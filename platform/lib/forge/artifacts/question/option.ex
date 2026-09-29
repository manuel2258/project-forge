defmodule Forge.Artifacts.Question.Option do
  @moduledoc """
  One option of a stored question, embedded in `questions.options`. The fields mirror
  `ForgeCore.Document.Question.Option`.

  `detail` may be nil on a row recorded before options had one; the migration that made options
  a headline and a sentence kept each old one as a headline alone
  (`docs/design/job-prompt.md` § Output format). The parser never makes such an option, which is
  why the stored one has to allow it and the parsed one does not.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :label, :string
    field :detail, :string
    field :recommended, :boolean, default: false
  end

  @type t :: %__MODULE__{label: String.t(), detail: String.t() | nil, recommended: boolean()}

  # `validate_required` is an equivalent mutant today: the parser refuses an option without a
  # label before anything is stored, and the migration made each old label one. It stays so that
  # a writer that is neither cannot store an option nobody can choose.
  def changeset(option, attrs) do
    option
    |> cast(attrs, [:label, :detail, :recommended])
    |> validate_required([:label])
  end
end
