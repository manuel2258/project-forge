defmodule Forge.Tickets.Ticket do
  @moduledoc """
  A unit of work moving through its project's workflow. The workflow is pinned at admission:
  `workflow` holds the parsed definition and `workflow_commit` the commit it was read from.
  `ticket_type` is the type it was admitted as, which names the file a re-pin reads; nil is the
  single `.forge/workflow.yml` (`docs/design/ticket-types.md`).
  `state` is a state name from that definition; `status` is the engine's view of the ticket.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @open [:active, :stuck]

  @doc """
  The statuses of a ticket that still has work ahead of it: active, or stuck waiting for a person.
  Done and cancelled are not. The one definition every surface and guard reads, so "open" cannot
  mean one thing on the board and another in the engine.
  """
  @spec open_statuses() :: [atom()]
  def open_statuses, do: @open

  @doc "`open_statuses/0` as a guard."
  defguard open?(status) when status in @open

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
    field :ticket_type, :string
    field :state, :string
    field :status, Ecto.Enum, values: [:active, :stuck, :done, :cancelled], default: :active
    field :cost_usd, :decimal, default: Decimal.new(0)
    field :pending_transition, :map

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
      :ticket_type,
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

  @doc """
  Changeset for a person re-pinning the ticket's workflow (`Forge.Engine.repin/2`): the definition
  and the commit it was read at, together, and nothing else.
  """
  def repin_changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [:workflow, :workflow_commit])
    |> validate_required([:workflow, :workflow_commit])
  end

  @doc """
  Changeset for the base a ticket's changeset is diffed against moving on, after its branch merged
  the default branch (`docs/design/workflow-grammar-v1.md` § Merging), and nothing else.
  """
  def base_changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [:base_commit])
    |> validate_required([:base_commit])
  end

  @doc "Changeset for the engine moving a ticket: state, status and accumulated cost only."
  def progress_changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [:state, :status, :cost_usd, :pending_transition])
    |> validate_required([:state, :status, :cost_usd])
    |> validate_number(:cost_usd, greater_than_or_equal_to: 0)
  end
end
