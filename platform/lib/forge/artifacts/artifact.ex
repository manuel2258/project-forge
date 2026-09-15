defmodule Forge.Artifacts.Artifact do
  @moduledoc """
  A named artifact of a ticket, or of a conversation. Holds no content: every write is a new
  `Version`. Unique per scope and name.

  Exactly one of `ticket_id` and `job_id` is set. A conversation with no ticket still writes
  things worth keeping, and they belong to the conversation — `docs/design/conversations.md`
  § Commits.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "artifacts" do
    field :name, :string
    field :kind, Ecto.Enum, values: [:document, :blob, :presentation]

    belongs_to :ticket, Forge.Tickets.Ticket
    belongs_to :job, Forge.Jobs.Job
    has_many :versions, Forge.Artifacts.Version

    timestamps(type: :utc_datetime)
  end

  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [:ticket_id, :job_id, :name, :kind])
    |> validate_required([:name, :kind])
    |> validate_one_scope()
    |> foreign_key_constraint(:ticket_id)
    |> foreign_key_constraint(:job_id)
    |> unique_constraint([:ticket_id, :name], name: :artifacts_ticket_id_name_index)
    |> unique_constraint([:job_id, :name], name: :artifacts_job_id_name_index)
    |> check_constraint(:ticket_id, name: :artifacts_one_scope)
  end

  defp validate_one_scope(changeset) do
    case {get_field(changeset, :ticket_id), get_field(changeset, :job_id)} do
      {nil, nil} -> add_error(changeset, :ticket_id, "an artifact belongs to a ticket or a chat")
      {id, job} when is_binary(id) and is_binary(job) -> both(changeset)
      _one -> changeset
    end
  end

  defp both(changeset),
    do: add_error(changeset, :job_id, "an artifact belongs to one of a ticket and a chat")
end
