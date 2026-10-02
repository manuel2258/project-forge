defmodule Forge.Workers.Log do
  @moduledoc """
  A machine's own history, kept by the platform and read on `/workers/:id`
  (`docs/design/worker-log.md`).

  Two sources in one log. `record/5` is the platform writing what it saw happen to a machine —
  made, joined, refused, swept, destroyed and by what — from `Forge.Workers` and the channel as it
  happens. `accept/2` is a line the machine sent in a `log` message: a job it accepted or finished,
  a seed it fetched. **Worker-level only**: what an agent did inside a job is the job's own event
  stream, and nothing here copies it.

  **Every field a machine sends is bounded before it is kept**, because the machine is only
  authenticated, not trusted to write what the page draws: the type must look like one, the level
  is one of three, the message is text cut to 500 code points, a job id is kept only if it is one,
  and the machine's clock is believed only within a window of the platform's. And the log is
  bounded as a whole: the last 500 lines per machine from each source, trimmed as each is written.
  """

  import Ecto.Query, only: [from: 2]

  alias Forge.Repo
  alias Forge.Workers.LogEntry

  require Logger

  @levels %{"info" => :info, "warning" => :warning, "error" => :error}
  @message 500
  @shown 200
  # How far a machine's clock is believed: a little ahead, for drift, and a week behind, for a
  # line held while the machine could not reach the platform. Outside that it is a clock that is
  # wrong, and the line is placed when it arrived.
  @ahead_s 5 * 60
  @behind_s 7 * 24 * 60 * 60

  @doc """
  Writes a line the platform saw happen to `worker_id`, stamped with the platform's clock.

  `job_id:` ties the line to a job. `once: true` is for what the platform would otherwise say on
  every pass or every knock — a sweep retrying a destroy the driver refuses, a refused machine
  joining again — and writes the line only if the platform has not written one of that type since
  the machine last joined.
  """
  @spec record(String.t(), String.t(), :info | :warning | :error, String.t(), keyword()) :: :ok
  def record(worker_id, type, level, message, opts \\ []) do
    if Keyword.get(opts, :once, false) and said_since_join?(worker_id, type) do
      :ok
    else
      write(%{
        worker_id: worker_id,
        source: :platform,
        type: type,
        level: level,
        message: clean(message, @message) || "",
        job_id: Keyword.get(opts, :job_id),
        at: now()
      })
    end
  end

  @doc "Whether the platform has written a line of `type` about `worker_id` since it last joined."
  @spec said?(String.t(), String.t()) :: boolean()
  def said?(worker_id, type), do: said_since_join?(worker_id, type)

  @doc """
  Keeps a line a machine sent about itself, bounded field by field (see the moduledoc). Called by
  the channel, which is what says whose machine it is — nothing in the payload names a worker —
  and which drops a payload that is not an object before it gets here.
  """
  @spec accept(String.t(), map()) :: :ok
  def accept(worker_id, payload) do
    write(%{
      worker_id: worker_id,
      source: :worker,
      type: type_of(payload["type"]),
      level: Map.get(@levels, payload["level"], :info),
      message: clean(payload["message"], @message) || "",
      job_id: uuid(payload["job_id"]),
      at: at(payload["at"])
    })
  end

  @doc "A machine's log, newest first: the last `limit` lines, 200 unless said."
  @spec for_worker(String.t(), pos_integer()) :: [LogEntry.t()]
  def for_worker(worker_id, limit \\ @shown) do
    Repo.all(
      from e in LogEntry,
        where: e.worker_id == ^worker_id,
        order_by: [desc: e.at, desc: e.id],
        limit: ^limit
    )
  end

  @doc """
  Text a machine sent, as a column can keep it: at most `max` code points, no NUL — which Postgres
  will not store at all — and nothing if what would be kept is not UTF-8. Code points and not
  graphemes, which `String.slice/3` counts and which a combining accent makes two of: the column
  counts the first.

  **Only what is kept is read.** It was checked whole and then cut, and a ten-megabyte message cost
  the channel that received it ten seconds and half a gigabyte; the socket's frame limit is the
  only other bound on how long a machine's text is. So what lies past the `max`th code point is
  never looked at, valid or not.
  """
  @spec clean(term(), pos_integer()) :: String.t() | nil
  def clean(value, max) when is_binary(value), do: take(value, max, [])
  def clean(_value, _max), do: nil

  defp take(<<>>, _max, kept), do: IO.iodata_to_binary(kept)
  defp take(_rest, 0, kept), do: IO.iodata_to_binary(kept)
  defp take(<<0, rest::binary>>, max, kept), do: take(rest, max, kept)
  defp take(<<c::utf8, rest::binary>>, max, kept), do: take(rest, max - 1, [kept, <<c::utf8>>])
  defp take(_not_utf8, _max, _kept), do: nil

  # **Kept, then trimmed to the last `keep` lines of that machine from that source.** By insertion
  # and not by the machine's clock: a line held while it was away arrives late and is not the one
  # to lose first. Per source, because the platform's record of a machine is not the machine's to
  # erase: with one budget, a machine sending lines pushed out every one the platform had written.
  defp write(attrs) do
    {:ok, _entry} = Repo.insert(struct(LogEntry, attrs))
    trim(attrs.worker_id, attrs.source)
  end

  defp trim(worker_id, source) do
    mine = from e in LogEntry, where: e.worker_id == ^worker_id and e.source == ^source

    cutoff =
      Repo.one(from e in mine, order_by: [desc: e.id], offset: ^keep(), limit: 1, select: e.id)

    if cutoff, do: Repo.delete_all(from e in mine, where: e.id <= ^cutoff)

    :ok
  end

  # **The platform's own lines, both of them.** A machine may send a line of any type it likes —
  # it is shown as the machine's — and one that sent `joined` would otherwise lift the platform's
  # silence, and one that sent `unreachable` would impose it. By insertion, as the trim is.
  defp said_since_join?(worker_id, type) do
    joined =
      Repo.one(
        from e in LogEntry,
          where: e.worker_id == ^worker_id and e.source == :platform and e.type == "joined",
          select: max(e.id)
      ) || 0

    Repo.exists?(
      from e in LogEntry,
        where:
          e.worker_id == ^worker_id and e.source == :platform and e.type == ^type and
            e.id > ^joined
    )
  end

  defp keep, do: :forge |> Application.get_env(__MODULE__, []) |> Keyword.get(:keep, 500)

  # Lower-case words joined by dots, as every type in the note is; anything else is kept as
  # `unknown` rather than refused, so a newer release's line is still a line.
  defp type_of(type) when is_binary(type) and byte_size(type) <= 64 do
    if type =~ ~r/\A[a-z]+(\.[a-z]+)*\z/, do: type, else: "unknown"
  end

  defp type_of(_type), do: "unknown"

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp uuid(_value), do: nil

  defp at(value) when is_binary(value) do
    now = now()

    with {:ok, at, _offset} <- DateTime.from_iso8601(value),
         true <- DateTime.diff(at, now) <= @ahead_s,
         true <- DateTime.diff(now, at) <= @behind_s do
      usec(at)
    else
      _unbelievable -> now
    end
  end

  defp at(_value), do: now()

  # **To the column's precision, whatever the machine wrote.** A time with no fraction parses at
  # second precision, which a `utc_datetime_usec` refuses to store — so a line stamped `…:00Z`
  # crashed the channel that received it rather than being kept.
  defp usec(%DateTime{microsecond: {us, _precision}} = at), do: %{at | microsecond: {us, 6}}

  defp now, do: DateTime.utc_now()
end
