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
    field :usage, :integer, default: 0
    field :usage_converted, :boolean, default: false

    # What people have added to the workflow's `limits.ticket_tokens` for this ticket alone, on the
    # Extend and Run again forms: kept as an addition so a re-pin that moves the workflow's cap
    # moves it under the raise (`Forge.Spend.ticket_cap/2`, `Forge.Tickets.CapRaise`).
    field :cap_raise, :integer, default: 0
    field :pending_transition, :map

    # A hold: set while a person has put the ticket on hold. `held_transition` and `held_entry` are
    # what the engine would have done meanwhile and does at release (`docs/design/workflow-grammar-v1.md`
    # § Holding a ticket). A flag and not a status, so a held ticket keeps its place in the merge
    # queue and its finishing run's outcome is still recorded.
    field :held_at, :utc_datetime
    field :held_transition, :map
    field :held_entry, :map
    field :position, :integer, default: 0

    belongs_to :project, Forge.Projects.Project
    belongs_to :milestone, Forge.Milestones.Milestone
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
      :state,
      :held_at,
      :held_entry,
      :milestone_id,
      :position
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
  Changeset for a release taking its version as its title (`Forge.ReleaseTickets`) and for a
  person retitling a ticket (`Forge.Operator.retitle/3`, which refuses a release's), and nothing
  else.
  """
  def rename_changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [:title])
    |> validate_required([:title])
  end

  @doc """
  Changeset for a release refreshing a ticket that never started (`Forge.Engine.release/2`): the
  pinned workflow, the commit it was read at and the base the branch moves to, together.
  """
  def refresh_changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [:workflow, :workflow_commit, :base_commit])
    |> validate_required([:workflow, :workflow_commit, :base_commit])
  end

  @doc "Changeset for the hold: `held_at`, what waits on it, and nothing else."
  def hold_changeset(ticket, attrs) do
    cast(ticket, attrs, [:held_at, :held_transition, :held_entry])
  end

  @doc "Changeset for a ticket's milestone and its place in that milestone's order, and nothing else."
  def place_changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [:milestone_id, :position])
    |> validate_required([:position])
    |> foreign_key_constraint(:milestone_id)
  end

  @doc "Whether the ticket is on hold."
  @spec held?(%__MODULE__{}) :: boolean()
  def held?(%__MODULE__{held_at: nil}), do: false
  def held?(%__MODULE__{}), do: true

  @doc """
  Changeset for the base a ticket's changeset is diffed against moving on, after its branch merged
  the default branch (`docs/design/workflow-grammar-v1.md` § Merging), and nothing else.
  """
  def base_changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [:base_commit])
    |> validate_required([:base_commit])
  end

  @doc """
  Changeset for the engine moving a ticket: state, status, accumulated usage, the cap raise a person
  made with an extension or a restart, and the approval or hold it waits on
  (`pending_transition`, `held_transition`, `held_entry`), and nothing else.
  """
  def progress_changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [
      :state,
      :status,
      :usage,
      :cap_raise,
      :pending_transition,
      :held_transition,
      :held_entry
    ])
    |> validate_required([:state, :status, :usage])
    |> validate_number(:usage, greater_than_or_equal_to: 0)
    |> validate_number(:cap_raise, greater_than_or_equal_to: 0)
  end
end
