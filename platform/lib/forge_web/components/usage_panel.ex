defmodule ForgeWeb.UsagePanel do
  @moduledoc """
  The usage panel (`22e`, `docs/design/ui.md` § Usage), dropped from either usage line: per window
  its percentage, its reset and its pace; the set's credentials, **naming only the viewer's own**;
  what is spending the window now; and *Details ›* to `/usage`.

  The panel breaks down **the set the line it was opened from averages** — the viewer's own
  credentials, or on a page about a project that project's pool — which `ForgeWeb.Capacity` keeps
  under the capacity assign's `:set`. Its window figures are the lines' own, so the two cannot
  disagree. A pool holds other people's credentials: they are one line, *others in game's pool*,
  never named (`docs/design/credentials.md` § Showing the windows).

  A live component so that what it reads is read once, when it opens, and again only when the
  lines change — never on every render of the page under it.

  The pieces `/usage` draws the same way — the reset and pace line, a line of what spent a window,
  the shares — are here too, public, so the panel and the page say one thing one way.
  """

  use ForgeWeb, :live_component

  alias Forge.{Projects, Usage}
  alias ForgeWeb.{Capacity, Format}

  @windows [{"five_hour", "5-hour window"}, {"seven_day", "Week"}]

  @doc "The panel, for the frame's drop: the lines' capacity assign and who is looking."
  attr :capacity, :map, required: true
  attr :viewer, :map, required: true

  def panel(assigns) do
    ~H"""
    <.live_component module={__MODULE__} id="usage-panel" capacity={@capacity} viewer={@viewer} />
    """
  end

  @impl true
  def update(%{capacity: capacity, viewer: viewer}, socket) do
    now = DateTime.utc_now()
    set = capacity[:set] || %{of: :own, ids: []}

    windows =
      Map.new(@windows, fn {type, _label} -> {type, Usage.window(type, capacity[type], now)} end)

    {:ok,
     assign(socket,
       capacity: capacity,
       windows: windows,
       now: now,
       credentials: Usage.credentials(set.ids, viewer, now),
       pool: pool(set.of),
       spending:
         set.ids
         |> Usage.breakdown(windows["five_hour"].start, :item, viewer,
           running: true,
           of: windows["five_hour"].mean
         )
         |> shown(windows["five_hour"].mean)
     )}
  end

  @doc false
  @spec set_label(map() | nil, %{own: list(), others: %{count: integer()}}) :: String.t()
  def set_label(nil, %{own: own}), do: "your #{length(own)} #{noun(length(own), "credential")}"

  def set_label(project, %{own: own, others: %{count: others}}) do
    n = length(own) + others
    "#{project.name}'s pool · #{n} #{noun(n, "credential")}"
  end

  # The project whose pool this is, for naming the line that names nobody else. The page that
  # switched the lines to it has already decided the viewer may see it.
  defp pool({:project, id}), do: Projects.get!(id)
  defp pool(:own), do: nil

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :labels, @windows)

    ~H"""
    <div id="usage-panel" class="frame-usage">
      <%!-- Whose figure this is (UX pass, D7): a project's pool on its pages, the viewer's own
            elsewhere — so 74% here and 91% on `/usage` do not read as a drop of 17 points. --%>
      <.eyebrow id="usage-panel-set">{set_label(@pool, @credentials)}</.eyebrow>
      <section
        :for={{type, label} <- @labels}
        id={"usage-panel-#{type}"}
        class="frame-usage-window"
      >
        <div class="frame-usage-head">
          <span class="frame-usage-label">{label}</span>
          <span class={["frame-usage-figure", tone_class(@capacity[type])]}>
            {Capacity.shown(@capacity[type])}
          </span>
        </div>
        <.usage_line
          percent={Capacity.percent(@capacity[type])}
          window={if type == "five_hour", do: "5h", else: "week"}
        />
        <.reset_line :if={@capacity[type]} window={@windows[type]} now={@now} />
        <p :if={@capacity[type]} class="frame-usage-meta">
          {@capacity[type].reporting} of {@capacity[type].known} {noun(
            @capacity[type].known,
            "credential"
          )} reporting
        </p>
        <p :if={!@capacity[type]} class="frame-usage-meta">No credential has reported this window.</p>
      </section>

      <section
        :if={@credentials.own != [] or @credentials.others.count > 0}
        id="usage-panel-credentials"
        class="usage-panel-section"
      >
        <.eyebrow>Credentials</.eyebrow>
        <div
          :for={%{credential: credential, windows: windows} <- @credentials.own}
          class="usage-cred"
        >
          <span class="usage-cred-name">{credential.name}</span>
          <span class="usage-cred-figures">
            5h {own_figure(windows["five_hour"])} · wk {own_figure(windows["seven_day"])}
          </span>
        </div>
        <div :if={@credentials.others.count > 0} id="usage-panel-others" class="usage-cred">
          <span class="usage-cred-name">{others(@credentials.others.count, @pool)}</span>
          <span class="usage-cred-figures">
            5h {Capacity.shown(@credentials.others.gauge["five_hour"])} · wk {Capacity.shown(
              @credentials.others.gauge["seven_day"]
            )}
          </span>
        </div>
      </section>

      <section id="usage-panel-now" class="usage-panel-section">
        <.eyebrow>Spending now</.eyebrow>
        <.spent :for={line <- @spending} line={line} compact />
        <p :if={@spending == []} class="frame-usage-meta">Nothing is running on these credentials.</p>
      </section>

      <.link id="usage-panel-details" navigate={~p"/usage"} class="usage-panel-details">
        Details ›
      </.link>
    </div>
    """
  end

  defp others(count, nil), do: "#{count} #{noun(count, "other")}"
  defp others(count, project), do: "#{count} #{noun(count, "other")} in #{project.name}'s pool"

  # One of the viewer's own credentials' windows, as its row on You draws it: a limited one is
  # full whatever it last said.
  defp own_figure(%{limited: true}), do: "100%"
  defp own_figure(%{utilization: u}) when is_number(u), do: "#{round(u * 100)}%"
  defp own_figure(_unreported), do: "—"

  defp tone_class(window) do
    case Capacity.percent(window) do
      nil -> nil
      percent -> "usage-tone--#{usage_tone(percent)}"
    end
  end

  @doc """
  A window's reset and its pace, one line: `↻ resets 14:00 · in 1h 12m` and, opposite,
  `full in ~25m at this rate` in the warning colour, or `on pace`. Times are UTC, as everywhere
  the platform writes one.
  """
  attr :window, :map, required: true, doc: "`Forge.Usage.window/3`"
  attr :now, :any, required: true

  def reset_line(assigns) do
    ~H"""
    <div class="usage-reset">
      <span :if={@window.resets_at} class="usage-reset-at">
        ↻ resets {reset_at(@window)} · {Format.until_phrase(@window.resets_at, @now)}
      </span>
      <span :if={!@window.resets_at} class="usage-reset-at">no reset reported</span>
      <span
        :if={@window.pace}
        class={["usage-pace", match?({:full_in, _}, @window.pace) && "usage-pace--full"]}
      >
        {pace(@window.pace, @now)}
      </span>
    </div>
    """
  end

  @doc "A pace in words: `full in ~25m at this rate`, `full`, or `on pace`."
  @spec pace({:full_in, non_neg_integer()} | :on_pace, DateTime.t()) :: String.t()
  def pace(:on_pace, _now), do: "on pace"
  def pace({:full_in, 0}, _now), do: "full"

  def pace({:full_in, seconds}, now),
    do: "full in ~#{Format.until(DateTime.add(now, max(seconds, 60)), now)} at this rate"

  # The five-hour window's reset is within the day: its clock time. The week's names its day.
  defp reset_at(%{type: "five_hour", resets_at: at}), do: clock(at)
  defp reset_at(%{resets_at: at}), do: Calendar.strftime(at, "%a ") <> clock(at)

  @doc "A moment as the charts label it, `14:00`, in UTC."
  @spec clock(DateTime.t()) :: String.t()
  def clock(at), do: Calendar.strftime(at, "%H:%M")

  @doc """
  One line of what spent a window (`Forge.Usage.breakdown/5`): what it was, a bar, and its share —
  `shown`, from `shown/2`, or its share as a percent. **The bar is absolute**: its share of the
  whole track, so a line at 22 % draws a fifth of it and the bars of a list add up to the card's
  own (UX pass, D6 — they were drawn against the largest line, so 22 % filled the track). A
  running item is marked `▸` and drawn in the running colour. *elsewhere* is spend in projects the
  viewer is not in, unnamed.
  """
  attr :line, :map, required: true
  attr :compact, :boolean, default: false, doc: "the panel's: no second line"
  attr :id, :string, default: nil

  def spent(assigns) do
    assigns = assign(assigns, :what, what(assigns.line))

    ~H"""
    <div id={@id} class={["usage-line", @line.running && "usage-line--running"]}>
      <span class="usage-line-what">
        <.link :if={@what.path} navigate={@what.path} class="usage-line-ref">
          {if @line.running, do: "▸ "}{@what.ref}
        </.link>
        <span :if={!@what.path} class="usage-line-ref">{@what.ref}</span>
        <span :if={@what.sub && !@compact} class="usage-line-sub">{@what.sub}</span>
      </span>
      <span class="usage-line-bar"><span style={"width: #{bar(@line.share)}%"} /></span>
      <span class="usage-line-share" title={Format.exact(@line[:usage])}>
        {@line[:shown] || percent(@line.share)}
      </span>
    </div>
    """
  end

  @doc "A share as a whole percent, `22%`, or `—` when there is none."
  @spec percent(float() | nil) :: String.t()
  def percent(nil), do: "—"
  def percent(share), do: "#{round(share * 100)}%"

  @doc """
  Lines with `:shown`, their shares as whole percents that **add up to the figure they split**.
  Rounded one by one, 45.5 % and 45.5 % of a 91 % window read 46 % and 46 %: more than the
  figure over them. So the whole percents are handed out by largest remainder, to one rounded
  whole: **where the lines are all of the figure, the card's own `round(of * 100)`** — rounding
  their sum instead put 95.49999… beside a card's `round(95.5)`, 95 % under 96 % (review fixes 7,
  L1) — and where they are a part of it, as the panel's running ones are, their sum rounded. A
  line with no share shows `—`, and with no figure the shares are estimates and are rounded as
  they are.
  """
  @spec shown([map()], number() | nil) :: [map()]
  def shown(lines, of) do
    shares = Enum.map(lines, & &1.share)

    if is_number(of) and nil not in shares and lines != [] do
      parts = Enum.map(shares, &(&1 * 100))
      lines |> Enum.zip(apportion(parts, whole(parts, of))) |> Enum.map(&put_shown/1)
    else
      Enum.map(lines, &Map.put(&1, :shown, percent(&1.share)))
    end
  end

  defp put_shown({line, whole}), do: Map.put(line, :shown, "#{whole}%")

  # The whole percent the parts are handed out to: the card's, when they add up to its figure —
  # within float error, which is all that tells "every line" from "some of them" here.
  defp whole(parts, of) do
    sum = Enum.sum(parts)
    if abs(sum - of * 100) < 1.0e-6, do: round(of * 100), else: round(sum)
  end

  # Largest remainder: each part floored, and the points left to reach the whole given to the
  # parts with the largest fractions, earliest first among equals.
  defp apportion(parts, whole) do
    floors = Enum.map(parts, &floor/1)
    left = whole - Enum.sum(floors)

    lucky =
      parts
      |> Enum.with_index()
      |> Enum.sort_by(fn {part, i} -> {-(part - floor(part)), i} end)
      |> Enum.take(max(left, 0))
      |> MapSet.new(fn {_part, i} -> i end)

    for {whole, i} <- Enum.with_index(floors), do: whole + if(i in lucky, do: 1, else: 0)
  end

  @doc "How long a share's bar is, in percent of the track: the share itself, at most all of it."
  @spec bar(float() | nil) :: number()
  def bar(nil), do: 0
  def bar(share), do: (share * 100.0) |> min(100.0) |> max(0.0) |> Float.round(1)

  # What a line is called, what it says under that, and where it leads. A job is its ticket and
  # its state's visit; a conversation is its project and what it was opened with.
  defp what(%{elsewhere: true}),
    do: %{ref: "elsewhere", sub: "in projects you are not in", path: nil}

  defp what(%{job: %{kind: :chat} = job, project: project, opening: opening}),
    do: %{ref: "chat · #{project.name}", sub: opening, path: ~p"/chats/#{job.id}"}

  defp what(%{job: job, ticket: %{} = ticket, project: project}) do
    %{
      ref: "#{project.name}##{ticket.number} · #{job.state} ##{job.attempt}",
      sub: Enum.join([ticket.title | outcome(job)], " · "),
      path: ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}"
    }
  end

  defp what(%{earlier: 1}), do: %{ref: "1 earlier job or chat", sub: nil, path: nil}
  defp what(%{earlier: n}), do: %{ref: "#{n} earlier jobs and chats", sub: nil, path: nil}
  defp what(%{model: model}) when is_binary(model), do: %{ref: model, sub: nil, path: nil}
  defp what(%{model: nil}), do: %{ref: "the project's default", sub: nil, path: nil}
  defp what(%{project: project}), do: %{ref: project.name, sub: nil, path: nil}

  # A finished job that did not converge says how it ended; one that did, and one still going,
  # say nothing.
  defp outcome(%{outcome: outcome}) when outcome in [nil, :converged], do: []
  defp outcome(%{outcome: outcome}), do: [ended(outcome)]

  # In words, never the enum (UX pass, D21).
  defp ended(:did_not_converge), do: "didn't converge"
  defp ended(:budget_exhausted), do: "out of budget"
  defp ended(:error), do: "failed"
  defp ended(outcome), do: to_string(outcome)

  defp noun(1, word), do: word
  defp noun(_n, word), do: word <> "s"
end
