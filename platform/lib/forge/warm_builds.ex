defmodule Forge.WarmBuilds do
  @moduledoc """
  A ticket's **warm build**: the command copy a command leaves on its machine for the ticket's next
  command (`docs/design/worker-tier.md` § The command copy).

  The platform never holds a copy. It holds what the commands reported (`jobs.warm_*`), and this is
  the reading of those rows: which copy the ticket's next command is sent to, whether a workflow
  declares one at all, recording what a worker reported, and the clear that makes every copy of a
  ticket unusable at once.

  **A clear is an epoch.** `tickets.warm_epoch` goes up by one; the assignment carries it, the
  worker writes it into the copy's marker and uses a copy only when the two are equal, so a clear
  needs no message to any machine and works for one that is offline.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Forge.{Events, Repo, Tickets}
  alias Forge.Jobs.Job
  alias Forge.Tickets.Ticket
  alias Forge.Workers.Worker
  alias ForgeCore.WarmBuild

  @typedoc """
  The copy the ticket's next command is sent to:

    * `:job` - the `%Forge.Jobs.Job{}` that kept it: `job.spec["command"]` holds its `"name"` and
      `"args"` (`ForgeCore.Workflow.Command.argv/1` shows them), `job.spec["command"]["at"]` the
      commit it ran at, and `job.worker_id` the machine
    * `:worker` - the `%Forge.Workers.Worker{}` it is on (never a destroyed one)
    * `:size` - bytes, or nil when the worker did not say
    * `:kept_at` - when the keeping command finished (`job.finished_at`)

  `copies/1` and `copy/2` (the ones a person may look into) add what a page draws: `:folders` (the
  saved sizes of its ignored folders, `ForgeCore.WarmBuild.folders/1`'s shape, or nil), `:next?`
  (the copy the next command starts from), `:cleared?` (kept under an epoch the ticket has left
  behind), `:command`, `:args` and `:commit` (what ran, from the job's spec).
  """
  @type copy :: %{
          required(:job) => Job.t(),
          required(:worker) => Worker.t(),
          required(:size) => non_neg_integer() | nil,
          required(:kept_at) => DateTime.t() | nil,
          optional(:folders) => map() | nil,
          optional(:next?) => boolean(),
          optional(:cleared?) => boolean(),
          optional(:command) => String.t() | nil,
          optional(:args) => [String.t()],
          optional(:commit) => String.t() | nil
        }

  @doc """
  Whether the ticket's pinned workflow has a command that declares `keep_build`: the one condition
  under which anything about warm builds is drawn or preferred. A pin that can no longer be built
  declares nothing.
  """
  @spec declared?(Ticket.t()) :: boolean()
  def declared?(%Ticket{} = ticket) do
    case Tickets.parsed_workflow(ticket) do
      {:ok, workflow} -> Enum.any?(workflow.commands, fn {_name, c} -> c.keep_build != [] end)
      _unreadable -> false
    end
  end

  @doc """
  The copy the ticket's next command will be sent to, or nil: the latest command of the ticket that
  kept its build in the ticket's **current epoch**, whose machine is not destroyed and where the
  ticket's last command is within `Forge.Jobs.config(:warm_retention_ms, 2 days)` — the platform's
  reading of "two days after the last command there", which is when the worker sweeps it. Copies on
  other machines are not listed. See `t:copy/0` for the shape.
  """
  @spec current(Ticket.t()) :: copy() | nil
  def current(%Ticket{id: id, warm_epoch: epoch}) do
    now = DateTime.utc_now()

    from(j in Job,
      where:
        j.ticket_id == ^id and j.kind == :command and j.warm_kept == true and
          j.warm_epoch == ^epoch and not is_nil(j.worker_id),
      order_by: [desc: j.finished_at, desc: j.inserted_at],
      limit: 20
    )
    |> Repo.all()
    |> Enum.find_value(fn job ->
      worker = Repo.get(Worker, job.worker_id)

      if worker && worker.status != :destroyed && fresh?(id, job.worker_id, now) do
        %{job: job, worker: worker, size: job.warm_size, kept_at: job.finished_at}
      end
    end)
  end

  # Any command of the ticket there touches the copy, used or not, so it is the last of them that
  # the two days run from.
  defp fresh?(ticket_id, worker_id, now) do
    case last_command_at(ticket_id, worker_id) do
      nil -> false
      last -> DateTime.diff(now, last, :millisecond) < retention_ms()
    end
  end

  defp last_command_at(ticket_id, worker_id) do
    Repo.one(
      from j in Job,
        where: j.ticket_id == ^ticket_id and j.kind == :command and j.worker_id == ^worker_id,
        select: type(max(coalesce(j.finished_at, j.started_at)), :utc_datetime)
    )
  end

  defp retention_ms, do: Forge.Jobs.config(:warm_retention_ms, :timer.hours(48))

  @doc """
  Every copy of the ticket still kept on a machine that a person may look into
  (`docs/design/worker-tier.md` § Looking into a copy): for each machine that is not destroyed, the
  ticket's latest command that kept a build there, **in any epoch** — a cleared copy is still on
  its disk, and is what a diagnosis compares against — while the ticket's last command there is
  within the retention. The copy `current/1` names comes first and is marked `:next?`; the rest are
  newest first. See `t:copy/0`.
  """
  @spec copies(Ticket.t()) :: [copy()]
  def copies(%Ticket{id: id} = ticket) do
    now = DateTime.utc_now()
    next = current(ticket)

    from(j in Job,
      where:
        j.ticket_id == ^id and j.kind == :command and j.warm_kept == true and
          not is_nil(j.worker_id),
      order_by: [desc: j.finished_at, desc: j.inserted_at]
    )
    |> Repo.all()
    |> Enum.uniq_by(& &1.worker_id)
    |> Enum.flat_map(fn job ->
      worker = Repo.get(Worker, job.worker_id)

      if worker && worker.status != :destroyed && fresh?(id, job.worker_id, now),
        do: [explorable(ticket, job, worker, next)],
        else: []
    end)
    |> Enum.sort_by(&{not &1.next?, -DateTime.to_unix(&1.kept_at || ~U[1970-01-01 00:00:00Z])})
  end

  @doc """
  One copy of this ticket by the id of the command that kept it, or `:error`: any kept command of
  **this ticket**, so a copy a later command replaced but the machine still holds (it is held while
  someone looks, `ForgeCore.Explore.hold_ms/0`) can be reached, and never one of another ticket or
  project, which answers as one that does not exist. `:error` too for a machine that is destroyed.
  """
  @spec copy(Ticket.t(), term()) :: {:ok, copy()} | :error
  def copy(%Ticket{id: id} = ticket, job_id) when is_binary(job_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(job_id),
         %Job{worker_id: worker_id} = job when is_binary(worker_id) <-
           Repo.one(
             from j in Job,
               where:
                 j.id == ^uuid and j.ticket_id == ^id and j.kind == :command and
                   j.warm_kept == true
           ),
         %Worker{status: status} = worker when status != :destroyed <-
           Repo.get(Worker, worker_id) do
      {:ok, explorable(ticket, job, worker, current(ticket))}
    else
      _not_a_copy_of_this_ticket -> :error
    end
  end

  def copy(%Ticket{}, _job_id), do: :error

  @doc """
  The command of this ticket that kept a build, by id, whether or not its copy is explorable now: for
  saying why a copy is gone. Nil for anything else — a command of another ticket included.
  """
  @spec kept_command(Ticket.t(), term()) :: Job.t() | nil
  def kept_command(%Ticket{id: id}, job_id) when is_binary(job_id) do
    case Ecto.UUID.cast(job_id) do
      {:ok, uuid} ->
        Repo.one(
          from j in Job,
            where:
              j.id == ^uuid and j.ticket_id == ^id and j.kind == :command and j.warm_kept == true
        )

      :error ->
        nil
    end
  end

  def kept_command(%Ticket{}, _job_id), do: nil

  defp explorable(ticket, job, worker, next) do
    command = (job.spec || %{})["command"] || %{}
    job_id = job.id

    %{
      job: job,
      worker: worker,
      size: job.warm_size,
      folders: job.warm_folders,
      kept_at: job.finished_at,
      next?: match?(%{job: %Job{id: ^job_id}}, next),
      cleared?: job.warm_epoch != ticket.warm_epoch,
      command: command["name"],
      args: command["args"] || [],
      commit: command["at"]
    }
  end

  @doc """
  Why a copy is not on its machine, from the platform's own rows: `:replaced` when a later command of
  the ticket kept a build there (`replaced_by` is that command, the first to), `:swept` when the
  ticket's last command there is past the retention, `:unknown` for no more than that. `copy` is a
  `t:copy/0` or the id of the command that kept it.
  """
  @spec gone(Ticket.t(), copy() | String.t(), String.t()) ::
          %{why: :replaced | :swept | :unknown, replaced_by: Job.t() | nil}
  def gone(%Ticket{id: id}, copy, worker_id) do
    job_id = if is_map(copy), do: copy.job.id, else: copy

    with {:ok, uuid} <- Ecto.UUID.cast(job_id),
         %Job{finished_at: %DateTime{} = kept} <-
           Repo.one(from j in Job, where: j.id == ^uuid and j.ticket_id == ^id) do
      why(id, worker_id, later_command(id, worker_id, kept))
    else
      _unknown_job -> %{why: :unknown, replaced_by: nil}
    end
  end

  defp later_command(ticket_id, worker_id, kept) do
    Repo.one(
      from j in Job,
        where:
          j.ticket_id == ^ticket_id and j.kind == :command and j.warm_kept == true and
            j.worker_id == ^worker_id and j.finished_at > ^kept,
        order_by: [asc: j.finished_at],
        limit: 1
    )
  end

  defp why(_ticket_id, _worker_id, %Job{} = later), do: %{why: :replaced, replaced_by: later}

  defp why(ticket_id, worker_id, nil) do
    if fresh?(ticket_id, worker_id, DateTime.utc_now()),
      do: %{why: :unknown, replaced_by: nil},
      else: %{why: :swept, replaced_by: nil}
  end

  @doc """
  Until when a copy on `worker_id` can be explored once the machine is back: the retention after the
  ticket's last command there (the worker's sweep counts from it), or nil when it ran none.
  """
  @spec explorable_until(Ticket.t(), String.t()) :: DateTime.t() | nil
  def explorable_until(%Ticket{id: id}, worker_id) do
    case last_command_at(id, worker_id) do
      nil -> nil
      last -> DateTime.add(last, retention_ms(), :millisecond)
    end
  end

  @doc """
  The machine a command of this ticket should be sent to: the one holding `current/1`'s copy, for a
  command whose spec does not turn `warm_start` off, or nil. A preference only: the scheduler still
  asks every gate the machine must pass (`Forge.Jobs.Scheduler`).
  """
  @spec preferred_worker(Job.t()) :: String.t() | nil
  def preferred_worker(%Job{kind: :command, ticket_id: ticket_id, spec: spec})
      when is_binary(ticket_id) do
    if get_in(spec, ["command", "warm_start"]) != false do
      case current(Tickets.get!(ticket_id)) do
        %{worker: %Worker{id: id}} -> id
        nil -> nil
      end
    end
  end

  def preferred_worker(%Job{}), do: nil

  @doc """
  What a finished command's result said, as the columns of its row (a map for
  `Forge.Jobs.Job.progress_changeset/2`; empty when nothing is to be recorded). Checked against
  `ForgeCore.WarmBuild`, so a word that is not one of its sources or reasons is dropped, and a
  `from` that is not a command of the same ticket is dropped with it.
  """
  @spec record(Job.t(), map() | nil) :: map()
  def record(%Job{} = job, warm) do
    case WarmBuild.sanitize(warm) do
      nil ->
        %{}

      facts ->
        %{
          warm_source: facts["source"],
          warm_from_id: same_ticket_command(job, facts["from"]),
          warm_kept: facts["kept"],
          warm_unkept: facts["unkept"],
          warm_size: facts["size"],
          warm_folders: facts["folders"]
        }
    end
  end

  defp same_ticket_command(%Job{ticket_id: ticket_id}, from) when is_binary(from) do
    with {:ok, uuid} <- Ecto.UUID.cast(from),
         id when is_binary(id) <-
           Repo.one(
             from j in Job,
               where: j.id == ^uuid and j.ticket_id == ^ticket_id and j.kind == :command,
               select: j.id
           ) do
      id
    else
      _not_ours -> nil
    end
  end

  defp same_ticket_command(_job, _from), do: nil

  @doc """
  Makes every copy of the ticket on every machine unusable: the epoch goes up by one, with the
  event that says who did it, in one transaction. The space is freed when a later command's build
  replaces the copy, or by the worker's two-day sweep. The guard is `Forge.Operator.clear_warm_build/2`'s.
  """
  @spec clear(Ticket.t(), Forge.Actor.t() | term()) :: {:ok, Ticket.t()} | {:error, term()}
  def clear(%Ticket{id: id}, actor) do
    Multi.new()
    |> Multi.run(:locked, fn repo, _changes ->
      {:ok, repo.one!(from t in Ticket, where: t.id == ^id, lock: "FOR UPDATE")}
    end)
    |> Multi.update(:ticket, fn %{locked: locked} ->
      Ecto.Changeset.change(locked, warm_epoch: locked.warm_epoch + 1)
    end)
    |> Events.log(:event, "ticket.warm_cleared", Forge.Actor.of(actor), fn %{locked: locked} ->
      %{ticket_id: id, payload: %{"epoch" => locked.warm_epoch + 1}}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, _changes} ->
        Events.notify(id)
        {:ok, Tickets.get!(id)}

      {:error, step, reason, _changes} ->
        {:error, {step, reason}}
    end
  end
end
