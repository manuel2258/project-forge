defmodule ForgeWeb.JobStream do
  @moduledoc """
  A job's event stream as a page holds it: **a page of it, read from the database, and kept current
  from the job's own topic** (`Forge.Events.notify_job/2`).

  It used to be the whole log, read once when the page loaded, which for a job of seventeen thousand
  events was seventeen thousand rows on every visit and every reload
  (`docs/design/storage.md` § Retention). Now a stream is read **a page at a time**
  (`Forge.Events.Stream`): the newest `page/0` entries when it is opened, the next older page when
  the reader reaches the old end (`older/1`), what arrived above it when the page reloads
  (`reload/1`), and everything back to a position when a dropped socket rejoins (`rejoin/2`). The
  figures it is headed by are counted by the database and move by one for each event heard.

  Three pages hold one or more: a conversation's Activity, a ticket's (its current job's) and a
  job's, which also holds its raw log as a stream of its own (`kind: :raw`). What they share is
  here, so an event is added to each the same way, in one assign.

  **An event is added by its place, not by when it arrived.** Events are numbered as they are
  written (`seq`), and two written in different transactions can be committed — and so announced
  — in the other order. A page that dropped everything numbered below the last it held dropped
  the one that came second. So an event already held is skipped, and any other is put where its
  number says, whichever order the two were heard in. An event numbered below everything held,
  while older entries wait unread, belongs to a page not read yet, and is counted and not held.
  """

  alias Forge.Events.{Event, Stream}

  # The largest `seq` there is: a position past it is no position, and the database would refuse it.
  @bigint 9_223_372_036_854_775_807

  defstruct job_id: nil,
            # nil until the stream is opened: a page counts a stream it is not showing.
            events: nil,
            more: false,
            notices: false,
            count: 0,
            notice_count: 0,
            # How far the figures of a stream **not opened** have read: an event numbered at or below
            # is in them. An opened stream holds its events and says what it has by those.
            counted_to: 0,
            # How far `notice_count` reads: a notice hidden is counted by the database and not held,
            # so one numbered at or below this was counted when the figures were last counted.
            notices_to: 0,
            kind: :entries

  @type t :: %__MODULE__{
          job_id: String.t(),
          events: [Event.t()] | nil,
          more: boolean(),
          notices: boolean(),
          count: non_neg_integer(),
          notice_count: non_neg_integer(),
          counted_to: non_neg_integer(),
          notices_to: non_neg_integer(),
          kind: :entries | :raw
        }

  @doc "How many entries a stream reads at first, and how many more each older page adds."
  @spec page() :: pos_integer()
  def page, do: 50

  @doc """
  A stream of `job_id` not yet opened, with its figures counted. A page that is not showing it
  holds this much, and `open/1` reads it when it is.
  """
  @spec new(String.t(), :entries | :raw) :: t()
  def new(job_id, kind \\ :entries), do: count(%__MODULE__{job_id: job_id, kind: kind})

  @doc "Whether the stream has been read."
  @spec open?(t() | nil) :: boolean()
  def open?(%__MODULE__{events: events}), do: is_list(events)
  def open?(nil), do: false

  @doc "What the stream holds, oldest first; nothing before it is opened."
  @spec held(t()) :: [Event.t()]
  def held(%__MODULE__{events: nil}), do: []
  def held(%__MODULE__{events: events}), do: events

  @doc "Reads the newest page, or `limit` entries when a toggle or a reload asks for as many as were drawn."
  @spec open(t(), pos_integer()) :: t()
  def open(%__MODULE__{} = stream, limit \\ page()) do
    %{events: events, more: more} = read(stream, nil, limit)
    count(%{stream | events: events, more: more})
  end

  @doc "Reads the next older page above what is held, which is the old end of the stream."
  @spec older(t()) :: t()
  def older(%__MODULE__{events: nil} = stream), do: open(stream)
  def older(%__MODULE__{events: []} = stream), do: stream

  def older(%__MODULE__{events: [oldest | _rest] = held} = stream) do
    %{events: events, more: more} = read(stream, oldest.seq, page())
    %{stream | events: merge(events, held), more: more}
  end

  @doc """
  Reads the stream again as far back as `position`, in one query bounded by it (`from/3`). A
  position that is not a whole number above zero, or that is not the stream's — a rejoin carries
  one for each stream the page held, and takes only its own — reads the newest page.
  """
  @spec rejoin(t(), term()) :: t()
  # `position > 0` is an equivalent mutant: `reach/2` is the only caller's source of a position and
  # returns nil for anything that is not above zero, so dropping the guard changes nothing a test
  # can reach. It stays as the function's own statement of what it takes.
  def rejoin(%__MODULE__{} = stream, position) when is_integer(position) and position > 0 do
    %{events: events, more: more} =
      case stream.kind do
        :entries -> Stream.from(stream.job_id, position, stream.notices)
        :raw -> Stream.raw_from(stream.job_id, position)
      end

    count(%{stream | events: events, more: more})
  end

  def rejoin(%__MODULE__{} = stream, _position), do: open(stream)

  @doc """
  What a reload does: the events above what is held are read and added, and the figures counted
  again. A stream not opened is only counted; one that heard its job's rows swept is read afresh,
  as many entries as it was holding.
  """
  @spec reload(t()) :: t()
  def reload(%__MODULE__{events: nil} = stream), do: count(stream)
  def reload(%__MODULE__{events: []} = stream), do: open(stream)

  def reload(%__MODULE__{events: [oldest | _rest] = held} = stream) do
    newest = List.last(held)

    fresh =
      case stream.kind do
        :entries -> Stream.newer(stream.job_id, newest.seq, oldest.seq, stream.notices)
        :raw -> Stream.raw_newer(stream.job_id, newest.seq)
      end

    if Enum.any?(fresh, &(&1.type == "job.swept")) do
      open(stream, max(length(held), page()))
    else
      count(%{stream | events: merge(held, fresh)})
    end
  end

  @doc """
  Shows or hides the notices: the newest as many entries as were drawn are read again under the
  new setting, which is what the toggle shows (a notice read under the old one is not in what is
  held, or is and is not drawn).
  """
  @spec toggle_notices(t(), non_neg_integer()) :: t()
  def toggle_notices(%__MODULE__{} = stream, drawn),
    do: open(%{stream | notices: not stream.notices}, max(drawn, page()))

  @doc """
  The position a stream is read back to, for a rejoin: the oldest event held, or nil when nothing is
  held. Sent beside the form recovery's `_look`, as `"job_id:seq"`, and read by `reach/2`.
  """
  @spec reach_of(t() | nil) :: String.t() | nil
  def reach_of(%__MODULE__{events: [oldest | _rest], job_id: job_id}),
    do: "#{job_id}:#{oldest.seq}"

  def reach_of(_stream), do: nil

  @doc """
  The position a rejoin carried for `job_id`: a whole number above zero, parsed strictly, and only
  when the value names this job — never another's, never a position taken off the request without
  its job. Anything else is nil, and the stream reads its newest page.
  """
  @spec reach(term(), String.t()) :: pos_integer() | nil
  def reach(value, job_id) when is_binary(value) do
    with [^job_id, seq] <- String.split(value, ":", parts: 2),
         true <- String.match?(seq, ~r/\A[0-9]+\z/),
         # After the pattern above `{n, ""}` always matches; loosening it to `{n, _}` is an
         # equivalent mutant and no test is written for it.
         {n, ""} when n > 0 and n <= @bigint <- Integer.parse(seq) do
      n
    else
      _other -> nil
    end
  end

  def reach(_value, _job_id), do: nil

  @doc """
  Adds an event heard on the job's topic: `{:ok, stream}`, or `:seen` when the stream has it
  already — read with the stream, and broadcast as well. The figures move with it.
  """
  @spec add(t(), Event.t()) :: {:ok, t()} | :seen
  def add(%__MODULE__{events: nil, counted_to: to} = stream, %Event{seq: seq} = event) do
    if seq <= to,
      do: :seen,
      else: {:ok, %{tally(stream, event) | counted_to: seq}}
  end

  def add(%__MODULE__{events: events} = stream, %Event{seq: seq} = event) do
    cond do
      Enum.any?(events, &(&1.seq == seq)) ->
        :seen

      counted_notice?(stream, event) ->
        :seen

      belongs_to_its_call?(stream, event) ->
        {:ok, stream}

      true ->
        {:ok, stream |> tally(event) |> then(&hold(&1, event))}
    end
  end

  # A notice that is hidden is never held, and a reload counts it with the database's figure: when
  # its own broadcast comes after that count it is counted already, not again. The count and the
  # position it covers (`Stream.notice_figures/1`) are one statement, and a job's notices are
  # written by one process in order, so a notice numbered above the position is not in the count.
  #
  # The `:entries` clause here is an equivalent mutant to drop: a raw stream's `notices_to` is never
  # set (`count/1` sets it only for entries), so it stays 0 and `seq <= notices_to` is never true.
  # **The one on `belongs_to_its_call?/2` is not equivalent** and is tested: a raw log shows every
  # event, so a result whose call is on a page not read is held and counted there.
  defp counted_notice?(%__MODULE__{kind: :entries} = stream, %Event{seq: seq} = event),
    do: notice?(event) and seq <= stream.notices_to

  defp counted_notice?(%__MODULE__{}, %Event{}), do: false

  # A result whose call is not held but exists has its place on the page that holds the call.
  defp belongs_to_its_call?(%__MODULE__{kind: :entries, events: events} = stream, event),
    do:
      result?(event) and not call_held?(events, event) and
        Stream.call_exists?(stream.job_id, call_id(event))

  defp belongs_to_its_call?(%__MODULE__{}, %Event{}), do: false

  # Held where its number says, unless it is older than everything held and older entries wait.
  defp hold(%__MODULE__{events: events, more: more} = stream, %Event{seq: seq} = event) do
    case events do
      [%Event{seq: oldest} | _rest] when seq < oldest and more -> stream
      _held -> %{stream | events: merge(events, [event])}
    end
  end

  # The figures: an entry head is one for the Activity count; a notice is counted by itself; a
  # result with a call is no entry of its own.
  defp tally(%__MODULE__{kind: :raw} = stream, _event), do: %{stream | count: stream.count + 1}

  defp tally(%__MODULE__{} = stream, %Event{type: "job.harness.notice"}),
    do: %{stream | notice_count: stream.notice_count + 1}

  defp tally(%__MODULE__{} = stream, %Event{} = event) do
    paired? =
      result?(event) and
        (call_held?(held(stream), event) or Stream.call_exists?(stream.job_id, call_id(event)))

    if paired?, do: stream, else: %{stream | count: stream.count + 1}
  end

  defp notice?(%Event{type: "job.harness.notice"}), do: true
  defp notice?(%Event{}), do: false

  defp result?(%Event{type: "job.harness.tool_result"}), do: true
  defp result?(%Event{}), do: false

  defp call_id(%Event{payload: payload}), do: payload["tool_use_id"]

  defp call_held?(events, event) do
    id = call_id(event)

    is_binary(id) and
      Enum.any?(events, &(&1.type == "job.harness.tool_use" and &1.payload["id"] == id))
  end

  defp read(%__MODULE__{kind: :entries} = stream, position, limit),
    do: Stream.page(stream.job_id, position, limit, stream.notices)

  defp read(%__MODULE__{kind: :raw} = stream, position, limit),
    do: Stream.raw_page(stream.job_id, position, limit)

  defp count(%__MODULE__{kind: :entries} = stream) do
    {notices, notices_to} = Stream.notice_figures(stream.job_id)

    counted = %{stream | count: Stream.count(stream.job_id), notice_count: notices}
    %{counted | counted_to: Stream.newest(stream.job_id), notices_to: notices_to}
  end

  defp count(%__MODULE__{kind: :raw} = stream),
    do: %{
      stream
      | count: Stream.raw_count(stream.job_id),
        counted_to: Stream.newest(stream.job_id)
    }

  # `seq` order, an event held once: what a page of events read below or above another is joined by.
  defp merge(first, second) do
    (first ++ second) |> Map.new(&{&1.seq, &1}) |> Map.values() |> Enum.sort_by(& &1.seq)
  end

  @doc """
  Whether an event is the harness's stream — what the agent said and did, and what the harness
  reported — which a page adds to the log it holds. Anything else on a job's topic (a turn
  ending, a wait, a message sent) changes more than the stream, and the page reloads.
  """
  @spec streamed?(Event.t()) :: boolean()
  def streamed?(%Event{type: "job.harness." <> _rest}), do: true
  def streamed?(%Event{}), do: false

  @doc """
  Whether an event may have come with a change to the job's branch: a call's result, since the
  agent commits and pushes with a call. A page showing the branch looks again shortly after one
  (`catch_up/2`) rather than on every event.
  """
  @spec may_have_moved?(Event.t()) :: boolean()
  def may_have_moved?(%Event{type: "job.harness.tool_result"}), do: true
  def may_have_moved?(%Event{}), do: false

  # Long enough that a burst of results is one look at the branch; short enough that a commit
  # reads as having just happened.
  @catch_up_after 1_000

  @doc """
  Schedules one `:catch_up` message to the page after an event that may have moved the branch,
  unless one is already due. The page answers it by reading again what the branch holds.
  """
  @spec catch_up(Phoenix.LiveView.Socket.t(), Event.t()) :: Phoenix.LiveView.Socket.t()
  def catch_up(socket, event) do
    if may_have_moved?(event) and not Map.get(socket.assigns, :catching_up, false) do
      Process.send_after(self(), :catch_up, @catch_up_after)
      Phoenix.Component.assign(socket, :catching_up, true)
    else
      socket
    end
  end
end
