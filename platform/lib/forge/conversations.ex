defmodule Forge.Conversations do
  @moduledoc """
  Conversations: agents you can talk to, in a project's or a ticket's context.
  `docs/design/conversations.md` is the standard; this is its platform half.

  A conversation is a job with a kind, so everything a job has — a worker, a slice, a cost, a
  transcript, an event stream — is already here. What is here and nowhere else is the talking:
  opening one, sending to it, interrupting it, and recording what each turn cost while it is
  still running.

  **The messages are the event log.** There is no message table: every message arrives as an
  event, `events.seq` already orders them, and the log is already append-only by trigger. A table
  beside it would be a second copy of the same facts and the first disagreement would have no
  arbiter. `messages/1` folds the log into what a person said and what they were told.
  """

  import Ecto.Query, only: [from: 2, where: 3]

  alias Ecto.Multi
  alias Forge.{Events, Git, Jobs, Projects, Proposals, Repo, Tickets, Workers}
  alias Forge.Events.Event
  alias Forge.Git.Tokens
  alias Forge.Jobs.{Job, Runs}
  alias ForgeCore.Proposal

  require Logger

  @doc """
  Opens a conversation about a project, or about one of its tickets, and queues it.

  The branch is created before the row is committed, the way `Tickets.admit/3` does it: a
  conversation whose branch does not exist is one the worker refuses on arrival, minutes later,
  after a machine has been found for it.
  """
  @spec open(Projects.Project.t(), String.t(), keyword()) :: {:ok, Job.t()} | {:error, term()}
  def open(project, text, opts \\ []) do
    # A chat has no state and so no declaration to resolve — the grammar is a workflow's, and
    # this is not one. So the person opening it says, and the platform's defaults are what they
    # get when they do not (`docs/design/conversations.md` § What it asks for).
    with {:ok, memory} <- resource(opts, :memory, Jobs.default_resources().memory),
         {:ok, cores} <- resource(opts, :cores, Jobs.default_resources().cores) do
      insert(project, text, Keyword.merge(opts, memory: memory, cores: cores))
    end
  end

  defp insert(project, text, opts) do
    ticket = Keyword.get(opts, :ticket)
    actor = Keyword.get(opts, :actor, :system)
    id = Ecto.UUID.generate()

    Multi.new()
    |> Multi.insert(
      :chat,
      Job.create_changeset(%Job{id: id}, %{
        kind: :chat,
        project_id: project.id,
        ticket_id: ticket && ticket.id,
        attempt: 1,
        # Chosen when it is opened, and only then: the model is fixed when the harness process
        # starts, so changing it later means a new process. A conversation that wants a different
        # one is a conversation you close and open again.
        model: model(opts),
        memory_max: Keyword.fetch!(opts, :memory),
        cores: Keyword.fetch!(opts, :cores)
      })
    )
    |> Events.log(:opened, "chat.opened", actor, fn %{chat: chat} ->
      %{
        ticket_id: chat.ticket_id,
        job_id: chat.id,
        payload: %{"branch" => Jobs.chat_branch(chat)}
      }
    end)
    |> Events.log(:first_message, "chat.message", actor, fn %{chat: chat} ->
      %{ticket_id: chat.ticket_id, job_id: chat.id, payload: %{"text" => text}}
    end)
    |> Multi.run(:branch, fn _repo, %{chat: chat} ->
      branch = Jobs.chat_branch(chat)

      with :ok <- Git.create_branch(Projects.repo_path(project), branch, base(project, ticket)) do
        {:ok, branch}
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{chat: chat}} ->
        Events.notify(chat.ticket_id)
        {:ok, chat}

      {:error, step, reason, _changes} ->
        {:error, {step, reason}}
    end
  end

  # Empty is not a choice: it resolves to the project's, which is what nil already means.
  defp model(opts) do
    case opts |> Keyword.get(:model) |> to_string() |> String.trim() do
      "" -> nil
      model -> model
    end
  end

  @doc """
  The branch a conversation's own is made from: the ticket's as it stands for a ticket chat, the
  default branch for a project chat (`docs/design/conversations.md` § Context). Opening makes it
  from here, and so does a reopen that finds it gone — and the page says which it will be, from
  this and not a copy of it.
  """
  @spec base_branch(Projects.Project.t(), Tickets.Ticket.t() | nil) :: String.t()
  def base_branch(project, nil), do: project.default_branch
  def base_branch(_project, ticket), do: ticket.branch

  defp base(project, ticket), do: "refs/heads/" <> base_branch(project, ticket)

  @spec get!(String.t()) :: Job.t()
  def get!(id) do
    case Repo.get!(Job, id) do
      %Job{kind: :chat} = chat -> chat
      %Job{} -> raise Ecto.NoResultsError, queryable: Job
    end
  end

  # Nothing said is the platform's default; anything said that is not a positive number is
  # refused. The form has already parsed and refused what a person typed; this is the second
  # reader of the same value — a caller off the CLI, a future API — and replacing a zero with
  # the default would open a conversation on figures nobody asked for, which is the silent
  # substitution `docs/design/conversations.md` § What it asks for rules out. Opened as given,
  # it would be a row the gate can never satisfy rather than a refusal anybody sees.
  defp resource(opts, key, default) do
    case Keyword.get(opts, key) do
      nil -> {:ok, default}
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, {:invalid, key}}
    end
  end

  @doc """
  Whether this conversation can still be spoken to: it holds a machine, or is waiting for one.

  Here rather than in each caller because it decides three different things — whether `send/2`
  accepts, whether the page shows a send box or a reopen button, and whether the queue lists it —
  and three copies of it would be three chances for a surface to offer something the context then
  refuses. `CLAUDE.md`: a guard must use the same model as the operation it guards.
  """
  @live_statuses [:pending, :running]

  @spec live?(Job.t() | atom()) :: boolean()
  def live?(%Job{status: status}), do: live?(status)
  def live?(status) when is_atom(status), do: status in @live_statuses

  @doc """
  The statuses `live?/1` accepts, for a query that must ask the database the same question.
  `where: j.status in ^Conversations.live_statuses()` and `live?/1` cannot drift apart.
  """
  @spec live_statuses() :: [atom()]
  def live_statuses, do: @live_statuses

  @doc """
  Sends a message to a running conversation.

  `:force` interrupts the turn in flight first; without it the message waits for the current turn
  to end. Both are recorded before either reaches the worker, because the log is the conversation
  and a message nobody can see is a message that was lost.

  **A conversation that is not live is refused, and nothing is written.** Its machine is gone, so
  there is nothing for the message to reach; recording it anyway would put a message in the
  transcript that was never delivered and never will be, which is the silent drop
  `docs/poc-plan.md` § Definition of usable rules out. Reopening is what takes a message again.
  """
  @spec send(Job.t(), String.t(), keyword()) ::
          {:ok, Event.t()} | {:error, :not_live} | {:error, term()}
  def send(%Job{kind: :chat} = chat, text, opts \\ []) do
    # Read the status from the row rather than from the caller's struct. A page rendered a minute
    # ago holds a conversation that may have ended since, and a stale struct saying `running` is
    # exactly the case this exists to refuse.
    if live?(Repo.one(from j in Job, where: j.id == ^chat.id, select: j.status)),
      do: do_send(chat, text, opts),
      else: {:error, :not_live}
  end

  defp do_send(%Job{kind: :chat} = chat, text, opts) do
    actor = Keyword.get(opts, :actor, :system)

    Multi.new()
    |> Events.log(:message, "chat.message", actor, %{
      ticket_id: chat.ticket_id,
      job_id: chat.id,
      payload: %{"text" => text}
    })
    |> Repo.transaction()
    |> case do
      {:ok, %{message: event}} ->
        if Keyword.get(opts, :force, false), do: push(chat, "interrupt", %{})

        push(chat, "message", %{
          "job_id" => chat.id,
          "message_id" => to_string(event.seq),
          "text" => text
        })

        Events.notify_job(chat.id, event)
        {:ok, event}

      {:error, step, reason, _changes} ->
        {:error, {step, reason}}
    end
  end

  @doc "Ends the turn in flight without sending anything. The conversation stays open."
  @spec stop(Job.t()) :: :ok
  def stop(%Job{kind: :chat} = chat), do: push(chat, "interrupt", %{"job_id" => chat.id})

  @doc """
  Ends the conversation: the harness's stdin closes, the last turn finishes, and the machine is
  released. The transcript and the events stay; the branch goes unless it would not merge
  cleanly, once the ending is recorded (`ended/3`, and `docs/design/conversations.md`
  § Lifetime). Closing is how a person abandons a conversation, and it is not terminal: a closed
  conversation can be reopened.

  **A conversation that is not live is refused**, `{:error, :not_live}`, on the row's status and
  not the caller's struct, as `send/3` is. The page offers End only on a live one, but an event is
  anything the socket sends: a close on one that had stopped went to a machine no longer running
  it, or — with no worker on the row — recorded a second ending and dealt with the branch of a
  conversation that was already dormant, which nobody decided.

  **A conversation with no process is ended here rather than asked to end itself**, and whether
  it has one is its status. `live?/1` counts `:pending`, so a chat waiting for a worker is one
  the page offers to close — and every other message to a conversation is a push, which for a
  chat with no `worker_id` logs that it was not delivered and returns `:ok`. Closing through that
  path left the row pending for ever with nothing said: a conversation the gate could never place
  could also never be got rid of. So when there is nobody to tell, the platform records the
  ending itself, which is what the worker's report would have caused anyway. It used to ask
  whether the row named a worker, and a pending row can name one: `Jobs.assign/2` puts a row back
  to `:pending` when the assignment cannot be pushed, and leaves the worker it chose.
  """
  @spec close(Job.t(), String.t()) :: :ok | {:error, :not_live} | {:error, term()}
  def close(%Job{kind: :chat} = chat, reason \\ "closed") do
    case Repo.one(from j in Job, where: j.id == ^chat.id, select: {j.status, j.worker_id}) do
      {:running, worker_id} when is_binary(worker_id) ->
        deliver(worker_id, chat.id, "close", %{"reason" => reason})

      {status, _worker_id} ->
        if live?(status), do: ended_here(chat, status, reason), else: {:error, :not_live}
    end
  end

  # Ended only if the row is still what was just read: a scheduling pass may have placed it in
  # between, and then there is a worker to tell instead, so it is asked again. The retry is out
  # of a test's reach — it needs a pass to commit between the read above and the lock in
  # `ended/4`, two statements apart in this process — so `ended/4`'s refusal is what is tested.
  defp ended_here(chat, seen, reason) do
    case ended(chat, nil, reason, expect: seen) do
      {:ok, _chat} -> :ok
      {:error, {:row, {:changed, _now}}} -> close(chat, reason)
      {:error, _reason} = error -> error
    end
  end

  # **The worker is read now, not taken from the struct the caller is holding.** A conversation
  # is opened before it has one and is spoken to afterwards, so any caller that kept the row it
  # opened — a page, a Mix task, the end-to-end check — holds `worker_id: nil` for the rest of
  # the conversation. Trusting it means every message after the first is written to the log and
  # delivered to nobody, which reads exactly like a chat that stopped replying. Every unit test
  # passed through this, because none of them had a worker at all.
  defp push(%Job{id: id} = chat, message, payload) do
    case worker_of(chat) do
      nil ->
        Logger.info("chat #{id} has no worker; #{message} was not delivered")
        :ok

      worker_id ->
        deliver(worker_id, id, message, payload)
    end
  end

  # Read now, never taken from the caller's struct, for the reason above.
  defp worker_of(%Job{id: id}),
    do: Repo.one(from j in Job, where: j.id == ^id, select: j.worker_id)

  defp deliver(worker_id, id, message, payload) do
    case Workers.push(worker_id, {message, Map.put(payload, "job_id", id)}) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("chat #{id}: #{message} failed: #{inspect(reason)}")
    end
  end

  @doc """
  Records that a turn ended: what it cost, how many turns it took, and where its work is.

  **Cost is set on the run, and the conversation's is every run's.** The harness reports
  `total_cost_usd` cumulatively across the process — measured, see § Spend — while `num_turns`
  counts one turn. `progress_attrs/2` adds both, and doing that here would count turn one's cost
  in every later turn: by turn five a conversation reports several times what it spent and the
  daily cap trips early on money nobody spent. So the figure is set on the current run
  (`Forge.Jobs.Runs.cost/3`), and a reopened conversation — a new process, whose figure starts
  again from nothing — adds a run rather than overwriting the last one's.

  Idempotent on `(job_id, session, turn)`: the worker re-sends a turn until it is acked, and it
  numbers turns from one in every process — so after a reopen, turn one is a turn nobody has
  recorded, not a re-send of the first session's.
  """
  @spec record_turn(Job.t(), map()) :: {:ok, Job.t()} | {:error, term()}
  def record_turn(%Job{kind: :chat} = chat, payload) do
    turn = payload["turn"]
    session = get_in(payload, ["harness", "session_id"])

    if recorded?(chat.id, session, turn) do
      {:ok, chat}
    else
      do_record_turn(chat, turn, payload)
    end
  end

  defp do_record_turn(chat, turn, payload) do
    harness = payload["harness"] || %{}
    {documents, refused} = documents(chat, payload)

    # The turn's figure is the process's running total, so it is *set* on this run
    # (`docs/design/conversations.md` § Spend) — and the conversation's cost is every run's, since
    # a conversation reopened is a new process whose total starts again from nothing.
    Multi.new()
    |> put_proposals(chat, payload)
    |> put_documents(chat, documents)
    |> Runs.cost(chat.id, decimal(harness["cost_usd"]))
    |> Multi.update(:job, fn _changes ->
      Job.progress_changeset(chat, %{
        status: :running,
        turns: chat.turns + (harness["turns"] || 1),
        cost_usd: Runs.total(chat.id),
        harness_session_id: harness["session_id"] || chat.harness_session_id
      })
    end)
    |> Events.log(:turn, "chat.turn", {:job, chat.id}, %{
      ticket_id: chat.ticket_id,
      job_id: chat.id,
      payload: %{
        "turn" => turn,
        "session_id" => harness["session_id"],
        "commit" => payload["commit"],
        "interrupted" => payload["interrupted"] == true,
        "cost_usd" => harness["cost_usd"],
        "subtype" => harness["subtype"],
        # Every turn, empty or not: the page reads the newest, so a file the agent fixed stops
        # being listed as refused the turn it is fixed.
        "refused_documents" => refused
      }
    })
    |> Repo.transaction()
    |> case do
      {:ok, %{job: chat, turn: event}} ->
        Events.notify_job(chat.id, event)
        Events.notify(chat.ticket_id)
        # A turn ending is the event worth a notification; an interrupted one is not, because
        # the person who interrupted it is the person who would be told.
        unless payload["interrupted"] == true, do: push_reply(chat)
        {:ok, chat}

      {:error, step, reason, _changes} ->
        {:error, {step, reason}}
    end
  end

  # A conversation proposes like any job, and its proposals arrive with the turn rather than
  # with a result: there is no result, because a conversation has no outcome and never calls
  # `Jobs.complete/2`. Recording is idempotent by content, so the same file reported on every
  # turn is stored once (`Forge.Proposals.put_from_result/4`).
  defp put_proposals(multi, chat, payload) do
    proposals =
      Map.new(payload["proposals"] || %{}, fn {file, map} ->
        {file, %Proposal{title: map["title"], body: map["body"], raw: map["raw"]}}
      end)

    Proposals.put_from_result(multi, chat, proposals, payload["invalid_proposals"] || %{})
  end

  # What a conversation left in `out/` besides its proposals, which it means to keep: split into
  # what is written this turn and what is refused, with why. `docs/design/conversations.md`
  # § Commits.
  #
  # Every check is made here, before the transaction, rather than left to fail inside it: the
  # turn's transaction also carries its cost, its commit and its proposals, and the worker
  # re-sends an unacked turn for ever — so a document that could not be stored would be a
  # conversation whose spending was never recorded again. The worker made the name and file
  # checks already; they are asked again because what crosses the channel is not a guard.
  defp documents(chat, payload) do
    scope = document_scope(chat)
    held = held(chat)

    checked =
      (payload["documents"] || %{})
      |> Enum.sort()
      |> Enum.map(fn {name, raw} -> {name, raw, check(scope, held, name, raw)} end)

    write =
      for {name, raw, {:ok, meta}} <- checked,
          not unchanged?(scope, name, raw, chat),
          do: {name, raw, meta}

    refused =
      for {name, _raw, {:refused, reason}} <- checked, into: %{}, do: {name, reason}

    {{scope, write}, Map.merge(payload["invalid_documents"] || %{}, refused)}
  end

  # Against the ticket for a ticket chat, because that is the work it is about; against the
  # conversation for a project chat, which has nothing else to belong to (§ Commits).
  defp document_scope(%Job{ticket_id: nil, id: id}), do: {:job, id}
  defp document_scope(%Job{ticket_id: ticket_id}), do: {:ticket, ticket_id}

  # Whether this can be recorded as `name` in `scope`: `{:ok, front_matter}`, or refused with
  # why. The workflow's rules where they apply, each with its one definition: the name, the text,
  # the parse, a name that on this ticket is already something a document version would
  # contradict — a transcript, the changeset — and a document a person's decision is waiting on.
  # The front matter comes back because the version is written without a second parse (below).
  defp check(scope, held, name, raw) do
    with nil <- ForgeCore.Workflow.document_name_error(name),
         nil <- ForgeCore.Document.text_error(raw),
         {:ok, document} <- parse(raw),
         nil <- kind_error(scope, name),
         nil <- held[name] do
      {:ok, document.front_matter}
    else
      reason when is_binary(reason) -> {:refused, reason}
    end
  end

  defp parse(raw) do
    case ForgeCore.Document.parse(raw) do
      {:ok, document} -> {:ok, document}
      {:error, errors} -> "does not parse as a document: " <> ForgeCore.Error.format(errors)
    end
  end

  # The documents on a ticket that a person's decision is waiting on, by name, with why a chat may
  # not write them now (`docs/design/conversations.md` § Commits). A version the chat wrote would
  # be the latest, and the latest is what both decisions read:
  #
  # - a document carrying an open blocking question, while a job waits — a question counts only
  #   on the latest version, so a version without the block closed it and left the job waiting on
  #   nothing, which nothing then resumed. Asked of the two functions `Operator.answer/4` resumes
  #   on, so the refusal and the resume cannot disagree about what holds a job;
  # - a document the pending transition is waiting to approve — `Engine.decide/4` approves the
  #   latest version, which would have been the chat's, and nobody had seen it.
  #
  # A project chat's documents are its own, and nothing waits on them.
  defp held(%Job{ticket_id: nil}), do: %{}

  defp held(%Job{ticket_id: ticket_id}) do
    ticket = Tickets.get!(ticket_id)
    Map.merge(questioned(ticket), awaiting_approval(ticket))
  end

  defp questioned(ticket) do
    case Jobs.waiting_job(ticket) do
      nil ->
        %{}

      _waiting ->
        ticket.id
        |> Forge.Artifacts.open_blocking_questions()
        |> Enum.group_by(& &1.artifact_version.artifact.name, & &1.key)
        |> Map.new(fn {name, keys} ->
          {name,
           "holds the question a waiting job stopped on (#{Enum.map_join(keys, ", ", &"`#{&1}`")})" <>
             ", and can be written once that is answered"}
        end)
    end
  end

  defp awaiting_approval(ticket) do
    Map.new(Forge.Engine.awaiting_approval(ticket), fn name ->
      {name,
       "is waiting for a person to approve the version they were shown, and can be written " <>
         "once that is decided"}
    end)
  end

  defp kind_error(scope, name) do
    case Forge.Artifacts.find(scope, name) do
      %{kind: kind} when kind != :document -> "is a #{kind} here, not a document"
      _document_or_nothing -> nil
    end
  end

  # Unchanged since this conversation last wrote it — not since anyone did (§ Commits).
  defp unchanged?(scope, name, raw, chat) do
    match?(%{content: ^raw}, Forge.Artifacts.latest_written(scope, name, chat.id))
  end

  # `parse: false`, as a proposal is recorded, and for the reason a conversation's documents are
  # not a job's: a conversation asks in its reply, where the person is. Parsed, a `question` block
  # in a chat's document became a question on the ticket — a blocking one held a waiting job on
  # something nobody had been asked. The block was still checked by `check/4`, which is also where
  # the front matter kept as the version's `meta` comes from (§ Commits).
  defp put_documents(multi, chat, {scope, write}) do
    Enum.reduce(write, multi, fn {name, raw, meta}, multi ->
      Forge.Artifacts.put_version(
        multi,
        {:document, name},
        scope,
        name,
        :document,
        {:job, chat.id},
        %{content: raw, parse: false, meta: meta}
      )
    end)
  end

  @doc """
  What the conversation's last turn left in `out/` that was not recorded, by name, with why. The
  newest turn's, because every turn reports all of `out/` and says so even when it is nothing.
  """
  @spec unrecorded(String.t()) :: %{String.t() => String.t()}
  def unrecorded(job_id) do
    Repo.one(
      from e in Event,
        where: e.job_id == ^job_id and e.type == "chat.turn",
        order_by: [desc: e.seq],
        limit: 1,
        select: e.payload
    )
    |> case do
      %{"refused_documents" => %{} = refused} -> refused
      _none -> %{}
    end
  end

  defp push_reply(chat), do: Forge.Push.chat_reply(chat)

  # `IS NOT DISTINCT FROM` so that a turn with no session matches another with none: a harness
  # that never reported one is one session as far as this can tell, which is what it was before
  # sessions were recorded.
  defp recorded?(job_id, session, turn) do
    Repo.exists?(
      from e in Event,
        where:
          e.job_id == ^job_id and e.type == "chat.turn" and
            fragment("(? -> 'turn')::int = ?", e.payload, ^turn) and
            fragment("(? ->> 'session_id') IS NOT DISTINCT FROM ?::text", e.payload, ^session)
    )
  end

  defp decimal(nil), do: Decimal.new(0)
  defp decimal(number) when is_float(number), do: Decimal.from_float(number)
  defp decimal(number) when is_integer(number), do: Decimal.new(number)

  @closed "closed"

  @doc """
  Records that a conversation stopped, and why. It is not over: reopening is a cold start.

  `expect: status` records it only if the row still has the status the caller read, and answers
  `{:error, {:row, {:changed, now}}}` otherwise (`close/2`).

  A chat that was closed is finished; one that lost its machine or its platform is dormant, and
  the difference is whether anyone asked for it.

  **A closed one has its branch dealt with here, and nowhere earlier** (`Merge.abandon_chat/1`).
  A conversation with a machine finishes its last turn and pushes it before the worker reports
  the ending, so this is the first moment the branch is the one the conversation left — and the
  credential is revoked first, so nothing can push to it afterwards. Deleting it when the person
  asked would delete a branch the worker was about to push to, and the push would put it back.
  Going idle, losing a machine and a restart are not a person deciding anything, and keep it.
  """
  @spec ended(Job.t(), String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, Job.t()} | {:error, term()}
  def ended(%Job{kind: :chat} = chat, commit, reason, opts \\ []) do
    status = if reason in [@closed, "idle"], do: :finished, else: :hibernated

    worker_id =
      chat.worker_id || Repo.one(from j in Job, where: j.id == ^chat.id, select: j.worker_id)

    Multi.new()
    |> Multi.run(:row, fn repo, _changes -> expected(repo, chat, opts[:expect]) end)
    |> Multi.update(
      :job,
      Job.progress_changeset(chat, %{status: status, finished_at: DateTime.utc_now(:second)})
    )
    |> Runs.close(chat.id, DateTime.utc_now(:second))
    |> Events.log(:ended, "chat.ended", :system, %{
      ticket_id: chat.ticket_id,
      job_id: chat.id,
      payload: %{"reason" => reason, "commit" => commit}
    })
    |> Repo.transaction()
    |> case do
      {:ok, %{job: chat, ended: event}} ->
        # What a job's completion does, and a conversation's ending has to do too: the
        # credential is no good to anyone once it is over, and the worker's memory is wanted
        # back. Without this the machine stays `busy` for ever and takes no more work — which
        # is not visible anywhere except the next thing that never gets scheduled.
        Tokens.revoke_for_job(chat.id)
        if reason == @closed, do: abandon_branch(chat)
        Workers.release(worker_id)
        Events.notify_job(chat.id, event)
        Events.notify(chat.ticket_id)
        {:ok, chat}

      {:error, step, reason, _changes} ->
        {:error, {step, reason}}
    end
  end

  # `:expect` is the status the caller read, locked and compared, the other half of
  # `Forge.Jobs`' check before it marks a row running. Without it — the worker reporting its own
  # ending — there is nothing to compare, because the process that ended is the one telling.
  defp expected(_repo, _chat, nil), do: {:ok, nil}

  defp expected(repo, %Job{id: id}, seen) do
    case repo.one!(from j in Job, where: j.id == ^id, lock: "FOR UPDATE", select: j.status) do
      ^seen -> {:ok, seen}
      now -> {:error, {:changed, now}}
    end
  end

  # After the transaction rather than inside it: the ending is recorded whatever git says, since
  # the worker is waiting on the ack. Each outcome is an event carrying the head, so the sha of
  # discarded work is in the log for as long as the object database still has it.
  defp abandon_branch(chat) do
    case Forge.Merge.abandon_chat(chat) do
      {:ok, :gone} ->
        :ok

      {:ok, {:deleted, how, head}} ->
        branch_event(chat, "chat.branch_deleted", %{"head" => head, "merged" => how == :merged})

      {:ok, {:kept, why, head}} ->
        branch_event(chat, "chat.branch_kept", %{"head" => head, "reason" => to_string(why)})

      {:error, reason} ->
        Logger.warning("chat #{chat.id}: could not deal with its branch: #{inspect(reason)}")
    end
  end

  defp branch_event(chat, type, payload) do
    {:ok, _event} =
      Events.append(type, :system, %{
        ticket_id: chat.ticket_id,
        job_id: chat.id,
        payload: Map.put(payload, "branch", Jobs.chat_branch(chat))
      })

    :ok
  end

  @doc """
  Reopens a conversation that is not live: back in the queue, cold. One that is live is
  refused, `{:error, :live}`.

  The machine is gone and so is the harness session, so the new process starts fresh rather
  than with `--resume`, which cannot find a session whose worktree no longer exists. What it is
  given is the branch as it stands and the conversation so far, replayed (`opening/1`): it reads
  what was said, and answers what the person says next rather than the opening message again.

  **A branch that is gone is made again**, where opening would make it — the default branch or
  the ticket's, as it stands now — and in the same transaction, the way `open/3` does: a worker
  handed a branch that does not exist refuses the conversation minutes later. Closing deletes a
  conversation's branch and a merge does too, and neither makes it one that cannot be reopened.
  """
  @spec reopen(Job.t()) :: {:ok, Job.t()} | {:error, :live} | {:error, term()}
  def reopen(%Job{kind: :chat} = chat) do
    Multi.new()
    |> Multi.run(:dormant, fn repo, _changes -> dormant(repo, chat) end)
    |> Multi.update(:job, fn %{dormant: row} ->
      Job.progress_changeset(row, %{
        status: :pending,
        worker_id: nil,
        harness_session_id: nil,
        finished_at: nil
      })
    end)
    |> Multi.run(:branch, fn _repo, _changes -> restore_branch(chat) end)
    |> Events.log(:reopened, "chat.reopened", :system, fn %{branch: branch} ->
      %{ticket_id: chat.ticket_id, job_id: chat.id, payload: %{"branch" => branch}}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{job: chat}} ->
        Events.notify(chat.ticket_id)
        {:ok, chat}

      {:error, :dormant, :live, _changes} ->
        {:error, :live}

      {:error, step, reason, _changes} ->
        {:error, {step, reason}}
    end
  end

  # **A live conversation is not reopened**, and the row says whether it is live — locked, so a
  # scheduler marking it running cannot slip between the question and the write. Reopening one
  # that is running cleared the `worker_id` its worker is still reporting under: every turn it
  # sent after that failed the channel's ownership check for ever, and the scheduler placed the
  # conversation a second time. The page offers Reopen only when `live?/1` says no; an event off
  # the socket is not the page.
  defp dormant(repo, chat) do
    row = repo.one!(from j in Job, where: j.id == ^chat.id, lock: "FOR UPDATE")
    if live?(row), do: {:error, :live}, else: {:ok, row}
  end

  defp restore_branch(chat) do
    %{project: project, ticket: ticket} = context(chat)
    repo = Projects.repo_path(project)
    branch = Jobs.chat_branch(chat)

    if Git.branch_exists?(repo, branch) do
      {:ok, "kept"}
    else
      with :ok <- Git.create_branch(repo, branch, base(project, ticket)), do: {:ok, "recreated"}
    end
  end

  # -- the projection ---------------------------------------------------------------------------

  @typedoc """
  One entry in a conversation. A `:user` message carries the state of its delivery; an
  `:assistant` message is one turn: its `items` in the order they happened, and its `text`, which
  is only what it said — the text blocks, a blank line between each.
  """
  @type message ::
          %{role: :user, text: String.t(), at: DateTime.t(), delivered: boolean(), id: String.t()}
          | %{
              role: :assistant,
              text: String.t(),
              items: [item()],
              at: DateTime.t(),
              turn: pos_integer() | nil
            }

  @typedoc """
  One thing in a turn: a block of what the agent said, or something it did.
  """
  @type item :: {:text, String.t()} | {:action, action()}

  @typedoc """
  One tool call, paired with its result. `result` is nil until the result arrives, which is
  what makes a call the one the agent is in the middle of. `children` are the calls a `Task`'s
  subagent made, found by their `parent_tool_use_id`.
  """
  @type action :: %{
          id: String.t() | nil,
          name: String.t() | nil,
          input: map(),
          at: DateTime.t(),
          result:
            nil | %{is_error: boolean(), excerpt: String.t(), bytes: non_neg_integer() | nil},
          children: [action()]
        }

  @doc """
  The conversation as a person reads it: what each side *said*.

  A turn that only acted and said nothing is left out. It is in `transcript/1`, which is what the
  page draws; the readers of this one — the queue, the replay a reopened process reads, the
  push — are asking what was said, and a turn that said nothing said nothing.
  """
  @spec messages(String.t()) :: [message()]
  def messages(job_id), do: job_id |> transcript() |> said()

  @doc """
  A transcript without the turns that said nothing: what `messages/1` is, for a caller that
  already has the transcript. The page asks whether a conversation waits on its person from
  this, which is what the queue asks it from.
  """
  @spec said([message()]) :: [message()]
  def said(transcript), do: Enum.reject(transcript, &silent?/1)

  defp silent?(%{role: :assistant, text: ""}), do: true
  defp silent?(_message), do: false

  @doc """
  The conversation, folded out of the event log: each turn as the sequence it happened in.

  **A turn is a sequence, not a string.** Each `job.harness.text` event is one content block of
  the agent's reply, and each is its own item; each `tool_use` is an item between them, paired
  with its `tool_result` by id. They used to be joined into one string with nothing between the
  blocks, so the sentence before a tool call ran into the one after it, and the calls were
  dropped on the way (`docs/design/conversations.md` § The page). Nothing new is recorded: this
  stops throwing away what was.

  A subagent's calls — a `parent_tool_use_id` naming a `Task` — fold under that call rather than
  interleaving with the agent's own, and a subagent's text is not the agent's reply. Notices and
  the rest of the harness's bookkeeping are not in it; they are the Activity tab's.

  Takes the job's id, or its events when the caller already has them — the page keeps the log
  it has read and appends to it as events arrive, rather than reading it again for each one.
  """
  @spec transcript(String.t() | [Event.t()]) :: [message()]
  def transcript(job_id) when is_binary(job_id), do: job_id |> Events.for_job() |> transcript()

  def transcript(events) when is_list(events) do
    %{done: done, open: open} = Enum.reduce(events, %{done: [], open: nil, round: 0}, &fold/2)

    # The reply being spoken right now, which has had no `chat.turn` to close it yet. Dropping it
    # would mean a conversation showed nothing at all until each turn finished — which is the
    # streaming case, and the whole reason the page subscribes per job.
    done
    |> flush(open)
    |> Enum.reverse()
    |> Enum.map(&finish_message/1)
  end

  # The fold's state: the messages finished so far, newest first; the agent's reply being
  # accumulated; and `round`, which counts the turns the log has closed and the processes it has
  # started. Every piece of an agent reply carries the round it was spoken in, so that a turn
  # split by a message sent in the middle of it is still one turn: `chat.turn` closes both
  # halves, and nothing from an earlier round.

  defp fold(%Event{type: "chat.message"} = event, state) do
    message = %{
      role: :user,
      id: to_string(event.seq),
      text: event.payload["text"],
      at: event.inserted_at,
      delivered: false
    }

    %{state | done: [message | flush(state.done, state.open)], open: nil}
  end

  # The harness echoes a message when it takes it, which for one sent mid-turn is after the
  # current turn's result — so this is delivery, not receipt (§ The wire).
  defp fold(%Event{type: "job.harness.delivered"} = event, state) do
    id = event.payload["message_id"]
    %{state | done: Enum.map(state.done, &mark_delivered(&1, id))}
  end

  # A subagent's words are its report to the agent, which the agent then says — or does not —
  # in its own. They are in the Activity tab like every other event.
  defp fold(%Event{type: "job.harness.text", payload: %{"parent_tool_use_id" => parent}}, state)
       when is_binary(parent),
       do: state

  defp fold(%Event{type: "job.harness.text"} = event, state),
    do: add_item(state, {:text, string(event.payload["text"])}, event)

  defp fold(%Event{type: "job.harness.tool_use", payload: payload} = event, state) do
    action = action(payload, event.inserted_at)

    # A child whose parent is nowhere in the log is drawn at the top level rather than dropped.
    case update_action(
           state,
           payload["parent_tool_use_id"],
           &%{&1 | children: [action | &1.children]}
         ) do
      {:ok, state} -> state
      :none -> add_item(state, {:action, action}, event)
    end
  end

  # A result for a call that is nowhere in the log has nothing to pair with. It is still in the
  # log, and in the Activity tab.
  defp fold(%Event{type: "job.harness.tool_result", payload: payload}, state) do
    case update_action(state, payload["tool_use_id"], &%{&1 | result: result(payload)}) do
      {:ok, state} -> state
      :none -> state
    end
  end

  defp fold(%Event{type: "chat.turn"} = event, %{round: round} = state) do
    turn = event.payload["turn"]
    stamp = fn message -> stamp(message, round, turn) end

    %{
      state
      | done: state.done |> flush(state.open) |> Enum.map(stamp),
        open: nil,
        round: round + 1
    }
  end

  # A new process: whatever reply was still open was cut off with the one before it, and what
  # the new one says is its own.
  defp fold(%Event{type: "job.started"}, state),
    do: %{state | done: flush(state.done, state.open), open: nil, round: state.round + 1}

  defp fold(%Event{}, state), do: state

  @doc """
  One tool call as the transcript holds it, from a `tool_use` event's payload. The agent wrote the
  input, so nothing in it is trusted to have the type its tool's schema says: a name that is not
  text has none, and an input that is not a map is empty.
  """
  @spec action(map(), DateTime.t()) :: action()
  def action(payload, at) do
    %{
      id: payload["id"],
      name: if(is_binary(payload["name"]), do: payload["name"]),
      input: if(is_map(payload["input"]), do: payload["input"], else: %{}),
      at: at,
      result: nil,
      children: []
    }
  end

  @doc "A call's result, from a `tool_result` event's payload."
  @spec result(map()) :: map()
  def result(payload) do
    %{
      is_error: payload["is_error"] == true,
      excerpt: string(payload["excerpt"]),
      bytes: payload["bytes"]
    }
  end

  defp string(text) when is_binary(text), do: text
  defp string(_other), do: ""

  # Items are kept newest first while the turn is folded, and put in order when it is finished.
  defp add_item(%{open: nil} = state, item, event),
    do: %{
      state
      | open: %{
          role: :assistant,
          items: [item],
          at: event.inserted_at,
          turn: nil,
          round: state.round
        }
    }

  defp add_item(%{open: open} = state, item, _event),
    do: %{state | open: %{open | items: [item | open.items]}}

  # The call `id`, wherever it is: the reply being spoken, a half of it that a message sent
  # mid-turn closed, or an earlier turn a late result or a subagent still reporting belongs to.
  # Tool ids are unique, so the first match is the call.
  defp update_action(_state, nil, _fun), do: :none

  defp update_action(state, id, fun) do
    case update_message(state.open, id, fun) do
      {:ok, open} ->
        {:ok, %{state | open: open}}

      :none ->
        with {:ok, done} <- update_done(state.done, id, fun), do: {:ok, %{state | done: done}}
    end
  end

  defp update_done([], _id, _fun), do: :none

  defp update_done([%{role: :assistant} = message | rest], id, fun) do
    case update_message(message, id, fun) do
      {:ok, message} -> {:ok, [message | rest]}
      :none -> with {:ok, rest} <- update_done(rest, id, fun), do: {:ok, [message | rest]}
    end
  end

  defp update_done([message | rest], id, fun) do
    with {:ok, rest} <- update_done(rest, id, fun), do: {:ok, [message | rest]}
  end

  defp update_message(nil, _id, _fun), do: :none

  defp update_message(message, id, fun) do
    case update_in_items(message.items, id, fun) do
      {:ok, items} -> {:ok, %{message | items: items}}
      :none -> :none
    end
  end

  defp update_in_items([], _id, _fun), do: :none

  defp update_in_items([{:action, %{id: id} = action} | rest], id, fun),
    do: {:ok, [{:action, fun.(action)} | rest]}

  defp update_in_items([{:action, action} = item | rest], id, fun) do
    case update_in_items(Enum.map(action.children, &{:action, &1}), id, fun) do
      {:ok, children} ->
        {:ok, [{:action, %{action | children: Enum.map(children, &elem(&1, 1))}} | rest]}

      :none ->
        with {:ok, rest} <- update_in_items(rest, id, fun), do: {:ok, [item | rest]}
    end
  end

  defp update_in_items([item | rest], id, fun) do
    with {:ok, rest} <- update_in_items(rest, id, fun), do: {:ok, [item | rest]}
  end

  defp stamp(%{role: :assistant, round: round, turn: nil} = message, round, turn),
    do: %{message | turn: turn}

  defp stamp(message, _round, _turn), do: message

  # A user message arriving mid-reply ends the assistant message being accumulated.
  defp flush(acc, nil), do: acc
  defp flush(acc, open), do: [open | acc]

  defp mark_delivered(%{role: :user, id: id} = message, id), do: %{message | delivered: true}
  defp mark_delivered(message, _id), do: message

  defp finish_message(%{role: :assistant, items: items} = message) do
    items = items |> Enum.reverse() |> Enum.map(&finish_item/1)

    text =
      for({:text, text} <- items, do: String.trim(text))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    message |> Map.delete(:round) |> Map.merge(%{items: items, text: text})
  end

  defp finish_message(message), do: message

  defp finish_item({:action, action}), do: {:action, finish_action(action)}
  defp finish_item(item), do: item

  defp finish_action(action),
    do: %{action | children: action.children |> Enum.reverse() |> Enum.map(&finish_action/1)}

  @typedoc """
  What the agent is doing right now, when a turn is open: the call with no result yet, a retry,
  or a limit that stopped it and when it lifts.
  """
  @type now ::
          {:action, action()}
          | {:retrying, integer() | nil, integer() | nil}
          | {:rate_limited, DateTime.t() | nil}
          | nil

  @doc """
  What the now line says (`docs/design/ui.md` § Talk): the call the agent is in the middle of, or
  — when the latest thing the harness reported since was a retry or a limit that refused it — that.

  Nil when no turn is open. A retry or a limit is not a line in the transcript, because it is not
  something the agent did; it is what is happening instead, until something else is reported.
  """
  @now_types ~w(job.harness.retry job.harness.rate_limit job.harness.text job.harness.tool_use
                job.harness.tool_result)

  @spec now([Event.t()]) :: now()
  def now(events) do
    open =
      events |> Enum.reverse() |> Enum.take_while(&(&1.type not in ["chat.turn", "job.started"]))

    case Enum.find(open, &(&1.type in @now_types)) do
      %Event{type: "job.harness.retry", payload: payload} ->
        {:retrying, payload["attempt"], payload["max_retries"]}

      %Event{type: "job.harness.rate_limit", payload: %{"status" => "rejected"} = payload} ->
        {:rate_limited, epoch(payload["resets_at"])}

      # The agent's side of the turn, both halves of it if a message sent mid-turn split it:
      # that message is queued behind the call in flight, which is still what the agent is doing.
      _other ->
        open
        |> Enum.reverse()
        |> transcript()
        |> Enum.flat_map(fn
          %{role: :assistant, items: items} -> items
          _said -> []
        end)
        |> pending()
    end
  end

  # The worker's integer, and `DateTime.from_unix!/1` raises on one outside the calendar — a
  # milliseconds value, say. A reset that cannot be read is said as a limit without a time, the
  # way `Forge.Credentials` reads the same field, rather than a page that cannot mount.
  defp epoch(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, at} -> at
      {:error, _outside} -> nil
    end
  end

  defp epoch(_other), do: nil

  # The last call with no result, innermost first: a `Task` is waiting on its subagent, and what
  # the subagent is doing is the more useful thing to say.
  defp pending(items) do
    items
    |> Enum.reverse()
    |> Enum.find_value(fn
      {:action, action} -> open_action(action)
      _text -> nil
    end)
    |> case do
      nil -> nil
      action -> {:action, action}
    end
  end

  defp open_action(%{result: nil} = action),
    do: action.children |> Enum.reverse() |> Enum.find_value(&open_action/1) || action

  defp open_action(_resolved), do: nil

  @doc """
  What a conversation's next process starts with: what was said before it, and what it answers.

  **Split at the agent's last reply.** Everything up to it is the conversation so far — what the
  person said and what they were told — rendered oldest first as `:replay`, which the worker
  writes to `$FORGE_JOB/conversation.md` and the manifest names. What the person said after it
  is `:prompt`, the message the process opens with. A conversation that has never been answered
  has no replay and its whole opening is the prompt, which is a first start; one whose last word
  was the agent's has a replay and no prompt, and the worker then holds the prompt until the
  person's next message (`docs/design/conversations.md` § Lifetime).

  That second case is a reopen, and it is why this exists. The prompt used to be the first
  `chat.message` and nothing else, so a reopened conversation began by answering its opening
  message a second time, as though new, and knew nothing that was said after it.

  Messages sent while the conversation waited for a machine are after the last reply too, so
  they are answered rather than pushed to nobody. What the split cannot see: a turn that said
  nothing leaves the message before it looking unanswered, and it is answered again; and a
  message queued mid-turn that the process never took reads as answered, because the projection
  draws the rest of that turn's reply after it.
  """
  @spec opening(String.t()) :: %{replay: String.t() | nil, prompt: String.t() | nil}
  def opening(job_id) do
    {said, waiting} = split_at_last_reply(messages(job_id))

    %{
      replay: render_replay(said),
      prompt:
        case waiting do
          [] -> nil
          texts -> Enum.join(texts, "\n\n")
        end
    }
  end

  defp split_at_last_reply(messages) do
    case messages |> Enum.reverse() |> Enum.find_index(&(&1.role == :assistant)) do
      nil ->
        {[], user_texts(messages)}

      from_end ->
        {said, after_it} = Enum.split(messages, length(messages) - from_end)
        {said, user_texts(after_it)}
    end
  end

  defp user_texts(messages), do: for(%{role: :user, text: text} <- messages, do: text)

  defp render_replay([]), do: nil

  defp render_replay(said) do
    """
    # The conversation so far

    Everything said before this process started, oldest first. It ends with your last reply;
    the person's next message is at the end of your prompt, not here.

    """ <> Enum.map_join(said, "\n", &replay_entry/1)
  end

  defp replay_entry(%{role: :user, text: text, at: at}),
    do: "## The person, #{stamp(at)}\n\n#{text}\n"

  # No `chat.turn` closed it: the process stopped while it was still speaking. Said so, because
  # a reply that ends mid-sentence reads as a finished one that trailed off.
  defp replay_entry(%{role: :assistant, text: text, at: at, turn: nil}),
    do: "## You, #{stamp(at)} — cut off: the process stopped before this reply ended\n\n#{text}\n"

  defp replay_entry(%{role: :assistant, text: text, at: at}),
    do: "## You, #{stamp(at)}\n\n#{text}\n"

  defp stamp(at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  @doc """
  The question a reply asked, if it asked one.

  A message *is* a body, so the parser a document uses parses it — nothing new in core. Every
  chat question is blocking, because the turn has ended and the agent is waiting whichever way
  the flag was written; `blocking: :always` also stops one question written without an assumption
  from failing the parse of the whole message and taking the question with it.
  See `docs/design/conversations.md` § Asking a question.
  """
  @spec question(message() | nil) :: ForgeCore.Document.Question.t() | nil
  def question(%{role: :assistant, text: text}) do
    case ForgeCore.Document.parse(text, blocking: :always) do
      {:ok, %ForgeCore.Document{questions: [question | _rest]}} -> question
      _none -> nil
    end
  end

  def question(_message), do: nil

  @doc "The conversations an operator can see for a project, newest first."
  @spec list_for_project(String.t()) :: [Job.t()]
  def list_for_project(project_id), do: Jobs.chats_for_project(project_id)

  @typedoc "A conversation as a list draws it: enough to recognise it and decide to open it."
  @type summary :: %{
          chat: Job.t(),
          project: Projects.Project.t(),
          ticket: Tickets.Ticket.t() | nil,
          live: boolean(),
          waiting: boolean(),
          said: {:user | :agent, String.t()} | nil
        }

  @doc """
  Conversations for a list, live ones first and newest within that.

  `:ticket_id` narrows it to one ticket's, `:project_id` to one project's; `:for` narrows it to
  the projects one user is a member of, which is what every operator surface passes. Without any
  of them this is every conversation on the node, and only the command line may ask for that.

  Live first because that is the one costing something and holding a machine. The rest are a
  record — a conversation is kept for ever, so this list only grows, and what it is for is
  finding one again rather than watching them all.
  """
  @spec summaries(keyword()) :: [summary()]
  def summaries(opts \\ []) do
    chats =
      cond do
        id = Keyword.get(opts, :ticket_id) -> Jobs.chats_for_ticket(id)
        id = Keyword.get(opts, :project_id) -> Jobs.chats_for_project(id)
        user = Keyword.get(opts, :for) -> for_user(user)
        true -> Repo.all(node_wide())
      end

    decorate(chats)
  end

  defp node_wide, do: from(j in Job, where: j.kind == :chat, order_by: [desc: j.inserted_at])

  # A row carries the project's name and the last thing the agent said, so an unscoped list is a
  # transcript leak and not only a name one. See `docs/design/identity.md` § Read scoping.
  defp for_user(%Forge.Accounts.User{} = user) do
    project_ids = Enum.map(Forge.Projects.list(user), & &1.id)
    Repo.all(from j in node_wide(), where: j.project_id in ^project_ids)
  end

  defp decorate([]), do: []

  defp decorate(chats) do
    # Three queries for any number of conversations rather than three per conversation: a list
    # is the one place an N+1 is not merely slow but grows with the product's own history.
    projects = by_id(Projects.Project, Enum.map(chats, & &1.project_id))
    tickets = by_id(Tickets.Ticket, Enum.reject(Enum.map(chats, & &1.ticket_id), &is_nil/1))
    said = last_said(Enum.map(chats, & &1.id))

    chats
    |> Enum.map(fn chat ->
      last = said[chat.id]

      %{
        chat: chat,
        project: projects[chat.project_id],
        ticket: tickets[chat.ticket_id],
        live: live?(chat),
        # Waiting on a person is the agent having spoken last, which is what the queue reads too.
        waiting: live?(chat) and match?({:agent, _text}, last),
        said: last
      }
    end)
    # Live first, newest within that. The sorter is descending, so both keys are the ones that
    # sort *high*: `live` rather than `not live`, and the later timestamp. It read `not live`
    # before, which put finished conversations on top — invisible while the live one was also
    # the newest, and wrong exactly when you came back to a machine you had left running.
    |> Enum.sort_by(&{&1.live, &1.chat.inserted_at}, fn a, b -> a >= b end)
  end

  defp by_id(_schema, []), do: %{}

  defp by_id(schema, ids),
    do: schema |> where([r], r.id in ^Enum.uniq(ids)) |> Repo.all() |> Map.new(&{&1.id, &1})

  # The last thing said in each conversation, in one query. `distinct` on the job with the order
  # descending by seq is Postgres's DISTINCT ON: the newest row per job and nothing else.
  defp last_said(job_ids) do
    Repo.all(
      from e in Event,
        where: e.job_id in ^job_ids and e.type in ["chat.message", "job.harness.text"],
        # A subagent's text is its report to the agent, not the agent speaking — the rule
        # `transcript/1` follows.
        where: fragment("(? ->> 'parent_tool_use_id') IS NULL", e.payload),
        distinct: e.job_id,
        order_by: [asc: e.job_id, desc: e.seq],
        select: {e.job_id, e.type, e.payload}
    )
    |> Map.new(fn {id, type, payload} -> {id, {role(type), payload["text"] || ""}} end)
  end

  defp role("chat.message"), do: :user
  defp role(_harness_text), do: :agent

  @doc """
  What every job that already ran on this ticket did, for a conversation to read.

  One entry per workflow job, oldest first: a short metadata document, and the store key and
  token for its transcript. **The transcript is fetched by the worker, not inlined here.** They
  run to a hundred kilobytes and more each, and a ticket has several — inlining them would put a
  megabyte through the channel and, far worse, into the prompt on every turn. The store exists
  so that large things reach a machine without crossing the channel, and the seed already works
  exactly this way.

  What the agent gets is therefore a folder it can read when it wants to, which is what an agent
  with file tools wants, rather than a prompt it has to pay for whether it reads it or not.
  """
  @spec history(Tickets.Ticket.t() | nil) :: [map()]
  def history(nil), do: []

  def history(%Tickets.Ticket{} = ticket) do
    ticket.id
    |> Jobs.for_ticket()
    |> Enum.map(&entry(&1, ticket))
  end

  defp entry(job, _ticket) do
    %{
      "dir" => Path.join(job.state, to_string(job.attempt)),
      "metadata" => metadata(job),
      "transcript" => transcript_ref(job)
    }
  end

  # Markdown rather than JSON: it is read by an agent and by a person looking at the job
  # directory, and neither wants to parse it.
  defp metadata(job) do
    """
    # #{job.state}, attempt #{job.attempt}

    - Job: `#{job.id}`
    - Status: #{job.status}
    - Outcome: #{outcome_line(job)}
    - Turns: #{job.turns}
    - Cost: #{job.cost_usd} USD
    - Started: #{job.started_at || "—"}
    - Finished: #{job.finished_at || "—"}

    ## What it wrote

    #{written(job)}

    ## Its transcript

    #{transcript_line(job)}
    """
  end

  defp outcome_line(%Job{outcome: nil}), do: "none yet"

  defp outcome_line(%Job{outcome: outcome, declared_outcome: nil}), do: to_string(outcome)

  defp outcome_line(%Job{outcome: outcome, declared_outcome: declared}),
    do: "#{declared} (the engine read it as #{outcome})"

  defp written(job) do
    case Forge.Artifacts.written_by(job.id) do
      [] ->
        "- nothing"

      versions ->
        Enum.map_join(versions, "\n", fn {a, v} -> "- `#{a.name}` version #{v.version}" end)
    end
  end

  defp transcript_line(job) do
    case transcript_ref(job) do
      nil -> "Not kept."
      _ref -> "`transcript.jsonl`, beside this file. One JSON object per line."
    end
  end

  # The store key and a token to read it. A job that never uploaded one — it failed before it
  # could, or the upload did — has none, and the folder says so rather than pretending.
  #
  # The worker fetches it only once the conversation's worktree is prepared, so the token has
  # to outlive the preparation as well as its own fifteen minutes (`docs/design/storage.md`
  # § Serving).
  defp transcript_ref(job) do
    with %{blob_uri: uri} when is_binary(uri) <- newest_transcript(job),
         {:ok, key} <- Forge.Storage.key_from_uri(uri) do
      token = Forge.Storage.Token.sign(:get, key, outlasting_ms: Jobs.preparation_margin_ms())
      %{"key" => key, "token" => token}
    else
      _none -> nil
    end
  end

  defp newest_transcript(job) do
    job.id
    |> Forge.Artifacts.written_by()
    |> Enum.filter(fn {artifact, _v} -> String.starts_with?(artifact.name, "transcript-") end)
    |> List.last()
    |> case do
      {_artifact, version} -> version
      nil -> nil
    end
  end

  @doc "Where a conversation is: its project, and its ticket when it has one."
  @spec context(Job.t()) :: %{project: Projects.Project.t(), ticket: Tickets.Ticket.t() | nil}
  def context(%Job{} = chat) do
    %{
      project: Projects.get!(chat.project_id),
      ticket: chat.ticket_id && Tickets.get!(chat.ticket_id)
    }
  end
end
