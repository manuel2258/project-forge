defmodule Forge.Jobs.Job do
  @moduledoc """
  One execution of one job state. `spec` is written once and never changed: prompt, input
  manifest pinned by artifact version, environment, commit, budgets and permitted children.
  A job has a process only while `status` is `:running`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:pending, :running, :waiting, :hibernated, :finished]
  @outcomes [:converged, :did_not_converge, :budget_exhausted, :error, :cancelled]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "jobs" do
    field :state, :string
    field :attempt, :integer
    field :spec, :map
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :outcome, Ecto.Enum, values: @outcomes
    field :declared_outcome, :string
    field :turns, :integer, default: 0
    field :cost_usd, :decimal, default: Decimal.new(0)
    field :harness_session_id, :string
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    belongs_to :ticket, Forge.Tickets.Ticket
    belongs_to :parent_job, __MODULE__
    belongs_to :worker, Forge.Workers.Worker
    has_many :events, Forge.Events.Event

    # Sub-second, because the order jobs are read back in is the ticket's timeline and two jobs
    # of one ticket can be created within the same second.
    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def outcomes, do: @outcomes

  @doc "Changeset for creating a job. The spec is immutable from here on."
  def create_changeset(job, attrs) do
    job
    |> cast(attrs, [:ticket_id, :state, :attempt, :parent_job_id, :spec, :worker_id])
    |> validate_required([:ticket_id, :state, :attempt, :spec])
    |> validate_number(:attempt, greater_than: 0)
    |> foreign_key_constraint(:ticket_id)
    |> foreign_key_constraint(:parent_job_id)
    |> foreign_key_constraint(:worker_id)
    |> unique_constraint([:ticket_id, :state, :attempt])
  end

  @doc "Changeset for everything that may change after creation. Never touches the spec."
  def progress_changeset(job, attrs) do
    job
    |> cast(attrs, [
      :status,
      :outcome,
      :declared_outcome,
      :turns,
      :cost_usd,
      :harness_session_id,
      :worker_id,
      :started_at,
      :finished_at
    ])
    |> validate_required([:status])
    |> validate_number(:turns, greater_than_or_equal_to: 0)
    |> validate_number(:cost_usd, greater_than_or_equal_to: 0)
    |> validate_outcome_only_when_finished()
  end

  defp validate_outcome_only_when_finished(changeset) do
    case {get_field(changeset, :status), get_field(changeset, :outcome)} do
      {:finished, nil} ->
        add_error(changeset, :outcome, "is required once finished")

      {status, outcome} when status != :finished and outcome != nil ->
        add_error(changeset, :outcome, "only a finished job has an outcome")

      _ ->
        changeset
    end
  end
end
