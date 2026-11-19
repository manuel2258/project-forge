defmodule ForgeCore.Cron do
  @moduledoc """
  A five-field cron line, read in UTC, for a workflow's `schedules:`
  (`docs/design/workflow-grammar-v1.md` § Schedules, `docs/design/schedules.md`).

  The dialect is the small one an agent writing the file already knows: minute `0-59`, hour
  `0-23`, day of month `1-31`, month `1-12` or `JAN-DEC`, day of week `0-7` or `SUN-SAT` (0 and 7
  are Sunday). A field is a comma list of `*`, `n`, `a-b`, `*/s` and `a-b/s`. There is no
  `@weekly`, `L`, `#` or `?`, and a step of 0, a reversed range or a value out of range is
  refused by name.

  **When both day fields are restricted a day must match both.** Standard cron reads
  `0 9 1-7 * 1` as days 1-7 *or* any Monday, about eleven firings a month; here it is the first
  Monday, which is the case the line is usually written for. One rule for every line, so the day
  test is a plain `and`, and `describe/1` says the same in words.

  Time has the resolution of a minute, and every function takes and returns UTC.
  """

  @enforce_keys [:source, :minutes, :hours, :doms, :months, :dows]
  defstruct [:source, :minutes, :hours, :doms, :months, :dows]

  @type t :: %__MODULE__{
          source: String.t(),
          minutes: MapSet.t(non_neg_integer()),
          hours: MapSet.t(non_neg_integer()),
          doms: MapSet.t(pos_integer()),
          months: MapSet.t(pos_integer()),
          # 0 is Sunday; a 7 in the line has already been folded into it.
          dows: MapSet.t(0..6)
        }

  @months ~w(JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC)
  @days ~w(SUN MON TUE WED THU FRI SAT)
  @month_names ~w(January February March April May June July August September October November
                  December)
  @day_names ~w(Sunday Monday Tuesday Wednesday Thursday Friday Saturday)

  # How far `next_after/3` and `latest_at_or_before/3` look before they say there is none. Thirty
  # years takes in a line written for a date that comes round every few years; `comes_due/1` looks
  # further for a leap day on a rare weekday.
  @horizon_years 30

  # -- parsing ------------------------------------------------------------------------------

  @doc """
  Parses a cron line. The error is a sentence naming the field and what is wrong with it, to be
  put after the schedule's path.
  """
  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(line) when is_binary(line) do
    case String.split(line) do
      [minute, hour, dom, month, dow] ->
        with {:ok, minutes} <- field(minute, "minute", 0..59, %{}),
             {:ok, hours} <- field(hour, "hour", 0..23, %{}),
             {:ok, doms} <- field(dom, "day of month", 1..31, %{}),
             {:ok, months} <- field(month, "month", 1..12, names(@months, 1)),
             {:ok, dows} <- field(dow, "day of week", 0..7, names(@days, 0)),
             cron = %__MODULE__{
               source: Enum.join([minute, hour, dom, month, dow], " "),
               minutes: minutes,
               hours: hours,
               doms: doms,
               months: months,
               dows: dows |> Enum.map(&rem(&1, 7)) |> MapSet.new()
             },
             :ok <- comes_due(cron) do
          {:ok, cron}
        end

      fields ->
        {:error,
         "must be five fields (minute hour day-of-month month day-of-week), not #{length(fields)}"}
    end
  end

  def parse(_line), do: {:error, "must be a string of five fields"}

  defp names(list, first),
    do: list |> Enum.with_index(first) |> Map.new()

  defp field(text, label, range, names) do
    text
    |> String.split(",")
    |> Enum.reduce_while({:ok, MapSet.new()}, fn item, {:ok, acc} ->
      case item(item, label, range, names) do
        {:ok, values} -> {:cont, {:ok, MapSet.union(acc, values)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp item(item, label, range, names) do
    {body, step} =
      case String.split(item, "/") do
        [body] -> {body, nil}
        [body, step] -> {body, step}
        _ -> {item, :bad}
      end

    with {:ok, step} <- step(step, label, item),
         {:ok, first, last} <- bounds(body, label, range, names, item) do
      {:ok, MapSet.new(first..last//step)}
    end
  end

  defp step(nil, _label, _item), do: {:ok, 1}

  defp step(step, label, item) when is_binary(step) do
    case Integer.parse(step) do
      {n, ""} when n >= 1 -> {:ok, n}
      {0, ""} -> {:error, "#{label}: #{inspect(item)} has a step of 0"}
      _ -> {:error, "#{label}: #{inspect(item)} has a step that is not a whole number"}
    end
  end

  defp step(:bad, label, item), do: {:error, "#{label}: #{inspect(item)} has more than one /"}

  # `*` is the field's whole range: for the day of week 0..7, where 7 is folded into 0 when the field
  # is built.
  defp bounds("*", _label, range, _names, _item), do: {:ok, range.first, range.last}

  defp bounds(body, label, range, names, item) do
    case String.split(body, "-") do
      [one] ->
        with {:ok, n} <- value(one, label, range, names),
             :ok <- unstepped(item, label),
             do: {:ok, n, n}

      [from, to] ->
        with {:ok, a} <- value(from, label, range, names),
             {:ok, b} <- value(to, label, range, names),
             do: forwards(a, b, label, item)

      _ ->
        {:error, "#{label}: #{inspect(item)} is not a value or a range"}
    end
  end

  defp forwards(a, b, _label, _item) when a <= b, do: {:ok, a, b}

  defp forwards(_a, _b, label, item),
    do: {:error, "#{label}: #{inspect(item)} is a range that runs backwards"}

  # `5/15` is not in the dialect: a step is of a range, and a single value has none.
  defp unstepped(item, label) do
    if String.contains?(item, "/"),
      do: {:error, "#{label}: #{inspect(item)} has a step but no range to step through"},
      else: :ok
  end

  defp value(text, label, range, names) do
    number =
      case Integer.parse(text) do
        {n, ""} -> n
        _ -> Map.get(names, String.upcase(text))
      end

    cond do
      number == nil ->
        {:error, "#{label}: #{inspect(text)} is not a number#{name_hint(names)}"}

      number in range ->
        {:ok, number}

      true ->
        {:error, "#{label}: #{number} is out of range #{range.first}-#{range.last}"}
    end
  end

  defp name_hint(names) when map_size(names) == 0, do: ""
  defp name_hint(_names), do: " or a name"

  # A line whose month and day of month name no date that exists (`0 0 30 2 *`), or whose days
  # never fall together, is a line that never fires, and a schedule that never fires is a mistake
  # worth refusing rather than keeping quietly. Looked for over a whole Gregorian cycle, because a
  # leap day on a Saturday is 2048 and not the next one after 2026.
  defp comes_due(cron) do
    if next_after(cron, ~U[2000-01-01 00:00:00Z], 400) == nil,
      do: {:error, "never comes due: no date matches its month, day of month and day of week"},
      else: :ok
  end

  # -- matching and searching ---------------------------------------------------------------

  @doc """
  Whether the minute `at` falls in is one the line names. Not used by the platform, which searches
  with `next_after/3` and `latest_at_or_before/3`: it is the tests' oracle, a walk over minutes that
  shares only the day test with them.
  """
  @spec matches?(t(), DateTime.t()) :: boolean()
  def matches?(%__MODULE__{} = cron, %DateTime{} = at),
    do:
      day_matches?(cron, DateTime.to_date(at)) and at.hour in cron.hours and
        at.minute in cron.minutes

  defp day_matches?(cron, date) do
    date.month in cron.months and date.day in cron.doms and
      rem(Date.day_of_week(date), 7) in cron.dows
  end

  @doc """
  The first time the line names strictly after `at`, or nil when there is none within thirty
  years. `at` need not be on a minute: 09:00:30 is after 09:00.
  """
  @spec next_after(t(), DateTime.t(), pos_integer()) :: DateTime.t() | nil
  def next_after(cron, at, years \\ @horizon_years) do
    first = DateTime.to_date(at)
    last = Date.add(first, years * 366)
    scan_forward(cron, first, last, at)
  end

  defp scan_forward(cron, date, last, at) do
    cond do
      Date.compare(date, last) == :gt ->
        nil

      date.month not in cron.months ->
        scan_forward(cron, next_month(date), last, at)

      day_matches?(cron, date) ->
        case first_time_after(cron, date, at) do
          nil -> scan_forward(cron, Date.add(date, 1), last, at)
          found -> found
        end

      true ->
        scan_forward(cron, Date.add(date, 1), last, at)
    end
  end

  # Minutes of the day the line names, as integers: building a DateTime for each of 1440 would make
  # a line that fires every minute the slowest to search.
  defp minutes_of_day(cron),
    do: for(h <- cron.hours, m <- cron.minutes, do: h * 60 + m) |> Enum.sort()

  # The seconds into the day `at` is, when it is on `date`: before `date` it is `-1` (everything of
  # the day is after it), after `date` it is a day and more (nothing of the day is).
  defp seconds_into(date, at) do
    case Date.compare(date, DateTime.to_date(at)) do
      :gt -> -1
      :lt -> 24 * 3600 + 1
      :eq -> at.hour * 3600 + at.minute * 60 + at.second
    end
  end

  defp first_time_after(cron, date, at) do
    seconds = seconds_into(date, at)

    case Enum.find(minutes_of_day(cron), &(&1 * 60 > seconds)) do
      nil -> nil
      minute -> at_minute(date, minute)
    end
  end

  defp next_month(date), do: date |> Date.end_of_month() |> Date.add(1)

  @doc """
  The latest time the line names at or before `at`, or nil when there is none within thirty years.
  What a schedule that was not looked at for a while is due for: one time, the latest, however
  many it missed.
  """
  @spec latest_at_or_before(t(), DateTime.t(), pos_integer()) :: DateTime.t() | nil
  def latest_at_or_before(cron, at, years \\ @horizon_years) do
    last = DateTime.to_date(at)
    first = Date.add(last, -years * 366)
    scan_back(cron, last, first, at)
  end

  defp scan_back(cron, date, first, at) do
    cond do
      Date.compare(date, first) == :lt ->
        nil

      date.month not in cron.months ->
        scan_back(cron, date |> Date.beginning_of_month() |> Date.add(-1), first, at)

      day_matches?(cron, date) ->
        case last_time_at_or_before(cron, date, at) do
          nil -> scan_back(cron, Date.add(date, -1), first, at)
          found -> found
        end

      true ->
        scan_back(cron, Date.add(date, -1), first, at)
    end
  end

  defp last_time_at_or_before(cron, date, at) do
    seconds = seconds_into(date, at)

    case cron |> minutes_of_day() |> Enum.reverse() |> Enum.find(&(&1 * 60 <= seconds)) do
      nil -> nil
      minute -> at_minute(date, minute)
    end
  end

  defp at_minute(date, minute),
    do: DateTime.new!(date, Time.new!(div(minute, 60), rem(minute, 60), 0), "Etc/UTC")

  # -- words --------------------------------------------------------------------------------

  @doc """
  The line in words a person reads, for the confirmation before a schedule is switched on:
  *every Monday at 06:00 UTC*, *every 15 minutes*, *at 09:00 UTC on a Monday that is day 1-7 of
  the month*. Every line that parses gets a sentence, by a generic list and range phrasing where
  no special one fits.
  """
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{} = cron) do
    day = day_phrase(cron)
    month = month_phrase(cron)

    [combine(time_phrase(cron), day), month]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  # `every Monday at 06:00 UTC`, `every day at 06:00 UTC`, `every 15 minutes, every Monday`,
  # `at 06:00 UTC on days 1-7 of the month`.
  defp combine({:at, time}, {:every, day}), do: "#{day} #{time}"
  defp combine({:at, time}, {:on, day}), do: "#{time} #{day}"
  defp combine({:every, time}, {:every, "every day"}), do: time
  defp combine({:every, time}, {_, day}), do: "#{time}, #{day}"

  defp time_phrase(cron) do
    if full?(cron.hours, 0..23),
      do: {:every, minutes_phrase(cron.minutes)},
      else: {:at, clock_phrase(cron.minutes, cron.hours)}
  end

  defp minutes_phrase(minutes) do
    step = stepped(minutes, 59)

    cond do
      full?(minutes, 0..59) -> "every minute"
      step not in [nil, 1] -> "every #{step} minutes"
      MapSet.size(minutes) == 1 -> single_minute(MapSet.to_list(minutes))
      true -> "every hour at minutes #{list(minutes)}"
    end
  end

  defp single_minute([0]), do: "every hour on the hour"
  defp single_minute([m]), do: "every hour at minute #{m}"

  defp clock_phrase(minutes, hours) do
    if MapSet.size(minutes) * MapSet.size(hours) <= 8 do
      times = for h <- Enum.sort(hours), m <- Enum.sort(minutes), do: clock(h, m)
      "at #{join_and(times)} UTC"
    else
      "at minute #{list(minutes)} of hours #{list(hours)} UTC"
    end
  end

  defp clock(h, m),
    do: "#{String.pad_leading("#{h}", 2, "0")}:#{String.pad_leading("#{m}", 2, "0")}"

  # The step of a set that is `0, s, 2s, ...` up to the field's last value, or nil.
  defp stepped(set, max) do
    case Enum.sort(set) do
      [0, step | _] = sorted when step > 1 ->
        if sorted == Enum.to_list(0..max//step), do: step, else: nil

      _ ->
        nil
    end
  end

  defp day_phrase(cron) do
    dom_all = full?(cron.doms, 1..31)
    dow_all = full?(cron.dows, 0..6)

    cond do
      dom_all and dow_all ->
        {:every, "every day"}

      dom_all ->
        {:every, "every #{weekdays(cron.dows)}"}

      dow_all ->
        {:on, "on #{days_of_month(cron.doms)}"}

      true ->
        {:on, "on a #{weekdays(cron.dows, "or")} that is #{days_of_month(cron.doms)}"}
    end
  end

  # Monday first and Sunday last, runs of three or more as `Monday to Friday`.
  defp weekdays(set, last_joiner \\ "and") do
    set
    |> Enum.map(&if(&1 == 0, do: 7, else: &1))
    |> ranges()
    |> Enum.flat_map(fn
      {a, b} when b - a >= 2 -> ["#{day_name(a)} to #{day_name(b)}"]
      {a, b} -> for n <- a..b, do: day_name(n)
    end)
    |> join_with(last_joiner)
  end

  defp day_name(n), do: Enum.at(@day_names, rem(n, 7))

  defp days_of_month(set) do
    case ranges(set) do
      [{n, n}] -> "day #{n} of the month"
      [{a, b}] -> "day #{a}-#{b} of the month"
      parts -> "days #{range_text(parts, "and")} of the month"
    end
  end

  defp month_phrase(cron) do
    if full?(cron.months, 1..12),
      do: "",
      else: "in " <> join_and(Enum.map(Enum.sort(cron.months), &Enum.at(@month_names, &1 - 1)))
  end

  defp full?(set, range), do: MapSet.size(set) == Enum.count(range)

  defp list(set), do: set |> ranges() |> range_text()

  # Runs of consecutive values as {first, last}: `[1,2,3,5]` is `[{1,3},{5,5}]`.
  defp ranges(set) do
    set
    |> Enum.sort()
    |> Enum.reduce([], fn
      n, [{first, last} | rest] when n == last + 1 -> [{first, n} | rest]
      n, acc -> [{n, n} | acc]
    end)
    |> Enum.reverse()
  end

  defp range_text(parts, joiner \\ "and") do
    parts
    |> Enum.map(fn
      {n, n} -> "#{n}"
      {a, b} -> "#{a}-#{b}"
    end)
    |> join_with(joiner)
  end

  defp join_and(items), do: join_with(items, "and")

  defp join_with([one], _joiner), do: one

  defp join_with(items, joiner),
    do: Enum.join(Enum.drop(items, -1), ", ") <> " #{joiner} " <> List.last(items)
end
