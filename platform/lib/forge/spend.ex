defmodule Forge.Spend do
  @moduledoc """
  What the platform is allowed to spend, and what it has.

  Two caps, and `docs/design/capacity.md` settles why they are not the same thing. A **ticket
  allowance** — `limits.ticket_cost` from the pinned workflow — is resolved by a human raising it
  or rerouting the work, so exhausting it sticks the ticket and puts it in the queue. A **daily
  cap** is resolved by time, like the provider's own window, so exhausting it pauses the node and
  the ticket stays `active` and out of the queue. A paused ticket in the inbox would train the
  operator to open items they cannot act on.

  The day's total is the sum of job costs where the job *started* in that UTC day: monotonic, and
  it matches what the operator watched happen. A job in flight has recorded nothing yet — cost
  lands at completion — so `committed/0` adds the budget of every live job to what is already
  spent. Without that, several concurrent jobs each pass the gate on their own and together walk
  through the cap.
  """

  import Ecto.Query, only: [from: 2]

  alias Forge.Jobs.Job
  alias Forge.Repo
  alias Forge.Tickets.Ticket
  alias ForgeCore.Workflow

  # A job started at the cap's edge would otherwise be handed a budget of zero and die on its
  # first turn, having billed an invocation to learn what the gate already knew.
  @floor 0.01

  @typedoc "What the gate says about starting a job for this ticket."
  @type verdict :: :ok | {:stick, String.t()} | {:pause, String.t()}

  @doc "Total cost of jobs that started on `date`, in UTC."
  @spec day_total(Date.t()) :: Decimal.t()
  def day_total(date \\ Date.utc_today()) do
    {:ok, from_time} = DateTime.new(date, ~T[00:00:00], "Etc/UTC")
    until = DateTime.add(from_time, 86_400, :second)

    Repo.one(
      from j in Job,
        where: j.started_at >= ^from_time and j.started_at < ^until,
        select: coalesce(sum(j.cost_usd), 0)
    )
  end

  @doc """
  Today's spend, plus what every live job is still budgeted to spend. The conservative figure,
  because a running job's cost is unknown until it ends.
  """
  @spec committed() :: Decimal.t()
  def committed do
    Decimal.add(day_total(), budgeted_live())
  end

  # Workflow jobs only, and explicitly rather than by accident: a conversation has no spec and so
  # no budget to commit against the day. What it has spent is already in `day_total/0`, because
  # a conversation records its cost per turn instead of once at the end — it does not have an
  # end until a person says so, and a cap that cannot see a job running all afternoon is not a
  # cap. See `docs/design/conversations.md` § Spend.
  defp budgeted_live do
    from(j in Job,
      where: j.status in [:pending, :running] and j.kind == :workflow,
      select: j.spec
    )
    |> Repo.all()
    |> Enum.reduce(Decimal.new(0), fn spec, acc ->
      Decimal.add(acc, decimal(get_in(spec, ["budget", "cost"])))
    end)
  end

  @doc "What is left of the ticket's own allowance."
  @spec ticket_remaining(Ticket.t(), Workflow.t()) :: Decimal.t()
  def ticket_remaining(%Ticket{cost_usd: spent}, %Workflow{limits: %{ticket_cost: cap}}) do
    cap |> decimal() |> Decimal.sub(spent) |> Decimal.max(0)
  end

  @doc "The configured daily cap, or `nil` when there is none."
  @spec daily_cap() :: Decimal.t() | nil
  def daily_cap do
    case Application.get_env(:forge, __MODULE__, [])[:daily_cost_usd] do
      nil -> nil
      value -> decimal(value)
    end
  end

  @doc "What is left of today, or `:unlimited` when no daily cap is configured."
  @spec day_remaining() :: Decimal.t() | :unlimited
  def day_remaining do
    case daily_cap() do
      nil -> :unlimited
      cap -> cap |> Decimal.sub(committed()) |> Decimal.max(0)
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
      Decimal.compare(ticket_remaining(ticket, workflow), 0) != :gt ->
        {:stick, "ticket cost cap reached"}

      paused?() ->
        {:pause, "daily spend cap reached"}

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
    if paused?(), do: {:pause, "daily spend cap reached"}, else: :ok
  end

  @doc "Whether the node is paused on the daily cap."
  @spec paused?() :: boolean()
  def paused? do
    case day_remaining() do
      :unlimited -> false
      remaining -> Decimal.compare(remaining, 0) != :gt
    end
  end

  @doc """
  The cost budget a job actually runs with: the smallest of what its state declared, what the
  ticket has left and what the day has left.

  The stored spec is not touched — a job's budget is written once — and the difference is recorded
  as a `job.budget_lowered` event, without which a job stopping at a tenth of its declared budget
  is inexplicable to anyone reading the log afterwards.
  """
  @spec effective_cost(number(), Ticket.t(), Workflow.t()) :: {float(), atom()}
  def effective_cost(state_cost, %Ticket{} = ticket, %Workflow{} = workflow) do
    candidates =
      [
        {decimal(state_cost), :state},
        {ticket_remaining(ticket, workflow), :ticket}
      ] ++ day_candidate()

    {cost, binding} = Enum.min_by(candidates, fn {value, _from} -> Decimal.to_float(value) end)
    {max(Decimal.to_float(cost), @floor), binding}
  end

  defp day_candidate do
    case day_remaining() do
      :unlimited -> []
      remaining -> [{remaining, :day}]
    end
  end

  defp decimal(nil), do: Decimal.new(0)
  defp decimal(%Decimal{} = value), do: value
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
end
