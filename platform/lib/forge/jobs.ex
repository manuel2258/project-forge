defmodule Forge.Jobs do
  @moduledoc """
  Jobs: creating one from a ticket's state (building the immutable spec), running it
  through the embedded worker, and recording what it produced. The engine decides what
  happens to the ticket afterwards; see `Forge.Engine`.

  Execution model in milestone 1: jobs are rows. Anything may create a `pending` job;
  the running node's `Forge.Jobs.Scheduler` starts them and records their results.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Forge.{Artifacts, Engine, Events, Git, Projects, Repo, Tickets}
  alias Forge.Jobs.Job
  alias Forge.Tickets.Ticket
  alias ForgeCore.Job.Spec
  alias ForgeCore.Job.Spec.Input
  alias ForgeCore.{Prompt, Workflow}
  alias ForgeCore.Workflow.State
  alias ForgeWorker.Job.{Result, Runner}

  require Logger

  # -- creation -------------------------------------------------------------------------------

  @doc "Adds the creation of a pending job for `state_name` to `multi` under `key`."
  @spec put_create(Multi.t(), term(), Ticket.t(), Workflow.t(), String.t()) :: Multi.t()
  def put_create(multi, key, %Ticket{} = ticket, %Workflow{} = workflow, state_name) do
    multi
    |> Multi.run(key, fn repo, _ ->
      with {:ok, spec} <- build_spec(repo, ticket, workflow, state_name) do
        repo.insert(
          Job.create_changeset(%Job{id: spec.job_id}, %{
            ticket_id: ticket.id,
            state: state_name,
            attempt: spec.attempt,
            spec: spec |> Spec.to_json() |> Jason.decode!()
          })
        )
      end
    end)
    |> Events.log({key, :event}, "job.created", :system, fn changes ->
      job = changes[key]

      %{
        ticket_id: ticket.id,
        job_id: job.id,
        payload: %{"state" => state_name, "attempt" => job.attempt}
      }
    end)
  end

  defp build_spec(repo, %Ticket{} = ticket, %Workflow{} = workflow, state_name) do
    %State{} = state = Workflow.state(workflow, state_name)
    project = Projects.get!(ticket.project_id)
    repo_path = Projects.repo_path(project)
    job_id = Ecto.UUID.generate()

    with {:ok, prompt} <- Git.show(repo_path, ticket.workflow_commit, ".forge/" <> state.prompt),
         {:ok, inputs} <- inputs(repo, ticket, repo_path, state.inputs) do
      {:ok,
       %Spec{
         job_id: job_id,
         ticket: %{number: ticket.number, title: ticket.title},
         state: state_name,
         attempt: next_attempt(repo, ticket.id, state_name),
         prompt: prompt,
         prompt_path: state.prompt,
         env: state.env,
         commit: ticket.workflow_commit,
         branch: ticket.branch,
         budget: %{turns: state.budget.turns, cost: state.budget.cost},
         preamble_hash: Prompt.preamble_hash(),
         inputs: inputs,
         produces: state.produces,
         outcomes: state.outcomes,
         permitted_children: []
       }}
    end
  end

  defp inputs(repo, ticket, repo_path, names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case input(repo, ticket, repo_path, name) do
        {:ok, input} -> {:cont, {:ok, acc ++ [input]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp input(_repo, ticket, repo_path, "changeset") do
    with {:ok, head} <- Git.resolve(repo_path, "refs/heads/" <> ticket.branch),
         {:ok, diff} <- Git.diff(repo_path, ticket.base_commit, head) do
      {:ok, %Input{name: "changeset", version: head, content: diff}}
    end
  end

  defp input(repo, ticket, _repo_path, name) do
    query =
      from v in Forge.Artifacts.Version,
        join: a in assoc(v, :artifact),
        where: a.ticket_id == ^ticket.id and a.name == ^name,
        order_by: [desc: v.version],
        limit: 1

    case repo.one(query) do
      nil -> {:error, {:missing_input, name}}
      version -> {:ok, %Input{name: name, version: version.version, content: version.content}}
    end
  end

  defp next_attempt(repo, ticket_id, state_name) do
    (repo.one(
       from j in Job,
         where: j.ticket_id == ^ticket_id and j.state == ^state_name,
         select: max(j.attempt)
     ) || 0) + 1
  end

  # -- reading --------------------------------------------------------------------------------

  @spec get!(String.t()) :: Job.t()
  def get!(id), do: Repo.get!(Job, id)

  @spec for_ticket(String.t()) :: [Job.t()]
  def for_ticket(ticket_id),
    do: Repo.all(from j in Job, where: j.ticket_id == ^ticket_id, order_by: j.inserted_at)

  @doc "Pending jobs on active tickets, oldest first."
  @spec pending(pos_integer()) :: [Job.t()]
  def pending(limit \\ 10) do
    Repo.all(
      from j in Job,
        join: t in assoc(j, :ticket),
        where: j.status == :pending and t.status == :active,
        order_by: j.inserted_at,
        limit: ^limit
    )
  end

  @doc "Whether a job for `state` on the ticket is pending, running or waiting."
  @spec live?(String.t(), String.t()) :: boolean()
  def live?(ticket_id, state) do
    Repo.exists?(
      from j in Job,
        where:
          j.ticket_id == ^ticket_id and j.state == ^state and
            j.status in [:pending, :running, :waiting]
    )
  end

  @spec spec(Job.t()) :: Spec.t()
  def spec(%Job{spec: map}), do: Spec.from_map(map)

  # -- execution ------------------------------------------------------------------------------

  @doc """
  Starts the job's harness process and returns the runner pid. The caller must later pass
  the awaited result to `complete/2`. Use `run/1` for the synchronous form.
  """
  @spec start(Job.t()) :: {:ok, pid()} | {:error, term()}
  def start(%Job{} = job) do
    ticket = Tickets.get!(job.ticket_id)
    project = Projects.get!(ticket.project_id)
    repo_path = Projects.repo_path(project)
    worktree = worktree_dir(job)

    # The row is marked before the harness is spawned, not after. A row the progress
    # changeset refuses then costs nothing; marking second meant it was refused only once a
    # billed invocation was already running, and the scheduler retried the job every tick.
    with :ok <-
           ensure_worktree(repo_path, worktree, ticket.branch, job.harness_session_id != nil),
         {:ok, job} <- mark_started(job) do
      case start_runner(job, ticket, worktree) do
        {:ok, pid} ->
          {:ok, pid}

        {:error, reason} ->
          # Nothing is running, so the job must not sit `running` until the next boot.
          Repo.update(Job.progress_changeset(job, %{status: :pending}))
          {:error, reason}
      end
    end
  end

  defp start_runner(job, ticket, worktree) do
    spec = runtime_spec(job, ticket)
    job_id = job.id
    ticket_id = ticket.id

    # The credential is resolved by the driver at spawn time, so it never sits in the
    # runner's start arguments or state, which crash reports would print.
    harness_opts =
      config(:harness_opts, [])
      |> Keyword.put(:credential, fn -> Keyword.get(config(:harness_opts, []), :credential) end)
      |> Keyword.merge(
        if(job.harness_session_id, do: [resume_session: job.harness_session_id], else: [])
      )

    opts = [
      spec: spec,
      root: Path.join(data_dir(), "jobs"),
      worktree: worktree,
      sink: fn event -> record_harness_event(ticket_id, job_id, event) end,
      harness_opts: harness_opts,
      wall_clock_ms: config(:wall_clock_ms, :timer.hours(1)),
      nix_env: config(:nix_env, false),
      extra_env: config(:extra_env, [])
    ]

    DynamicSupervisor.start_child(ForgeWorker.Job.Supervisor, {Runner, opts})
  end

  # The stored spec never changes; answers given since are appended at run time, and the
  # keys already answered are passed so the worker does not wait on them again.
  defp runtime_spec(%Job{} = job, %Ticket{id: ticket_id}) do
    spec = %{spec(job) | answered_keys: Artifacts.answered_keys(ticket_id)}

    case Artifacts.latest(ticket_id, Workflow.answers_artifact()) do
      nil ->
        spec

      version ->
        answers = %Input{
          name: Workflow.answers_artifact(),
          version: version.version,
          content: version.content
        }

        %{spec | inputs: spec.inputs ++ [answers]}
    end
  end

  defp record_harness_event(ticket_id, job_id, %{type: type, payload: payload}) do
    case Events.append(type, {:job, job_id}, %{
           ticket_id: ticket_id,
           job_id: job_id,
           payload: json_safe(payload)
         }) do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.warning("dropped harness event #{type}: #{inspect(changeset.errors)}")
    end
  end

  defp json_safe(term), do: term |> Jason.encode!() |> Jason.decode!()

  defp mark_started(%Job{} = job) do
    now = DateTime.utc_now(:second)

    Multi.new()
    |> Multi.update(
      :job,
      Job.progress_changeset(job, %{status: :running, started_at: job.started_at || now})
    )
    |> Events.log(:event, "job.started", :system, %{
      ticket_id: job.ticket_id,
      job_id: job.id,
      payload: %{"resume" => job.harness_session_id != nil}
    })
    |> Repo.transaction()
    |> case do
      {:ok, %{job: job}} ->
        Events.notify(job.ticket_id)
        {:ok, job}

      # `Repo.transaction/1` reports a Multi failure as a four-tuple, which callers of
      # `start/1` are not promised and `Forge.Jobs.Scheduler` does not match.
      {:error, failed, reason, _changes} ->
        {:error, {failed, reason}}
    end
  end

  @doc "Runs a job to its end synchronously and records the result. For tests and tasks."
  @spec run(Job.t()) :: {:ok, Job.t()} | {:error, term()}
  def run(%Job{} = job) do
    with {:ok, pid} <- start(job),
         {:ok, %Result{} = result} <- Runner.await(pid) do
      complete(job.id, result)
    end
  end

  @doc """
  Records a runner result, then lets the engine decide what follows. Recording (documents,
  transcript, changeset head, status, accounting, event) is one transaction that never
  depends on the follow-up; if creating the next job fails, the ticket is stuck with the
  reason rather than the result being lost. A waiting job keeps its worktree; a finished
  one loses it. A resume that never reached the harness is re-queued as a fresh run.
  """
  @spec complete(String.t(), Result.t()) :: {:ok, Job.t()} | {:error, term()}
  def complete(job_id, %Result{} = result) do
    job = get!(job_id)
    ticket = Tickets.get!(job.ticket_id)

    if resume_failed?(job, result),
      do: requeue_fresh(job, ticket, result),
      else: record_and_follow_up(job, ticket, result)
  end

  # A resumed harness that produced no `started` event never got going (session not found,
  # different host); the design says fall back to a fresh invocation.
  defp resume_failed?(%Job{harness_session_id: session}, %Result{} = result) do
    session != nil and result.status == :finished and result.killed == nil and
      result.harness[:model] == nil and result.outcome == :error
  end

  defp requeue_fresh(job, ticket, result) do
    Multi.new()
    |> put_transcript(ticket, job, result)
    |> Multi.update(
      :job,
      Job.progress_changeset(job, %{status: :pending, harness_session_id: nil})
    )
    |> Events.log(:event, "job.resume_failed", {:job, job.id}, %{
      ticket_id: ticket.id,
      job_id: job.id,
      payload: result_payload(result)
    })
    |> Repo.transaction()
    |> case do
      {:ok, %{job: job}} ->
        Events.notify(ticket.id)
        {:ok, job}

      {:error, step, reason, _} ->
        {:error, {step, reason}}
    end
  end

  defp record_and_follow_up(job, ticket, result) do
    with {:ok, %{job: job, ticket_cost: ticket}} <- record(job, ticket, result) do
      case job.status do
        :finished ->
          remove_worktree(ticket, job)
          follow_up(ticket, job, result)

        :waiting ->
          Enum.each(result.questions, &Forge.Push.blocking_question(ticket, &1))
      end

      Events.notify(ticket.id)
      {:ok, job}
    end
  end

  defp record(job, ticket, result) do
    Multi.new()
    |> put_documents(ticket, job, result)
    |> put_transcript(ticket, job, result)
    |> put_changeset(ticket, job, result)
    |> Multi.update(:job, Job.progress_changeset(job, progress_attrs(job, result)))
    |> Tickets.put_progress(:ticket_cost, ticket, %{
      cost_usd: Decimal.add(ticket.cost_usd, decimal(result.harness[:cost_usd]))
    })
    |> Events.log(:event, "job.#{result.status}", {:job, job.id}, %{
      ticket_id: ticket.id,
      job_id: job.id,
      payload: result_payload(result)
    })
    |> Repo.transaction()
    |> case do
      {:ok, changes} -> {:ok, changes}
      {:error, step, reason, _} -> {:error, {step, reason}}
    end
  end

  defp follow_up(ticket, job, %Result{} = result) do
    outcome =
      if result.outcome == :converged,
        do: result.declared_outcome,
        else: Atom.to_string(result.outcome)

    case Engine.after_job(ticket, job, outcome) do
      {:ok, _ticket} ->
        :ok

      {:error, reason} ->
        Engine.stick(ticket, "could not continue after #{job.state}: #{inspect(reason)}")
    end
  end

  @doc "Marks a job whose runner died as finished with an error, then lets the engine decide."
  @spec fail(String.t(), term()) :: {:ok, Job.t()} | {:error, term()}
  def fail(job_id, reason) do
    job = get!(job_id)
    ticket = Tickets.get!(job.ticket_id)
    attrs = %{status: :finished, outcome: :error, finished_at: DateTime.utc_now(:second)}

    Multi.new()
    |> Multi.update(:job, Job.progress_changeset(job, attrs))
    |> Events.log(:event, "job.finished", :system, %{
      ticket_id: ticket.id,
      job_id: job.id,
      payload: %{"outcome" => "error", "reason" => inspect(reason)}
    })
    |> Repo.transaction()
    |> case do
      {:ok, %{job: job}} ->
        remove_worktree(ticket, job)
        follow_up(ticket, job, %Result{status: :finished, outcome: :error})
        Events.notify(ticket.id)
        {:ok, job}

      {:error, step, reason, _} ->
        {:error, {step, reason}}
    end
  end

  defp put_documents(multi, ticket, job, %Result{documents: documents}) do
    Enum.reduce(documents, multi, fn {name, document}, multi ->
      Artifacts.put_version(multi, {:doc, name}, ticket.id, name, :document, {:job, job.id}, %{
        content: document.raw
      })
    end)
  end

  defp put_transcript(multi, ticket, job, %Result{transcript_path: path}) do
    name = "transcript-#{job.state}-#{job.attempt}.jsonl"
    attrs = %{blob_uri: "file://" <> path, content_hash: file_hash(path)}
    Artifacts.put_version(multi, :transcript, ticket.id, name, :blob, {:job, job.id}, attrs)
  end

  # The transcript sits in the job directory, which the harness could write to; hashing it at
  # completion pins what was recorded.
  defp file_hash(path) do
    case File.read(path) do
      {:ok, content} -> "sha256:" <> Base.encode16(:crypto.hash(:sha256, content), case: :lower)
      {:error, _} -> "missing"
    end
  end

  # A finished job that produces the changeset gets the branch head recorded as a version,
  # so an approval of `changeset` attaches to an exact commit.
  defp put_changeset(multi, ticket, job, %Result{status: :finished}) do
    spec = spec(job)

    if Workflow.changeset_artifact() in spec.produces do
      repo_path = ticket |> Tickets.project_of() |> Projects.repo_path()

      case Git.resolve(repo_path, "refs/heads/" <> ticket.branch) do
        {:ok, head} -> Artifacts.put_changeset(multi, :changeset, ticket.id, {:job, job.id}, head)
        {:error, reason} -> Multi.error(multi, :changeset, reason)
      end
    else
      multi
    end
  end

  defp put_changeset(multi, _ticket, _job, _result), do: multi

  defp progress_attrs(job, %Result{} = result) do
    base = %{
      turns: job.turns + (result.harness[:turns] || 0),
      cost_usd: Decimal.add(job.cost_usd, decimal(result.harness[:cost_usd])),
      harness_session_id: result.harness[:session_id] || job.harness_session_id
    }

    case result.status do
      :waiting ->
        Map.put(base, :status, :waiting)

      :finished ->
        Map.merge(base, %{
          status: :finished,
          outcome: result.outcome,
          declared_outcome: result.declared_outcome,
          finished_at: DateTime.utc_now(:second)
        })
    end
  end

  defp result_payload(%Result{} = result) do
    %{
      "outcome" => result.outcome,
      "declared_outcome" => result.declared_outcome,
      "reason" => result.reason,
      "killed" => result.killed,
      "exit_status" => result.exit_status,
      "questions" => Enum.map(result.questions, & &1.key),
      "harness" => json_safe(result.harness)
    }
  end

  @doc "Resumes a waiting job once its blocking questions are answered: back to pending."
  @spec resume(Job.t()) :: {:ok, Job.t()} | {:error, term()}
  def resume(%Job{status: :waiting} = job) do
    Multi.new()
    |> Multi.update(:job, Job.progress_changeset(job, %{status: :pending}))
    |> Events.log(:event, "job.resumed", :system, %{ticket_id: job.ticket_id, job_id: job.id})
    |> Repo.transaction()
    |> case do
      {:ok, %{job: job}} -> {:ok, job}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  @doc "On boot: jobs left `running` by a previous node are re-queued. Their spec still holds."
  @spec recover() :: non_neg_integer()
  def recover do
    jobs = Repo.all(from j in Job, where: j.status == :running)

    Enum.each(jobs, fn job ->
      {:ok, _} =
        Multi.new()
        |> Multi.update(:job, Job.progress_changeset(job, %{status: :pending}))
        |> Events.log(:event, "job.interrupted", :system, %{
          ticket_id: job.ticket_id,
          job_id: job.id
        })
        |> Repo.transaction()

      Events.notify(job.ticket_id)
    end)

    length(jobs)
  end

  # -- filesystem -----------------------------------------------------------------------------

  @spec data_dir() :: String.t()
  def data_dir, do: Path.expand(config(:data_dir, "tmp/forge"))

  defp worktree_dir(%Job{id: id}), do: Path.join([data_dir(), "worktrees", id])

  # The worktree is removed when a job finishes, so one still standing belongs to a run that
  # did not: a node that died. A resume continues that run and keeps its work in progress; a
  # cold start does not, and must not inherit it. Commits are on the branch either way.
  defp ensure_worktree(repo_path, worktree, branch, resume?) do
    cond do
      not File.dir?(worktree) -> Git.worktree_add(repo_path, worktree, branch)
      resume? -> :ok
      true -> Git.worktree_reset(worktree, branch)
    end
  end

  defp remove_worktree(ticket, job) do
    repo_path = ticket |> Tickets.project_of() |> Projects.repo_path()
    worktree = worktree_dir(job)

    if File.dir?(worktree) do
      case Git.worktree_remove(repo_path, worktree) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("could not remove worktree #{worktree}: #{inspect(reason)}")
      end
    end
  end

  defp decimal(nil), do: Decimal.new(0)
  defp decimal(number) when is_float(number), do: Decimal.from_float(number)
  defp decimal(number) when is_integer(number), do: Decimal.new(number)

  @doc false
  def config(key, default),
    do: Application.get_env(:forge, __MODULE__, []) |> Keyword.get(key, default)
end
