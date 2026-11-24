defmodule Forge.Pages.Version do
  @moduledoc """
  One version of a page: which job published it and which version of each file made it up.
  Append-only by trigger. `files` is `%{"index.html" => artifact_version_id}`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "page_versions" do
    field :version, :integer
    field :files, :map, default: %{}

    belongs_to :page, Forge.Pages.Page
    belongs_to :job, Forge.Jobs.Job

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}
end
