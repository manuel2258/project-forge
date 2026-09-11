defmodule Forge.Artifacts.Answer do
  @moduledoc """
  A person's answer to a question. Also recorded as a version of the ticket's `answers.md`
  document (`artifact_version_id`); this row is the queryable index.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "answers" do
    field :choice, :string
    field :text, :string

    belongs_to :question, Forge.Artifacts.Question
    belongs_to :user, Forge.Accounts.User
    belongs_to :artifact_version, Forge.Artifacts.Version

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(answer, attrs) do
    answer
    |> cast(attrs, [:question_id, :user_id, :choice, :text, :artifact_version_id])
    |> validate_required([:question_id, :user_id, :artifact_version_id])
    |> validate_choice_or_text()
    |> foreign_key_constraint(:question_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:artifact_version_id)
  end

  defp validate_choice_or_text(changeset) do
    if get_field(changeset, :choice) || get_field(changeset, :text),
      do: changeset,
      else: add_error(changeset, :choice, "either a choice or free text is required")
  end
end
