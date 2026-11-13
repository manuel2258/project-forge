defmodule ForgeWorker.Job.Meter do
  @moduledoc """
  Counts what a run uses, call by call, as the harness streams it, in weighted tokens
  (`ForgeCore.Usage`; `docs/design/capacity.md` § Usage in weighted tokens).

  A harness driver emits a `usage` event for each model call it sees — `message_id`, and `tokens`
  by kind. **One call is counted once**: Claude Code's stream repeats a call across several
  `assistant` lines, each carrying the call's `usage` as it stood, so the meter keeps what it has
  counted per `message_id` and a repeated line adds only its increase (per kind, never a
  decrease). A subagent's lines count like any other, because they carry their own ids. Only
  calls this process made are in the sum, so a resumed run's usage is its own and never its
  session's running total.

  `over?/2` is the whole of "forge stops a run itself": the runner asks it after every line and
  stops the process once usage has passed its budget. The call that crosses the line has already
  been paid for, and the process is stopped by a signal, so a run overshoots by what the harness
  streams before it ends: that call and anything already in flight. That is the cap working, as
  the dollar cap did, and it is not bounded at one call.
  """

  alias ForgeCore.Usage

  defstruct counted: %{}, tokens: %{input: 0, cache_write: 0, cache_read: 0, output: 0}

  @type t :: %__MODULE__{counted: %{String.t() => Usage.tokens()}, tokens: Usage.tokens()}

  @doc "A meter that has counted nothing."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Takes one `usage` event's payload into the count."
  @spec observe(t(), map()) :: t()
  def observe(%__MODULE__{} = meter, %{message_id: id, tokens: tokens}) when is_binary(id) do
    seen = Usage.normalize(Map.get(meter.counted, id))
    now = Usage.normalize(tokens)

    # Per kind the larger of the two, so a line that repeats a call with less than a line before
    # it (a partial write) cannot take tokens back.
    kept = Map.new(Usage.kinds(), fn kind -> {kind, max(seen[kind], now[kind])} end)
    added = Map.new(Usage.kinds(), fn kind -> {kind, kept[kind] - seen[kind]} end)

    %{meter | counted: Map.put(meter.counted, id, kept), tokens: Usage.add(meter.tokens, added)}
  end

  def observe(%__MODULE__{} = meter, _payload), do: meter

  @doc "Weighted tokens counted so far."
  @spec usage(t()) :: non_neg_integer()
  def usage(%__MODULE__{tokens: tokens}), do: Usage.weigh(tokens)

  @doc "Tokens counted so far, by kind."
  @spec tokens(t()) :: Usage.tokens()
  def tokens(%__MODULE__{tokens: tokens}), do: tokens

  @doc """
  Whether usage has passed `budget`. A run with no budget (`nil`) is never over, and a run is over
  only when it has *passed* the line: using exactly the budget is not exceeding it.
  """
  @spec over?(t(), non_neg_integer() | nil) :: boolean()
  def over?(_meter, nil), do: false
  def over?(%__MODULE__{} = meter, budget), do: usage(meter) > budget
end
