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
  alias Forge.{Events, Git, Jobs, Projects, Repo, Tickets, Workers}
  alias Forge.Events.Event
  alias Forge.Git.Tokens
  alias Forge.Jobs.Job

  require Logger

  @doc """
  Opens a conversation about a project, or about one of its tickets, and queues it.

  The branch is created before the row is committed, the way `Tickets.admit/3` does it: a
  conversation whose branch does not exist is one the worker refuses on arrival, minutes later,
  after a machine has been found for it.
  """
  @spec open(Projects.Project.t(), String.t(), keyword()) :: {:ok, Job.t()} | {:error, term()}
  def open(project, text, opts \\ []) do
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
        model: model(opts)
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

  # A ticket chat starts from the ticket's branch as it stands, a project chat from the default
  # branch: the same context the ticket's next job would get, which is the point (§ Context).
  defp base(project, nil), do: "refs/heads/" <> project.default_branch
  defp base(_project, ticket), do: "refs/heads/" <> ticket.branch

  @spec get!(String.t()) :: Job.t()
  def get!(id) do
    case Repo.get!(Job, id) do
      %Job{kind: :chat} = chat -> chat
      %Job{} -> raise Ecto.NoResultsError, queryable: Job
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
  released. The transcript, the events and the branch stay.
  """
  @spec close(Job.t(), String.t()) :: :ok
  def close(%Job{kind: :chat} = chat, reason \\ "closed"),
    do: push(chat, "close", %{"job_id" => chat.id, "reason" => reason})

  # **The worker is read now, not taken from the struct the caller is holding.** A conversation
  # is opened before it has one and is spoken to afterwards, so any caller that kept the row it
  # opened — a page, a Mix task, the end-to-end check — holds `worker_id: nil` for the rest of
  # the conversation. Trusting it means every message after the first is written to the log and
  # delivered to nobody, which reads exactly like a chat that stopped replying. Every unit test
  # passed through this, because none of them had a worker at all.
  defp push(%Job{id: id}, message, payload) do
    case Repo.one(from j in Job, where: j.id == ^id, select: j.worker_id) do
      nil ->
        Logger.info("chat #{id} has no worker; #{message} was not delivered")
        :ok

      worker_id ->
        deliver(worker_id, id, message, payload)
    end
  end

  defp deliver(worker_id, id, message, payload) do
    case Workers.push(worker_id, {message, Map.put(payload, "job_id", id)}) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("chat #{id}: #{message} failed: #{inspect(reason)}")
    end
  end

  @doc """
  Records that a turn ended: what it cost, how many turns it took, and where its work is.

  **Cost is set, not added.** The harness reports `total_cost_usd` cumulatively across the
  session — measured, see § Spend — while `num_turns` counts one turn. `progress_attrs/2` adds
  both, and doing that here would count turn one's cost in every later turn: by turn five a
  conversation reports several times what it spent and the daily cap trips early on money nobody
  spent. The number stays plausible and monotonic the whole time, which is why this is written
  down rather than left to be noticed.

  Idempotent on `(job_id, turn)`: the worker re-sends a turn until it is acked.
  """
  @spec record_turn(Job.t(), map()) :: {:ok, Job.t()} | {:error, term()}
  def record_turn(%Job{kind: :chat} = chat, payload) do
    turn = payload["turn"]

    if recorded?(chat.id, turn) do
      {:ok, chat}
    else
      do_record_turn(chat, turn, payload)
    end
  end

  defp do_record_turn(chat, turn, payload) do
    harness = payload["harness"] || %{}

    Multi.new()
    |> Multi.update(
      :job,
      Job.progress_changeset(chat, %{
        status: :running,
        turns: chat.turns + (harness["turns"] || 1),
        cost_usd: decimal(harness["cost_usd"]),
        harness_session_id: harness["session_id"] || chat.harness_session_id
      })
    )
    |> Events.log(:turn, "chat.turn", {:job, chat.id}, %{
      ticket_id: chat.ticket_id,
      job_id: chat.id,
      payload: %{
        "turn" => turn,
        "commit" => payload["commit"],
        "interrupted" => payload["interrupted"] == true,
        "cost_usd" => harness["cost_usd"],
        "subtype" => harness["subtype"]
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

  defp push_reply(chat) do
    case chat.id |> messages() |> List.last() do
      %{role: :assistant, text: text} -> Forge.Push.chat_reply(chat, text)
      _other -> :ok
    end
  end

  defp recorded?(job_id, turn) do
    Repo.exists?(
      from e in Event,
        where:
          e.job_id == ^job_id and e.type == "chat.turn" and
            fragment("(? -> 'turn')::int = ?", e.payload, ^turn)
    )
  end

  defp decimal(nil), do: Decimal.new(0)
  defp decimal(number) when is_float(number), do: Decimal.from_float(number)
  defp decimal(number) when is_integer(number), do: Decimal.new(number)

  @doc """
  Records that a conversation stopped, and why. It is not over: reopening is a cold start.

  A chat that was closed is finished; one that lost its machine or its platform is dormant, and
  the difference is whether anyone asked for it.
  """
  @spec ended(Job.t(), String.t() | nil, String.t() | nil) :: {:ok, Job.t()} | {:error, term()}
  def ended(%Job{kind: :chat} = chat, commit, reason) do
    status = if reason in ["closed", "idle"], do: :finished, else: :hibernated

    worker_id =
      chat.worker_id || Repo.one(from j in Job, where: j.id == ^chat.id, select: j.worker_id)

    Multi.new()
    |> Multi.update(
      :job,
      Job.progress_changeset(chat, %{status: status, finished_at: DateTime.utc_now(:second)})
    )
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
        Workers.release(worker_id)
        Events.notify_job(chat.id, event)
        Events.notify(chat.ticket_id)
        {:ok, chat}

      {:error, step, reason, _changes} ->
        {:error, {step, reason}}
    end
  end

  @doc """
  Reopens a dormant conversation: back in the queue, cold.

  The machine is gone and so is the harness session, so the new process starts with the
  transcript replayed as context rather than `--resume`, which cannot find a session whose
  worktree no longer exists.
  """
  @spec reopen(Job.t()) :: {:ok, Job.t()} | {:error, term()}
  def reopen(%Job{kind: :chat} = chat) do
    Multi.new()
    |> Multi.update(
      :job,
      Job.progress_changeset(chat, %{
        status: :pending,
        worker_id: nil,
        harness_session_id: nil,
        finished_at: nil
      })
    )
    |> Events.log(:reopened, "chat.reopened", :system, %{
      ticket_id: chat.ticket_id,
      job_id: chat.id
    })
    |> Repo.transaction()
    |> case do
      {:ok, %{job: chat}} ->
        Events.notify(chat.ticket_id)
        {:ok, chat}

      {:error, step, reason, _changes} ->
        {:error, {step, reason}}
    end
  end

  # -- the projection ---------------------------------------------------------------------------

  @typedoc """
  One entry in a conversation. A `:user` message carries the state of its delivery; an
  `:assistant` message is the text of one turn, which arrives in pieces and is joined here.
  """
  @type message ::
          %{role: :user, text: String.t(), at: DateTime.t(), delivered: boolean(), id: String.t()}
          | %{role: :assistant, text: String.t(), at: DateTime.t(), turn: pos_integer() | nil}

  @doc """
  The conversation, folded out of the event log.

  Assistant text arrives as several `job.harness.text` events within one turn and is joined into
  one message per turn, because that is what a person sees: a reply, not the four pieces it was
  streamed in.
  """
  @spec messages(String.t()) :: [message()]
  def messages(job_id) do
    {done, open} =
      job_id
      |> Events.for_job()
      |> Enum.reduce({[], nil}, &fold/2)

    # The reply being spoken right now, which has had no `chat.turn` to close it yet. Dropping it
    # would mean a conversation showed nothing at all until each turn finished — which is the
    # streaming case, and the whole reason the page subscribes per job.
    done
    |> flush(open)
    |> Enum.reverse()
    |> Enum.map(&finish_message/1)
  end

  defp fold(%Event{type: "chat.message"} = event, {acc, open}) do
    message = %{
      role: :user,
      id: to_string(event.seq),
      text: event.payload["text"],
      at: event.inserted_at,
      delivered: false
    }

    {[message | flush(acc, open)], nil}
  end

  # The harness echoes a message when it takes it, which for one sent mid-turn is after the
  # current turn's result — so this is delivery, not receipt (§ The wire).
  defp fold(%Event{type: "job.harness.delivered"} = event, {acc, open}) do
    id = event.payload["message_id"]
    {Enum.map(acc, &mark_delivered(&1, id)), open}
  end

  defp fold(%Event{type: "job.harness.text"} = event, {acc, open}) do
    text = event.payload["text"] || ""

    case open do
      nil -> {acc, %{role: :assistant, text: [text], at: event.inserted_at, turn: nil}}
      %{text: pieces} = open -> {acc, %{open | text: pieces ++ [text]}}
    end
  end

  defp fold(%Event{type: "chat.turn"} = event, {acc, open}) do
    case open do
      nil -> {acc, nil}
      open -> {[%{open | turn: event.payload["turn"]} | acc], nil}
    end
  end

  defp fold(%Event{}, state), do: state

  # A user message arriving mid-reply ends the assistant message being accumulated.
  defp flush(acc, nil), do: acc
  defp flush(acc, open), do: [open | acc]

  defp mark_delivered(%{role: :user, id: id} = message, id), do: %{message | delivered: true}
  defp mark_delivered(message, _id), do: message

  defp finish_message(%{role: :assistant, text: pieces} = message),
    do: %{message | text: pieces |> Enum.join() |> String.trim()}

  defp finish_message(message), do: message

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

  `:project_id` narrows it to one project; without it this is every conversation on the node.

  Live first because that is the one costing something and holding a machine. The rest are a
  record — a conversation is kept for ever, so this list only grows, and what it is for is
  finding one again rather than watching them all.
  """
  @spec summaries(keyword()) :: [summary()]
  def summaries(opts \\ []) do
    chats =
      case Keyword.get(opts, :project_id) do
        nil -> Repo.all(from j in Job, where: j.kind == :chat, order_by: [desc: j.inserted_at])
        id -> Jobs.chats_for_project(id)
      end

    decorate(chats)
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
  defp transcript_ref(job) do
    with %{blob_uri: uri} when is_binary(uri) <- newest_transcript(job),
         {:ok, key} <- Forge.Storage.key_from_uri(uri) do
      %{"key" => key, "token" => Forge.Storage.Token.sign(:get, key)}
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
