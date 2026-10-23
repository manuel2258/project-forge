defmodule Forge.Jobs.Runs do
  @moduledoc """
  The run ledger: each start of a job, the credential it spent and what it cost
  (`docs/design/credentials.md` § Spend).

  Every function adds a step to the caller's `Ecto.Multi`, so a run opens and closes in the same
  transaction as the status change that means it — a job marked running with no run, or a run
  left open under a job that stopped, is not a state anything here can produce.

  **A job has at most one open run.** Opening closes whatever the job left open: a run whose
  machine was lost never reported, and what it spent is unknown rather than zero — but the next
  run must not inherit its row.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Forge.Jobs.{Job, Run}
  alias Forge.Repo

  @doc "Opens a run of `job` on `worker` and `credential`, closing any run the job left open."
  @spec open(Multi.t(), Job.t(), map(), map() | nil, DateTime.t()) :: Multi.t()
  def open(multi, %Job{id: job_id}, worker, credential, now) do
    multi
    |> close(job_id, now)
    |> Multi.insert(:run, %Run{
      job_id: job_id,
      worker_id: worker.id,
      # A command runs on no credential (`docs/design/commands.md` § An invocation is a job).
      credential_id: credential && credential.id,
      started_at: now
    })
  end

  @doc """
  Closes `job_id`'s open run, adding `cost` to it — a workflow job's result, which reports what
  that run spent. Without a cost the run is closed as it stands: a conversation's has been set
  turn by turn, and a run that stopped without reporting spent nothing anyone knows of.
  """
  @spec close(Multi.t(), String.t(), DateTime.t(), Decimal.t() | nil) :: Multi.t()
  def close(multi, job_id, now, cost \\ nil)

  def close(multi, job_id, now, nil),
    do: Multi.update_all(multi, :close_run, open_runs(job_id), set: [finished_at: now])

  def close(multi, job_id, now, %Decimal{} = cost) do
    Multi.update_all(multi, :close_run, open_runs(job_id),
      set: [finished_at: now],
      inc: [cost_usd: cost]
    )
  end

  @doc """
  Sets what `job_id`'s latest run has cost so far: a conversation's turn, whose figure is the
  harness's running total for the process (`docs/design/conversations.md` § Spend).

  The latest run rather than the open one, because a turn is re-sent until it is acked and can
  arrive after its conversation ended and closed the run it belongs to. Its cost still belongs to
  that run; nothing opens another between a turn and its conversation's end.
  """
  @spec cost(Multi.t(), String.t(), Decimal.t()) :: Multi.t()
  def cost(multi, job_id, %Decimal{} = cost) do
    latest =
      from r in Run,
        where: r.job_id == ^job_id,
        order_by: [desc: r.started_at, desc: r.inserted_at],
        limit: 1,
        select: r.id

    Multi.update_all(multi, :run_cost, from(r in Run, where: r.id in subquery(latest)),
      set: [cost_usd: cost]
    )
  end

  @doc """
  When each of `job_ids`' open runs started, as `%{job_id => DateTime}` — the start of the run a
  job is in *now*.

  `jobs.started_at` is not that: `Forge.Jobs.mark_started/3` writes it `job.started_at || now`,
  so on every run after the first it still holds the first one's start. A job that is not running
  has no open run and so no key here.
  """
  @spec started([String.t()]) :: %{String.t() => DateTime.t()}
  def started(job_ids) do
    Repo.all(
      from r in Run,
        where: r.job_id in ^job_ids and is_nil(r.finished_at),
        select: {r.job_id, r.started_at}
    )
    |> Map.new()
  end

  @doc "What `job_id`'s runs have cost between them, read inside the caller's transaction."
  @spec total(String.t()) :: Decimal.t()
  def total(job_id) do
    Repo.one(from r in Run, where: r.job_id == ^job_id, select: sum(r.cost_usd)) ||
      Decimal.new(0)
  end

  @doc "Closes the open runs of every job in `job_ids` at once, for a ticket cancelled whole."
  @spec close_all(Multi.t(), [String.t()], DateTime.t()) :: Multi.t()
  def close_all(multi, job_ids, now) do
    Multi.update_all(
      multi,
      :close_runs,
      from(r in Run, where: r.job_id in ^job_ids and is_nil(r.finished_at)),
      set: [finished_at: now]
    )
  end

  defp open_runs(job_id), do: from(r in Run, where: r.job_id == ^job_id and is_nil(r.finished_at))
end
