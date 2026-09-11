defmodule Forge.Events.Event do
  @moduledoc """
  One entry in the append-only event log. `seq` is the global order. `actor` is
  `%{"kind" => "system" | "user" | "job", "id" => id | nil}`. `type` is dotted, e.g.
  `ticket.admitted`, `job.harness.tool_use`, `transition.taken`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:seq, :id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "events" do
    field :actor, :map
    field :type, :string
    field :payload, :map, default: %{}

    belongs_to :ticket, Forge.Tickets.Ticket
    belongs_to :job, Forge.Jobs.Job

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:ticket_id, :job_id, :actor, :type, :payload])
    |> validate_required([:actor, :type, :payload])
    |> validate_format(:type, ~r/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$/,
      message: "must be dotted, e.g. ticket.admitted"
    )
    |> validate_actor()
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
