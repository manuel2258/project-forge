defmodule Forge.Jobs.Commands do
  @moduledoc """
  Command jobs on the platform (`docs/design/commands.md`): making them — for a command state on
  entry, and for a parked agent's invocations — recording what they did, and what follows when a
  batch is done: the parked agent resumes, or the command state's outcome is decided.

  A command is a job row of `kind: :command`, so scheduling, the gate, the slice, the channel's
  `assign`, cancellation and the timeline are the ones every job has. What is here is what a
  command has and a job does not: a script read at the pinned commit, a commit to run at, a batch
  it belongs to, and an exit status.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Ecto.Multi
  alias Forge.{Artifacts, Engine, Events, Git, Jobs, Projects, Repo, Storage, Tickets}
  alias Forge.Artifacts.Version
  alias Forge.Events.Event
  alias Forge.Jobs.{Job, Runs}
  alias Forge.Tickets.Ticket
  alias ForgeCore.Job.{Result, Spec}
  alias ForgeCore.Workflow
  alias ForgeCore.Workflow.{Command, State}

  # -- making them ------------------------------------------------------------------------------

  @doc """
  Adds the command jobs a command state runs on entry to `multi`, under `{key, index}`: one per
  `invoke` entry, all at the ticket branch's head, one batch.
  """
  @spec put_for_state(Multi.t(), term(), Ticket.t(), Workflow.t(), String.t()) :: Multi.t()
  def put_for_state(multi, key, %Ticket{} = ticket, %Workflow{} = workflow, state_name) do
    %State{invoke: invoke} = Workflow.state(workflow, state_name)
    batch = Ecto.UUID.generate()
    repo_path = ticket |> Tickets.project_of() |> Projects.repo_path()

    invocation = %{state: state_name, parent: nil, batch: batch, concurrent: nil}

    multi
    |> Multi.run({key, :at}, fn _repo, _changes ->
      Git.resolve(repo_path, "refs/heads/" <> ticket.branch)
    end)
    |> put_state_invocations(key, ticket, workflow, invoke, invocation)
    |> Events.log({key, :event}, "commands.started", :system, fn changes ->
      %{
        ticket_id: ticket.id,
        payload: %{
          "state" => state_name,
          "batch" => batch,
          "at" => changes[{key, :at}],
          "jobs" => for(index <- 0..(length(invoke) - 1), do: changes[{key, index}].id)
        }
      }
    end)
  end

  defp put_state_invocations(multi, key, ticket, workflow, invoke, invocation) do
    invoke
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {%{command: name, args: args}, index}, multi ->
      Multi.run(multi, {key, index}, fn repo, changes ->
        attrs = Map.merge(invocation, %{command: name, args: args, at: changes[{key, :at}]})
        insert(repo, ticket, workflow, attrs)
      end)
    end)
  end

  @doc """
  Adds to `multi` a command job and a `command.invoked` event, under `{:command, index}` and
  `{:command_event, index}`, for each entry of a parked agent's `decided` that runs — all at `at`,
  one batch. A refused entry adds nothing here: its reason is on the `job.parked` event
  (`invocation_entries/3`).
  """
  @spec put_invoked(Multi.t(), Ticket.t(), Workflow.t(), Job.t(), list(), String.t(), String.t()) ::
          Multi.t()
  def put_invoked(multi, ticket, workflow, job, decided, at, batch) do
    decided
    |> Enum.with_index()
    |> Enum.reduce(multi, fn
      {{:run, invocation}, index}, multi ->
        multi
        |> Multi.run({:command, index}, fn repo, _changes ->
          insert(repo, ticket, workflow, %{
            command: invocation.command,
            args: invocation.args,
            at: at,
            state: job.state,
            parent: job.id,
            batch: batch,
            concurrent: invocation.concurrent
          })
        end)
        |> Events.log({:command_event, index}, "command.invoked", {:job, job.id}, fn changes ->
          %{
            ticket_id: ticket.id,
            job_id: job.id,
            payload: %{
              "command" => invocation.command,
              "args" => invocation.args,
              "commit" => at,
              "command_job_id" => changes[{:command, index}].id
            }
          }
        end)

      {{:refused, _entry}, _index}, multi ->
        multi
    end)
  end

  @doc "What `job.parked` records of `decided`: each entry's job, or its refusal."
  @spec invocation_entries(list(), String.t(), map()) :: [map()]
  def invocation_entries(decided, at, changes) do
    decided
    |> Enum.with_index()
    |> Enum.map(fn
      {{:run, invocation}, index} ->
        %{
          "command" => invocation.command,
          "args" => invocation.args,
          "at" => at,
          "job_id" => changes[{:command, index}].id
        }

      {{:refused, entry}, _index} ->
        entry
    end)
  end

  @doc """
  Inserts one command job, inside the caller's transaction. The script is read from the ticket's
  pinned commit here, so what runs is the workflow's and never the branch's
  (`docs/design/commands.md` § How a command gets the code).
  """
  @spec insert(Ecto.Repo.t(), Ticket.t(), Workflow.t(), map()) ::
          {:ok, Job.t()} | {:error, term()}
  def insert(repo, %Ticket{} = ticket, %Workflow{} = workflow, invocation) do
    %Command{} = command = Workflow.command(workflow, invocation.command)
    repo_path = ticket |> Tickets.project_of() |> Projects.repo_path()

    with {:ok, script} <- Git.show(repo_path, ticket.workflow_commit, command.run) do
      job_id = Ecto.UUID.generate()
      attempt = next_attempt(repo, ticket.id)

      spec = %Spec{
        job_id: job_id,
        kind: :command,
        ticket: %{number: ticket.number, title: ticket.title},
        state: invocation.state,
        attempt: attempt,
        env: command.env,
        commit: ticket.workflow_commit,
        branch: ticket.branch,
        command: %{
          "name" => command.name,
          "args" => invocation.args,
          "run" => command.run,
          "script" => script,
          "at" => invocation.at,
          "timeout_ms" => command.timeout_ms,
          "produces" => command.produces,
          "outputs" => command.outputs,
          "batch" => invocation.batch,
          "concurrent" => invocation.concurrent
        }
      }

      :ok = Spec.validate(spec)

      resources =
        workflow
        |> Workflow.command_resources(command.name, invocation.state)
        |> Jobs.admitted()

      repo.insert(
        Job.create_changeset(%Job{id: job_id}, %{
          kind: :command,
          ticket_id: ticket.id,
          project_id: ticket.project_id,
          state: invocation.state,
          attempt: attempt,
          parent_job_id: invocation.parent,
          spec: spec |> Spec.to_json() |> Jason.decode!(),
          memory_max: resources.memory,
          cores: resources.cores
        })
      )
    end
  end

  # A command's attempt counts the ticket's commands: two entered in one batch share a state.
  defp next_attempt(repo, ticket_id) do
    (repo.one(
       from j in Job,
         where: j.ticket_id == ^ticket_id and j.kind == :command,
         select: max(j.attempt)
     ) || 0) + 1
  end

  @doc """
  Decides what a parked job asked for against its grant: `{:run, invocation}` or `{:refused,
  entry}` for each, in order (`docs/design/commands.md` § Limits). `max` is counted over the job's
  whole life from its command jobs; a refusal is not an invocation and does not count.
  """
  @spec decide(Job.t(), Spec.t(), Workflow.t(), Result.t()) :: [
          {:run, map()} | {:refused, map()}
        ]
  def decide(%Job{} = job, %Spec{may_invoke: grants}, %Workflow{} = workflow, %Result{} = result) do
    if result.invocation_error do
      [
        {:refused,
         %{"command" => "invoke.json", "args" => [], "refused" => result.invocation_error}}
      ]
    else
      {decided, _used} =
        Enum.map_reduce(result.invocations, invoked_counts(job.id), fn invocation, used ->
          decide_one(invocation, grants, workflow, used)
        end)

      decided
    end
  end

  defp decide_one(%{"command" => name} = invocation, grants, workflow, used) do
    args = Map.get(invocation, "args") || []
    grant = Map.get(grants, name)
    count = Map.get(used, name, 0)

    # `Workflow.command(...) == nil` is an equivalent mutant: the validator refuses a grant that
    # names an undeclared command, so a granted name is always declared. Kept against a pinned
    # workflow read from a row the validator never saw.
    cond do
      grant == nil or Workflow.command(workflow, name) == nil ->
        {{:refused, refusal(name, args, "`#{name}` is not a command this state may run")}, used}

      count >= grant["max"] ->
        {{:refused,
          refusal(name, args, "no invocations of `#{name}` remain: #{grant["max"]} were allowed")},
         used}

      true ->
        {{:run, %{command: name, args: args, concurrent: grant["concurrent"]}},
         Map.put(used, name, count + 1)}
    end
  end

  defp refusal(name, args, reason), do: %{"command" => name, "args" => args, "refused" => reason}

  @doc "How many of each command `job_id` has invoked, over its whole life."
  @spec invoked_counts(String.t()) :: %{String.t() => non_neg_integer()}
  def invoked_counts(job_id) do
    from(j in Job,
      where: j.parent_job_id == ^job_id and j.kind == :command,
      select: fragment("?->'command'->>'name'", j.spec)
    )
    |> Repo.all()
    |> Enum.frequencies()
  end

  @doc "What the job's grant has left, by command, for its manifest."
  @spec remaining(Job.t(), map()) :: map()
  def remaining(%Job{id: id}, grants) when map_size(grants) == 0 and is_binary(id), do: grants

  def remaining(%Job{id: id}, grants) do
    used = invoked_counts(id)

    Map.new(grants, fn {name, grant} ->
      {name, Map.put(grant, "remaining", max(grant["max"] - Map.get(used, name, 0), 0))}
    end)
  end

  # -- finishing them ---------------------------------------------------------------------------

  @doc """
  Records a command's result and does what follows it: its log becomes a version of the artifact
  its command produces, the job is finished with its exit status, and then the batch it belongs to
  is looked at — a parked parent resumes once all of its commands are done, and a command state's
  outcome is decided once all of its are.
  """
  @spec complete(Job.t(), Ticket.t(), Result.t()) :: {:ok, Job.t()} | {:error, term()}
  def complete(%Job{} = job, %Ticket{} = ticket, %Result{} = result) do
    spec = Jobs.spec(job)
    log = owned_log(job, result.log)
    outcome = result.outcome || :error
    now = DateTime.utc_now(:second)

    # **The ticket's row first.** Two commands of one batch can finish together and write the
    # same artifact — `[test, a]` and `[test, b]` both producing `test.log` — and a version is
    # numbered by reading the latest: unserialised, the second transaction hit the unique index,
    # the worker was told the result was not recorded, and the job stayed running for good.
    #
    # A mutant the suite cannot catch: the SQL sandbox runs a test on one connection, so two
    # transactions never interleave there. The race was reproduced by the review that found it,
    # on two real connections.
    Multi.new()
    |> Multi.run(:serial, fn repo, _changes ->
      {:ok, repo.one!(from t in Ticket, where: t.id == ^ticket.id, lock: "FOR UPDATE")}
    end)
    |> put_log(ticket, job, spec, log)
    |> Forge.Jobs.Blobs.put(ticket.id, job, spec, result)
    |> Multi.update(
      :job,
      Job.progress_changeset(job, %{
        status: :finished,
        outcome: outcome,
        exit_status: reported_status(outcome, result),
        finished_at: now
      })
    )
    |> Runs.close(job.id, now)
    |> Events.log(:event, "job.finished", {:job, job.id}, %{
      ticket_id: ticket.id,
      job_id: job.id,
      payload: finished_payload(spec, result, outcome, log)
    })
    |> put_parent_event(job, spec, result, outcome)
    |> Repo.transaction()
    |> case do
      {:ok, %{job: job}} ->
        Forge.Git.Tokens.revoke_for_job(job.id)
        Forge.Workers.release(job.worker_id)
        follow_up(job)
        Events.notify(ticket.id)
        {:ok, job}

      {:error, step, reason, _changes} ->
        {:error, {step, reason}}
    end
  end

  @doc """
  What follows a command job that has finished, however it finished — a result, or a failure the
  worker reported (`Forge.Jobs.fail/2`): its parent resumes, or its state's batch is decided, once
  every command in its batch is done.
  """
  @spec follow_up(Job.t()) :: :ok
  def follow_up(%Job{parent_job_id: nil} = job), do: decide_batch(job)
  def follow_up(%Job{} = job), do: resume_parent(job)

  @doc """
  On boot, after `Forge.Jobs.recover/0`: the follow-ups a node went down between. A command's
  result commits before its follow-up runs, so a crash in between left a parent parked on a batch
  that is done, or a command state undecided, with nothing left to wake either. Each is followed
  up again, which is safe twice — a resume checks the parent is still parked on that batch, and a
  decision is recorded once. Says how many batches it looked at.
  """
  @spec recover() :: non_neg_integer()
  def recover do
    # One finished command per batch that may be owed a follow-up: of a job still parked, or of a
    # command state its ticket is still in.
    owed =
      Repo.all(
        from j in Job,
          join: t in Ticket,
          on: t.id == j.ticket_id,
          left_join: p in Job,
          on: p.id == j.parent_job_id,
          where:
            j.kind == :command and j.status == :finished and t.status == :active and
              ((is_nil(j.parent_job_id) and t.state == j.state) or p.status == :parked),
          distinct: fragment("?->'command'->>'batch'", j.spec),
          select: j
      )

    Enum.each(owed, &follow_up/1)
    length(owed)
  end

  # The log went to the store under the key minted for this job; a key elsewhere is not this
  # job's to record, whatever the worker says (`docs/design/storage.md` § Keys).
  defp owned_log(%Job{id: id}, key), do: if(Storage.Key.job?(key, id), do: key)

  # A status is the script's answer only when it ran to one: a killed command's is the signal's.
  defp reported_status(:converged, %Result{exit_status: status}), do: status
  defp reported_status(_outcome, _result), do: nil

  defp put_log(multi, _ticket, _job, _spec, nil), do: multi

  defp put_log(multi, ticket, job, %Spec{command: %{"produces" => produces}}, key)
       when is_binary(produces) do
    case Storage.stat(key) do
      {:ok, %{hash: hash}} ->
        Artifacts.put_version(multi, :log, ticket.id, produces, :blob, {:job, job.id}, %{
          blob_uri: Storage.uri(key),
          content_hash: hash
        })

      {:error, reason} ->
        Logger.warning("command #{job.id} reported log #{key}: #{inspect(reason)}")
        multi
    end
  end

  defp put_log(multi, _ticket, _job, _spec, _key), do: multi

  defp finished_payload(spec, result, outcome, log) do
    %{
      "command" => spec.command["name"],
      "args" => spec.command["args"],
      "at" => spec.command["at"],
      "outcome" => Atom.to_string(outcome),
      "exit_status" => reported_status(outcome, result),
      "reason" => result.reason,
      "duration_ms" => result.duration_ms,
      "log" => log,
      "invalid_blobs" => result.invalid_blobs
    }
  end

  # On the invoking job's timeline too, which is where a person reading it looks for what its
  # agent ran (`docs/design/commands.md` § Events and the timeline).
  defp put_parent_event(multi, %Job{parent_job_id: nil}, _spec, _result, _outcome), do: multi

  defp put_parent_event(multi, %Job{} = job, spec, result, outcome) do
    Events.log(multi, :parent_event, "command.finished", {:job, job.id}, %{
      ticket_id: job.ticket_id,
      job_id: job.parent_job_id,
      payload: %{
        "command_job_id" => job.id,
        "command" => spec.command["name"],
        "args" => spec.command["args"],
        "outcome" => Atom.to_string(outcome),
        "exit_status" => reported_status(outcome, result),
        "duration_ms" => result.duration_ms
      }
    })
  end

  # The parent goes back to pending once every command of the batch it parked on has finished.
  # Its row is locked for the check, so two commands finishing together resume it once: the
  # second finds it pending already.
  defp resume_parent(%Job{parent_job_id: parent_id} = job) do
    batch = Jobs.spec(job).command["batch"]

    # Parked **on this batch**, not merely parked: a command of an earlier batch that is reported
    # finished again must not wake a parent that has since parked on a new one, with the old
    # batch's results as though they answered it.
    Multi.new()
    |> Multi.run(:parent, fn repo, _changes ->
      {:ok, repo.one!(from j in Job, where: j.id == ^parent_id, lock: "FOR UPDATE")}
    end)
    |> Multi.run(:open, fn repo, _changes -> {:ok, open_in_batch(repo, parent_id, batch)} end)
    |> Multi.run(:parked_on, fn _repo, _changes -> {:ok, parked_on(parent_id)} end)
    |> Multi.merge(fn
      %{parent: %Job{status: :parked} = parent, open: 0, parked_on: ^batch} ->
        put_resume(Multi.new(), parent, batch)

      _still_running_or_moved_on ->
        Multi.new()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, _changes} ->
        Events.notify(job.ticket_id)
        :ok

      # Not only a line in the log: a parent that cannot be resumed is a ticket that will not
      # move, and the operator is told as for a command state that cannot be decided.
      {:error, step, reason, _changes} ->
        Logger.error(
          "could not resume #{parent_id} after its commands: #{inspect({step, reason})}"
        )

        ticket = Tickets.get!(job.ticket_id)

        Engine.stick(
          ticket,
          "could not resume #{job.state} after its commands: #{inspect(reason)}"
        )

        :ok
    end
  end

  @doc """
  Adds putting a parked job back in the queue to `multi`, recording which batch it resumes after —
  the record its next run's spec reads the results from (`results/1`).
  """
  @spec put_resume(Multi.t(), Job.t(), String.t()) :: Multi.t()
  def put_resume(multi, %Job{} = parent, batch) do
    multi
    |> Multi.update(:resumed, Job.progress_changeset(parent, %{status: :pending}))
    |> put_resumed_event(parent, batch)
  end

  @doc """
  Adds the `job.resumed` naming `batch` to `multi`, for a caller that has put the job back in the
  queue itself: a park with nothing to run, which goes back in the same update that parks it.
  """
  @spec put_resumed_event(Multi.t(), Job.t(), String.t()) :: Multi.t()
  def put_resumed_event(multi, %Job{} = job, batch) do
    Events.log(multi, :resumed_event, "job.resumed", :system, %{
      ticket_id: job.ticket_id,
      job_id: job.id,
      payload: %{"batch" => batch}
    })
  end

  @doc """
  The commands not finished yet: what a parked job is still waiting on. One definition for the
  batch that decides whether its parent resumes (`open_in_batch/3`) and for the claim a parked job
  has on the machine it ran on (`Forge.Workers.goes_at/2`), so the two cannot disagree about which
  commands are still open.
  """
  @spec open() :: Ecto.Query.t()
  def open, do: from(j in Job, where: j.kind == :command and j.status != :finished)

  defp open_in_batch(repo, parent_id, batch) do
    repo.one(
      from j in open(),
        where:
          j.parent_job_id == ^parent_id and
            fragment("?->'command'->>'batch'", j.spec) == ^batch,
        select: count()
    )
  end

  # A command state's outcome, decided once, when the last of its batch has finished: the first
  # non-zero status in `invoke` order, mapped by `exit` (`ForgeCore.Workflow.exit_outcome/2`). The
  # ticket's row is locked and the decision recorded as an event, so two commands finishing
  # together decide it once — and a state that loops to itself starts a new batch rather than
  # deciding the old one twice.
  defp decide_batch(%Job{} = job) do
    batch = Jobs.spec(job).command["batch"]

    # `:locked` and not `:ticket`: `Engine.put_after_job/4` writes the moved ticket under `:ticket`.
    Multi.new()
    |> Multi.run(:locked, fn repo, _changes ->
      {:ok, repo.one!(from t in Ticket, where: t.id == ^job.ticket_id, lock: "FOR UPDATE")}
    end)
    |> Multi.run(:batch, fn repo, _changes -> {:ok, batch_state(repo, job.ticket_id, batch)} end)
    |> Multi.merge(fn
      %{locked: ticket, batch: {:done, jobs}} -> put_decision(ticket, job, batch, jobs)
      _open_or_decided -> Multi.new()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{locked: before} = changes} ->
        # A transition into a state with an entry action runs it, as `Engine.after_job/3` does.
        case changes[:ticket] do
          %Ticket{state: state} = moved when state != before.state -> enter(moved)
          _stayed -> :ok
        end

        Events.notify(job.ticket_id)
        :ok

      {:error, step, reason, _changes} ->
        Logger.error(
          "could not decide #{job.state} after its commands: #{inspect({step, reason})}"
        )

        ticket = Tickets.get!(job.ticket_id)
        Engine.stick(ticket, "could not continue after #{job.state}: #{inspect(reason)}")
        :ok
    end
  end

  defp batch_state(repo, ticket_id, batch) do
    decided =
      repo.exists?(
        from e in Event,
          where:
            e.ticket_id == ^ticket_id and e.type == "commands.decided" and
              fragment("?->>'batch'", e.payload) == ^batch
      )

    jobs =
      repo.all(
        from j in Job,
          where:
            j.ticket_id == ^ticket_id and j.kind == :command and is_nil(j.parent_job_id) and
              fragment("?->'command'->>'batch'", j.spec) == ^batch,
          order_by: j.attempt
      )

    cond do
      decided -> :decided
      Enum.any?(jobs, &(&1.status != :finished)) -> :open
      true -> {:done, jobs}
    end
  end

  defp put_decision(ticket, job, batch, jobs) do
    workflow = Tickets.workflow(ticket)
    %State{exit: exit} = Workflow.state(workflow, job.state)
    statuses = Enum.map(jobs, &exit_status/1)
    outcome = Workflow.exit_outcome(exit, statuses)

    Multi.new()
    |> Events.log(:decided, "commands.decided", :system, %{
      ticket_id: ticket.id,
      payload: %{
        "batch" => batch,
        "state" => job.state,
        "statuses" => statuses,
        "outcome" => outcome
      }
    })
    |> Engine.put_after_job(ticket, job, outcome)
  end

  # Only a command that ran to a status has one; one stopped or that never started counts as
  # non-zero, which `exit_outcome/2` reads nil as.
  # With `complete/3` storing a status only for `converged`, the second clause is an equivalent
  # mutant for any row this module wrote — and each guard masks the other. Kept here because the
  # decision must not depend on the writer having been careful.
  defp exit_status(%Job{outcome: :converged, exit_status: status}), do: status
  defp exit_status(%Job{}), do: nil

  defp enter(ticket), do: Engine.enter(ticket, Tickets.workflow(ticket), ticket.state, nil)

  # -- reading them back ------------------------------------------------------------------------

  @doc """
  The results of the batch `job` last resumed after, for its next run's spec
  (`docs/design/job-prompt.md` § Commands), as `{results, logs}`: the manifest's entries, and the
  store key of each log with the file name it is written under in `$FORGE_JOB/commands/`.

  Read from the job's latest `job.resumed`: one that names a batch is a resume after commands,
  and a later resume after an answered question names none — so the results of an old batch are
  not shown again as though they were new.
  """
  @spec results(Job.t()) :: {[map()], [%{file: String.t(), key: String.t()}]}
  def results(%Job{id: id}) do
    with %Event{payload: %{"batch" => batch}} <- Events.latest_for_job(id, "job.resumed"),
         %Event{payload: %{"invocations" => invocations}} <- parked(id, batch) do
      result_entries(invocations, "")
    else
      _none -> {[], []}
    end
  end

  @doc """
  The batch a command state last ran, if it ran to a decision: what a job entered from that state
  is told about (`docs/design/job-prompt.md` § How the job arrived). Nil for a state with no
  batch, and for one whose latest batch was never decided — cancelled, or still running — since
  an older batch's results would describe a visit that is not the one the ticket came from.
  """
  @spec decided_batch(Ecto.UUID.t(), String.t()) :: String.t() | nil
  def decided_batch(ticket_id, state) do
    with %Event{payload: %{"batch" => batch}} <- latest_started(ticket_id, state),
         :decided <- batch_state(Repo, ticket_id, batch) do
      batch
    else
      _none -> nil
    end
  end

  @doc """
  What the batch `job` was entered after said, for its spec, as `results/1` returns a resume's:
  the manifest's entries in `invoke` order, and each log's store key with the file it is written
  under — `entered-<n>-<command>.log`, so it cannot collide with a log of the job's own.
  """
  @spec entered(Job.t()) :: {[map()], [%{file: String.t(), key: String.t()}]}
  def entered(%Job{ticket_id: ticket_id, spec: %{"entered" => %{"batch" => batch}}})
      when is_binary(batch) do
    case started(ticket_id, batch) do
      %Event{payload: %{"jobs" => ids}} ->
        jobs = Map.new(Repo.all(from j in Job, where: j.id in ^ids), &{&1.id, &1})

        ids
        |> Enum.map(&Map.fetch!(jobs, &1))
        |> Enum.map(&invocation/1)
        |> result_entries("entered-")

      nil ->
        {[], []}
    end
  end

  def entered(%Job{}), do: {[], []}

  @doc """
  The end of each failed command's log in the ticket's latest decided batch, by job id: what the
  ticket page shows under a command that sent the ticket back, so why `build_failed` fired is on
  the page rather than behind a download (`docs/design/ui.md` § Decide and Timeline). The latest
  batch only, since an older failure was answered by the work after it, and at most `bytes` of
  each log, from the start of a line.
  """
  @spec failure_tails(Ecto.UUID.t(), pos_integer()) :: %{Ecto.UUID.t() => String.t()}
  def failure_tails(ticket_id, bytes) do
    with %Event{payload: %{"batch" => batch}} <- latest_decided(ticket_id),
         %Event{payload: %{"jobs" => ids}} <- started(ticket_id, batch) do
      from(j in Job, where: j.id in ^ids)
      |> Repo.all()
      |> Enum.reject(&(exit_status(&1) == 0))
      |> Enum.flat_map(&failure_tail(&1, bytes))
      |> Map.new()
    else
      _none -> %{}
    end
  end

  defp failure_tail(%Job{id: id}, bytes) do
    with %Event{payload: %{"log" => key}} when is_binary(key) <-
           Events.latest_for_job(id, "job.finished"),
         {:ok, text} <- Artifacts.excerpt(%Version{blob_uri: Storage.uri(key)}, 0, bytes) do
      [{id, text}]
    else
      _none -> []
    end
  end

  # A command state's job carries what an agent's invocation would have said about it.
  defp invocation(%Job{id: id, spec: %{"command" => command}}),
    do: %{
      "job_id" => id,
      "command" => command["name"],
      "args" => command["args"],
      "at" => command["at"]
    }

  # Each invocation's manifest entry, numbered from one, and the logs there are to fetch: a
  # refused invocation has an entry and no log.
  defp result_entries(invocations, prefix) do
    {results, logs} =
      invocations
      |> Enum.with_index(1)
      |> Enum.map(&result_entry(&1, prefix))
      |> Enum.unzip()

    {results, Enum.reject(logs, &is_nil/1)}
  end

  defp result_entry({%{"refused" => _reason} = refused, _n}, _prefix), do: {refused, nil}

  defp result_entry({%{"job_id" => job_id} = invocation, n}, prefix) do
    finished = Events.latest_for_job(job_id, "job.finished")
    payload = (finished && finished.payload) || %{}
    file = "#{prefix}#{n}-#{invocation["command"]}.log"
    key = payload["log"]

    result = %{
      "command" => invocation["command"],
      "args" => invocation["args"],
      "at" => payload["at"] || invocation["at"],
      "outcome" => payload["outcome"],
      "exit_status" => payload["exit_status"],
      "duration_ms" => payload["duration_ms"],
      "log" => if(key, do: file)
    }

    {result, if(key, do: %{file: file, key: key})}
  end

  defp parked_on(job_id) do
    case Events.latest_for_job(job_id, "job.parked") do
      %Event{payload: %{"batch" => batch}} -> batch
      _none -> nil
    end
  end

  defp latest_decided(ticket_id) do
    Repo.one(
      from e in Event,
        where: e.ticket_id == ^ticket_id and e.type == "commands.decided",
        order_by: [desc: e.seq],
        limit: 1
    )
  end

  defp latest_started(ticket_id, state) do
    Repo.one(
      from e in Event,
        where:
          e.ticket_id == ^ticket_id and e.type == "commands.started" and
            fragment("?->>'state'", e.payload) == ^state,
        order_by: [desc: e.seq],
        limit: 1
    )
  end

  defp started(ticket_id, batch) do
    Repo.one(
      from e in Event,
        where:
          e.ticket_id == ^ticket_id and e.type == "commands.started" and
            fragment("?->>'batch'", e.payload) == ^batch,
        limit: 1
    )
  end

  defp parked(job_id, batch) do
    Repo.one(
      from e in Event,
        where:
          e.job_id == ^job_id and e.type == "job.parked" and
            fragment("?->>'batch'", e.payload) == ^batch,
        order_by: [desc: e.seq],
        limit: 1
    )
  end
end
