defmodule Forge.Pages.Page do
  @moduledoc """
  A page of a ticket, or of a project chat, and the counters of its store
  (`docs/design/pages.md` § What a page is). Its files are blob artifacts named
  `<page>/<file>` and its versions are `Forge.Pages.Version` rows; this row exists from the first
  version or the first write to its store.

  Exactly one of `ticket_id` and `job_id` is set, as on an artifact, and the database says so too.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "pages" do
    field :name, :string
    field :seq, :integer, default: 0
    field :key_count, :integer, default: 0
    field :data_bytes, :integer, default: 0

    belongs_to :project, Forge.Projects.Project
    belongs_to :ticket, Forge.Tickets.Ticket
    belongs_to :job, Forge.Jobs.Job

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
