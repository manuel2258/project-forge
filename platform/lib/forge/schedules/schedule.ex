defmodule Forge.Schedules.Schedule do
  @moduledoc """
  What a person did about one schedule of a workflow file, and what came of it
  (`docs/design/schedules.md` § The model). The schedule itself — its cron line, title and body — is
  in the repository; **a schedule with no row is off**.

  *On* is `enabled_by_id` being set. `alerted_at` is an open queue item, and `problem` is what the
  schedule says is wrong with it, which outlives the item: dismissing one clears `alerted_at` and
  leaves the problem on the Workflow view.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "schedules" do
    field :ticket_type, :string
    field :name, :string
    field :enabled_at, :utc_datetime
    field :cron, :string
    field :fires_after, :utc_datetime
    field :problem, :string
    field :problem_kind, Ecto.Enum, values: [:failed, :switched_off]
    field :problem_at, :utc_datetime
    field :alerted_at, :utc_datetime

    belongs_to :project, Forge.Projects.Project
    belongs_to :enabled_by, Forge.Accounts.User
    belongs_to :last_ticket, Forge.Tickets.Ticket

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc "Whether the schedule is switched on."
  @spec on?(t()) :: boolean()
  def on?(%__MODULE__{enabled_by_id: id}), do: not is_nil(id)
end
