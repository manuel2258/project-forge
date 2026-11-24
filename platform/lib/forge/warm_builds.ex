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
  """
  @type copy :: %{
          job: Job.t(),
          worker: Worker.t(),
          size: non_neg_integer() | nil,
          kept_at: DateTime.t() | nil
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
    last =
      Repo.one(
        from j in Job,
          where: j.ticket_id == ^ticket_id and j.kind == :command and j.worker_id == ^worker_id,
          select: type(max(coalesce(j.finished_at, j.started_at)), :utc_datetime)
      )

    last != nil and
      DateTime.diff(now, last, :millisecond) <
        Forge.Jobs.config(:warm_retention_ms, :timer.hours(48))
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
          warm_size: facts["size"]
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
