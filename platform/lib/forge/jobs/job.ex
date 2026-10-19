defmodule Forge.Jobs.Job do
  @moduledoc """
  One execution of one job state. `spec` is written once and never changed: prompt, input
  manifest pinned by artifact version, environment, commit, budgets and permitted children.
  A job has a process only while `status` is `:running`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias ForgeCore.Workflow.Resources

  # `:parked` is a job waiting on commands it invoked: it holds no slice, unlike `:waiting`, and
  # is live for its ticket (`docs/design/commands.md` § Always park).
  @statuses [:pending, :running, :waiting, :parked, :hibernated, :finished]
  @outcomes [:converged, :did_not_converge, :budget_exhausted, :error, :cancelled]
  # Which ceiling a `budget_exhausted` job ran out of. Not an outcome of its own: the engine
  # routes on the outcome, and a workflow naming `budget_exhausted` must keep working whichever
  # ceiling bound (`docs/design/capacity.md` § Four exhaustions, three treatments).
  @ceilings [:turns, :cost, :wall_clock]
  @kinds [:workflow, :chat, :command]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "jobs" do
    field :kind, Ecto.Enum, values: @kinds, default: :workflow
    # A conversation's model, chosen when it was opened. A workflow job has none: its model is
    # its state's, which is in the pinned workflow rather than on the row.
    field :model, :string
    field :state, :string
    field :attempt, :integer
    field :spec, :map
    # What the scheduler gates on, resolved once at creation from the workflow's chain and the
    # platform's defaults (`docs/design/provisioning.md` § What a job asks for). Denormalised out
    # of `spec` because `Workers.promised/1` sums them across a worker's jobs on every pass, and
    # written once like `spec` for the same reason: what a job was admitted as does not change
    # under it. Nullable in the database for rows that predate the column; required here, because
    # a job with no figures is one the gate cannot place.
    field :memory_max, :integer
    field :cores, :integer
    # The project secrets it is handed, by name: its state's, its command's, or what the person
    # opening a conversation picked. Written once, like `spec` (`docs/design/secrets.md`).
    field :secret_names, {:array, :string}, default: []
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :outcome, Ecto.Enum, values: @outcomes
    field :declared_outcome, :string
    # What a `budget_exhausted` job ran out of: its turn ceiling, its cost ceiling, or the
    # driver's wall clock. Null for every other job — and for one recorded before the column
    # existed, or by a worker too old to send it, where nothing on the row can say.
    field :exhausted, Ecto.Enum, values: @ceilings
    # A command's exit status; nil for every other kind, and for a command that ended without one.
    field :exit_status, :integer
    field :turns, :integer, default: 0
    field :cost_usd, :decimal, default: Decimal.new(0)
    field :harness_session_id, :string
    # The latest session file the worker uploaded — `%{"key", "version"}` — which a resume on
    # another machine puts back (`docs/design/claude-code-events.md` § Resume).
    field :session_blob, :map
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    belongs_to :ticket, Forge.Tickets.Ticket
    # A workflow job reaches its project through its ticket, but a project chat has no ticket;
    # without this there is nothing to clone and no project to schedule it for.
    belongs_to :project, Forge.Projects.Project
    belongs_to :parent_job, __MODULE__
    # The previous attempt of this state whose session this one forks: a new attempt the ticket
    # came back to (`docs/design/claude-code-events.md` § Resume). Cleared when a resume is refused.
    belongs_to :resume_from, __MODULE__
    belongs_to :worker, Forge.Workers.Worker
    # What pays for it: the credential it picked from its project's pool at its first start, and
    # keeps while that is usable (`docs/design/credentials.md` § How a job picks). A credential's
    # spend is a query over the jobs carrying it. Null for a job that has never started, and for
    # every job before credentials existed, which the node's own key paid for.
    belongs_to :credential, Forge.Credentials.Credential
    has_many :events, Forge.Events.Event

    # Sub-second, because the order jobs are read back in is the ticket's timeline and two jobs
    # of one ticket can be created within the same second.
    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def outcomes, do: @outcomes
  def kinds, do: @kinds

  @doc """
  Changeset for creating a job. The spec is immutable from here on.

  What is required depends on the kind, and the database says the same thing in a CHECK
  constraint: a workflow job has a ticket, a state and a spec; a chat has a project and none of
  them. Two statements of one rule, because a changeset can be bypassed and a constraint cannot.
  """
  def create_changeset(job, attrs) do
    job
    |> cast(attrs, [
      :kind,
      :ticket_id,
      :project_id,
      :state,
      :attempt,
      :parent_job_id,
      :resume_from_id,
      :spec,
      :worker_id,
      :model,
      :memory_max,
      :cores,
      :secret_names
    ])
    |> validate_required([:kind, :project_id, :attempt, :memory_max, :cores])
    |> validate_shape()
    |> validate_number(:attempt, greater_than: 0)
    # The least a job can run in, and the last refusal on the platform's side: a caller that
    # bypassed the form and the grammar — the CLI, a future API — still cannot make a row with a
    # ceiling that takes its machine down (`docs/design/workflow-grammar-v1.md` § Resources).
    |> validate_number(:memory_max,
      greater_than_or_equal_to: Resources.minimum_memory(),
      message: Resources.too_little_memory()
    )
    |> validate_number(:cores, greater_than: 0)
    |> foreign_key_constraint(:ticket_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:parent_job_id)
    |> foreign_key_constraint(:worker_id)
    |> unique_constraint([:ticket_id, :state, :attempt])
    |> check_constraint(:kind, name: :jobs_kind_shape)
  end

  defp validate_shape(changeset) do
    case get_field(changeset, :kind) do
      :chat -> validate_absent(changeset, [:state, :spec])
      _workflow_or_command -> validate_required(changeset, [:ticket_id, :state, :spec])
    end
  end

  # A chat with a state would be a chat the timeline draws as a visit to it, and a chat with a
  # spec would be a chat the engine can read a budget and an outcome list out of.
  defp validate_absent(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      case get_field(changeset, field) do
        nil -> changeset
        _value -> add_error(changeset, field, "belongs to a workflow job, not a conversation")
      end
    end)
  end

  @doc "Changeset for everything that may change after creation. Never touches the spec."
  def progress_changeset(job, attrs) do
    job
    |> cast(attrs, [
      :status,
      :outcome,
      :declared_outcome,
      :exhausted,
      :turns,
      :cost_usd,
      :harness_session_id,
      :session_blob,
      :resume_from_id,
      :worker_id,
      :credential_id,
      :started_at,
      :finished_at,
      :exit_status
    ])
    |> validate_required([:status])
    |> validate_number(:turns, greater_than_or_equal_to: 0)
    |> validate_number(:cost_usd, greater_than_or_equal_to: 0)
    |> validate_outcome_only_when_finished()
    |> validate_ceiling_only_when_exhausted()
  end

  # A ceiling is what `budget_exhausted` ran out of, so a job with any other outcome carrying one
  # would be a row saying it ran out of something it never ran out of. The other direction is not
  # required: a worker built before the ceiling crossed the wire reports none, and refusing its
  # result would lose the whole run over a word.
  #
  # **Refusing is not free either**, and the comment above used to imply it was: an error here
  # fails `Forge.Jobs.complete/2` with `not_recorded`, which the worker re-sends forever. No
  # worker built from this `forge_core` can send that pair — every clause of
  # `ForgeCore.Job.Outcome.finished/2` that names a ceiling returns `:budget_exhausted` — so the
  # only window is a worker from a revision where that stopped being true, and the protocol is
  # deliberately not bumped for an addition. Kept as a refusal rather than a silent drop because
  # the pair means one of the two facts is wrong, and guessing which would be the worse answer.
  defp validate_ceiling_only_when_exhausted(changeset) do
    case {get_field(changeset, :outcome), get_field(changeset, :exhausted)} do
      {outcome, ceiling} when outcome != :budget_exhausted and ceiling != nil ->
        add_error(changeset, :exhausted, "only a budget_exhausted job ran out of a ceiling")

      _ok ->
        changeset
    end
  end

  # A conversation is over when a person is done with it, and that is not an outcome: there is no
  # state it left and no transition it selects. "Finished" means over; "outcome" is a workflow
  # word, and a chat carrying one would be a chat the engine could act on.
  defp validate_outcome_only_when_finished(%{data: %{kind: :chat}} = changeset) do
    case get_field(changeset, :outcome) do
      nil -> changeset
      _outcome -> add_error(changeset, :outcome, "a conversation has no outcome")
    end
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
