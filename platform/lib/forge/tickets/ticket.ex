defmodule Forge.Tickets.Ticket do
  @moduledoc """
  A unit of work moving through its project's workflow. The workflow is pinned at admission:
  `workflow` holds the parsed definition and `workflow_commit` the commit it was read from.
  `state` is a state name from that definition; `status` is the engine's view of the ticket.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tickets" do
    field :number, :integer
    field :title, :string
    field :body, :string, default: ""
    field :base_commit, :string
    field :branch, :string
    field :workflow, :map
    field :workflow_commit, :string
    field :state, :string
    field :status, Ecto.Enum, values: [:active, :stuck, :done, :cancelled], default: :active
    field :cost_usd, :decimal, default: Decimal.new(0)

    belongs_to :project, Forge.Projects.Project
    has_many :jobs, Forge.Jobs.Job
    has_many :artifacts, Forge.Artifacts.Artifact
    has_many :events, Forge.Events.Event

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for admitting a ticket. Everything pinned is required up front."
  def admit_changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [
      :project_id,
      :number,
      :title,
      :body,
      :base_commit,
      :branch,
      :workflow,
      :workflow_commit,
      :state
    ])
    |> validate_required([
      :project_id,
      :number,
      :title,
      :base_commit,
      :branch,
      :workflow,
      :workflow_commit,
      :state
    ])
    |> validate_number(:number, greater_than: 0)
    |> foreign_key_constraint(:project_id)
    |> unique_constraint([:project_id, :number])
  end

  @doc "Changeset for the engine moving a ticket: state, status and accumulated cost only."
  def progress_changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [:state, :status, :cost_usd])
    |> validate_required([:state, :status, :cost_usd])
    |> validate_number(:cost_usd, greater_than_or_equal_to: 0)
  end
end
