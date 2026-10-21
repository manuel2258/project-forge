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
    Secrets,
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

  # The worker protocols commands, and then questions as a headline and a sentence, arrived in
  # (`docs/design/worker-channel.md` § Versions). Facts about when, fixed once true.
  @commands_protocol 2
  @questions_protocol 3
  @integration_protocol 5
  @secrets_protocol 6
  @optional_outputs_protocol 7

  # How many of the merges that landed on the default branch since a ticket's base an integrating
  # job is told about by name; the rest are counted (`docs/design/job-prompt.md` § Integrating the
  # default branch).
  @landed_shown 20

  # How much of a command's log a state reading it as an input is handed: its first and last bytes,
  # a quarter of a document's size in all (`docs/design/workflow-grammar-v1.md` § Inputs).
  @log_input_head 64 * 1024
  @log_input_tail 192 * 1024

  # -- creation -------------------------------------------------------------------------------

  @doc """
  Adds the creation of a pending job for `state_name` to `multi` under `key`.

  `entered` is how the ticket came into the state — `%{"from", "outcome", "by", "comment"}` from
  the transition that is creating the job — and nil for the ticket's first state. It goes into the
  spec so the job is told why it is here (`docs/design/job-prompt.md` § How the job arrived).

  `came_back: true` says a transition is creating the job, as opposed to a person asking for the
  state again. The engine passes it on every transition, a state's first entry included, and
  whether there is anything to come back to is `forkable/4`'s: a new attempt forks its
  predecessor's harness session when that one finished with an outcome it declared, left a
  session to fork, and was given the same instructions (`docs/design/claude-code-events.md`
  § Resume).
  """
  @spec put_create(
          Multi.t(),
          term(),
          Ticket.t(),
          Workflow.t(),
          String.t(),
          map() | nil,
          keyword()
        ) ::
          Multi.t()
  def put_create(
        multi,
        key,
        %Ticket{} = ticket,
        %Workflow{} = workflow,
        state_name,
        entered \\ nil,
        opts \\ []
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
            resume_from_id:
              if(Keyword.get(opts, :came_back, false),
                do: forkable(repo, ticket.id, state_name, spec)
              ),
            spec: spec |> Spec.to_json() |> Jason.decode!(),
            memory_max: resources.memory,
            cores: resources.cores,
            secret_names: Workflow.state(workflow, state_name).secrets
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
         ticket: %{number: ticket.number, title: ticket.title, ticket_type: ticket.ticket_type},
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
         optional: state.optional,
         outcomes: state.outcomes,
         permitted_children: [],
         integration: integration(workflow, state_name, project)
       }}
    end
  end

  # Only the branch's name is stored: what conflicted and what landed are read when the job runs
  # (`runtime_spec/2`), so a job that waited reads the state of things then.
  defp integration(workflow, state_name, project) do
    if Workflow.integrating?(workflow, state_name),
      do: %{"default_branch" => project.default_branch}
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
      version -> input_version(name, version)
    end
  end

  defp input_version(name, %{content: content} = version) when is_binary(content),
    do: {:ok, %Input{name: name, version: version.version, content: content}}

  # A command's log, the one blob a state may read (`docs/design/workflow-grammar-v1.md` § Inputs).
  # Inlined like a document, so the worker needs nothing new to hand it over, and cut to its two
  # ends so a runaway build cannot make every later job's spec the size of its log. A log the
  # store cannot give back is an input not written: such an input is always optional.
  defp input_version(name, version) do
    case Artifacts.excerpt(version, @log_input_head, @log_input_tail) do
      {:ok, text} ->
        {:ok, %Input{name: name, version: version.version, content: text}}

      {:error, reason} ->
        Logger.warning("could not read #{name} version #{version.version}: #{inspect(reason)}")
        {:error, {:missing_input, name}}
    end
  end

  # The previous attempt of the state, if it is one a new attempt may fork: it finished having
  # converged — its agent declared an outcome — and left a session and the file to restore it
  # from. An attempt that ended any other way is not carried on from.
  #
  # **And it was given the same instructions.** A fork remembers the prompt its session began
  # with and is told its instructions are the ones it was given, so a re-pin that moved the
  # state's prompt, or a platform whose preamble changed, starts the new attempt fresh instead.
  #
  # `status == :finished` is an equivalent mutant: a row carries an outcome only once finished
  # (`Job.progress_changeset/2`). Kept for what it says.
  defp forkable(repo, ticket_id, state_name, %Spec{attempt: attempt} = spec) do
    from(j in previous_attempt(ticket_id, state_name, attempt),
      where:
        j.status == :finished and j.outcome == :converged and
          not is_nil(j.harness_session_id) and not is_nil(j.session_blob),
      select: j.id
    )
    |> given_the_same(spec)
    |> repo.one()
  end

  # The agent's attempt of `state_name` before attempt `attempt`, the one a fork carries on from
  # and a second review reads what changed since. An agent's own, not a command's: the commands
  # it invokes share its state's name and number their own attempts (`next_attempt/3`).
  defp previous_attempt(ticket_id, state_name, attempt) do
    from j in Job,
      where:
        j.ticket_id == ^ticket_id and j.state == ^state_name and j.kind == :workflow and
          j.attempt == ^(attempt - 1)
  end

  defp given_the_same(query, %Spec{prompt: prompt, preamble_hash: preamble}) do
    from j in query,
      where:
        fragment("(? ->> 'prompt') IS NOT DISTINCT FROM ?", j.spec, ^prompt) and
          fragment("(? ->> 'preamble_hash') IS NOT DISTINCT FROM ?", j.spec, ^preamble)
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
         {:ok, secrets} <- secrets_for(job, worker),
         {:ok, token, _row} <- Tokens.issue_for_job(job, ticket, project),
         {:ok, started} <- mark_started(job, worker, credential),
         assignment =
           started
           |> assignment(ticket, project, token)
           |> Map.put("credential", wire)
           |> put_secrets(secrets),
         :ok <- Workers.push(worker.id, {:assign, assignment}) do
      {:ok, _worker} = Workers.busy(worker)
      log_backlog(started, assignment)
      log_secrets(started, secrets)
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

    with {:ok, secrets} <- secrets_for(job, worker),
         {:ok, token, _row} <- Tokens.issue_for_job(job, ticket, project),
         {:ok, started} <- mark_started(job, worker, nil),
         assignment =
           started |> command_assignment(ticket, project, token) |> put_secrets(secrets),
         :ok <- Workers.push(worker.id, {:assign, assignment}) do
      {:ok, _worker} = Workers.busy(worker)
      log_secrets(started, secrets)
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

  # **The job's secrets, resolved again**, as the credential is: the scheduler looked before it went
  # for a machine, and this is the answer that counts (`docs/design/secrets.md` § Delivery). A
  # workflow job or a command naming one deleted since goes back to pending, and the next pass
  # sticks its ticket. A conversation holds what is still set, and its run's record names what is
  # not, which its page shows (§ Conversations).
  defp secrets_for(%Job{secret_names: []}, _worker), do: {:ok, nil}

  defp secrets_for(%Job{} = job, worker) do
    case Secrets.resolve(job.project_id, job.secret_names) do
      {_found, [_ | _] = missing} when job.kind != :chat ->
        {:error, {:no_secret, missing}}

      {found, gone} ->
        case Secrets.for_wire(found, worker, job.id) do
          {:ok, sealed} ->
            {:ok, %{sealed: sealed, held: Secrets.held(found), gone: gone}}

          {:error, {:unreadable, names}} ->
            Logger.error(
              "secrets #{inspect(names)} cannot be decrypted on this node; set them again"
            )

            {:error, {:secrets_unreadable, names}}
        end
    end
  end

  # Only when the job names any: a job that names none sends what it always sent, so a protocol 4
  # worker reads its assignment as before (`Forge.Jobs.protocol/1`).
  defp put_secrets(assignment, nil), do: assignment

  # The spec names what the run holds and, for a conversation, what it was opened with that has
  # been deleted since — so the manifest, or a resumed conversation's continuation, tells the agent
  # exactly what is in its environment and what is not any more.
  defp put_secrets(assignment, %{sealed: sealed, held: held, gone: gone}) do
    assignment
    |> Map.put("secrets", sealed)
    |> put_in(["spec", "secrets"], Enum.map(held, & &1["name"]))
    |> put_in(["spec", "secrets_gone"], gone)
  end

  # What this run held, by id and version, and what a conversation named that is no longer set.
  # Never a value: the event log is read by every member.
  defp log_secrets(_job, nil), do: :ok

  defp log_secrets(%Job{} = job, %{held: held, gone: gone}) do
    {:ok, _event} =
      Events.append("job.secrets", :system, %{
        ticket_id: job.ticket_id,
        job_id: job.id,
        payload: %{"held" => held, "gone" => gone}
      })

    :ok
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
  The worker protocol a job needs, or 0 for any.

  - **An agent — a workflow job or a conversation — needs protocol 3.** Its questions are a
    headline and a sentence, and the release that composes its prompt and corrects its outputs is
    what teaches and checks that. A release from before it teaches `options: [a, b]` and
    `default:`, which this platform's parser refuses when it records the document — so the job's
    result could never be recorded, and a chat's question would reach the page as prose
    (`docs/design/job-prompt.md` § Output format).
  - **A command needs protocol 2**, which commands and groups of files arrived in: a release from
    before them would run a command's spec as an agent job's (`docs/design/commands.md`
    § Worker pools). Its output is a script's, not an agent's, so the questions change asks
    nothing more of it.
  - **An integrating job needs protocol 5**: a release from before it neither fetches the default
    branch nor keeps the merge through its squash, and would push a resolution whose next check
    finds the same conflict (`docs/design/worker-channel.md` § Versions).
  - **A job that names a secret needs protocol 6**, whatever its kind: a release from before it
    ignores the assignment's `secrets` and would run the job without them, where it should not
    run at all (`docs/design/secrets.md` § Delivery). A job that names none asks nothing more.
  - **A job whose state declares a presentation or an optional output needs protocol 7**: the
    worker is what composes the manifest, collects `out/` and decides the outcome, and a release
    from before these does all three wrong. It strips no marker, so it names
    `out/presentation.md!` in the manifest and collects the file under that name, which the
    platform then records as an approvable *document*; and its manifest says every declared
    document is required, because the note that says otherwise is new with this, so it nags for
    an optional one the agent skipped and ends the job `error` on a state with no `error` edge
    (`docs/design/worker-channel.md` § Versions). A state that declares neither asks nothing more.
  """
  @spec protocol(Job.t()) :: non_neg_integer()
  def protocol(%Job{} = job),
    do: Enum.max([kind_protocol(job), secrets_protocol(job), outputs_protocol(job)])

  defp secrets_protocol(%Job{secret_names: [_ | _]}), do: @secrets_protocol
  defp secrets_protocol(%Job{}), do: 0

  # Read from the stored spec rather than the workflow, as the integrating clause is: the spec is
  # what the worker is handed, and a workflow edited since cannot change what this job needs.
  defp outputs_protocol(%Job{kind: :workflow} = job) do
    spec = spec(job)

    if spec.optional != [] or Enum.any?(spec.produces, &Workflow.presentation?/1),
      do: @optional_outputs_protocol,
      else: 0
  end

  defp outputs_protocol(%Job{}), do: 0

  defp kind_protocol(%Job{kind: :command}), do: @commands_protocol

  defp kind_protocol(%Job{kind: :workflow} = job) do
    if spec(job).integration, do: @integration_protocol, else: @questions_protocol
  end

  defp kind_protocol(%Job{kind: :chat}), do: @questions_protocol
  defp kind_protocol(%Job{}), do: 0

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
      "git" =>
        %{
          "url" => Url.for_worker(project),
          "token" => git_token,
          "branch" => branch(job, ticket),
          "base" => ticket && ticket.base_commit
        }
        |> put_default_branch(job),
      "store" =>
        %{
          "transcript_key" => transcript,
          # Used when the job stops, not when it starts, so it lives as long as the job may: its
          # preparation and then its whole clock, which the worker starts only once the clone and
          # the seed are ready (`docs/design/storage.md` § Serving).
          "transcript_token" =>
            Storage.Token.sign(:put, transcript,
              outlasting_ms: wall_clock_ms(job) + preparation_margin_ms()
            )
        }
        |> Map.merge(session_upload(job)),
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
      "wall_clock_ms" => wall_clock_ms(job)
    }
    |> Map.merge(resume_keys(job))
    |> Map.merge(chat_assignment(job))
    |> Map.merge(command_logs(job))
    |> Map.merge(group_outputs(job))
  end

  # Where the run's harness session goes, one file per upload under a prefix of its own — a
  # conversation uploads after every turn — with a token that lives as long as the run may
  # (`docs/design/claude-code-events.md` § Resume). A command has no harness, and its
  # assignment is `command_assignment/4`'s, which asks for none.
  defp session_upload(%Job{} = job) do
    prefix = session_prefix(job.id) <> Storage.Key.nonce() <> "/"

    %{
      "session_prefix" => prefix,
      "session_token" =>
        Storage.Token.sign_prefix(prefix,
          outlasting_ms: wall_clock_ms(job) + preparation_margin_ms()
        )
    }
  end

  # What this run resumes, if anything: `resume_session`, whether to fork it, and the session file
  # to put back, with a token to fetch it that lives the preparation margin, as a command log's
  # does. `resume_session` is always a key of the assignment, nil when there is nothing to resume.
  defp resume_keys(job) do
    case resume_source(job) do
      {id, blob, fork} ->
        %{"resume_session" => id, "fork_session" => fork}
        |> Map.merge(session_ref(id, blob))

      nil ->
        %{"resume_session" => nil}
    end
  end

  defp session_ref(id, %{"key" => key} = blob) do
    %{
      "session" => %{
        "key" => key,
        "token" => Storage.Token.sign(:get, key, outlasting_ms: preparation_margin_ms()),
        "id" => id,
        "version" => blob["version"]
      }
    }
  end

  defp session_ref(_id, _none), do: %{}

  @doc """
  The session a run of `job` resumes, as `{session_id, session_blob, fork?}`, or nil
  (`docs/design/claude-code-events.md` § Resume):

  - a job's own session, when it has one — a resume after a question, a park, a rate limit;
  - otherwise the previous attempt's, forked, when the job came back to a state that attempt
    finished in (`jobs.resume_from_id`);
  - a conversation's own, forked, and only when a file was carried: a reopen is a new process
    whose turns are numbered from one again, and nothing re-queues a conversation whose resume
    finds nothing, so it never resumes on the chance the machine holds the session.
  """
  @spec resume_source(Job.t()) :: {String.t(), map() | nil, boolean()} | nil
  def resume_source(%Job{kind: :chat, harness_session_id: id, session_blob: %{} = blob})
      when is_binary(id),
      do: {id, blob, true}

  def resume_source(%Job{kind: :chat}), do: nil

  def resume_source(%Job{harness_session_id: id, session_blob: blob}) when is_binary(id),
    do: {id, blob, false}

  # `%{} = blob` is an equivalent mutant here: `resume_from_id` is set only to an attempt that had
  # a session file (`forkable/4`), and nothing clears a workflow job's afterwards.
  def resume_source(%Job{resume_from_id: from}) when is_binary(from) do
    case Repo.get(Job, from) do
      %Job{harness_session_id: id, session_blob: %{} = blob} when is_binary(id) ->
        {id, blob, true}

      _gone ->
        nil
    end
  end

  def resume_source(%Job{}), do: nil

  # Where a job's groups of files go, for a job that declares one (`Forge.Jobs.Blobs`). Uploaded
  # when the job stops, so the token lives as long as a transcript's does.
  defp group_outputs(%Job{kind: :chat}), do: %{}

  defp group_outputs(%Job{} = job),
    do: Blobs.outputs(job, spec(job), wall_clock_ms(job) + preparation_margin_ms())

  # A resume after commands is handed each command's log, by key and a `get` token, to fetch into
  # `$FORGE_JOB/commands/` before it starts (`docs/design/job-prompt.md` § Commands), and so is a
  # job entered from a command state, on every run (§ How the job arrived). Spent while the
  # worktree is prepared, so it lives the preparation margin and not the clock.
  defp command_logs(%Job{kind: :workflow} = job) do
    {_results, own} = Commands.results(job)
    {_entered, entered} = Commands.entered(job)

    case entered ++ own do
      [] ->
        %{}

      logs ->
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
    {entered, _logs} = Commands.entered(job)

    spec = %{
      spec
      | may_invoke: Commands.remaining(job, spec.may_invoke),
        command_results: results,
        entered_commands: entered,
        previous_changeset: previous_changeset(job, spec),
        integration: integration_now(spec.integration, ticket)
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

  # An integrating job's checkout fetches the default branch too; every other job's does not
  # (`docs/design/git-hosting.md` § The job's own git).
  defp put_default_branch(git, %Job{kind: :workflow} = job) do
    case spec(job).integration do
      %{"default_branch" => branch} -> Map.put(git, "default_branch", branch)
      nil -> git
    end
  end

  defp put_default_branch(git, %Job{}), do: git

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
  # gets what it wrote itself. Every start of a conversation begins with `out/` empty, a resumed
  # reopen included, so without this a reopened project chat could not see a document it wrote an
  # hour ago,
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
    workflow = Tickets.workflow(ticket)
    {cost, binding} = Spend.effective_cost(spec.budget.cost, ticket, workflow)
    spec = put_allowance(spec, ticket, workflow)

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

      budget =
        Map.merge(spec.budget, %{
          cost: cost,
          declared: spec.budget.cost,
          lowered_by: Atom.to_string(binding)
        })

      %{spec | budget: budget}
    end
  end

  # The commit the previous attempt of this state read as its `changeset`, for a job that reads one:
  # read from that job's own stored spec, which pinned it when it was made.
  defp previous_changeset(%Job{kind: :workflow, attempt: n} = job, %Spec{inputs: inputs})
       when is_integer(n) and n > 1 do
    with true <- Enum.any?(inputs, &(&1.name == Workflow.changeset_artifact())),
         %Job{spec: %{"inputs" => previous}} <-
           Repo.one(previous_attempt(job.ticket_id, job.state, n)),
         %{"version" => sha} <-
           Enum.find(previous, &(&1["name"] == Workflow.changeset_artifact())) do
      sha
    else
      _none -> nil
    end
  end

  defp previous_changeset(%Job{}, _spec), do: nil

  # What an integrating job is told, read when it runs: the default branch's head, what the
  # ticket's latest conflict was, and the merges that landed since its base, first-parent and
  # newest first (`docs/design/job-prompt.md` § Integrating the default branch).
  defp integration_now(nil, _ticket), do: nil

  defp integration_now(%{"default_branch" => branch} = stored, %Ticket{} = ticket) do
    repo = ticket |> Tickets.project_of() |> Projects.repo_path()

    conflict =
      case Events.latest_for_ticket(ticket.id, "ticket.merge_conflicted") do
        %{payload: payload} -> payload
        nil -> %{}
      end

    {head, landed} =
      with {:ok, head} <- Git.resolve(repo, "refs/heads/" <> branch),
           {:ok, log} <- Git.log(repo, ticket.base_commit, head, first_parent: true) do
        {head, log}
      else
        _unreadable -> {nil, []}
      end

    Map.merge(stored, %{
      "head" => head,
      "base" => ticket.base_commit,
      "paths" => conflict["paths"] || [],
      "changeset" => conflict["changeset"],
      "merges" =>
        landed
        |> Enum.take(@landed_shown)
        |> Enum.map(&%{"sha" => &1.sha, "subject" => &1.subject}),
      "more" => max(length(landed) - @landed_shown, 0)
    })
  end

  # What the ticket has left of its allowance, beside the job's own budget: a job weighing whether
  # another round is worth it was left to guess at the one figure that decides it
  # (`docs/design/capacity.md` § Spend caps).
  defp put_allowance(spec, ticket, %Workflow{limits: %{ticket_cost: cap}} = workflow)
       when is_number(cap) do
    left = ticket |> Spend.ticket_remaining(workflow) |> Decimal.to_float()
    %{spec | budget: Map.merge(spec.budget, %{ticket_left: left, ticket_limit: cap})}
  end

  defp put_allowance(spec, _ticket, _workflow), do: spec

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
      payload: %{"resume" => resume_source(job) != nil}
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

  # A job's run that never got going ends in `error`, having written nothing; one that did not end
  # in `error` is recorded as whatever it was.
  defp resume_failed?(%Job{} = job, %Result{} = result),
    do: resume_refused?(job, result) and result.outcome == :error

  @doc """
  Whether a run asked to resume a session never got going: the harness exited on its own and
  never said which model it runs, which is how it refuses a session it cannot find
  (`docs/measurements.md` § Session resume). A fork is a resume too: the previous attempt's
  session, which the machine may not find.

  A job's is re-queued fresh (`docs/design/claude-code-events.md` § Resume). A conversation's
  session is forgotten, so that the next reopen starts cold rather than being refused again
  (`Forge.Conversations.ended/4`).
  """
  @spec resume_refused?(Job.t(), Result.t()) :: boolean()
  def resume_refused?(%Job{} = job, %Result{} = result) do
    resume_source(job) != nil and result.status == :finished and result.killed == nil and
      result.harness["model"] == nil
  end

  defp requeue_fresh(job, ticket, result) do
    Multi.new()
    |> put_transcript(ticket, job, result)
    |> Multi.update(
      :job,
      Job.progress_changeset(job, %{
        status: :pending,
        harness_session_id: nil,
        resume_from_id: nil
      })
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
      {:ok, %{job: job, ticket_cost: ticket} = changes} ->
        followed_up(job, moved_base(ticket, changes[:base]), result)

      # Finished between the read in `complete/2` and the lock below: its ticket was cancelled.
      {:error, {:still_live, :finished}} ->
        settled(get!(job.id), result.harness)

      {:error, _reason} = error ->
        error
    end
  end

  # The ticket the follow-up reads is the one the cost was added to, read before the result was
  # recorded: a base the result moved has to reach it, or the job made next is handed a changeset
  # diffed against the base from before the integration (`put_base/4`).
  defp moved_base(ticket, nil), do: ticket
  defp moved_base(ticket, %Ticket{base_commit: base}), do: %{ticket | base_commit: base}

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

  # A document arrives under the name on disk whether its state declared it `deck.md` or
  # `deck.md!`; the state's declaration is what says which kind it is recorded under, and the
  # presentation kind is what every surface reads to draw it `VIEW ONLY` with no approval slot
  # (`docs/design/workflow-grammar-v1.md` § Semantics).
  defp put_documents(multi, ticket, job, %Result{documents: documents}) do
    presentations = job |> spec() |> Spec.presentation_outputs() |> MapSet.new()

    Enum.reduce(documents, multi, fn {name, document}, multi ->
      kind = if MapSet.member?(presentations, name), do: :presentation, else: :document

      Artifacts.put_version(multi, {:doc, name}, ticket.id, name, kind, {:job, job.id}, %{
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

    # The same predicate the worker decides to commit on (`ForgeWorker.Link`): a state that does
    # not promise the diff of its branch neither pushes one nor has one recorded.
    if Spec.changeset?(spec) do
      repo_path = ticket |> Tickets.project_of() |> Projects.repo_path()

      case Git.resolve(repo_path, "refs/heads/" <> ticket.branch) do
        {:ok, head} ->
          multi
          |> Artifacts.put_changeset(:changeset, ticket.id, {:job, job.id}, head)
          |> put_base(ticket, repo_path, head)

        {:error, reason} ->
          Multi.error(multi, :changeset, reason)
      end
    else
      multi
    end
  end

  defp put_changeset(multi, _ticket, _job, _result), do: multi

  # **The base follows an integration** (`docs/design/workflow-grammar-v1.md` § Merging). A
  # changeset whose commit has merged the default branch would otherwise be diffed against a base
  # from before every other ticket's work since, and show all of it as this ticket's. So the base
  # moves to where the commit and the default branch's head last met — when that is past the base,
  # which it is only once the branch has the default branch's later history in it.
  defp put_base(multi, %Ticket{base_commit: base} = ticket, repo_path, head) do
    default = Projects.get!(ticket.project_id).default_branch

    with {:ok, tip} <- Git.resolve(repo_path, "refs/heads/" <> default),
         {:ok, met} when met != base <- Git.merge_base(repo_path, head, tip),
         true <- Git.ancestor?(repo_path, base, met) do
      multi
      |> Multi.update(:base, Ticket.base_changeset(ticket, %{base_commit: met}))
      |> Events.log(:base_event, "ticket.base_moved", :system, %{
        ticket_id: ticket.id,
        payload: %{"from" => base, "to" => met}
      })
    else
      _unmoved -> multi
    end
  end

  # What any run adds to its job, however it ended.
  defp accounting(job, %Result{} = result) do
    %{
      turns: job.turns + (result.harness["turns"] || 0),
      cost_usd: Decimal.add(job.cost_usd, decimal(result.harness["cost_usd"])),
      harness_session_id: result.harness["session_id"] || job.harness_session_id,
      session_blob: session_blob(job, result.harness) || job.session_blob
    }
  end

  @doc """
  The session file a run or a turn reports it uploaded, as `jobs.session_blob` keeps it — its key
  and the version that wrote it — or nil. Only a key under the job's own prefix is taken: the
  worker names it, and a key elsewhere in the store would hand a later resume another job's
  session (`docs/design/claude-code-events.md` § Resume).
  """
  @spec session_blob(Job.t(), map()) :: map() | nil
  def session_blob(%Job{id: id}, %{"session_blob" => key} = harness) when is_binary(key) do
    if String.starts_with?(key, session_prefix(id)) and Storage.Key.validate(key) == {:ok, key},
      do: %{"key" => key, "version" => harness["version"]}
  end

  def session_blob(%Job{}, _harness), do: nil

  # Everything a job's sessions are uploaded under; each assignment adds its own nonce, so a
  # resumed run never collides with the key an earlier run of the same job wrote.
  defp session_prefix(job_id), do: Storage.Key.job(job_id, "session-")

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
          exhausted: result.exhausted,
          finished_at: DateTime.utc_now(:second)
        })
    end
  end

  defp result_payload(%Result{} = result) do
    %{
      "outcome" => result.outcome,
      "declared_outcome" => result.declared_outcome,
      "reason" => result.reason,
      "exhausted" => result.exhausted,
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

  @doc """
  What the platform refused of what `job` wrote, by name, with why: the documents that did not
  parse, from its latest `job.finished`. A refused document is not kept, so this is the only
  record of what was wrong with it — the reason a job ended `error` with nothing to show.
  """
  @spec refusals(Job.t()) :: %{String.t() => String.t()}
  def refusals(%Job{id: id}) do
    case Events.latest_for_job(id, "job.finished") do
      %Event{payload: %{"invalid" => invalid}} when is_map(invalid) -> invalid
      _none -> %{}
    end
  end

  @doc """
  The last thing `job`'s agent said, from its latest `job.harness.text`, or nil. What a reader
  reconstructing a job wants before its transcript, which is too large to read to find it.
  """
  @spec last_words(Job.t()) :: String.t() | nil
  def last_words(%Job{id: id}) do
    case Events.latest_for_job(id, "job.harness.text") do
      %Event{payload: %{"text" => text}} when is_binary(text) -> text
      _none -> nil
    end
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
  conversation (`docs/decisions.md`). A workflow job is put back to `pending` to be resumed; a
  conversation, which a person resumes, goes `hibernated`.
  """
  @spec hibernate(String.t(), String.t() | nil, String.t() | nil, map() | nil) ::
          {:ok, Job.t()} | {:error, term()}
  def hibernate(job_id, commit, reason, result \\ nil) do
    job = get!(job_id)

    cond do
      # A re-sent report, about a job hibernated before a workflow job's hibernation re-queued it.
      # Since then the channel drops a re-sent one for a job back in the queue
      # (`WorkerChannel.still_its/3`) and a conversation never comes here (`Conversations.ended/4`),
      # so this is for rows from before, and for a direct call.
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

  # **A workflow job that hibernated goes back to the queue, to resume from its commit**; a
  # conversation would go dormant (`interrupted_status/1`) — an equivalent mutant today, since the
  # channel sends a chat's `hibernated` to `Conversations.ended/4` and nothing else calls this with
  # one; it is the one rule for "a run ended without an outcome" rather than a second copy of it.
  # A workflow job used to be set `hibernated` too, and nothing ever moved one on — the scheduler
  # places only `pending` jobs — so its ticket sat with no job running and nothing in the queue
  # saying so (`docs/design/worker-tier.md` § Hibernation and resume).
  defp hibernate_running(job, commit, reason) do
    Multi.new()
    |> Multi.update(:job, Job.progress_changeset(job, %{status: interrupted_status(job)}))
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
  On boot: the work a previous node left `running` that no machine can ever report on — on a
  worker row that is `destroyed`, or on none (a deleted row nils `worker_id`) — is dealt with. A
  job is re-queued — its spec still holds and nothing is watching it. A conversation is **not**:
  it goes dormant.

  **Every other running job is left exactly as it is**, its credential and its open run with it
  (`docs/design/worker-channel.md` § A platform restart). Its machine is still running it, and
  says so at its rejoin, seconds after the node is up: listed, the job runs on; not listed, the
  rejoin re-queues it; never back, the unreachable sweep does. This used to re-queue everything,
  and every rejoin after a deploy was then told to cancel the runs the platform had just given up
  on — every run in flight thrown away by every restart.

  Re-queueing a chat would mean every platform restart silently starting conversations nobody is
  in, each taking a slice and spending the day's allowance on a greeting nobody reads. A chat has
  a person in it, and the person decides when it resumes — `docs/design/conversations.md`
  § Lifetime.
  """
  @spec recover() :: non_neg_integer()
  def recover do
    jobs =
      Repo.all(
        from j in Job,
          left_join: w in Forge.Workers.Worker,
          on: w.id == j.worker_id,
          where: j.status == :running and (is_nil(w.id) or w.status == :destroyed)
      )

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
