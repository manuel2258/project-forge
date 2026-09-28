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

  import Ecto.Query, only: [from: 2, dynamic: 2]

  alias Ecto.Multi

  alias Forge.{
    Artifacts,
    Backlog,
    Conversations,
    Credentials,
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

  alias Forge.Events.Event
  alias Forge.Git.{Tokens, Url}
  alias Forge.Jobs.{Blobs, Commands, Job, Runs}
  alias Forge.Tickets.Ticket
  alias Forge.Workers.Worker
  alias ForgeCore.Job.{Result, Spec}
  alias ForgeCore.Job.Spec.Input
  alias ForgeCore.{Prompt, Workflow}
  alias ForgeCore.Workflow.State

  require Logger

  # The worker protocol commands arrived in (`docs/design/worker-channel.md` § Versions).
  @commands_protocol 2

  # -- creation -------------------------------------------------------------------------------

  @doc """
  Adds the creation of a pending job for `state_name` to `multi` under `key`.

  `entered` is how the ticket came into the state — `%{"from", "outcome", "by", "comment"}` from
  the transition that is creating the job — and nil for the ticket's first state. It goes into the
  spec so the job is told why it is here (`docs/design/job-prompt.md` § How the job arrived).
  """
  @spec put_create(Multi.t(), term(), Ticket.t(), Workflow.t(), String.t(), map() | nil) ::
          Multi.t()
  def put_create(
        multi,
        key,
        %Ticket{} = ticket,
        %Workflow{} = workflow,
        state_name,
        entered \\ nil
      ) do
    multi
    |> Multi.run(key, fn repo, _ ->
      with {:ok, spec} <- build_spec(repo, ticket, workflow, state_name, entered),
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
  def resources(%Workflow{} = workflow, state_name),
    do: admitted(Workflow.resources(workflow, state_name))

  @doc """
  A declaration's figures with the platform's last link filled in: what a field nobody declared
  is admitted as. `resources/2` for a job state, and a command's chain for a command
  (`ForgeCore.Workflow.command_resources/3`).
  """
  @spec admitted(ForgeCore.Workflow.Resources.t()) :: %{
          memory: pos_integer(),
          cores: pos_integer()
        }
  def admitted(declared) do
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

  defp build_spec(repo, %Ticket{} = ticket, %Workflow{} = workflow, state_name, entered) do
    %State{} = state = Workflow.state(workflow, state_name)
    project = Projects.get!(ticket.project_id)
    repo_path = Projects.repo_path(project)
    job_id = Ecto.UUID.generate()

    with {:ok, prompt} <- Git.show(repo_path, ticket.workflow_commit, ".forge/" <> state.prompt),
         {:ok, inputs, absent} <- inputs(repo, ticket, repo_path, workflow, state) do
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
         absent_inputs: absent,
         entered: entered,
         may_invoke: grants(state),
         produces: state.produces,
         outcomes: state.outcomes,
         permitted_children: []
       }}
    end
  end

  # String keys, as the spec crosses the wire in JSON and is read back from the row.
  defp grants(%State{may_invoke: grants}) do
    Map.new(grants, fn {name, grant} ->
      {name, %{"max" => grant.max, "concurrent" => grant.concurrent}}
    end)
  end

  # An optional input that has not been written is left out and named, and a required one that
  # is missing still fails the creation — it is the platform's guarantee that it exists, so its
  # absence is a bug to hear about rather than a state to run in
  # (`docs/design/workflow-grammar-v1.md` § Inputs).
  defp inputs(repo, ticket, repo_path, workflow, %State{name: state_name, inputs: names}) do
    Enum.reduce_while(names, {:ok, [], []}, fn name, {:ok, found, absent} ->
      case input(repo, ticket, repo_path, name) do
        {:ok, input} ->
          {:cont, {:ok, found ++ [input], absent}}

        {:error, {:missing_input, ^name}} = error ->
          missing(Workflow.required_input?(workflow, state_name, name), error, found, absent)

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp missing(true = _required, error, _found, _absent), do: {:halt, error}

  defp missing(false, {:error, {:missing_input, name}}, found, absent),
    do: {:cont, {:ok, found, absent ++ [name]}}

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

  # An agent's attempts, not its commands': they share its state, and count their own
  # (`Forge.Jobs.Commands`).
  defp next_attempt(repo, ticket_id, state_name) do
    (repo.one(
       from j in Job,
         where: j.ticket_id == ^ticket_id and j.state == ^state_name and j.kind == :workflow,
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

  @doc """
  A ticket's command jobs, oldest first (`docs/design/commands.md`). Apart from `for_ticket/1`,
  whose callers name what they build by a job's state and attempt, and a command's attempt counts
  the ticket's commands rather than its state's visits.
  """
  @spec commands_for_ticket(String.t()) :: [Job.t()]
  def commands_for_ticket(ticket_id) do
    Repo.all(
      from j in Job,
        where: j.ticket_id == ^ticket_id and j.kind == :command,
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

  **Ahead of them, the jobs pending since before `waited_since`**, longest-waiting first: the ones
  old enough to reserve the machines they need (`docs/design/provisioning.md` § The gate). By
  insertion alone, a job made earlier and pending again only just now — a parked agent back from
  its commands — was offered before one that had waited half an hour, and took the room it was
  holding out for; and a window of ten could hold no room for it at all.
  """
  @spec pending(pos_integer(), DateTime.t() | nil) :: [Job.t()]
  def pending(limit \\ 10, waited_since \\ nil) do
    Repo.all(
      from j in Job,
        left_join: t in assoc(j, :ticket),
        where: j.status == :pending and (j.kind == :chat or t.status == :active),
        order_by: ^pending_order(waited_since),
        limit: ^limit
    )
  end

  defp pending_order(nil), do: [asc: :inserted_at]

  defp pending_order(since) do
    [
      asc: dynamic([j], j.updated_at > ^since),
      asc:
        dynamic([j], fragment("CASE WHEN ? <= ? THEN ? END", j.updated_at, ^since, j.updated_at)),
      asc: :inserted_at
    ]
  end

  @doc """
  The job of the ticket's current state that is stopped on a question, or nil.

  One definition, because two things ask it and must agree: `Forge.Operator.answer/4`, which
  resumes it once no blocking question on the ticket is open, and `Forge.Conversations`, which
  refuses a chat the document holding such a question while it waits — a version without the
  block would close the question and leave this job waiting on nothing.
  """
  @spec waiting_job(Ticket.t()) :: Job.t() | nil
  # `&1.state == state` is an equivalent mutant, kept because it says which job is meant. A
  # ticket leaves a state by a transition: the engine's, once that state's job has finished; a
  # person's approval of one, which is pending only once that job has finished; or a person's
  # `Engine.choose/4`, which refuses while a job there is live, `:waiting` included. So no
  # waiting job is ever in a state other than its ticket's, and a test telling the two apart
  # would have to write a row the product cannot produce.
  def waiting_job(%Ticket{id: ticket_id, state: state}),
    do: Enum.find(for_ticket(ticket_id), &(&1.status == :waiting and &1.state == state))

  @doc "Whether a job for `state` on the ticket is pending, running, waiting or parked."
  @spec live?(String.t(), String.t()) :: boolean()
  def live?(ticket_id, state) do
    Repo.exists?(
      from j in Job,
        where:
          j.ticket_id == ^ticket_id and j.state == ^state and
            j.status in [:pending, :running, :waiting, :parked]
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
  def assign(%Job{kind: :command} = job, %Worker{} = worker), do: assign_command(job, worker)

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
         {:ok, credential} <- Credentials.for_job(job),
         {:ok, wire} <- sealed(credential, worker, job),
         {:ok, token, _row} <- Tokens.issue_for_job(job, ticket, project),
         {:ok, started} <- mark_started(job, worker, credential),
         assignment = Map.put(assignment(started, ticket, project, token), "credential", wire),
         :ok <- Workers.push(worker.id, {:assign, assignment}) do
      {:ok, _worker} = Workers.busy(worker)
      log_backlog(started, assignment)
      {:ok, started}
    else
      # Somebody else moved the row first — a conversation closed during the pass. It is theirs
      # now: putting it back to `:pending` would reopen what they ended.
      {:error, {:changed, _now}} = changed ->
        Tokens.revoke_for_job(job.id)
        changed

      {:error, reason} ->
        unassign(job, reason)
    end
  end

  # Nothing is running, so the job must not sit `running` until the next boot, the run it was
  # marked with never happened, and the credential or token it would have used is no good to
  # anyone.
  defp unassign(job, reason) do
    Multi.new()
    |> Multi.update(:job, Job.progress_changeset(get!(job.id), %{status: :pending}))
    |> Runs.close(job.id, DateTime.utc_now(:second))
    |> Repo.transaction()

    Tokens.revoke_for_job(job.id)
    {:error, reason}
  end

  # A command carries no harness, no credential, no model and no budget
  # (`docs/design/commands.md` § An invocation is a job): no spend gate, no pick from the pool, and
  # a git token that can read and not write (§ How a command gets the code).
  defp assign_command(%Job{} = job, %Worker{} = worker) do
    ticket = Tickets.get!(job.ticket_id)
    project = Projects.get!(job.project_id)

    with {:ok, token, _row} <- Tokens.issue_for_job(job, ticket, project),
         {:ok, started} <- mark_started(job, worker, nil),
         assignment = command_assignment(started, ticket, project, token),
         :ok <- Workers.push(worker.id, {:assign, assignment}) do
      {:ok, _worker} = Workers.busy(worker)
      {:ok, started}
    else
      {:error, {:changed, _now}} = changed ->
        Tokens.revoke_for_job(job.id)
        changed

      {:error, reason} ->
        unassign(job, reason)
    end
  end

  @doc "What the worker is told when a command is assigned. See `docs/design/worker-channel.md`."
  @spec command_assignment(Job.t(), Ticket.t(), Forge.Projects.Project.t(), String.t()) :: map()
  def command_assignment(%Job{kind: :command} = job, %Ticket{} = ticket, project, git_token) do
    log = Storage.Key.job(job.id, "log-#{job.attempt}-#{Storage.Key.nonce()}.txt")

    %{
      "job_id" => job.id,
      "kind" => "command",
      "spec" => job.spec,
      "git" => %{
        "url" => Url.for_worker(project),
        "token" => git_token,
        "branch" => ticket.branch,
        "base" => ticket.base_commit
      },
      "store" => %{
        "log_key" => log,
        "log_token" =>
          Storage.Token.sign(:put, log,
            outlasting_ms: wall_clock_ms(job) + preparation_margin_ms()
          )
      },
      "seed" => seed(project),
      "slice" => %{
        "memory_max" => job.memory_max || Workers.slice_bytes(),
        "cpu_weight" => Workers.config(:cpu_weight, 100)
      },
      "wall_clock_ms" => wall_clock_ms(job)
    }
    |> Map.merge(group_outputs(job))
  end

  # A credential whose secret this node cannot open — a rotated `secret_key_base` — is one no job
  # can run on, and it is said once per attempt rather than crashing the pass
  # (`Forge.Provisioning.Vault` records the same cost for provider credentials).
  defp sealed(credential, worker, job) do
    case Credentials.for_wire(credential, worker, job.id) do
      {:ok, wire} ->
        {:ok, wire}

      {:error, :unreadable} ->
        Logger.error("credential #{credential.id} cannot be decrypted on this node; add it again")
        {:error, {:credential_unreadable, credential.id}}
    end
  end

  @doc """
  The harness a job runs, and so the harness its credential has to be for.

  `claude_code` for both kinds that exist. The workflow grammar has no field for it yet; when it
  does, this is where it is read and nothing downstream changes (`docs/design/credentials.md`
  § What a worker offers now).
  """
  @spec harness(Job.t()) :: String.t() | nil
  def harness(%Job{kind: :command}), do: nil
  def harness(%Job{}), do: "claude_code"

  @doc """
  The worker protocol a job needs, or 0 for any: commands and groups of files arrived in protocol
  2, and a release from before them would run a command's spec as an agent job's, leave an
  agent's `invoke.json` unread, and read a group `name/*` as a document it never finds — every
  such job ending `error` however well it did (`docs/design/commands.md` § Worker pools).
  """
  @spec protocol(Job.t()) :: non_neg_integer()
  def protocol(%Job{kind: :command}), do: @commands_protocol

  def protocol(%Job{kind: :workflow} = job) do
    decoded = spec(job)

    if decoded.may_invoke != %{} or Spec.group_outputs(decoded) != [],
      do: @commands_protocol,
      else: 0
  end

  def protocol(%Job{}), do: 0

  @doc "How many of `parent_id`'s invocations of `command` are running now."
  @spec running_commands(String.t(), String.t()) :: non_neg_integer()
  def running_commands(parent_id, command) do
    Repo.one(
      from j in Job,
        where:
          j.parent_job_id == ^parent_id and j.kind == :command and j.status == :running and
            fragment("?->'command'->>'name'", j.spec) == ^command,
        select: count()
    )
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
    transcript = Storage.Key.job(job.id, "transcript-#{job.attempt}-#{Storage.Key.nonce()}.jsonl")

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
        # Used when the job stops, not when it starts, so it lives as long as the job may: its
        # preparation and then its whole clock, which the worker starts only once the clone and
        # the seed are ready (`docs/design/storage.md` § Serving).
        "transcript_token" =>
          Storage.Token.sign(:put, transcript,
            outlasting_ms: wall_clock_ms(job) + preparation_margin_ms()
          )
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
      "wall_clock_ms" => wall_clock_ms(job)
    }
    |> Map.merge(chat_assignment(job))
    |> Map.merge(command_logs(job))
    |> Map.merge(group_outputs(job))
  end

  # Where a job's groups of files go, for a job that declares one (`Forge.Jobs.Blobs`). Uploaded
  # when the job stops, so the token lives as long as a transcript's does.
  defp group_outputs(%Job{kind: :chat}), do: %{}

  defp group_outputs(%Job{} = job),
    do: Blobs.outputs(job, spec(job), wall_clock_ms(job) + preparation_margin_ms())

  # A resume after commands is handed each command's log, by key and a `get` token, to fetch into
  # `$FORGE_JOB/commands/` before it starts (`docs/design/job-prompt.md` § Commands). Spent while
  # the worktree is prepared, so it lives the preparation margin and not the clock.
  defp command_logs(%Job{kind: :workflow} = job) do
    case Commands.results(job) do
      {_results, []} ->
        %{}

      {_results, logs} ->
        %{
          "commands" =>
            Enum.map(logs, fn %{file: file, key: key} ->
              %{
                "file" => file,
                "key" => key,
                "token" => Storage.Token.sign(:get, key, outlasting_ms: preparation_margin_ms())
              }
            end)
        }
    end
  end

  defp command_logs(%Job{}), do: %{}

  @doc """
  How long a job may run once assigned: an hour for a workflow job, a day for a conversation.
  The worker enforces it; the platform sizes the credentials it hands out by it, because a
  credential that lapses before the job does fails the job's last act rather than its first.
  """
  @spec wall_clock_ms(Job.t()) :: pos_integer()
  def wall_clock_ms(%Job{kind: :chat}), do: config(:chat_wall_clock_ms, :timer.hours(24))

  # A command's own timeout, which the worker enforces; the credentials it is handed are sized to
  # it the way an agent job's are sized to the hour.
  def wall_clock_ms(%Job{kind: :command, spec: %{"command" => %{"timeout_ms" => ms}}})
      when is_integer(ms),
      do: ms

  def wall_clock_ms(%Job{}), do: config(:wall_clock_ms, :timer.hours(1))

  @doc """
  How long a job may spend being prepared — cloned, its seed fetched and unpacked — before the
  worker starts its clock. A store token minted at assignment and spent after that has to
  outlive it as well: the transcript's `put`, and a conversation's history
  (`docs/design/storage.md` § Serving).
  """
  @spec preparation_margin_ms() :: non_neg_integer()
  # The hour here is an equivalent mutant: `config/config.exs` sets the key for every
  # environment, so this default is never read. It matches config so that a node that dropped
  # the key would get the same answer rather than a token that lapses mid-preparation.
  def preparation_margin_ms, do: config(:preparation_margin_ms, :timer.hours(1))

  # What only a conversation carries. `max_cost_usd` is what is left of the day, passed to the
  # harness as its per-turn ceiling: a chat has no state to take a budget from, and the daily cap
  # is the only one there is (`docs/design/conversations.md` § Spend).
  defp chat_assignment(%Job{kind: :chat} = job) do
    %{
      "idle_ms" => config(:chat_idle_ms, :timer.minutes(30)),
      "max_cost_usd" => remaining_today(),
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

  # Every billed invocation passes through `assign/2`, so this is where both caps are asked
  # rather than in the scheduler alone. A ticket over its own
  # allowance is stuck, which also takes it out of `pending/2` and stops the scheduler retrying it
  # every tick; the daily cap only pauses, and the ticket stays active and out of the queue.
  # A conversation has no ticket allowance and no workflow to take one from: the note says the
  # daily cap is its only ceiling, and this is where that is true rather than merely intended.
  # The harness is also given what is left of the day as its ceiling (`chat_assignment/1`), but
  # read once, at assignment, and never refreshed: spend by other jobs during the conversation
  # does not lower it, so the node's pause is the backstop (`docs/design/conversations.md`
  # § Spend).
  #
  # **A pause writes nothing here.** It used to append a `spend.paused` event, and this runs on
  # every scheduling pass for every pending job a worker was found for, so a paused node wrote
  # one per job every two seconds until midnight. The scheduler records it as the job's wait
  # reason instead, once per change (`record_wait/3`, `docs/design/provisioning.md` § The gate).
  defp spend_gate(%Job{kind: :chat}, _ticket) do
    case Spend.day_gate() do
      :ok -> :ok
      {:pause, _reason} -> {:error, {:spend_paused, :day}}
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

      {:pause, _reason} ->
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
    # Read from the log rather than stored on the row, because the log is already the
    # conversation (§ Shape) and a copy on the row would be a second one. A prompt of nil is a
    # reopen with nothing to answer, which the worker holds for the person's next message.
    opening = Conversations.opening(job.id)

    spec = %Spec{
      job_id: job.id,
      kind: :chat,
      branch: chat_branch(job),
      ticket: ticket && %{number: ticket.number, title: ticket.title},
      commit: ticket && ticket.base_commit,
      prompt: opening.prompt,
      replay: opening.replay,
      inputs: chat_inputs(job, ticket),
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
    {results, _logs} = Commands.results(job)

    spec = %{
      spec
      | may_invoke: Commands.remaining(job, spec.may_invoke),
        command_results: results
    }

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

  # A ticket chat gets every document on the ticket, which is more than any one of its jobs is
  # handed and is the point: it is for asking about, or fixing, the work in flight. A project chat
  # gets what it wrote itself. Every start of a conversation is cold and begins with `out/`
  # empty, so without this a reopened project chat could not see a document it wrote an hour ago,
  # while a ticket chat's came back as the ticket's (`docs/design/conversations.md` § Context).
  # Its proposals are its own too, and are left out: they are backlog, not documents, and an open
  # one is already in `tickets/index.md`.
  defp chat_inputs(%Job{} = chat, nil) do
    {:job, chat.id}
    |> Artifacts.latest_documents()
    |> Enum.reject(&Workflow.proposal?(&1.name))
    |> Enum.map(&as_input/1)
  end

  defp chat_inputs(%Job{}, %Ticket{id: ticket_id}) do
    ticket_id
    |> Artifacts.latest_documents()
    |> Enum.map(&as_input/1)
  end

  defp as_input(document),
    do: %Input{name: document.name, version: document.version, content: document.content}

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

  # -- waiting --------------------------------------------------------------------------------

  @doc """
  Records why a pending job was not placed, unless that is already what it says.

  One `job.waiting` event per *change* of reason, never one per pass: the scheduler asks every
  two seconds and `events` is append-only, so an event per ask would bury the job's history
  under one sentence (`docs/design/provisioning.md` § The gate). `reason` is what is compared;
  `text` is the sentence the operator reads, kept beside it so the log says what was shown.

  Compared with `current_wait/1`, the same reading the pages draw, so what counts as the
  current reason is decided once.
  """
  @spec record_wait(Job.t(), String.t(), String.t()) :: :ok
  def record_wait(%Job{} = job, reason, text) do
    case current_wait(job) do
      %Event{payload: %{"reason" => ^reason}} ->
        :ok

      _changed_or_first ->
        {:ok, event} =
          Events.append("job.waiting", :system, %{
            ticket_id: job.ticket_id,
            job_id: job.id,
            payload: %{"reason" => reason, "text" => text}
          })

        # Per job for a conversation's page, and per ticket for the ticket's timeline and the
        # job's own page, which is what each of them is subscribed to.
        Events.notify_job(job.id, event)
        if job.ticket_id, do: Events.notify(job.ticket_id)
        :ok
    end
  end

  @doc """
  Why a pending job is waiting: its latest `job.waiting` since it last started, or nil.

  **Since it last started**, because `job.started` is the first thing an assignment writes: a
  job that ran and came back to the queue — requeued, recovered, a conversation reopened — is
  waiting afresh, and what held it up before is history.

  **Nil for a job that is not pending**, whatever its log holds. A job can leave the queue
  without starting — the scheduler fails one that raised on its way to a worker — and its last
  wait is then not why it is anything.

  Not the job status `:waiting`, which is a job stopped on a question.
  """
  @spec current_wait(Job.t()) :: Event.t() | nil
  def current_wait(%Job{status: :pending, id: id}) do
    Repo.one(
      from e in Event,
        where: e.job_id == ^id and e.type in ["job.waiting", "job.started"],
        order_by: [desc: e.seq],
        limit: 1
    )
    |> case do
      %Event{type: "job.waiting"} = event -> event
      _started_or_never_waited -> nil
    end
  end

  def current_wait(%Job{}), do: nil

  @doc """
  Records one harness event against its job. Events arrive over the channel and are the
  timeline, not the contract: one that cannot be written is logged and dropped rather than
  failing anything.
  """
  @spec record_harness_event(String.t(), ForgeCore.Job.Event.t()) :: :ok
  def record_harness_event(job_id, %{type: "job.harness." <> _rest = type, payload: payload}) do
    {ticket_id, credential_id} =
      Repo.one(from j in Job, where: j.id == ^job_id, select: {j.ticket_id, j.credential_id}) ||
        {nil, nil}

    case Events.append(type, {:job, job_id}, %{
           ticket_id: ticket_id,
           job_id: job_id,
           payload: payload |> json_safe() |> stamp(type, credential_id)
         }) do
      {:ok, event} ->
        Events.notify_job(job_id, event)
        :ok

      {:error, changeset} ->
        Logger.warning("dropped harness event #{type}: #{inspect(changeset.errors)}")
    end
  end

  # **Only the harness's own namespace.** The rest of the log is the platform's record of what
  # happened, and is read back as such: a `job.finished` names the log a parent's next spec is
  # handed a token for, a `job.parked` the batch it resumes on, a `commands.decided` whether a
  # command state has been decided. A worker holding a job could write any of them for it.
  def record_harness_event(job_id, %{type: type}) do
    Logger.warning("dropped an event of type #{inspect(type)} for job #{job_id}: not a harness's")
  end

  defp json_safe(term), do: term |> Jason.encode!() |> Jason.decode!()

  # **A limit is an account's**, so a `rate_limit` event is stamped with the credential the job ran
  # on when it arrived — which is what `Forge.Credentials.limited/2` reads to know whose window it
  # describes. Stamped here and not looked up later through the job: a job whose credential was
  # replaced would otherwise move its old credential's window onto the new one
  # (`docs/design/credentials.md` § Rate limits are per credential).
  #
  # **Always overwritten, nil included.** The payload arrives from the worker, and one carrying a
  # `credential_id` of its own would otherwise mark somebody else's credential limited and steer
  # every pick away from it.
  defp stamp(payload, "job.harness.rate_limit", credential_id),
    do: Map.put(payload, "credential_id", credential_id)

  defp stamp(payload, _type, _credential_id), do: payload

  defp mark_started(%Job{} = job, %Worker{} = worker, credential) do
    now = DateTime.utc_now(:second)

    Multi.new()
    |> Multi.run(:row, fn repo, _changes -> still_pending(repo, job) end)
    |> Multi.update(
      :job,
      Job.progress_changeset(job, %{
        status: :running,
        worker_id: worker.id,
        credential_id: credential && credential.id,
        started_at: job.started_at || now
      })
    )
    |> Runs.open(job, worker, credential, now)
    |> put_credential_changed(job, credential)
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

      {:error, :row, changed, _changes} ->
        {:error, changed}

      # `Repo.transaction/1` reports a Multi failure as a four-tuple, which callers are not
      # promised and `Forge.Jobs.Scheduler` does not match.
      {:error, failed, reason, _changes} ->
        {:error, {failed, reason}}
    end
  end

  # **The row is still pending, whatever the struct says.** A pass holds the rows `pending/2` gave
  # it for as long as the pass takes, and a conversation can be closed in the meantime; writing
  # `running` from the old struct started a chat that had ended, on a branch already deleted.
  # Asked of the row, not compared with the struct, because pending is the only status a job is
  # started from. Locked, so a close waiting on the same row sees `running` and asks the worker
  # instead (`Forge.Conversations.close/2`).
  defp still_pending(repo, %Job{id: id}) do
    case repo.one!(from j in Job, where: j.id == ^id, lock: "FOR UPDATE", select: j.status) do
      :pending -> {:ok, :pending}
      now -> {:error, {:changed, now}}
    end
  end

  # A job keeps its credential while it is usable, so a different one here means the first was
  # revoked or taken out of the project mid-job — and the job's whole cost now lands on the new
  # one. That is the one inexactness in a credential's spend, and this event is how anyone reading
  # the figure later finds it (`docs/design/credentials.md` § How a job picks).
  defp put_credential_changed(multi, %Job{credential_id: nil}, _credential), do: multi
  defp put_credential_changed(multi, %Job{credential_id: id}, %{id: id}), do: multi

  defp put_credential_changed(multi, %Job{} = job, credential) do
    Events.log(multi, :credential_changed, "job.credential_changed", :system, %{
      ticket_id: job.ticket_id,
      job_id: job.id,
      payload: %{"from" => job.credential_id, "to" => credential.id}
    })
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
      # hear the same one twice. Keyed by the job: a job is recorded once. Not "is it running":
      # a worker that rejoins before its result is acked has the job re-queued under it
      # (`WorkerChannel.reconcile/2`), and the result that follows is still the run's answer.
      job.status == :finished -> settled(job, result.harness)
      # A command's result is its exit status and its log (`docs/design/commands.md`).
      job.kind == :command -> Commands.complete(job, ticket, result)
      # An agent that asked for commands: the run is over and the job is not.
      result.status == :parked -> park(job, ticket, result)
      # Before a failed resume: a resume refused by the limit never got going either, and must
      # keep the session it will resume once there is a credential to resume it on.
      stopped_by_limit(result) -> requeue_limited(job, ticket, result)
      resume_failed?(job, result) -> requeue_fresh(job, ticket, result)
      true -> record_and_follow_up(job, ticket, result)
    end
  end

  # **Stopped by its account's limit, not failed** (`docs/design/credentials.md` § A limit reached
  # mid-run): it ended in error, nobody killed it, and the last window report it saw blocks —
  # read by `Forge.Credentials`' rule for every other report. The report is the result's own and
  # not the timeline's, which is unacked.
  defp stopped_by_limit(%Result{status: :finished, killed: nil, outcome: :error} = result),
    do: Credentials.blocks_until(result.harness["rate_limit"], DateTime.utc_now())

  defp stopped_by_limit(%Result{}), do: nil

  # The run is recorded as any run is — its cost, its turns, its session, its transcript; its work
  # is already on the branch — and the job goes back to pending with its session rather than on
  # to its outcome. Its documents are not recorded: the job is not done, and its next run writes
  # them. Its machine is let go, because a wait may be a week; the pick decides on the next pass
  # whether it moves to a free credential or waits for the reset.
  defp requeue_limited(job, ticket, result) do
    report = result.harness["rate_limit"]
    cost = decimal(result.harness["cost_usd"])

    Multi.new()
    |> put_transcript(ticket, job, result)
    |> Multi.update(
      :job,
      Job.progress_changeset(job, Map.put(accounting(job, result), :status, :pending))
    )
    |> Runs.close(job.id, DateTime.utc_now(:second), cost)
    |> Tickets.put_progress(:ticket_cost, ticket, %{cost_usd: Decimal.add(ticket.cost_usd, cost)})
    |> Events.log(:event, "job.rate_limited", {:job, job.id}, %{
      ticket_id: ticket.id,
      job_id: job.id,
      payload: %{
        "credential_id" => job.credential_id,
        "rate_limit_type" => report["rate_limit_type"],
        "status" => report["status"],
        "resets_at" => report["resets_at"],
        "result" => result_payload(result)
      }
    })
    |> Repo.transaction()
    |> case do
      {:ok, %{job: job}} ->
        Tokens.revoke_for_job(job.id)
        Workers.release(job.worker_id)
        Events.notify(ticket.id)
        {:ok, job}

      {:error, step, reason, _} ->
        {:error, {step, reason}}
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
    |> Runs.close(job.id, DateTime.utc_now(:second))
    |> Events.log(:event, "job.resume_failed", {:job, job.id}, %{
      ticket_id: ticket.id,
      job_id: job.id,
      payload: result_payload(result)
    })
    |> Repo.transaction()
    |> case do
      {:ok, %{job: job}} ->
        # The fresh run mints its own (`assign/2`); see `requeue/2` for why this one goes now.
        Tokens.revoke_for_job(job.id)
        Events.notify(ticket.id)
        {:ok, job}

      {:error, step, reason, _} ->
        {:error, {step, reason}}
    end
  end

  # `docs/design/commands.md` § How an agent invokes. The run is recorded as any run is — its cost,
  # its turns, its session, its transcript — and nothing it wrote is collected: it is not done.
  # What it asked for is decided against its grant, the allowed invocations become command jobs
  # at the commit it pushed, and the job parks on them. With nothing to run it goes straight back
  # to pending, with only the refusals to read, because a job parked on nothing is never woken.
  defp park(job, ticket, %Result{} = result) do
    workflow = Tickets.workflow(ticket)
    decided = Commands.decide(job, spec(job), workflow, result)
    runs? = Enum.any?(decided, &match?({:run, _invocation}, &1))
    batch = Ecto.UUID.generate()
    cost = decimal(result.harness["cost_usd"])

    with {:ok, at} <- parked_at(ticket, result) do
      # Once per run, under the row's lock: a parked result re-sent after its ack was lost would
      # otherwise park the job again — a second batch of commands, its cost counted twice. Not
      # by status, which a park with nothing to run has already put back to `pending`.
      Multi.new()
      |> Multi.run(:running, fn repo, _changes -> unparked_run(repo, job.id) end)
      |> put_transcript(ticket, job, result)
      |> Multi.update(
        :job,
        Job.progress_changeset(
          job,
          Map.put(accounting(job, result), :status, if(runs?, do: :parked, else: :pending))
        )
      )
      |> Runs.close(job.id, DateTime.utc_now(:second), cost)
      |> Tickets.put_progress(:ticket_cost, ticket, %{
        cost_usd: Decimal.add(ticket.cost_usd, cost)
      })
      |> Commands.put_invoked(ticket, workflow, job, decided, at, batch)
      |> Events.log(:event, "job.parked", {:job, job.id}, fn changes ->
        %{
          ticket_id: ticket.id,
          job_id: job.id,
          payload: %{
            "batch" => batch,
            "commit" => at,
            "invocations" => Commands.invocation_entries(decided, at, changes),
            "result" => result_payload(result)
          }
        }
      end)
      |> put_immediate_resume(runs?, job, batch)
      |> Repo.transaction()
      |> case do
        {:ok, %{job: job}} ->
          Tokens.revoke_for_job(job.id)
          Workers.release(job.worker_id)
          Events.notify(ticket.id)
          {:ok, job}

        {:error, :running, :already_recorded, _changes} ->
          {:error, :already_recorded}

        {:error, step, reason, _changes} ->
          {:error, {step, reason}}
      end
    end
  end

  # A run starts with `job.started` (`mark_started/3`) and parks at most once, so a `job.parked`
  # later than the latest start is this run's, already recorded.
  defp unparked_run(repo, job_id) do
    job = repo.one!(from j in Job, where: j.id == ^job_id, lock: "FOR UPDATE")

    latest =
      repo.all(
        from e in Event,
          where: e.job_id == ^job_id and e.type in ["job.started", "job.parked"],
          order_by: [desc: e.seq],
          limit: 1,
          select: e.type
      )

    case latest do
      ["job.parked"] -> {:error, :already_recorded}
      _started_or_never -> {:ok, job}
    end
  end

  # The commit the worker pushed before it parked, which is the one its commands run at. A worker
  # that did not say is answered from the branch, which it pushed to before it reported.
  defp parked_at(_ticket, %Result{commit: commit}) when is_binary(commit), do: {:ok, commit}

  defp parked_at(ticket, %Result{}) do
    ticket
    |> Tickets.project_of()
    |> Projects.repo_path()
    |> Git.resolve("refs/heads/" <> ticket.branch)
  end

  # A park with nothing to run is back in the queue in the same update that parks it, and says
  # which batch it resumes on (`Commands.results/1`).
  defp put_immediate_resume(multi, true = _runs?, _job, _batch), do: multi

  defp put_immediate_resume(multi, false, job, batch),
    do: Commands.put_resumed_event(multi, job, batch)

  defp record_and_follow_up(job, ticket, result) do
    case record(job, ticket, result) do
      {:ok, %{job: job, ticket_cost: ticket}} -> followed_up(job, ticket, result)
      # Finished between the read in `complete/2` and the lock below: its ticket was cancelled.
      {:error, {:still_live, :finished}} -> settled(get!(job.id), result.harness)
      {:error, _reason} = error -> error
    end
  end

  defp followed_up(job, ticket, result) do
    case job.status do
      :finished ->
        # The worktree is the worker's to throw away, and it already has. What is left here
        # is the credential, which is no good to anyone once the job is over, and the
        # worker's memory, which the next job wants back.
        Tokens.revoke_for_job(job.id)
        Workers.release(job.worker_id)
        follow_up(ticket, job, result)

      :waiting ->
        # Stopped on a question: the run is over, and the answer resumes it with a new one.
        # The question is pushed by `Forge.Push.Watch`, which hears the notice below and
        # pushes whatever on the ticket has started waiting — this is one of those.
        Tokens.revoke_for_job(job.id)
    end

    Events.notify(ticket.id)
    {:ok, job}
  end

  defp record(job, ticket, result) do
    Multi.new()
    # Locked and re-read: `Engine.cancel/2` locks the same row, so a result and a cancel cannot
    # both win. Without it a result read as running before the cancel committed was recorded after
    # it, and moved the cancelled ticket on to its next state. No test reaches the refusal — it
    # needs the cancel to commit between two statements of this process — so `settled/2`'s own
    # tests are what cover what happens next.
    |> Multi.run(:still_live, fn repo, _changes ->
      case repo.one!(from j in Job, where: j.id == ^job.id, lock: "FOR UPDATE", select: j.status) do
        :finished -> {:error, :finished}
        status -> {:ok, status}
      end
    end)
    |> put_documents(ticket, job, result)
    |> put_blobs(ticket, job, result)
    |> put_proposals(job, result)
    |> put_transcript(ticket, job, result)
    |> put_changeset(ticket, job, result)
    |> Multi.update(:job, Job.progress_changeset(job, progress_attrs(job, result)))
    |> Runs.close(job.id, DateTime.utc_now(:second), decimal(result.harness["cost_usd"]))
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

  # A report for a job already finished. For a job its ticket's cancel ended (`Engine.cancel/2`) it
  # is the machine saying it stopped: what that last run spent is recorded — the cancel closed the
  # run with nothing, and spend is read from runs — and the machine is released, which nothing else
  # does for it. Idempotent, because a report is re-sent until it is acked: the run's cost is set,
  # not added, and the job and ticket move by the difference. Any other finished job's report is a
  # re-send, and changes nothing.
  defp settled(%Job{status: :finished, outcome: :cancelled} = job, harness) do
    cost = decimal((harness || %{})["cost_usd"])
    before = latest_run_cost(job.id)
    delta = Decimal.sub(cost, before)
    ticket = job.ticket_id && Tickets.get!(job.ticket_id)

    Multi.new()
    |> Runs.cost(job.id, cost)
    |> Multi.update(
      :job,
      Job.progress_changeset(job, %{cost_usd: Decimal.add(job.cost_usd, delta)})
    )
    |> then(fn multi ->
      if ticket,
        do:
          Tickets.put_progress(multi, :ticket_cost, ticket, %{
            cost_usd: Decimal.add(ticket.cost_usd, delta)
          }),
        else: multi
    end)
    |> Repo.transaction()

    Workers.release(job.worker_id)
    {:error, :already_recorded}
  end

  defp settled(%Job{}, _harness), do: {:error, :already_recorded}

  defp latest_run_cost(job_id) do
    Repo.one(
      from r in Forge.Jobs.Run,
        where: r.job_id == ^job_id,
        order_by: [desc: r.started_at, desc: r.inserted_at],
        limit: 1,
        select: r.cost_usd
    ) || Decimal.new(0)
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
    case get!(job_id) do
      # A failure reported twice, or after the result: finished is finished, and a second
      # follow-up would run the engine — or wake a command's parent — over a job already done.
      %Job{status: :finished} -> {:error, :already_recorded}
      job -> fail_job(job, reason)
    end
  end

  defp fail_job(job, reason) do
    ticket = job.ticket_id && Tickets.get!(job.ticket_id)
    attrs = fail_attrs(job)

    Multi.new()
    |> Multi.update(:job, Job.progress_changeset(job, attrs))
    |> Runs.close(job.id, DateTime.utc_now(:second))
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

        # A command that failed is finished all the same: its batch is looked at as for any other.
        if job.kind == :command, do: Commands.follow_up(job)

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
  #
  # **And not for a run that ended in `error`.** Its proposals were written beside work that was
  # thrown away — a refinement that did not parse, say — so they point at scope nobody was shown,
  # and a person was asked to decide them anyway. They are named in an event rather than dropped
  # in silence, and a run of the state again proposes afresh (`ticket-proposals.md` § A failed
  # job proposes nothing).
  defp put_proposals(multi, job, %Result{status: :finished, outcome: :error} = result) do
    names = Enum.sort(Map.keys(result.proposals) ++ Map.keys(result.invalid_proposals))

    if names == [] do
      multi
    else
      Events.log(multi, :proposals_withheld, "proposals.withheld", :system, %{
        ticket_id: job.ticket_id,
        job_id: job.id,
        payload: %{"files" => names, "reason" => "the job ended in error"}
      })
    end
  end

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

  # A finished run's groups of files; a waiting one's are still in its `out/` for the resume.
  defp put_blobs(multi, ticket, job, %Result{status: :finished} = result),
    do: Blobs.put(multi, ticket.id, job, spec(job), result)

  defp put_blobs(multi, _ticket, _job, %Result{}), do: multi

  # The transcript is in the store before the worker sends its result: it uploaded it with a
  # token for exactly that key. What crosses the wire is the key, and the platform asks the
  # store what it holds rather than trusting a size or a hash the worker reported.
  #
  # A transcript that never arrived is logged and skipped rather than failing the job. The
  # documents and the outcome are the contract; the conversation never was.
  # Only one of this job's own keys (`Storage.Key.job?/2`): the worker names the key, and one it
  # names from somewhere else — another project's transcript, a seed — would be recorded on this
  # ticket as this job's, readable by everyone who can read the ticket.
  defp put_transcript(multi, ticket, job, %Result{transcript: key}) when is_binary(key) do
    name = "transcript-#{job.state}-#{job.attempt}.jsonl"

    case Storage.Key.job?(key, job.id) && Storage.stat(key) do
      false ->
        Logger.warning("job #{job.id} reported transcript #{key}, which is not one of its keys")
        multi

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

  # What any run adds to its job, however it ended.
  defp accounting(job, %Result{} = result) do
    %{
      turns: job.turns + (result.harness["turns"] || 0),
      cost_usd: Decimal.add(job.cost_usd, decimal(result.harness["cost_usd"])),
      harness_session_id: result.harness["session_id"] || job.harness_session_id
    }
  end

  defp progress_attrs(job, %Result{} = result) do
    base = accounting(job, result)

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
      "harness" => json_safe(result.harness),
      "invalid_blobs" => result.invalid_blobs,
      # What was wrong with each document that did not parse, as text. The reason names them in
      # one line; this keeps each one's errors whole (`claude-code-events.md` § Naming the failure).
      "invalid" =>
        Map.new(result.invalid, fn {name, why} -> {name, ForgeCore.Error.to_text(why)} end)
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
  @spec hibernate(String.t(), String.t() | nil, String.t() | nil, map() | nil) ::
          {:ok, Job.t()} | {:error, term()}
  def hibernate(job_id, commit, reason, result \\ nil) do
    job = get!(job_id)

    cond do
      # A re-sent report.
      job.status == :hibernated ->
        {:ok, job}

      # A job ended under the worker — its ticket cancelled (`Engine.cancel/2`) — whose machine is
      # only now saying it stopped. Recording it would make a cancelled ticket's job resumable
      # again; what the run spent is settled and the machine released instead.
      job.status == :finished ->
        settled(job, (result || %{})["harness"])
        {:ok, job}

      true ->
        hibernate_running(job, commit, reason)
    end
  end

  defp hibernate_running(job, commit, reason) do
    Multi.new()
    |> Multi.update(:job, Job.progress_changeset(job, %{status: :hibernated}))
    |> Runs.close(job.id, DateTime.utc_now(:second))
    |> Events.log(:event, "job.hibernated", {:job, job.id}, %{
      ticket_id: job.ticket_id,
      job_id: job.id,
      payload: %{"commit" => commit, "reason" => reason}
    })
    |> Repo.transaction()
    |> case do
      {:ok, %{job: job}} ->
        # The worker pushed before it said so, and a resume is a new assignment with a new
        # credential — for a conversation, a day's worth of one (`requeue/2`).
        Tokens.revoke_for_job(job.id)
        Events.notify(job.ticket_id)
        {:ok, job}

      {:error, step, reason, _changes} ->
        {:error, {step, reason}}
    end
  end

  @doc """
  Puts a job back in the queue without recording a result: the run it was having is gone.
  Used when a worker rejoins without a job the platform believes it is running, and when a
  worker is lost or retired.

  **The run's git credential goes with it.** The next assignment mints its own, and the old one
  lives the job's whole wall clock — a day, for a conversation — so a machine that is only
  partitioned, not gone, could otherwise go on pushing to the branch after its job was handed to
  somebody else. The same holds wherever a run stops without the job ending — `recover/0`,
  `hibernate/3`, a failed resume, a stop on a question — and each of them revokes it too.
  """
  @spec requeue(String.t(), atom()) :: {:ok, Job.t()} | {:error, term()}
  def requeue(job_id, reason) do
    job = get!(job_id)

    Multi.new()
    |> Multi.update(:job, Job.progress_changeset(job, %{status: interrupted_status(job)}))
    |> Runs.close(job.id, DateTime.utc_now(:second))
    |> Events.log(:event, "job.interrupted", :system, %{
      ticket_id: job.ticket_id,
      job_id: job.id,
      payload: %{"reason" => to_string(reason)}
    })
    |> Repo.transaction()
    |> case do
      {:ok, %{job: job}} ->
        Tokens.revoke_for_job(job.id)
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
        |> Runs.close(job.id, DateTime.utc_now(:second))
        |> Events.log(:event, "job.interrupted", :system, %{
          ticket_id: job.ticket_id,
          job_id: job.id
        })
        |> Repo.transaction()

      # Whatever machine was running it may still be up and reachable; see `requeue/2`.
      Tokens.revoke_for_job(job.id)
      Events.notify(job.ticket_id)
    end)

    Commands.recover()
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
