defmodule Forge.Events.Event do
  @moduledoc """
  One entry in the append-only event log. `seq` is the global order. `actor` is
  `%{"kind" => "system" | "user" | "job", "id" => id | nil}`. `type` is dotted, e.g.
  `ticket.admitted`, `job.harness.tool_use`, `transition.taken`.

  `project_id` is denormalised rather than reached through the ticket or the job, because both
  are nullable and a node-wide event has neither. It is what makes "the events I may read" one
  indexed query — `docs/design/identity.md` § Read scoping is the half that leaks. Null means
  node-wide, which only a node admin reads.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:seq, :id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "events" do
    field :actor, :map
    field :type, :string
    field :payload, :map, default: %{}

    belongs_to :project, Forge.Projects.Project
    belongs_to :ticket, Forge.Tickets.Ticket
    belongs_to :job, Forge.Jobs.Job

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:project_id, :ticket_id, :job_id, :actor, :type, :payload])
    |> validate_required([:actor, :type, :payload])
    |> validate_format(:type, ~r/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$/,
      message: "must be dotted, e.g. ticket.admitted"
    )
    |> validate_actor()
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:ticket_id)
    |> foreign_key_constraint(:job_id)
  end

  defp validate_actor(changeset) do
    case get_field(changeset, :actor) do
      %{"kind" => "system"} -> changeset
      %{"kind" => kind, "id" => id} when kind in ["user", "job"] and is_binary(id) -> changeset
      _ -> add_error(changeset, :actor, "must be %{kind: system | user | job, id: id}")
    end
  end
end
