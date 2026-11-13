defmodule Forge.Usage do
  @moduledoc """
  What spent the inference windows, and how fast they are filling (`docs/design/capacity.md`
  § Usage history, `docs/design/ui.md` § Usage).

  Every function here reads over a set of credentials **the caller has already decided the viewer
  may see**: the viewer's own on `/usage`, or a project's pool on a page about that project. What
  this module decides is what of the projects behind that spend the viewer may read — an item in a
  project the viewer is not a member of is counted and never named (`breakdown/4`).

  Nothing here stores anything. Pace is projected from the latest utilization the windows already
  carry, and what was used over time is the run ledger in weighted tokens (`capacity.md` § Usage in
  weighted tokens), each run in the bucket of the moment its usage was last written: `finished_at`
  for a run that reported, and for one still open the moment a conversation's turn last counted
  it, which `Forge.Jobs.Runs.record/3` records in `updated_at`. No dollars: a run's `usage` is the
  one figure, for both harnesses.
  """

  import Ecto.Query, only: [from: 2]

  alias Forge.Accounts.User
  alias Forge.{Credentials, Projects, Repo}
  alias Forge.Events.Event
  alias Forge.Jobs.{Job, Run}
  alias ForgeCore.Capacity

  @types ["five_hour", "seven_day"]
  @lengths %{"five_hour" => 5 * 3_600, "seven_day" => 7 * 86_400}
  @steps %{"five_hour" => 15 * 60, "seven_day" => 86_400}

  @type window :: %{
          type: String.t(),
          length: pos_integer(),
          mean: float() | nil,
          reporting: non_neg_integer(),
          known: non_neg_integer(),
          resets_at: DateTime.t() | nil,
          start: DateTime.t(),
          pace: {:full_in, non_neg_integer()} | :on_pace | nil
        }

  @doc """
  Both windows over these credentials, always both keys: the mean, reporting and known of
  `Forge.Credentials.gauge/2` — the figures the lines draw — the soonest reset, the window's start
  and its pace.

  **A window's start is its reset less its length**, five hours or seven days. A window no
  credential has reported has no reset; its start is then its length before `now`, so its spend
  can still be drawn as the trailing five hours or week, and it has no pace.
  """
  @spec windows([String.t()], DateTime.t()) :: %{String.t() => window()}
  def windows(ids, now \\ DateTime.utc_now()) do
    gauge = Credentials.gauge(ids, now)
    Map.new(@types, &{&1, window(&1, gauge[&1], now)})
  end

  @doc """
  One window from its entry in `Forge.Credentials.gauge/2` — nil when nothing reported it — for a
  caller that already holds the gauge, as the usage panel does from the lines it was opened from.
  """
  @spec window(String.t(), map() | nil, DateTime.t()) :: window()
  def window(type, known, now \\ DateTime.utc_now()) when type in @types do
    length = @lengths[type]
    resets_at = known && known.soonest
    start = DateTime.add(resets_at || now, -length)
    mean = known && known.mean

    %{
      type: type,
      length: length,
      mean: mean,
      reporting: (known && known.reporting) || 0,
      known: (known && known.known) || 0,
      resets_at: resets_at,
      start: start,
      pace: pace(mean, start, resets_at, now)
    }
  end

  @doc """
  A window's pace: its average rate since `start`, projected to `resets_at`. `{:full_in, seconds}`
  when that projection reaches 100 % before the reset — `0` for a window already full — and
  `:on_pace` otherwise. Nil without a figure or a reset, or for a window that has not started.
  """
  @spec pace(number() | nil, DateTime.t(), DateTime.t() | nil, DateTime.t()) ::
          {:full_in, non_neg_integer()} | :on_pace | nil
  def pace(nil, _start, _resets_at, _now), do: nil
  def pace(_mean, _start, nil, _now), do: nil

  def pace(mean, start, resets_at, now) do
    elapsed = DateTime.diff(now, start, :second)
    remaining = DateTime.diff(resets_at, now, :second)

    cond do
      elapsed <= 0 -> nil
      mean <= 0 -> :on_pace
      true -> project(mean, elapsed, remaining)
    end
  end

  # The time to 100 % at the rate so far, against the time left until the reset. **The `max` is an
  # equivalent mutant**: `Credentials.gauge/2` clamps every figure to 0..1, so `1 - mean` is never
  # negative here; it stays for a caller handing `pace/4` a figure of its own.
  defp project(mean, elapsed, remaining) do
    to_full = max(1 - mean, 0) * elapsed / mean

    if to_full < remaining, do: {:full_in, round(to_full)}, else: :on_pace
  end

  @doc """
  The usage of these credentials over `window`, in weighted tokens, from its start: fifteen-minute buckets for the
  five-hour window (twenty), a day's for the week (seven), each `:past`, `:now` — the one holding
  `now` — or `:future`, which is the time left before the reset. Each run is in the one bucket
  holding the moment its usage was last written; a bucket holds its start and not its end.
  """
  @spec spend_series([String.t()], window(), DateTime.t()) :: [map()]
  def spend_series(ids, %{type: type, start: start, length: length}, now \\ DateTime.utc_now()) do
    step = @steps[type]
    finish = DateTime.add(start, length)

    moments =
      Repo.all(
        from r in Run,
          where: r.credential_id in ^ids,
          where: fragment("coalesce(?, ?)", r.finished_at, r.updated_at) >= ^start,
          # `<` here is an equivalent mutant of `<=`: a run at `finish` exactly is in no bucket
          # anyway, since the last one ends there and a bucket holds its start and not its end.
          where: fragment("coalesce(?, ?)", r.finished_at, r.updated_at) < ^finish,
          select:
            {type(fragment("coalesce(?, ?)", r.finished_at, r.updated_at), :utc_datetime),
             r.usage}
      )

    for i <- 0..(div(length, step) - 1) do
      from = DateTime.add(start, i * step)
      to = DateTime.add(from, step)

      usage = for {at, used} <- moments, within?(at, from, to), reduce: 0, do: (sum -> sum + used)

      %{from: from, to: to, usage: usage, when: tense(from, to, now)}
    end
  end

  defp within?(at, from, to),
    do: DateTime.compare(at, from) != :lt and DateTime.compare(at, to) == :lt

  defp tense(from, to, now) do
    cond do
      DateTime.compare(now, from) == :lt -> :future
      within?(now, from, to) -> :now
      true -> :past
    end
  end

  @doc """
  What used these credentials' windows since `from`, as lines with their usage in weighted tokens
  and their share,
  by `:item` (a job or a conversation, running ones marked), `:project` or `:model`.

  **With `of:`, the window's measured figure** — the mean utilization the line over the page
  draws, 0..1 — **each line's share is that figure split by usage**: its weighted tokens over
  those of everything these credentials used since `from`, times the figure. The shares then add up to the
  figure they explain, and never to more (UX pass, D6: shares of a configured window cost added up
  to 95 % under a headline of 91 %, because the two were different units). **Use of these
  credentials outside forge is split in with them**, in the same proportion: the figure is the
  provider's and counts it, and forge cannot see it to set it apart. With a figure and nothing
  used, every share is 0. Without a figure the share is the estimate `share/1` makes — the usage
  over `window_tokens`, a share of one window (`docs/design/capacity.md` § Usage history).

  **Spend in a project `viewer` is not a member of is one line, `:elsewhere`**, last: counted,
  because these credentials paid for it, and never named — nothing of those jobs is read beyond
  their project and their usage (`docs/design/identity.md` § Read scoping).

  Items come running first, then newest first; projects and models largest first.

  With `running: true`, only what is spending now: the jobs and conversations with a run open —
  their shares still of everything spent since `from`, so the figure is split the same way.
  """
  @spec breakdown([String.t()], DateTime.t(), :item | :project | :model, User.t(), keyword()) ::
          [map()]
  def breakdown(ids, %DateTime{} = from, by, %User{} = viewer, opts \\ [])
      when by in [:item, :project, :model] do
    rows =
      Repo.all(
        from r in Run,
          join: j in Job,
          on: j.id == r.job_id,
          where: r.credential_id in ^ids,
          where: fragment("coalesce(?, ?)", r.finished_at, r.updated_at) >= ^from,
          group_by: [j.id, j.project_id],
          select: %{
            job_id: j.id,
            project_id: j.project_id,
            usage: type(coalesce(sum(r.usage), 0), :integer),
            running: fragment("bool_or(? IS NULL)", r.finished_at),
            last:
              type(max(fragment("coalesce(?, ?)", r.finished_at, r.updated_at)), :utc_datetime)
          }
      )

    sharer = sharer(Keyword.get(opts, :of), total(rows))
    rows = Enum.filter(rows, &(&1.running or not Keyword.get(opts, :running, false)))

    members = viewer |> Projects.list() |> Map.new(&{&1.id, &1})
    {mine, others} = Enum.split_with(rows, &Map.has_key?(members, &1.project_id))

    (lines(by, mine, members) ++ elsewhere(others))
    |> Enum.map(&Map.put(&1, :share, sharer.(&1.usage)))
  end

  # How usage becomes a share: of the measured figure, split by usage over everything used; with
  # no figure, the estimate from the window's weighted tokens. **Under a figure, nothing spent is no share at
  # all**, not the estimate: the lines are read as parts of the figure over them, and an estimate —
  # nil where no window size is configured — is not one (review fixes 7, L2). Without the guard,
  # a window whose only work had used nothing yet divided by zero on `/usage`.
  defp sharer(figure, total) when is_number(figure) do
    if total > 0,
      do: &(&1 / total * figure),
      else: fn _usage -> 0.0 end
  end

  defp sharer(_figure, _total), do: &share/1

  defp lines(:item, rows, members) do
    jobs = Repo.all(from j in Job, where: j.id in ^Enum.map(rows, & &1.job_id), preload: :ticket)
    jobs = Map.new(jobs, &{&1.id, &1})
    openings = openings(for %{kind: :chat, id: id} <- Map.values(jobs), do: id)

    rows
    |> Enum.map(fn row ->
      job = jobs[row.job_id]

      line(%{
        key: job.id,
        job: job,
        ticket: job.ticket,
        project: members[row.project_id],
        opening: openings[job.id],
        running: row.running,
        last: row.last,
        usage: row.usage
      })
    end)
    |> Enum.sort_by(&{not &1.running, -DateTime.to_unix(&1.last)})
  end

  defp lines(:project, rows, members) do
    rows
    |> Enum.group_by(& &1.project_id)
    |> Enum.map(fn {id, rows} ->
      line(%{key: id, project: members[id], usage: total(rows)})
    end)
    |> largest_first()
  end

  defp lines(:model, [], _members), do: []

  defp lines(:model, rows, _members) do
    models =
      Repo.all(
        from j in Job,
          where: j.id in ^Enum.map(rows, & &1.job_id),
          select: {j.id, fragment("coalesce(?, ?->>'model')", j.model, j.spec)}
      )
      |> Map.new()

    rows
    |> Enum.group_by(&models[&1.job_id])
    |> Enum.map(fn {model, rows} -> line(%{key: model, model: model, usage: total(rows)}) end)
    |> largest_first()
  end

  defp elsewhere([]), do: []
  defp elsewhere(rows), do: [line(%{key: :elsewhere, elsewhere: true, usage: total(rows)})]

  defp line(fields), do: Map.merge(%{elsewhere: false, running: false}, fields)

  defp total(rows), do: rows |> Enum.map(& &1.usage) |> Enum.sum()

  defp largest_first(lines), do: Enum.sort_by(lines, & &1.usage, :desc)

  # What a person opened each conversation with: its first message, which is the closest thing a
  # conversation has to a title.
  defp openings([]), do: %{}

  defp openings(chat_ids) do
    Repo.all(
      from e in Event,
        where: e.job_id in ^chat_ids and e.type == "chat.message",
        distinct: e.job_id,
        order_by: [asc: e.job_id, asc: e.seq],
        select: {e.job_id, fragment("?->>'text'", e.payload)}
    )
    |> Map.new()
  end

  @doc """
  Weighted tokens as a share of one five-hour window — `0.22` is 22 % of one — or nil when
  `window_tokens` is not configured and there is no honest conversion (`ForgeCore.Capacity`).
  """
  @spec share(non_neg_integer()) :: float() | nil
  def share(tokens) when is_integer(tokens), do: Capacity.windows(tokens, window_tokens())

  @doc "The configured weighted tokens of one five-hour window (`docs/design/capacity.md`)."
  @spec window_tokens() :: number()
  def window_tokens do
    :forge |> Application.get_env(:capacity, []) |> Keyword.get(:window_tokens, 0)
  end

  @doc """
  The credentials of a set as the panel names them (`docs/design/credentials.md` § Showing the
  windows): **the viewer's own**, each with its windows, and **the rest as one gauge** that names
  nobody — a pool holds other people's credentials, and a row naming one is its owner's alone.
  """
  @spec credentials([String.t()], User.t(), DateTime.t()) :: %{
          own: [%{credential: Credentials.Credential.t(), windows: map()}],
          others: %{count: non_neg_integer(), gauge: map()}
        }
  def credentials(ids, %User{} = viewer, now \\ DateTime.utc_now()) do
    own = viewer |> Credentials.list() |> Enum.filter(&(&1.id in ids))
    own_ids = Enum.map(own, & &1.id)
    others = ids -- own_ids
    windows = Credentials.windows(own_ids, now)

    %{
      own: Enum.map(own, &%{credential: &1, windows: Map.get(windows, &1.id, %{})}),
      others: %{count: length(others), gauge: Credentials.gauge(others, now)}
    }
  end
end
