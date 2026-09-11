defmodule Forge.Artifacts.Version do
  @moduledoc """
  One immutable version of an artifact. Rows are insert-only, enforced by a database trigger.
  `author` is `%{"kind" => "job" | "user", "id" => id}`. Documents carry `content`; blobs
  carry `blob_uri`. `meta` holds the parsed front matter.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "artifact_versions" do
    field :version, :integer
    field :author, :map
    field :content, :string
    field :blob_uri, :string
    field :content_hash, :string
    field :meta, :map, default: %{}

    belongs_to :artifact, Forge.Artifacts.Artifact
    has_many :questions, Forge.Artifacts.Question, foreign_key: :artifact_version_id
    has_many :approvals, Forge.Artifacts.Approval, foreign_key: :artifact_version_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(version, attrs) do
    version
    |> cast(attrs, [:artifact_id, :version, :author, :content, :blob_uri, :content_hash, :meta])
    |> validate_required([:artifact_id, :version, :author, :content_hash])
    |> validate_number(:version, greater_than: 0)
    |> validate_author()
    |> validate_content_or_blob()
    |> foreign_key_constraint(:artifact_id)
    |> unique_constraint([:artifact_id, :version])
  end

  defp validate_author(changeset) do
    case get_field(changeset, :author) do
      %{"kind" => kind, "id" => id} when kind in ["job", "user"] and is_binary(id) -> changeset
      _ -> add_error(changeset, :author, "must be %{kind: job | user, id: id}")
    end
  end

  defp validate_content_or_blob(changeset) do
    case {get_field(changeset, :content), get_field(changeset, :blob_uri)} do
      {nil, nil} -> add_error(changeset, :content, "either content or blob_uri is required")
      {_content, nil} -> changeset
      {nil, _uri} -> changeset
      _ -> add_error(changeset, :content, "content and blob_uri are exclusive")
    end
  end
end
