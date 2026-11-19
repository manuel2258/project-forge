defmodule Forge.Jobs.Extensions do
  @moduledoc """
  What a person may give a job that ran out of budget, and when
  (`docs/design/workflow-grammar-v1.md` § Extending a job).

  **One definition of "extendable", for the offer and the act.** `extendable/3` is what
  `Forge.Engine.extend/5` checks inside its transaction, on the rows it has locked, and `offer/1`
  is what the ticket page, the queue and the API show beforehand — through the same function, so a
  surface never offers what the act would refuse (`CLAUDE.md` § Rules: a guard uses the model of
  the operation it guards).

  Also here: the extension record's reads (`current/1`, `all/1`), and the parsing of what a person
  typed into the Extend and Run again forms, which is pure.
  """

  import Ecto.Query, only: [from: 2]

  alias Forge.Jobs
  alias Forge.Jobs.{Extension, Job, Run}
  alias Forge.MergeQueue
  alias Forge.Repo
  alias Forge.Spend
  alias Forge.Tickets
  alias Forge.Tickets.Ticket
  alias ForgeCore.{Harness, Usage}
  alias ForgeCore.Workflow
  alias ForgeCore.Workflow.State

  @typedoc "Why a job cannot be extended."
  @type why ::
          :not_stuck
          | :queued
          | :wrong_ticket
          | :not_this_state
          | :not_an_agent_state
          | :not_a_workflow_job
          | :not_finished
          | :not_exhausted
          | :not_the_latest_attempt
          | :no_session
          | :workflow_broken

  @doc """
  Whether `job` may be extended on `ticket` now: `:ok`, or the refusal.

  The ticket is stuck and not in the merge queue; the job is this ticket's, of the state it rests
  in, an agent state's (a prompt, not a chat); the job is a workflow job that finished
  `budget_exhausted`, is the highest attempt of its state, and no job of the state is live; and it
  kept a session to continue (`harness_session_id` and `session_blob`). A job that ended any other
  way has *Run again* only.
  """
  @spec extendable(Ticket.t(), Job.t(), Workflow.t()) ::
          :ok
          | {:error,
             {:not_extendable, why()} | {:job_live, String.t()} | {:step_live, String.t()}}
  def extendable(%Ticket{} = ticket, %Job{} = job, %Workflow{} = workflow) do
    with :ok <- ensure(ticket.status == :stuck, :not_stuck),
         # Not reached through the engine — sticking a ticket takes it out of the merge queue
         # (`Forge.Engine.put_stuck/4`) — and asked because every other act on a ticket's state asks
         # it, and an extension is not to be the one that does not. Tested on a queue row written
         # by hand (`extend_test.exs`).
         :ok <- ensure(not MergeQueue.queued?(ticket), :queued),
         :ok <- ensure(job.ticket_id == ticket.id, :wrong_ticket),
         :ok <- ensure(job.state == ticket.state, :not_this_state),
         :ok <- ensure(agent_state?(workflow, ticket.state), :not_an_agent_state),
         :ok <- ensure(job.kind == :workflow, :not_a_workflow_job),
         :ok <- ensure(job.status == :finished, :not_finished),
         :ok <- ensure(job.outcome == :budget_exhausted, :not_exhausted),
         :ok <- ensure(latest_attempt?(job), :not_the_latest_attempt),
         :ok <- Forge.Engine.no_live_job(ticket) do
      ensure(is_binary(job.harness_session_id) and is_map(job.session_blob), :no_session)
    end
  end

  defp ensure(true, _why), do: :ok
  defp ensure(false, why), do: {:error, {:not_extendable, why}}

  # A prompt and not a chat: the states `Forge.Engine.retry/3` runs as a job. A command state has
  # no session, and a chat step is carried on by a message.
  defp agent_state?(workflow, state) do
    case Workflow.state(workflow, state) do
      %State{chat: chat, prompt: prompt} when is_binary(prompt) and chat != true -> true
      _human_command_chat_or_missing -> false
    end
  end

  defp latest_attempt?(%Job{ticket_id: ticket_id, state: state, attempt: attempt}) do
    latest =
      Repo.one(
        from j in Job,
          where: j.ticket_id == ^ticket_id and j.state == ^state and j.kind == :workflow,
          select: max(j.attempt)
      )

    latest == attempt
  end

  @doc """
  What the Extend form is drawn from, or nil when the ticket's job cannot be extended: the job that
  ran out, what it has used and what the state declared, the half of each the boxes start at, and
  what the ticket has left of its cap.

  The job is the latest of the ticket's state, and what is asked of it is `extendable/3`'s.
  """
  @spec offer(Ticket.t()) :: map() | nil
  def offer(%Ticket{status: :stuck} = ticket) do
    with {:ok, workflow} <- Tickets.parsed_workflow(ticket),
         %Job{} = job <- latest_job(ticket),
         :ok <- extendable(ticket, job, workflow) do
      spec = Jobs.spec(job)
      bounded = Harness.bounds_turns?(job.harness)

      %{
        job_id: job.id,
        state: job.state,
        attempt: job.attempt,
        exhausted: job.exhausted,
        used_tokens: job.usage,
        used_turns: job.turns,
        runs: Repo.aggregate(from(r in Jobs.Run, where: r.job_id == ^job.id), :count),
        extensions: Repo.aggregate(from(e in Extension, where: e.job_id == ^job.id), :count),
        declared_tokens: spec.budget.tokens,
        declared_turns: spec.budget.turns,
        default_tokens: half(spec.budget.tokens),
        default_turns: half(spec.budget.turns),
        bounds_turns: bounded,
        left: Spend.ticket_remaining(ticket, workflow),
        cap: Spend.ticket_cap(ticket, workflow),
        cap_raise: ticket.cap_raise,
        workflow_cap: workflow.limits.ticket_tokens
      }
    else
      _not_offered -> nil
    end
  end

  def offer(%Ticket{}), do: nil

  # Rounded up: a 12M / 150-turn state starts at 6M and 75, and an odd figure never starts at zero.
  defp half(n) when is_integer(n), do: div(n + 1, 2)

  defp latest_job(%Ticket{id: id, state: state}) do
    Repo.one(
      from j in Job,
        where: j.ticket_id == ^id and j.state == ^state and j.kind == :workflow,
        order_by: [desc: j.attempt, desc: j.inserted_at],
        limit: 1
    )
  end

  @doc "The job's latest extension, or nil."
  @spec current(Job.t() | String.t()) :: Extension.t() | nil
  def current(%Job{id: id}), do: current(id)

  def current(job_id) when is_binary(job_id) do
    Repo.one(
      from e in Extension,
        where: e.job_id == ^job_id,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: 1
    )
  end

  @doc """
  Whether no run has yet been started on this extension: the next run is the one the person gave it
  to, and is told so (`job_runs.extension_id` is stamped on that run alone). A run the platform
  took back with no result — the harness refused its session (`Forge.Jobs.requeue_fresh/3`), its
  machine was lost or never reached, or it hibernated — is not one: it lets go of the extension, so
  the run that follows is told as the first would have been.
  Every later run of the job keeps the extension's ceiling and is told what any resume is.
  """
  @spec first_run?(Extension.t()) :: boolean()
  def first_run?(%Extension{id: id}),
    do: not Repo.exists?(from r in Run, where: r.extension_id == ^id)

  @doc """
  Whether the run being assigned is a later one than the extension's own: the job's open run — the
  one `Forge.Jobs.mark_started/3` has just opened, the only one a job has open — is not the one
  stamped with the extension, or it is not the only one that is. Read after the run is opened, which
  is when the spec is built. (Runs are timed to the second, so "latest" is not asked of them.)
  """
  @spec later_run?(Job.t(), Extension.t()) :: boolean()
  def later_run?(%Job{id: job_id}, %Extension{id: id}) do
    open =
      Repo.one(
        from r in Run,
          where: r.job_id == ^job_id and is_nil(r.finished_at),
          limit: 1,
          select: r.extension_id
      )

    stamped = Repo.aggregate(from(r in Run, where: r.extension_id == ^id), :count)
    not (open == id and stamped == 1)
  end

  @doc "The extension the job's next run is the first of, or nil: what the run is stamped with."
  @spec to_tell(Job.t()) :: Extension.t() | nil
  def to_tell(%Job{} = job) do
    case current(job) do
      %Extension{} = extension -> if first_run?(extension), do: extension
      nil -> nil
    end
  end

  @doc "The job's extensions, oldest first: the order they were given in."
  @spec all(String.t()) :: [Extension.t()]
  def all(job_id) do
    Repo.all(
      from e in Extension,
        where: e.job_id == ^job_id,
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  @doc """
  Who gave an extension, as every author is served (`Forge.Artifacts` answers, the review): a
  person is `%{kind: "user", id: id, name: nil}` — the platform names no person's address to an API
  client — and a project token `%{kind: "api", id: id, name: its name}`.
  """
  @spec author(Extension.t() | Forge.Tickets.Restart.t() | Forge.Tickets.CapRaise.t()) :: map()
  def author(%{token_id: token_id}) when is_binary(token_id),
    do: %{kind: "api", id: token_id, name: Repo.get!(Forge.Git.Token, token_id).name}

  def author(%{user_id: user_id}), do: %{kind: "user", id: user_id, name: nil}

  @doc "Which extension of its job this is: 1 for the first."
  @spec number(Extension.t()) :: pos_integer()
  def number(%Extension{job_id: job_id, id: id}) do
    all(job_id) |> Enum.find_index(&(&1.id == id)) |> Kernel.+(1)
  end

  @doc """
  What the Extend and Run again forms are drawn against, apart from the job: what the ticket has
  left of its cap, the cap and the raise on it, and what *Run again* would need — the state's
  declared tokens, 0 for a state that spends none. One function for the ticket page, the queue and
  the API, so the three never draw different figures.
  """
  @spec cap_facts(Ticket.t(), Workflow.t()) :: map()
  def cap_facts(%Ticket{} = ticket, %Workflow{} = workflow) do
    %{
      left: Spend.ticket_remaining(ticket, workflow),
      cap: Spend.ticket_cap(ticket, workflow),
      cap_raise: ticket.cap_raise,
      workflow_cap: workflow.limits.ticket_tokens,
      restart_need: restart_need(workflow, ticket.state)
    }
  end

  @doc """
  What running the state again is given to spend, in weighted tokens: its declared budget. A
  command state, a human state and a chat spend none, so the cap never refuses them.
  """
  @spec restart_need(Workflow.t(), String.t()) :: non_neg_integer()
  def restart_need(%Workflow{} = workflow, state) do
    case Workflow.state(workflow, state) do
      %State{chat: chat, prompt: prompt, budget: %{tokens: tokens}}
      when is_binary(prompt) and chat != true ->
        tokens

      _spends_nothing ->
        0
    end
  end

  @doc """
  A refusal of `extend` or *Run again* in the words a person acts on, or nil for one that is not
  these: the page draws it under the form, and the API says it as the detail of its error.
  """
  @spec explain(term()) :: String.t() | nil
  def explain({:not_extendable, why}), do: "it cannot be extended: " <> why_not(why)

  def explain({:invalid_tokens, _raw}),
    do: "the tokens must be a positive amount such as 800k, 1.5M or 2000000"

  def explain({:invalid_turns, _raw}), do: "the turns must be a positive whole number"

  def explain({:note_too_long, length}),
    do: "the note is #{length} characters and the longest is #{Extension.note_limit()}"

  def explain({:invalid_note, _raw}), do: "the note must be text, without a NUL byte"

  def explain({:invalid_raise, _raw}),
    do: "the cap raise must be a positive amount such as 2M or 2000000, or empty"

  def explain({:raise_short, left, shortfall}),
    do:
      "the ticket has #{Usage.format(left)} left of its cap, so the cap must be raised by at " <>
        "least #{Usage.format(shortfall)}"

  def explain(:raise_not_needed),
    do: "the ticket has enough left of its cap, so there is nothing to raise"

  def explain(_other), do: nil

  defp why_not(:not_stuck), do: "its ticket is not stuck"
  defp why_not(:queued), do: "its ticket is in the merge queue"
  defp why_not(:wrong_ticket), do: "it belongs to another ticket"
  defp why_not(:not_this_state), do: "the ticket has moved to another state"
  defp why_not(:not_an_agent_state), do: "its state runs no agent"
  defp why_not(:not_a_workflow_job), do: "it is not a workflow job"
  defp why_not(:not_finished), do: "it has not finished"
  defp why_not(:not_exhausted), do: "it did not run out of budget"
  defp why_not(:not_the_latest_attempt), do: "a later attempt of its state exists"
  defp why_not(:no_session), do: "it left no session to continue; run the state again"
  defp why_not(:workflow_broken), do: "the ticket's workflow no longer parses"
  defp why_not(:cancelled), do: "its ticket is cancelled"
  defp why_not(:done), do: "its ticket is done"
  defp why_not(other), do: to_string(other)

  # -- what a person typed ----------------------------------------------------------------------

  @typedoc "What an Extend submission parses to."
  @type figures :: %{
          tokens: pos_integer(),
          turns: pos_integer() | nil,
          note: String.t() | nil,
          raise: pos_integer() | nil
        }

  @max_turns 2_147_483_647

  @doc """
  Parses the Extend form's fields: `tokens` in the grammar `ForgeCore.Usage.parse/1` reads
  (`800k`, `1.5M`, `2000000`), `turns` as a whole number — read only where the harness bounds them
  (`bounds_turns?`), and blank meaning the job's own — a `note` and a `raise`.

  Errors are named for the field and carry what was typed, so a surface can say which box and keep
  its text: `{:invalid_tokens, raw}`, `{:invalid_turns, raw}`, `{:note_too_long, length}`,
  `{:invalid_note, raw}`, `{:invalid_raise, raw}`.
  """
  @spec parse(map(), boolean()) :: {:ok, figures()} | {:error, term()}
  def parse(attrs, bounds_turns?) when is_map(attrs) do
    with {:ok, tokens} <- tokens(field(attrs, :tokens)),
         {:ok, turns} <- turns(field(attrs, :turns), bounds_turns?),
         {:ok, note} <- note(field(attrs, :note)),
         {:ok, raise} <- raise_amount(field(attrs, :raise)) do
      {:ok, %{tokens: tokens, turns: turns, note: note, raise: raise}}
    end
  end

  @doc "Parses a note and a raise alone, as *Run again* takes them."
  @spec parse_restart(map()) ::
          {:ok, %{note: String.t() | nil, raise: pos_integer() | nil}} | {:error, term()}
  def parse_restart(attrs) when is_map(attrs) do
    with {:ok, note} <- note(field(attrs, :note)),
         {:ok, raise} <- raise_amount(field(attrs, :raise)) do
      {:ok, %{note: note, raise: raise}}
    end
  end

  defp field(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp tokens(raw) do
    case Usage.parse(raw) do
      {:ok, tokens} when tokens > 0 -> {:ok, tokens}
      _invalid -> {:error, {:invalid_tokens, raw}}
    end
  end

  defp turns(_raw, false), do: {:ok, nil}
  defp turns(raw, true) when raw in [nil, ""], do: {:ok, nil}
  defp turns(raw, true) when is_integer(raw) and raw > 0 and raw <= @max_turns, do: {:ok, raw}

  defp turns(raw, true) when is_binary(raw) do
    case Integer.parse(String.trim(raw)) do
      {turns, ""} when turns > 0 and turns <= @max_turns -> {:ok, turns}
      _invalid -> {:error, {:invalid_turns, raw}}
    end
  end

  defp turns(raw, true), do: {:error, {:invalid_turns, raw}}

  defp note(nil), do: {:ok, nil}

  # Text the database can store: it refuses a NUL byte and a string that is not UTF-8 outright, and
  # that would raise in the act instead of being refused under the form (as `Forge.Secrets` says of
  # a name). A JSON `\u0000` is enough to send one.
  defp note(raw) when is_binary(raw) do
    if String.valid?(raw) and not String.contains?(raw, <<0>>),
      do: note_text(String.trim(raw)),
      else: {:error, {:invalid_note, raw}}
  end

  defp note(raw), do: {:error, {:invalid_note, raw}}

  defp note_text(trimmed) do
    case trimmed do
      "" ->
        {:ok, nil}

      note ->
        # Codepoints, as the database's `char_length` check counts them: a note of 4,000 accented
        # letters is 4,000 graphemes and, written as e + a combining mark, 8,000 codepoints.
        length = note |> String.to_charlist() |> length()

        if length > Extension.note_limit(),
          do: {:error, {:note_too_long, length}},
          else: {:ok, note}
    end
  end

  defp raise_amount(raw) when raw in [nil, "", 0], do: {:ok, nil}

  defp raise_amount(raw) do
    case Usage.parse(raw) do
      {:ok, 0} -> {:ok, nil}
      {:ok, amount} -> {:ok, amount}
      _invalid -> {:error, {:invalid_raise, raw}}
    end
  end

  @doc """
  What the cap says about `need` weighted tokens on a ticket with `left` of it, and the `raise` a
  person asked for: `{:ok, raise}` (nil for none) or the refusal.

  - Nothing short: a raise is refused, because there is no raise anywhere but the two forms and
    one that nothing asks for is a mistake (`:raise_not_needed`).
  - Short, `strict?` (an extension, and a restart of a ticket with nothing left): a raise below the
    shortfall is refused, `{:raise_short, left, shortfall}`.
  - Short, not strict (a restart with something left): any raise is taken, and none runs the job
    lowered to what is left.
  """
  @spec check_cap(non_neg_integer(), non_neg_integer(), pos_integer() | nil, boolean()) ::
          {:ok, pos_integer() | nil} | {:error, term()}
  def check_cap(need, left, raise, strict?),
    do: judge(max(need - left, 0), left, raise, strict?)

  # Nothing short: a raise nothing asks for is refused.
  defp judge(0, _left, nil, _strict?), do: {:ok, nil}
  defp judge(0, _left, _raise, _strict?), do: {:error, :raise_not_needed}

  # Short and not strict (a restart with something left): no raise runs lowered, and any raise is
  # taken. Strict (an extension, a restart with nothing left): a raise covering the shortfall.
  defp judge(_shortfall, _left, nil, false), do: {:ok, nil}
  defp judge(shortfall, left, nil, true), do: {:error, {:raise_short, left, shortfall}}

  defp judge(shortfall, left, raise, true) when raise < shortfall,
    do: {:error, {:raise_short, left, shortfall}}

  defp judge(_shortfall, _left, raise, _strict?), do: {:ok, raise}
end
