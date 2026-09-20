defmodule Forge.Jobs do
  @moduledoc """
  Jobs: creating one from a ticket's state (building the immutable spec), assigning it to a
  worker, and recording what it produced. The engine decides what happens to the ticket
  afterwards; see `Forge.Engine`.

  Jobs are rows. Anything may create a `pending` job; `Forge.Jobs.Scheduler` assigns them to
  a worker over the channel (`docs/design/worker-channel.md`) and the channel brings back
  events, a result, or a hibernation. The platform runs nothing itself: it has not compiled
  the worker in since milestone 3.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi

  alias Forge.{
    Artifacts,
    Backlog,
    Conversations,
    Engine,
    Events,
    Git,
    Projects,
    Proposals,
    Repo,
    Spend,
    Storage,
    Tickets,
    Workers
  }

  alias Forge.Git.{Tokens, Url}
  alias Forge.Jobs.Job
  alias Forge.Tickets.Ticket
  alias Forge.Workers.Worker
  alias ForgeCore.Job.{Result, Spec}
  alias ForgeCore.Job.Spec.Input
  alias ForgeCore.{Prompt, Workflow}
  alias ForgeCore.Workflow.State

  require Logger

  # -- creation -------------------------------------------------------------------------------

  @doc "Adds the creation of a pending job for `state_name` to `multi` under `key`."
  @spec put_create(Multi.t(), term(), Ticket.t(), Workflow.t(), String.t()) :: Multi.t()
  def put_create(multi, key, %Ticket{} = ticket, %Workflow{} = workflow, state_name) do
    multi
    |> Multi.run(key, fn repo, _ ->
      with {:ok, spec} <- build_spec(repo, ticket, workflow, state_name),
           # The one place a workflow spec is built, and so the one place the keys the struct
           # can no longer enforce are checked. A spec that reaches the worker incomplete is a
           # job that fails on the machine, after a credential has been minted and a slice made.
           :ok <- Spec.validate(spec) do
        resources = resources(workflow, state_name)

        repo.insert(
          Job.create_changeset(%Job{id: spec.job_id}, %{
            kind: :workflow,
            ticket_id: ticket.id,
            project_id: ticket.project_id,
            state: state_name,
            attempt: spec.attempt,
            spec: spec |> Spec.to_json() |> Jason.decode!(),
            memory_max: resources.memory,
            cores: resources.cores
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

  @doc """
  What a job in `state_name` is admitted with: the workflow's chain, then the platform's.

  `ForgeCore.Workflow.resources/2` walks the part `forge_core` can see — the state's
  declaration, then the workflow's `defaults` — and leaves a field nil when nobody said, because
  core has no configuration to read the last link from. This is that last link
  (`docs/design/provisioning.md` § What a job asks for).

  **The resolved figures live on the job row and nowhere else.** Putting them in `spec` as well
  would be two copies of one decision that can disagree, and the row is the one the scheduler
  sums. The assignment carries them to the worker from the row.
  """
  @spec resources(Workflow.t(), String.t()) :: %{memory: pos_integer(), cores: pos_integer()}
  def resources(%Workflow{} = workflow, state_name) do
    declared = Workflow.resources(workflow, state_name)

    %{
      memory: declared.memory || Workers.slice_bytes(),
      cores: declared.cpu || Workers.default_cores()
    }
  end

  @doc """
  What a job with no workflow behind it is admitted with — a chat, which declares nothing.

  **Its own number, and not the build slice it used to borrow.** `Workers.chat_slice_bytes/0`
  says why; the short of it is that `resources` is a workflow state's grammar, a chat has no
  state, and inheriting a cold build's peak reserved a machine's worth of memory to run an
  agent that talks. Cores stay `default_cores/0`: the gate counts whole cores, and what a unit
  actually runs at is `CPUWeight`, which is a share rather than a quota.
  """
  @spec default_resources() :: %{memory: pos_integer(), cores: pos_integer()}
  def default_resources,
    do: %{memory: Workers.chat_slice_bytes(), cores: Workers.default_cores()}

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
         model: state.model,
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

  @doc """
  Gets a job, or nil.

  For ids that arrive from a worker: a message addressing a job that does not exist, or an id
  that is not a UUID at all, is a refusal rather than a crash on the channel.
  """
  @spec get(String.t()) :: Job.t() | nil
  def get(id) do
    Repo.get(Job, id)
  rescue
    Ecto.Query.CastError -> nil
  end

  @doc """
  A ticket's workflow jobs, oldest first — the ticket's timeline.

  Conversations about the ticket are excluded, and that is the point: every reader of this walks
  the workflow. The timeline chunks by state, so a chat would draw as a visit to a state named
  nothing; the CLI renders a state per row; the operator looks here for a job waiting on a
  question. Conversations are `chats_for_ticket/1`, which is a different list because it is a
  different thing.
  """
  @spec for_ticket(String.t()) :: [Job.t()]
  def for_ticket(ticket_id) do
    Repo.all(
      from j in Job,
        where: j.ticket_id == ^ticket_id and j.kind == :workflow,
        order_by: j.inserted_at
    )
  end

  @doc "Conversations about a ticket, newest first."
  @spec chats_for_ticket(String.t()) :: [Job.t()]
  def chats_for_ticket(ticket_id) do
    Repo.all(
      from j in Job,
        where: j.ticket_id == ^ticket_id and j.kind == :chat,
        order_by: [desc: j.inserted_at]
    )
  end

  @doc "Conversations belonging to a project, newest first. Includes its tickets' chats."
  @spec chats_for_project(String.t()) :: [Job.t()]
  def chats_for_project(project_id) do
    Repo.all(
      from j in Job,
        where: j.project_id == ^project_id and j.kind == :chat,
        order_by: [desc: j.inserted_at]
    )
  end

  @doc """
  Pending work, oldest first: jobs on active tickets, and conversations.

  The join is a left join because a project chat has no ticket, and an inner join would have
  dropped it from the queue without saying so — the conversation would sit pending for ever and
  nothing anywhere would report a problem. A chat is not filtered by a ticket's status either:
  a chat about a stuck ticket is the conversation you most want to be able to have.
  """
  @spec pending(pos_integer()) :: [Job.t()]
  def pending(limit \\ 10) do
    Repo.all(
      from j in Job,
        left_join: t in assoc(j, :ticket),
        where: j.status == :pending and (j.kind == :chat or t.status == :active),
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
  Assigns a pending job to a worker and tells that worker to run it. The assignment carries
  everything the job needs from the platform and nothing it can get for itself: the spec, a
  git endpoint with a token scoped to the ticket branch, the store key and token for its
  transcript, and the limits its slice is to have.

  The row is marked before the assignment goes out, not after, and the same reasoning holds
  as when the runner was in-process: a row the progress changeset refuses costs nothing, and
  marking second meant it was refused only once a billed invocation was already running. A
  worker that never gets the message is reconciled on its next join.
  """
  @spec assign(Job.t(), Worker.t()) :: {:ok, Job.t()} | {:error, term()}
  def assign(%Job{} = job, %Worker{} = worker) do
    # A workflow job reaches its project through its ticket; a chat has a project of its own and
    # may have no ticket at all. `Tickets.get!(nil)` raises, so the nil is answered here rather
    # than by a crash in the scheduler.
    ticket = job.ticket_id && Tickets.get!(job.ticket_id)
    project = Projects.get!(job.project_id)

    # Both caps are asked here, as they were when the runner was in-process: this is still the
    # one place every billed invocation passes. A ticket over its allowance is stuck before a
    # machine is spoken to, not after.
    with :ok <- spend_gate(job, ticket),
         {:ok, token, _row} <- Tokens.issue_for_job(job, ticket, project),
         {:ok, started} <- mark_started(job, worker),
         assignment = assignment(started, ticket, project, token),
         :ok <- Workers.push(worker.id, {:assign, assignment}) do
      {:ok, _worker} = Workers.busy(worker)
      log_backlog(started, assignment)
      {:ok, started}
    else
      {:error, reason} ->
        # Nothing is running, so the job must not sit `running` until the next boot, and the
        # credential it would have used is no good to anyone.
        Repo.update(Job.progress_changeset(get!(job.id), %{status: :pending}))
        Tokens.revoke_for_job(job.id)
        {:error, reason}
    end
  end

  # The backlog is the one thing a job is handed that is not an artifact version, so "what was
  # this built on?" is answered by the hash rather than by a manifest entry: the snapshot is
  # reproducible from the log, which is what keeps `docs/decisions.md`'s promise intact for it.
  defp log_backlog(%Job{} = job, %{"backlog" => %{} = backlog}) do
    Events.append("job.backlog", :system, %{
      ticket_id: job.ticket_id,
      job_id: job.id,
      payload: %{
        "hash" => backlog["hash"],
        "tickets" => length(backlog["tickets"] || []),
        "proposals" => length(backlog["proposals"] || [])
      }
    })

    :ok
  end

  defp log_backlog(%Job{}, _assignment), do: :ok

  @doc "What the worker is told when a job is assigned. See `docs/design/worker-channel.md`."
  @spec assignment(Job.t(), Ticket.t() | nil, Forge.Projects.Project.t(), String.t()) :: map()
  def assignment(%Job{} = job, ticket, project, git_token) do
    # Per assignment, not per job: a resumed run uploads its own transcript, and the store
    # refuses to overwrite one that is already there.
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false) |> String.downcase()
    transcript = Storage.Key.job(job.id, "transcript-#{job.attempt}-#{nonce}.jsonl")

    %{
      "job_id" => job.id,
      "kind" => Atom.to_string(job.kind),
      "spec" => job |> runtime_spec(ticket) |> Spec.to_json() |> Jason.decode!(),
      "git" => %{
        "url" => Url.for_worker(project),
        "token" => git_token,
        "branch" => branch(job, ticket),
        "base" => ticket && ticket.base_commit
      },
      "store" => %{
        "transcript_key" => transcript,
        "transcript_token" => Storage.Token.sign(:put, transcript)
      },
      # Every job, workflow and chat alike, with no grammar key: an unread file costs nothing
      # (`docs/design/ticket-proposals.md` § Reading the backlog).
      "backlog" => Backlog.compose(project),
      "seed" => seed(project),
      # The job's own figures, from the row it was admitted with, rather than one number for
      # every job (`docs/design/provisioning.md` § What a job asks for). `cpu_weight` stays a
      # constant and is not `cores`: the slice gets a proportional *share*, never a quota, so a
      # command with the machine to itself uses all of it — `cores` is what the gate reserved,
      # which is a different question from what the unit is allowed to run at.
      "slice" => %{
        "memory_max" => job.memory_max || Workers.slice_bytes(),
        "cpu_weight" => Workers.config(:cpu_weight, 100)
      },
      "resume_session" => job.harness_session_id,
      "wall_clock_ms" => config(:wall_clock_ms, :timer.hours(1))
    }
    |> Map.merge(chat_assignment(job))
  end

  # What only a conversation carries. `max_cost_usd` is what is left of the day, passed to the
  # harness as its per-turn ceiling: a chat has no state to take a budget from, and the daily cap
  # is the only one there is (`docs/design/conversations.md` § Spend).
  defp chat_assignment(%Job{kind: :chat} = job) do
    %{
      "idle_ms" => config(:chat_idle_ms, :timer.minutes(30)),
      "max_cost_usd" => remaining_today(),
      "wall_clock_ms" => config(:chat_wall_clock_ms, :timer.hours(24)),
      # What already ran on this ticket. Metadata inline because it is small; transcripts as a
      # key and a token, because they are not (`Conversations.history/1`).
      "history" => job.ticket_id |> ticket_of() |> Conversations.history()
    }
  end

  defp chat_assignment(%Job{}), do: %{}

  defp ticket_of(nil), do: nil
  defp ticket_of(ticket_id), do: Tickets.get!(ticket_id)

  defp remaining_today do
    case Spend.day_remaining() do
      :unlimited -> nil
      remaining -> Decimal.to_float(remaining)
    end
  end

  # A conversation's branch is its own, never the ticket's: a chat writing the ticket's ref would
  # race the jobs that own it and muddy what the changeset means (§ Commits).
  defp branch(%Job{kind: :chat} = job, _ticket), do: chat_branch(job)
  defp branch(%Job{}, %Ticket{} = ticket), do: ticket.branch

  @doc "The branch a conversation's work goes to."
  @spec chat_branch(Job.t()) :: String.t()
  def chat_branch(%Job{id: id}), do: "chat/" <> id

  # The warm starting point the worker snapshots this job's worktree from, with a token to
  # fetch it. A project nobody has published a seed for gets nil and the worker clones, which
  # is slow rather than wrong (`docs/design/worker-tier.md` § Volumes and the seed).
  #
  # The token is minted per assignment like every other one the worker holds: a machine that
  # already has this seed never spends it, and one that does not is fetching within minutes.
  defp seed(%{seed_id: seed_id, name: name}) when is_binary(seed_id) do
    key = Storage.Key.seed(name, seed_id)
    %{"key" => key, "token" => Storage.Token.sign(:get, key)}
  end

  defp seed(_project), do: nil

  # Every billed invocation passes through `start/1`, including `run/1` from a Mix task, so this
  # is where both caps are asked rather than in the scheduler alone. A ticket over its own
  # allowance is stuck, which also takes it out of `pending/1` and stops the scheduler retrying it
  # every tick; the daily cap only pauses, and the ticket stays active and out of the queue.
  # A conversation has no ticket allowance and no workflow to take one from: the note says the
  # daily cap is its only ceiling, and this is where that is true rather than merely intended.
  # Each turn is also invoked with what is left of the day — see `Conversations` — so the cap
  # binds during the conversation as well as before it.
  defp spend_gate(%Job{kind: :chat}, _ticket) do
    case Spend.day_gate() do
      :ok ->
        :ok

      {:pause, reason} ->
        Events.append("spend.paused", :system, %{payload: %{"reason" => reason}})
        {:error, {:spend_paused, :day}}
    end
  end

  defp spend_gate(_job, %Ticket{} = ticket), do: spend_gate(ticket)

  defp spend_gate(%Ticket{} = ticket) do
    case Spend.gate(ticket, Tickets.workflow(ticket)) do
      :ok ->
        :ok

      {:stick, reason} ->
        Engine.stick(ticket, reason)
        {:error, {:spend_exhausted, :ticket}}

      {:pause, reason} ->
        Events.append("spend.paused", :system, %{
          ticket_id: ticket.id,
          payload: %{"reason" => reason}
        })

        {:error, {:spend_paused, :day}}
    end
  end

  # The stored spec never changes; answers given since are appended at run time, the keys already
  # answered are passed so the worker does not wait on them again, and the cost budget is lowered
  # to whatever cap binds first. That last one is what stops a runaway job mid-flight: the figure
  # reaches the harness as its own budget, and the harness stops itself.
  # A conversation's spec is synthesised at assignment and never stored — the precedent is right
  # below, where a workflow job's assignment spec is already not the row's. What it carries is
  # what a chat actually has: where its work goes, and the context it was opened with.
  defp runtime_spec(%Job{kind: :chat} = job, ticket) do
    spec = %Spec{
      job_id: job.id,
      kind: :chat,
      branch: chat_branch(job),
      ticket: ticket && %{number: ticket.number, title: ticket.title},
      commit: ticket && ticket.base_commit,
      prompt: opening_prompt(job),
      inputs: chat_inputs(ticket),
      preamble_hash: ForgeCore.Prompt.chat_preamble_hash(),
      model: model_for(job),
      produces: [],
      outcomes: []
    }

    :ok = Spec.validate(spec)
    spec
  end

  defp runtime_spec(%Job{} = job, %Ticket{id: ticket_id} = ticket) do
    # The model is resolved here rather than frozen into the stored spec at creation. The spec
    # carries what the *state* declared, which is pinned with the workflow and right to keep;
    # the project's default is not pinned, and a job created a week before it ran should use the
    # project's answer now rather than the one it had then.
    spec = %{spec(job) | answered_keys: Artifacts.answered_keys(ticket_id), model: model_for(job)}
    spec = lower_budget(spec, job, ticket)

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

  @doc """
  What this job runs on: the most specific thing that says so.

  A state's model, then the project's, then nil — and nil is not "no model", it is the machine's,
  which is the platform-wide setting the worker was built with. A conversation has no state, so
  the first link is the model it was opened with.

  Resolved here and carried in the spec, so the worker is told rather than deciding: the platform
  knows the state and the project, and a machine knows neither.
  """
  @spec model_for(Job.t()) :: String.t() | nil
  def model_for(%Job{kind: :chat} = job), do: job.model || project_model(job.project_id)

  def model_for(%Job{} = job), do: spec(job).model || project_model(job.project_id)

  defp project_model(nil), do: nil

  defp project_model(project_id) do
    Repo.one(from p in Projects.Project, where: p.id == ^project_id, select: p.model)
  end

  # The message that opened the conversation, which the worker delivers as the first turn. It is
  # read from the log rather than stored on the row, because the log is already the conversation
  # (§ Shape) and a copy on the row would be a second one.
  defp opening_prompt(%Job{id: job_id}) do
    Repo.one(
      from e in Forge.Events.Event,
        where: e.job_id == ^job_id and e.type == "chat.message",
        order_by: e.seq,
        limit: 1,
        select: fragment("? ->> 'text'", e.payload)
    ) || "Hello."
  end

  # The same inputs the ticket's next job would get, which is the point of a ticket chat: it is
  # for asking about, or fixing, the work in flight (§ Context).
  defp chat_inputs(nil), do: []

  defp chat_inputs(%Ticket{id: ticket_id}) do
    ticket_id
    |> Artifacts.latest_documents()
    |> Enum.map(&%Input{name: &1.name, version: &1.version, content: &1.content})
  end

  # The job row's `spec` is written once and never rewritten — the invariant holds for what was
  # declared. Only the copy the harness runs with is narrowed, and the difference is an event,
  # without which a job stopping at a tenth of its declared budget is inexplicable later.
  defp lower_budget(spec, %Job{} = job, %Ticket{} = ticket) do
    {cost, binding} = Spend.effective_cost(spec.budget.cost, ticket, Tickets.workflow(ticket))

    if binding == :state or cost >= spec.budget.cost do
      spec
    else
      Events.append("job.budget_lowered", :system, %{
        ticket_id: ticket.id,
        job_id: job.id,
        payload: %{
          "spec_cost" => spec.budget.cost,
          "effective_cost" => cost,
          "binding" => Atom.to_string(binding)
        }
      })

      %{spec | budget: %{spec.budget | cost: cost}}
    end
  end

  @doc """
  Records one harness event against its job. Events arrive over the channel and are the
  timeline, not the contract: one that cannot be written is logged and dropped rather than
  failing anything.
  """
  @spec record_harness_event(String.t(), ForgeCore.Job.Event.t()) :: :ok
  def record_harness_event(job_id, %{type: type, payload: payload}) do
    ticket_id = Repo.one(from j in Job, where: j.id == ^job_id, select: j.ticket_id)

    case Events.append(type, {:job, job_id}, %{
           ticket_id: ticket_id,
           job_id: job_id,
           payload: json_safe(payload)
         }) do
      {:ok, event} ->
        Events.notify_job(job_id, event)
        :ok

      {:error, changeset} ->
        Logger.warning("dropped harness event #{type}: #{inspect(changeset.errors)}")
    end
  end

  defp json_safe(term), do: term |> Jason.encode!() |> Jason.decode!()

  defp mark_started(%Job{} = job, %Worker{} = worker) do
    now = DateTime.utc_now(:second)

    Multi.new()
    |> Multi.update(
      :job,
      Job.progress_changeset(job, %{
        status: :running,
        worker_id: worker.id,
        started_at: job.started_at || now
      })
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

  @doc """
  Records a runner result, then lets the engine decide what follows. Recording (documents,
  transcript, changeset head, status, accounting, event) is one transaction that never
  depends on the follow-up; if creating the next job fails, the ticket is stuck with the
  reason rather than the result being lost. A resume that never reached the harness is
  re-queued as a fresh run.

  The push is the worker's now, and it happens before the worker reports at all
  (`docs/design/worker-tier.md` § Git): the branch already carries what the agent wrote by the
  time this is called, so there is nothing left for the platform to push.
  """
  @spec complete(String.t(), Result.t()) :: {:ok, Job.t()} | {:error, :already_recorded | term()}
  def complete(job_id, %Result{} = result) do
    job = get!(job_id)
    ticket = job.ticket_id && Tickets.get!(job.ticket_id)

    cond do
      # A conversation never sends one: it ends by hibernating, because it has no outcome to
      # report. One arriving anyway is a worker the platform does not understand, and recording
      # it would run the whole workflow follow-up over a job with no state to leave.
      job.kind == :chat -> {:error, :not_a_workflow_job}
      # The worker re-sends a result until it is acked, so the platform has to be able to
      # hear the same one twice. Keyed by the job: a job is recorded once.
      job.status == :finished -> {:error, :already_recorded}
      resume_failed?(job, result) -> requeue_fresh(job, ticket, result)
      true -> record_and_follow_up(job, ticket, result)
    end
  end

  # A resumed harness that produced no `started` event never got going (session not found,
  # different host); the design says fall back to a fresh invocation.
  defp resume_failed?(%Job{harness_session_id: session}, %Result{} = result) do
    session != nil and result.status == :finished and result.killed == nil and
      result.harness["model"] == nil and result.outcome == :error
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
          # The worktree is the worker's to throw away, and it already has. What is left here
          # is the credential, which is no good to anyone once the job is over, and the
          # worker's memory, which the next job wants back.
          Tokens.revoke_for_job(job.id)
          Workers.release(job.worker_id)
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
    |> put_proposals(job, result)
    |> put_transcript(ticket, job, result)
    |> put_changeset(ticket, job, result)
    |> Multi.update(:job, Job.progress_changeset(job, progress_attrs(job, result)))
    |> Tickets.put_progress(:ticket_cost, ticket, %{
      cost_usd: Decimal.add(ticket.cost_usd, decimal(result.harness["cost_usd"]))
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
    ticket = job.ticket_id && Tickets.get!(job.ticket_id)
    attrs = fail_attrs(job)

    Multi.new()
    |> Multi.update(:job, Job.progress_changeset(job, attrs))
    |> Events.log(:event, "job.finished", :system, %{
      ticket_id: job.ticket_id,
      job_id: job.id,
      payload: %{"outcome" => attrs[:outcome], "reason" => inspect(reason)}
    })
    |> Repo.transaction()
    |> case do
      {:ok, %{job: job}} ->
        Tokens.revoke_for_job(job.id)
        Workers.release(job.worker_id)
        # A conversation has no engine to continue: it failed, and a person decides what next.
        # On the kind, not on "does it have a ticket" — a *ticket* chat has one, so that guard
        # sent every failed ticket chat into `Engine.after_job`, which has no state to move from
        # and logs `job.orphaned`. The note names this as the failure mode to guard against; the
        # comment here was right and the condition under it was not.
        if job.kind == :workflow and ticket do
          follow_up(ticket, job, %Result{status: :finished, outcome: :error})
        end

        Events.notify(job.ticket_id)
        {:ok, job}

      {:error, step, reason, _} ->
        {:error, {step, reason}}
    end
  end

  defp fail_attrs(%Job{kind: :chat}),
    do: %{status: :finished, finished_at: DateTime.utc_now(:second)}

  defp fail_attrs(%Job{}),
    do: %{status: :finished, outcome: :error, finished_at: DateTime.utc_now(:second)}

  # Only for a run that ended. A waiting job's `out/proposals/` is still there when it resumes
  # and would be collected again, so recording now would put the same proposal in as a second
  # version of itself for every question the job stopped on.
  defp put_proposals(multi, job, %Result{status: :finished} = result) do
    Proposals.put_from_result(multi, job, result.proposals, result.invalid_proposals)
  end

  defp put_proposals(multi, _job, %Result{}), do: multi

  defp put_documents(multi, ticket, job, %Result{documents: documents}) do
    Enum.reduce(documents, multi, fn {name, document}, multi ->
      Artifacts.put_version(multi, {:doc, name}, ticket.id, name, :document, {:job, job.id}, %{
        content: document.raw
      })
    end)
  end

  # The transcript is in the store before the worker sends its result: it uploaded it with a
  # token for exactly that key. What crosses the wire is the key, and the platform asks the
  # store what it holds rather than trusting a size or a hash the worker reported.
  #
  # A transcript that never arrived is logged and skipped rather than failing the job. The
  # documents and the outcome are the contract; the conversation never was.
  defp put_transcript(multi, ticket, job, %Result{transcript: key}) when is_binary(key) do
    name = "transcript-#{job.state}-#{job.attempt}.jsonl"

    case Storage.stat(key) do
      {:ok, %{hash: hash}} ->
        attrs = %{blob_uri: Storage.uri(key), content_hash: hash}
        Artifacts.put_version(multi, :transcript, ticket.id, name, :blob, {:job, job.id}, attrs)

      {:error, reason} ->
        Logger.warning("job #{job.id} reported transcript #{key}: #{inspect(reason)}")
        multi
    end
  end

  defp put_transcript(multi, _ticket, _job, %Result{}), do: multi

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
      turns: job.turns + (result.harness["turns"] || 0),
      cost_usd: Decimal.add(job.cost_usd, decimal(result.harness["cost_usd"])),
      harness_session_id: result.harness["session_id"] || job.harness_session_id
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

  @doc """
  Records that a job committed its work and stopped. `commit` is where that work is on the
  ticket branch; resuming reconstructs from the branch and the manifest, never from the
  conversation (`docs/decisions.md`).
  """
  @spec hibernate(String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, Job.t()} | {:error, term()}
  def hibernate(job_id, commit, reason) do
    job = get!(job_id)

    if job.status == :hibernated do
      {:ok, job}
    else
      Multi.new()
      |> Multi.update(:job, Job.progress_changeset(job, %{status: :hibernated}))
      |> Events.log(:event, "job.hibernated", {:job, job.id}, %{
        ticket_id: job.ticket_id,
        job_id: job.id,
        payload: %{"commit" => commit, "reason" => reason}
      })
      |> Repo.transaction()
      |> case do
        {:ok, %{job: job}} ->
          Events.notify(job.ticket_id)
          {:ok, job}

        {:error, step, reason, _changes} ->
          {:error, {step, reason}}
      end
    end
  end

  @doc """
  Puts a job back in the queue without recording a result: the run it was having is gone.
  Used when a worker rejoins without a job the platform believes it is running.
  """
  @spec requeue(String.t(), atom()) :: {:ok, Job.t()} | {:error, term()}
  def requeue(job_id, reason) do
    job = get!(job_id)

    Multi.new()
    |> Multi.update(:job, Job.progress_changeset(job, %{status: interrupted_status(job)}))
    |> Events.log(:event, "job.interrupted", :system, %{
      ticket_id: job.ticket_id,
      job_id: job.id,
      payload: %{"reason" => to_string(reason)}
    })
    |> Repo.transaction()
    |> case do
      {:ok, %{job: job}} ->
        Events.notify(job.ticket_id)
        {:ok, job}

      {:error, step, reason, _changes} ->
        {:error, {step, reason}}
    end
  end

  @doc "Jobs a worker is supposed to be running."
  @spec running_on(String.t()) :: [Job.t()]
  def running_on(worker_id),
    do: Repo.all(from j in Job, where: j.worker_id == ^worker_id and j.status == :running)

  @doc """
  On boot: work left `running` by a previous node is dealt with. A job is re-queued — its spec
  still holds and nothing is watching it. A conversation is **not**: it goes dormant.

  Re-queueing a chat would mean every platform restart silently starting conversations nobody is
  in, each taking a slice and spending the day's allowance on a greeting nobody reads. A chat has
  a person in it, and the person decides when it resumes — `docs/design/conversations.md`
  § Lifetime.
  """
  @spec recover() :: non_neg_integer()
  def recover do
    jobs = Repo.all(from j in Job, where: j.status == :running)

    Enum.each(jobs, fn job ->
      {:ok, _} =
        Multi.new()
        |> Multi.update(:job, Job.progress_changeset(job, %{status: interrupted_status(job)}))
        |> Events.log(:event, "job.interrupted", :system, %{
          ticket_id: job.ticket_id,
          job_id: job.id
        })
        |> Repo.transaction()

      Events.notify(job.ticket_id)
    end)

    length(jobs)
  end

  @doc """
  What a running job becomes when the run under it is gone: pending for a job, dormant for a
  conversation.

  `:hibernated` already means "stopped without an outcome" and is already excluded from
  `Workers.promised/1`, so a dormant chat neither schedules itself nor counts against a worker.
  """
  @spec interrupted_status(Job.t()) :: :pending | :hibernated
  def interrupted_status(%Job{kind: :chat}), do: :hibernated
  def interrupted_status(%Job{}), do: :pending

  # -- filesystem -----------------------------------------------------------------------------

  # Worktrees and build directories belong to the worker now: it snapshots them from its seed
  # and throws them away, and the platform has no disk they live on. What is left here is the
  # job directory root the platform still uses for its own scratch space.
  @spec data_dir() :: String.t()
  def data_dir, do: Path.expand(config(:data_dir, "tmp/forge"))

  defp decimal(nil), do: Decimal.new(0)
  defp decimal(number) when is_float(number), do: Decimal.from_float(number)
  defp decimal(number) when is_integer(number), do: Decimal.new(number)

  @doc false
  def config(key, default),
    do: Application.get_env(:forge, __MODULE__, []) |> Keyword.get(key, default)
end
