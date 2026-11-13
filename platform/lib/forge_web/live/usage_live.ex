defmodule ForgeWeb.UsageLive do
  @moduledoc """
  `/usage` (`23a`, `23b`, `docs/design/ui.md` § Usage): the detail behind the two lines, over the
  viewer's own credentials. A card per window — its percentage, its line, the reset and the pace,
  and its spend over time: fifteen-minute steps for the five-hour window with the time left before
  the reset hatched, a bar a day for the week. Beneath, what spent the five-hour window by item,
  project or model, as shares of the window's figure split by usage in weighted tokens (`docs/design/capacity.md`
  § Usage history); on a wide screen the week's split by project beside it.

  **The figures are the lines'**: the windows are drawn from the frame's own capacity assign, which
  on this page is the viewer's credentials, so the page and the lines over it cannot disagree.
  What spent them is `Forge.Usage`'s, which names nothing in a project the viewer is not in.

  It reads again once a minute, as the lines do; nothing announces usage being written.
  """

  use ForgeWeb, :live_view

  alias Forge.Usage
  alias ForgeWeb.{Format, UsagePanel}

  @refresh :timer.minutes(1)
  @named 5
  @by %{"item" => :item, "project" => :project, "model" => :model}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :usage_tick, @refresh)

    {:ok, assign(socket, page_title: "Usage", by: :item)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(:by, Map.get(@by, params["by"], :item)) |> load()}
  end

  # Which breakdown is on screen: page state, kept in the address so a reload keeps it.
  @impl true
  def handle_event("by", %{"value" => by}, socket) do
    {:noreply, push_patch(socket, to: ~p"/usage?#{%{by: by}}")}
  end

  @impl true
  def handle_info(:usage_tick, socket) do
    Process.send_after(self(), :usage_tick, @refresh)
    {:noreply, load(socket)}
  end

  defp load(socket) do
    %{capacity: capacity, current_scope: %{user: user}, by: by} = socket.assigns
    ids = (capacity[:set] || %{ids: []}).ids
    now = DateTime.utc_now()
    windows = Map.new(~w(five_hour seven_day), &{&1, Usage.window(&1, capacity[&1], now)})

    five = windows["five_hour"]
    week = windows["seven_day"]
    lines = ids |> Usage.breakdown(five.start, by, user, of: five.mean) |> fold(by)

    assign(socket,
      now: now,
      windows: windows,
      series:
        Map.new(windows, fn {type, window} -> {type, Usage.spend_series(ids, window, now)} end),
      lines: UsagePanel.shown(lines, five.mean),
      models: models(ids, five.start, by, user),
      week:
        ids
        |> Usage.breakdown(week.start, :project, user, of: week.mean)
        |> week_shown(week.mean)
    )
  end

  # How many models spent the window, other than *elsewhere*: with one, *By model* says nothing
  # *By item* does not (UX pass, D21), so the switch leaves it out — unless it is the one shown.
  defp models(_ids, _from, :model, _user), do: :shown

  defp models(ids, from, _by, user),
    do: ids |> Usage.breakdown(from, :model, user) |> Enum.count(&(not &1.elsewhere))

  defp by_options(models) when models == :shown or models > 1,
    do: [{"By item", "item"}, {"By project", "project"}, {"By model", "model"}]

  defp by_options(_models), do: [{"By item", "item"}, {"By project", "project"}]

  # The week's split: a share of the week's figure when there is one, in percent like it; in
  # windows, the estimate's unit, when no credential has reported the week.
  defp week_shown(lines, mean) when is_number(mean), do: UsagePanel.shown(lines, mean)

  defp week_shown(lines, _mean),
    do: Enum.map(lines, &Map.put(&1, :shown, ForgeCore.Capacity.format(&1.share) || "—"))

  # By item, the first few are named and the rest are one line; elsewhere stays last, apart.
  defp fold(lines, :item) do
    {elsewhere, items} = Enum.split_with(lines, & &1.elsewhere)
    {named, earlier} = Enum.split(items, @named)
    named ++ earlier(earlier) ++ elsewhere
  end

  defp fold(lines, _by), do: lines

  defp earlier([]), do: []

  defp earlier(lines) do
    usage = lines |> Enum.map(& &1.usage) |> Enum.sum()

    [
      %{
        key: :earlier,
        earlier: length(lines),
        elsewhere: false,
        running: false,
        usage: usage,
        # The folded lines' shares added up, so the figure they split is still split whole.
        share: lines |> Enum.map(& &1.share) |> sum()
      }
    ]
  end

  defp sum(shares), do: if(nil in shares, do: nil, else: Enum.sum(shares))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      frame={@frame}
      capacity={@capacity}
      title="Usage"
      top_level={:usage}
      measure={nil}
    >
      <div id="usage" class="usage-page">
        <div class="usage-cards">
          <.window_card
            id="usage-five_hour"
            label="5-hour window"
            window={@windows["five_hour"]}
            series={@series["five_hour"]}
            now={@now}
          />
          <.window_card
            id="usage-seven_day"
            label="Week"
            window={@windows["seven_day"]}
            series={@series["seven_day"]}
            now={@now}
          />
        </div>

        <div class="usage-below">
          <section id="usage-spent" class="usage-spent">
            <div class="usage-spent-head">
              <.eyebrow>What spent this 5h window</.eyebrow>
              <.segmented
                id="usage-by"
                size="md"
                options={by_options(@models)}
                value={@by}
                on_select="by"
              />
            </div>
            <UsagePanel.spent
              :for={line <- @lines}
              id={"usage-line-#{line_id(line)}"}
              line={line}
            />
            <p :if={@lines == []} class="usage-empty">Nothing has spent this window yet.</p>
            <p id="usage-legend" class="usage-legend">
              {legend(@windows["five_hour"])} · ▸ running now
            </p>
          </section>

          <div class="usage-side">
            <div class="usage-note">
              <.eyebrow>When a window is spent</.eyebrow>
              <p>
                A job starts on a credential with room left, and one stopped by a limit mid-run
                moves to another and resumes. When every credential in its pool is spent, new
                jobs and chat turns wait until one resets. Nothing is lost.
              </p>
            </div>

            <section :if={@week != []} id="usage-week-projects" class="usage-week">
              <.eyebrow>By project, this week</.eyebrow>
              <div :for={line <- @week} class="usage-week-row">
                <span class="usage-week-name">
                  {if line.elsewhere, do: "elsewhere", else: line.project.name}
                </span>
                <span class="usage-line-bar">
                  <span style={"width: #{UsagePanel.bar(line.share)}%"} />
                </span>
                <span class="usage-week-figure">{line.shown}</span>
              </div>
              <p class="usage-legend">{legend(@windows["seven_day"])}</p>
            </section>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :window, :map, required: true
  attr :series, :list, required: true
  attr :now, :any, required: true

  # A window's card: its figure large, its bar, its reset and pace, and its spend over time.
  defp window_card(assigns) do
    assigns =
      assign(assigns,
        percent: assigns.window.mean && round(assigns.window.mean * 100),
        top: assigns.series |> Enum.map(& &1.usage) |> Enum.max(fn -> 0 end)
      )

    ~H"""
    <section id={@id} class={["usage-card", "usage-card--#{@window.type}"]}>
      <div class="usage-card-head">
        <span class="usage-card-label">{@label}</span>
        <span class={["usage-card-figure", tone(@percent)]}>
          {if @percent, do: "#{@percent}%", else: "—"}
        </span>
      </div>
      <div class="usage-card-bar">
        <span :if={@percent} class={tone(@percent)} style={"width: #{min(@percent, 100)}%"} />
      </div>
      <UsagePanel.reset_line window={@window} now={@now} />
      <p :if={@window.known == 0} class="usage-empty">No credential has reported this window.</p>

      <div class="usage-chart" aria-label={"Spend in #{@label}"}>
        <div class="usage-bars">
          <span
            :for={bucket <- @series}
            class={["usage-bar", "usage-bar--#{bucket.when}", bucket.when == :now && tone(@percent)]}
            style={bucket.when != :future && "height: #{height(bucket.usage, @top)}%"}
            data-usage={bucket.when != :future && bucket.usage}
            title={bucket.when != :future && Format.exact(bucket.usage)}
          />
        </div>
        <div :if={@window.type == "five_hour"} class="usage-axis">
          <span
            :for={{text, left} <- clock_labels(@window, @now)}
            class={[left < 6 && "usage-axis--start", left > 94 && "usage-axis--end"]}
            style={"left: #{left}%"}
          >
            {text}
          </span>
        </div>
        <div :if={@window.type == "seven_day"} class="usage-days">
          <span :for={bucket <- @series} class={bucket.when == :now && "usage-day--now"}>
            {Calendar.strftime(bucket.from, "%a")}
          </span>
        </div>
      </div>
    </section>
    """
  end

  # What a line's figure is a share of: the card's figure above it, split by usage, or — with no
  # figure reported — one window, estimated from weighted tokens (`Forge.Usage.breakdown/5`).
  # Use outside forge is in the figure and not in any forge usage, so it is split in with them, and the
  # legend says so rather than letting the lines read as forge's alone (review fixes 7, M2).
  defp legend(%{mean: mean}) when is_number(mean),
    do:
      "shares of the #{round(mean * 100)}% above, split by what each used; " <>
        "use of these credentials outside forge is split in with them"

  defp legend(%{type: "five_hour"}), do: "share of one 5h window, estimated from tokens used"
  defp legend(_week), do: "in 5h windows, estimated from tokens used"

  defp tone(nil), do: nil
  defp tone(percent), do: "usage-tone--#{usage_tone(percent)}"

  # A bucket's bar against the largest. One that spent nothing is a stub on the baseline, so the
  # steps still read as steps; one that spent anything is never shorter than a sliver.
  defp height(usage, top) do
    if usage == 0,
      do: 3,
      else: max(Float.round(usage / top * 100, 1), 6)
  end

  # The five-hour axis: each whole hour in the window, `now` where it is, and the reset at the
  # end — an hour only where it does not crowd `now` or the reset (UX pass, D21: ticks every
  # 75 minutes from the window's start read 13:53, 15:08).
  defp clock_labels(window, now) do
    here = min(DateTime.diff(now, window.start, :second) / window.length, 1.0)
    ends = if here < 0.88, do: [{clock(DateTime.add(window.start, window.length)), 1}], else: []

    hours =
      for at <- hours(window),
          fraction = DateTime.diff(at, window.start, :second) / window.length,
          abs(fraction - here) >= 0.12,
          ends == [] or fraction <= 0.88,
          do: {clock(at), fraction}

    for {text, fraction} <- hours ++ [{"now", here}] ++ ends,
        do: {text, Float.round(fraction * 100.0, 1)}
  end

  # The whole hours after a window's start and before its end.
  defp hours(%{start: start, length: length}) do
    first = DateTime.add(%{start | minute: 0, second: 0, microsecond: {0, 0}}, 3_600)
    last = DateTime.add(start, length)

    first
    |> Stream.iterate(&DateTime.add(&1, 3_600))
    |> Enum.take_while(&(DateTime.compare(&1, last) == :lt))
  end

  defp clock(at), do: UsagePanel.clock(at)

  defp line_id(%{key: key}) when is_atom(key) or is_nil(key), do: to_string(key || "default")
  defp line_id(%{key: key}), do: key
end
