defmodule Forge.Artifacts.Question do
  @moduledoc """
  A question extracted from a document version at write time. The fields mirror
  `ForgeCore.Document.Question`; `line` is the file line of the block, and each option is a
  `Forge.Artifacts.Question.Option`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "questions" do
    field :key, :string
    field :anchor, :string
    field :text, :string
    embeds_many :options, Forge.Artifacts.Question.Option, on_replace: :delete
    field :blocking, :boolean, default: false
    field :assumption, :string
    field :line, :integer

    belongs_to :artifact_version, Forge.Artifacts.Version
    has_many :answers, Forge.Artifacts.Answer

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(question, attrs) do
    question
    |> cast(attrs, [
      :artifact_version_id,
      :key,
      :anchor,
      :text,
      :blocking,
      :assumption,
      :line
    ])
    |> cast_embed(:options, with: &Forge.Artifacts.Question.Option.changeset/2)
    |> validate_required([:artifact_version_id, :key, :text, :line])
    |> foreign_key_constraint(:artifact_version_id)
    |> unique_constraint([:artifact_version_id, :key])
  end

  @doc "Builds attrs from a parsed core question."
  def attrs_from_core(%ForgeCore.Document.Question{} = question, artifact_version_id) do
    question
    |> Map.from_struct()
    |> Map.update!(:options, fn options -> Enum.map(options, &Map.from_struct/1) end)
    |> Map.put(:artifact_version_id, artifact_version_id)
  end
end
