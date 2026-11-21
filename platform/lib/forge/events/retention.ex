defmodule Forge.Events.Retention do
  @moduledoc """
  The sweep that deletes a finished job's harness stream once it is old enough
  (`docs/design/storage.md` § Retention).

  **Which types go is the database's say, not this module's.** The selection calls
  `forge_event_swept/1`, the SQL function the `events_append_only` trigger asks too, so a sweep
  cannot reach a type the trigger protects without the database refusing it. What this module
  adds is only age and status: a job has ended when it is `finished` or `hibernated`, and is swept
  once its `finished_at` is more than `days` ago. A job that is `pending`, `running`, `waiting` or
  `parked` is never swept, whatever its age.

  **One transaction per job**, which locks the job's row under the same condition the candidate
  list was read with — so a job reopened since is skipped, by the same model as the delete — and
  records `job.swept` in the place of what it removed. A run then records one `events.swept` of its
  own, zero included, so that a sweep that stopped running shows as an event that stopped. Neither
  carries any of a payload: counts, days and dates.
  """

  import Ecto.Query, only: [from: 2]

  alias Forge.Events
  alias Forge.Events.Event
  alias Forge.Jobs.Job
  alias Forge.Repo

  @ended [:finished, :hibernated]

  @doc "How many days after a job ended its harness stream is swept: `FORGE_HARNESS_RETENTION_DAYS`."
  @spec days() :: pos_integer()
  def days, do: config(:days, 30)

  @doc "Milliseconds between sweeps."
  @spec every_ms() :: pos_integer()
  def every_ms, do: config(:every_ms, :timer.hours(24))

  @doc "Milliseconds after boot to the first sweep."
  @spec first_after_ms() :: non_neg_integer()
  def first_after_ms, do: config(:first_after_ms, :timer.minutes(10))

  defp config(key, default),
    do: Application.get_env(:forge, __MODULE__, []) |> Keyword.get(key, default)

  @doc """
  Sweeps every job that ended more than `days/0` before `now`. Returns `{rows, jobs}`: the rows
  deleted and the jobs they came from.
  """
  @spec sweep(DateTime.t()) :: {non_neg_integer(), non_neg_integer()}
  def sweep(now \\ DateTime.utc_now()) do
    days = days()
    cutoff = now |> DateTime.add(-days * 86_400) |> DateTime.truncate(:second)

    removed = for id <- candidates(cutoff), n = sweep_job(id, cutoff, days), n > 0, do: n

    rows = Enum.sum(removed)
    jobs = length(removed)

    {:ok, _event} =
      Events.append("events.swept", :system, %{
        payload: %{
          "removed" => rows,
          "jobs" => jobs,
          "days" => days,
          "cutoff" => DateTime.to_iso8601(cutoff)
        }
      })

    {rows, jobs}
  end

  # Oldest first.
  defp candidates(cutoff) do
    Repo.all(
      from j in Job,
        where: j.status in ^@ended and j.finished_at < ^cutoff,
        where:
          fragment(
            "EXISTS (SELECT 1 FROM events e WHERE e.job_id = ? AND forge_event_swept(e.type))",
            j.id
          ),
        order_by: [asc: j.finished_at],
        select: j.id
    )
  end

  # **The lock's own condition is a race's guard**, not a second filter: `candidates/1` has already
  # selected by the same status and age, so in a single process dropping either from the query
  # below changes nothing (an equivalent mutant, and no test is written for it). It matters when a
  # job is reopened between that read and this lock, which a test cannot interleave.
  defp sweep_job(id, cutoff, days) do
    result =
      Repo.transaction(fn ->
        job =
          Repo.one(
            from j in Job,
              where: j.id == ^id and j.status in ^@ended and j.finished_at < ^cutoff,
              lock: "FOR UPDATE"
          )

        with %Job{} <- job,
             {n, _} when n > 0 <-
               Repo.delete_all(
                 from e in Event,
                   where: e.job_id == ^id and fragment("forge_event_swept(?)", e.type)
               ) do
          {:ok, event} =
            Events.append("job.swept", :system, %{
              ticket_id: job.ticket_id,
              job_id: job.id,
              payload: %{
                "removed" => n,
                "days" => days,
                "ended" => DateTime.to_iso8601(job.finished_at)
              }
            })

          {n, event}
        else
          _skipped -> {0, nil}
        end
      end)

    case result do
      {:ok, {0, _none}} ->
        0

      {:ok, {n, event}} ->
        # The page holding the job's stream reopens it: the rows it held are gone.
        Events.notify_job(id, event)
        n
    end
  end
end
