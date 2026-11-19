defmodule Forge.Jobs.Runs do
  @moduledoc """
  The run ledger: each start of a job, the credential it used and what it used
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
  alias Forge.Jobs.{Extension, Job, Run}
  alias Forge.Repo

  @doc """
  Opens a run of `job` on `worker` and `credential`, closing any run the job left open. `extension`
  is the extension the run is the first of (`Forge.Jobs.Extensions.to_tell/1`), stamped on it
  (`job_runs.extension_id`), or nil.
  """
  @spec open(Multi.t(), Job.t(), map(), map() | nil, DateTime.t(), Extension.t() | nil) ::
          Multi.t()
  def open(multi, %Job{id: job_id}, worker, credential, now, extension \\ nil) do
    multi
    |> close(job_id, now)
    |> Multi.insert(
      :run,
      %Run{
        job_id: job_id,
        worker_id: worker.id,
        extension_id: extension && extension.id,
        # A command runs on no credential (`docs/design/commands.md` § An invocation is a job).
        credential_id: credential && credential.id,
        # Copied from the credential's kind, now and for good: a kind redefined later does not
        # change a hold already taken. **A live exclusive run is a hold**, and the index under it
        # refuses a second, which comes back as `{:error, :run, changeset, _}` and is answered
        # as held (`Forge.Jobs.mark_started/3`).
        exclusive: exclusive?(credential),
        started_at: now
      }
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.unique_constraint(:credential_id,
        name: :job_runs_one_live_exclusive_index,
        message: "is held by another run"
      )
    )
  end

  defp exclusive?(nil), do: false

  defp exclusive?(%{harness: harness, kind: kind}),
    do: Forge.Harness.traits(harness, kind).exclusive

  @typedoc """
  What a run used, as a worker reports it: weighted tokens, the tokens by kind behind them, and
  Claude Code's own dollar figure when the harness has one. `tokens` and `claude_cost_usd` may be
  nil (a worker that sent none).
  """
  @type figure :: %{
          required(:usage) => non_neg_integer(),
          optional(:tokens) => map() | nil,
          optional(:claude_cost_usd) => Decimal.t() | nil
        }

  @doc false
  # What a worker's report of a run says it used: weighted tokens, the tokens by kind behind them
  # and Claude Code's own dollar figure. Protocol 11 workers send `usage`; a report without it
  # (nothing counted) uses nothing, which is what a run that stopped before its first call used.
  @spec figure(map() | nil) :: figure()
  def figure(harness) do
    harness = harness || %{}

    %{
      usage: usage_of(harness["usage"]),
      tokens: if(is_map(harness["tokens"]), do: ForgeCore.Usage.normalize(harness["tokens"])),
      claude_cost_usd: if(is_number(harness["cost_usd"]), do: to_decimal(harness["cost_usd"]))
    }
  end

  defp usage_of(n) when is_integer(n) and n >= 0, do: n
  defp usage_of(_), do: 0

  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)

  @doc """
  Closes `job_id`'s open run, adding `figure` to it — a workflow job's result, which reports what
  that run used. Without a figure the run is closed as it stands: a conversation's has been set
  turn by turn, and a run that stopped without reporting used nothing anyone knows of.

  `resumed:` (an option) is whether the run resumed its session, written to the run when it is a
  boolean (`resumed/1` reads it from a result). `release_extension: true` clears the run's
  `extension_id`, for a run the platform took back with no result: its machine was lost or never
  reached, it hibernated, or the harness refused its session. The extension was not delivered by it, and the next
  run is its first (`Forge.Jobs.Extensions.first_run?/1`).
  """
  @spec close(Multi.t(), String.t(), DateTime.t(), figure() | nil, keyword()) :: Multi.t()
  def close(multi, job_id, now, figure \\ nil, opts \\ [])

  def close(multi, job_id, now, nil, opts),
    do:
      Multi.update_all(multi, :close_run, open_runs(job_id),
        set: [finished_at: now] ++ resumed_set(opts)
      )

  # `usage` is added to what the run holds, as the dollar figure was; `tokens` and `claude_cost_usd`
  # are set to the report's (nil when the worker sent none). A run is closed once — `open_runs`
  # selects only runs not yet finished — so nothing here is summed twice.
  def close(multi, job_id, now, %{usage: usage} = figure, opts) do
    Multi.update_all(
      multi,
      :close_run,
      open_runs(job_id),
      [
        set:
          [
            finished_at: now,
            tokens: figure[:tokens],
            claude_cost_usd: figure[:claude_cost_usd]
          ] ++ resumed_set(opts)
      ] ++
        [inc: [usage: usage]]
    )
  end

  # `resumed` is written only when the caller knows: a result that said nothing leaves the run's
  # column null, as does a run closed without one.
  defp resumed_set(opts) do
    resumed =
      case Keyword.get(opts, :resumed) do
        resumed when is_boolean(resumed) -> [resumed: resumed]
        nil -> []
      end

    # `release_extension: true` lets go of the extension the run was started on: a run that ended
    # with no result (`Extensions.first_run?/1`). A run that failed or was cancelled keeps it, and
    # the job page's label, as the run of that extension it was.
    if Keyword.get(opts, :release_extension, false),
      do: [extension_id: nil] ++ resumed,
      else: resumed
  end

  @doc """
  Whether the run resumed its session, as a worker's report says (`harness["resumed"]`): a boolean,
  or nil from a worker that does not say — a protocol 11 worker, which nothing here guesses for.
  """
  @spec resumed(map() | nil) :: boolean() | nil
  def resumed(%{"resumed" => resumed}) when is_boolean(resumed), do: resumed
  def resumed(_harness), do: nil

  @doc """
  Sets what `job_id`'s latest run has used so far: a conversation's turn, whose figure is the
  process's own running total — counted per model call by the worker, so a resumed session's past
  is never in it (`docs/design/conversations.md` § Spend).

  The latest run rather than the open one, because a turn is re-sent until it is acked and can
  arrive after its conversation ended and closed the run it belongs to. Its usage still belongs to
  that run; nothing opens another between a turn and its conversation's end.

  **It records when it wrote**, in `updated_at`, which `update_all` would otherwise leave at the
  run's insert: an open run's spend is drawn at the moment it was last costed
  (`docs/design/capacity.md` § Usage history, `Forge.Usage`).
  """
  @spec record(Multi.t(), String.t(), figure()) :: Multi.t()
  def record(multi, job_id, %{usage: usage} = figure) do
    Multi.update_all(multi, :run_usage, from(r in Run, where: r.id in subquery(latest(job_id))),
      set: [
        usage: usage,
        tokens: figure[:tokens],
        claude_cost_usd: figure[:claude_cost_usd],
        updated_at: DateTime.utc_now(:second)
      ]
    )
  end

  @doc "A job's runs, oldest first: what each used, by kind when it was counted, and when."
  @spec for_job(String.t()) :: [Run.t()]
  def for_job(job_id) do
    Repo.all(
      from r in Run,
        where: r.job_id == ^job_id,
        order_by: [asc: r.started_at, asc: r.inserted_at]
    )
  end

  defp latest(job_id) do
    from r in Run,
      where: r.job_id == ^job_id,
      order_by: [desc: r.started_at, desc: r.inserted_at],
      limit: 1,
      select: r.id
  end

  @doc """
  The id of a job's newest run: the process a report that has just arrived came from. A
  conversation's turns are numbered from one in every process, so a turn is told from a re-send by
  its run as well as its number (`Forge.Conversations.record_turn/2`).
  """
  @spec latest_id(String.t()) :: String.t() | nil
  def latest_id(job_id), do: Repo.one(latest(job_id))

  @doc """
  When each of `job_ids`' open runs started, as `%{job_id => DateTime}` — the start of the run a
  job is in *now*.

  `jobs.started_at` is not that: `Forge.Jobs.mark_started/3` writes it `job.started_at || now`,
  so on every run after the first it still holds the first one's start. A job that is not running
  has no open run and so no key here.
  """
  @spec started([String.t()]) :: %{String.t() => DateTime.t()}
  # An equivalent mutant, kept for the round trip it saves, and matching the clause
  # `Jobs.current_waits/1` carries for the same reason. `job_id in ^[]` selects nothing and
  # `Map.new([])` is `%{}`, so removing this clause changes nothing a test can see: a list of
  # tickets with nothing running (`Forge.Tickets.Doing.live/1`) would simply ask the database for
  # the empty set.
  def started([]), do: %{}

  def started(job_ids) do
    Repo.all(
      from r in Run,
        where: r.job_id in ^job_ids and is_nil(r.finished_at),
        select: {r.job_id, r.started_at}
    )
    |> Map.new()
  end

  @doc "What `job_id`'s runs have used between them, read inside the caller's transaction."
  @spec total(String.t()) :: non_neg_integer()
  def total(job_id) do
    Repo.one(
      from r in Run, where: r.job_id == ^job_id, select: type(coalesce(sum(r.usage), 0), :integer)
    )
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
