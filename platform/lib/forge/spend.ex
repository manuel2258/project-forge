defmodule Forge.Spend do
  @moduledoc """
  What the platform is allowed to use, and what it has, in weighted tokens (`ForgeCore.Usage`).

  Two caps, and `docs/design/capacity.md` settles why they are not the same thing. A **ticket
  allowance** — `limits.ticket_tokens` from the pinned workflow — is resolved by a human raising it
  or rerouting the work, so exhausting it sticks the ticket and puts it in the queue. A **daily
  cap** is resolved by time, like the provider's own window, so exhausting it pauses the node and
  the ticket stays `active` and out of the queue. A paused ticket in the inbox would train the
  operator to open items they cannot act on.

  The day's total is the sum of the usage of the runs that *started* in that UTC day — each start
  of a job is a run (`Forge.Jobs.Runs`): monotonic, and it matches what the operator watched
  happen. Per run rather than per job, so a job that resumes the next day spends on the day it
  ran, and so a credential's figure, read from the same rows, adds up with this one. A job in flight has recorded nothing yet — usage
  lands at completion — so `committed/0` adds the budget of every live job to what is already
  spent. Without that, several concurrent jobs each pass the gate on their own and together walk
  through the cap.
  """

  import Ecto.Query, only: [from: 2]

  alias Forge.Jobs.{Job, Run}
  alias Forge.Repo
  alias Forge.Tickets.Ticket
  alias ForgeCore.Workflow

  # A job started at the cap's edge would otherwise be handed a budget of nothing and be stopped
  # on its first call, having billed an invocation to learn what the gate already knew.
  @floor 10_000

  @typedoc "What the gate says about starting a job for this ticket."
  @type verdict :: :ok | {:stick, String.t()} | {:pause, String.t()}

  @doc "The smallest budget a job is ever handed, in weighted tokens."
  @spec floor() :: pos_integer()
  def floor, do: @floor

  @doc "Total usage of the runs that started on `date`, in UTC, in weighted tokens."
  @spec day_total(Date.t()) :: non_neg_integer()
  def day_total(date \\ Date.utc_today()) do
    {from_time, until} = day(date)

    Repo.one(
      from r in Run,
        where: r.started_at >= ^from_time and r.started_at < ^until,
        select: type(coalesce(sum(r.usage), 0), :integer)
    )
  end

  @doc """
  The UTC day `date` is, as `[from, until)`: what "used today" means everywhere it is said — the
  node's cap here and a credential's figure in `Forge.Credentials.used_today/2` — so the two add
  up rather than disagree about where a day ends.
  """
  @spec day(Date.t()) :: {DateTime.t(), DateTime.t()}
  def day(date \\ Date.utc_today()) do
    {:ok, from_time} = DateTime.new(date, ~T[00:00:00], "Etc/UTC")
    {from_time, DateTime.add(from_time, 86_400, :second)}
  end

  @doc """
  Today's usage, plus what every live job is still budgeted to use. The conservative figure,
  because a running job's usage is unknown until it ends.
  """
  @spec committed() :: non_neg_integer()
  def committed, do: day_total() + budgeted_live()

  # Workflow jobs only, and explicitly rather than by accident: a conversation has no spec and so
  # no budget to commit against the day. What it has used is already in `day_total/0`, because
  # a conversation records its usage per turn instead of once at the end — it does not have an
  # end until a person says so, and a cap that cannot see a job running all afternoon is not a
  # cap. See `docs/design/conversations.md` § Spend.
  defp budgeted_live do
    from(j in Job,
      where: j.status in [:pending, :running] and j.kind == :workflow,
      select: j.spec
    )
    |> Repo.all()
    |> Enum.reduce(0, fn spec, acc -> acc + budget_tokens(spec) end)
  end

  # A spec stored before budgets were counted in tokens carries `cost`, in dollars, and is read
  # the way `ForgeCore.Job.Spec` reads it.
  defp budget_tokens(spec) do
    case get_in(spec, ["budget", "tokens"]) do
      tokens when is_integer(tokens) ->
        tokens

      _ ->
        case get_in(spec, ["budget", "cost"]) do
          cost when is_number(cost) -> ForgeCore.Usage.from_dollars(cost)
          _ -> 0
        end
    end
  end

  @doc "What is left of the ticket's own allowance."
  @spec ticket_remaining(Ticket.t(), Workflow.t()) :: non_neg_integer()
  def ticket_remaining(%Ticket{usage: used}, %Workflow{limits: %{ticket_tokens: cap}}) do
    max(cap - (used || 0), 0)
  end

  @doc "The configured daily cap in weighted tokens, or `nil` when there is none."
  @spec daily_cap() :: non_neg_integer() | nil
  def daily_cap, do: Application.get_env(:forge, __MODULE__, [])[:daily_tokens]

  @doc "What is left of today, or `:unlimited` when no daily cap is configured."
  @spec day_remaining() :: non_neg_integer() | :unlimited
  def day_remaining do
    case daily_cap() do
      nil -> :unlimited
      cap -> max(cap - committed(), 0)
    end
  end

  @doc """
  Whether a job for this ticket may start now, and which cap says otherwise.

  `{:stick, reason}` is the ticket's own allowance: a human decides what happens next.
  `{:pause, reason}` is the daily cap: midnight decides, and the ticket keeps waiting.
  """
  @spec gate(Ticket.t(), Workflow.t()) :: verdict()
  def gate(%Ticket{} = ticket, %Workflow{} = workflow) do
    cond do
      ticket_remaining(ticket, workflow) <= 0 ->
        {:stick, "ticket usage cap reached"}

      paused?() ->
        {:pause, "daily usage cap reached"}

      true ->
        :ok
    end
  end

  @doc """
  Whether anything may start now on the day's allowance alone.

  This is `gate/2` without the ticket half, for work that has no ticket allowance and no workflow
  to read one from. A conversation is the only such work, and the daily cap is its only ceiling.
  """
  @spec day_gate() :: :ok | {:pause, String.t()}
  def day_gate do
    if paused?(), do: {:pause, "daily usage cap reached"}, else: :ok
  end

  @doc "Whether the node is paused on the daily cap."
  @spec paused?() :: boolean()
  def paused? do
    case day_remaining() do
      :unlimited -> false
      remaining -> remaining <= 0
    end
  end

  @doc """
  The token budget a job actually runs with: the smallest of what its state declared, what the
  ticket has left and what the day has left.

  The stored spec is not touched — a job's budget is written once — and the difference is recorded
  as a `job.budget_lowered` event, without which a job stopping at a tenth of its declared budget
  is inexplicable to anyone reading the log afterwards.
  """
  @spec effective_tokens(non_neg_integer(), Ticket.t(), Workflow.t()) ::
          {non_neg_integer(), atom()}
  def effective_tokens(state_tokens, %Ticket{} = ticket, %Workflow{} = workflow) do
    candidates =
      [{state_tokens, :state}, {ticket_remaining(ticket, workflow), :ticket}] ++ day_candidate()

    {tokens, binding} = Enum.min_by(candidates, fn {value, _from} -> value end)
    {max(tokens, @floor), binding}
  end

  defp day_candidate do
    case day_remaining() do
      :unlimited -> []
      remaining -> [{remaining, :day}]
    end
  end
end
