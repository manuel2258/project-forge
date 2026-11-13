defmodule ForgeWeb.UI.Navigation do
  @moduledoc """
  The navigation primitives (`docs/design/ui/design_system/components/navigation/`,
  `docs/design/ui.md` § The frame): the top bar with its queue button and usage lines, and the
  strip of an object's views with its desktop form, the title row's view tabs.

  Styles are in `assets/css/components.css` under the same names.
  """
  use Phoenix.Component

  import ForgeWeb.UI.Data, only: [count_bubble: 1]

  @doc """
  The phone top bar (`navigation/TopBar`), 52px, between the two usage lines: the queue button
  on the left, the title and a mono subline in the middle, the context object on the right.

  `menu` draws ▾ (▴ while `menu_open`) after the title, for a top-level page whose title is the
  switch. `on_title` makes the title a button. `usage` is `%{five_h: n, week: n}` or `nil`, which
  draws a plain 1px rule instead (a modal screen). `disconnected`, a countdown string, turns the
  bar red-hatched under a 2px red rule with "Not connected" for a title and no usage lines.

  The `:left` and `:right` slots replace the queue button and the context; `queue={false}` draws
  nothing on the left (the queue page itself).
  """
  attr :id, :string, default: nil
  attr :title, :string, required: true
  attr :queue, :boolean, default: true
  attr :queue_count, :integer, default: 0
  attr :queue_path, :string, default: "/"
  attr :context, :string, default: nil, doc: "the parent object, e.g. the project's name"
  attr :context_path, :any, default: nil
  attr :context_click, :any, default: nil, doc: "a `%JS{}` for an action in the context's place"
  attr :menu, :boolean, default: false
  attr :menu_open, :boolean, default: false
  attr :on_title, :any, default: nil, doc: "phx-click for the title"
  attr :usage, :map, default: nil, doc: "%{five_h: percent | nil, week: percent | nil}"
  attr :on_usage, :any, default: nil, doc: "phx-click for the usage lines"
  attr :disconnected, :any, default: false, doc: "false, or the countdown line"

  attr :framed, :boolean,
    default: false,
    doc: "drawn inside `Layouts.app`, which draws the usage lines itself, once for every width"

  attr :rest, :global

  slot :subline
  slot :left
  slot :right
  slot :inner_block, doc: "drawn under the bar inside its positioned wrapper: a drop panel"

  def top_bar(assigns) do
    assigns = assign(assigns, :offline, assigns.disconnected not in [false, nil])

    ~H"""
    <div id={@id} class={["ui-top", @offline && "ui-top--disconnected"]} {@rest}>
      <.usage_line
        :if={@usage && !@offline && !@framed}
        window="5h"
        percent={@usage[:five_h]}
        on_click={@on_usage}
      />
      <div class="ui-top-bar">
        <%= cond do %>
          <% @left != [] -> %>
            {render_slot(@left)}
          <% @queue -> %>
            <.queue_button count={@queue_count} navigate={@queue_path} />
          <% true -> %>
        <% end %>
        <.title_block on_title={@on_title} offline={@offline}>
          <span class="ui-top-name">
            <.offline_mark :if={@offline} />{if @offline, do: "Not connected", else: @title}<span
              :if={@menu && !@offline}
              class="ui-top-menu"
              aria-hidden="true"
            >{if @menu_open, do: "▴", else: "▾"}</span>
          </span>
          <span :if={@offline} class="ui-top-sub">{@disconnected}</span>
          <span :if={!@offline && @subline != []} class="ui-top-sub">{render_slot(@subline)}</span>
          <%!-- In the frame the connection is the browser's to know: this is shown in place of
                the title while it is lost, and the `Connection` hook writes the line. --%>
          <span :if={@framed} class="ui-top-offline" role="status">
            <span class="ui-top-name"><.offline_mark />Not connected</span>
            <span class="ui-top-sub" data-connection-line></span>
          </span>
        </.title_block>
        <%= cond do %>
          <% @right != [] -> %>
            {render_slot(@right)}
          <% @context -> %>
            <%!-- `›` goes to the parent; an action (`+ New`) opens in place and draws none. --%>
            <.link :if={@context_path} navigate={@context_path} class="ui-top-context">
              <span>{@context}{context_mark(@context)}</span>
            </.link>
            <button
              :if={!@context_path && @context_click}
              type="button"
              class="ui-top-context"
              phx-click={@context_click}
            >
              <span>{@context}</span>
            </button>
            <span :if={!@context_path && !@context_click} class="ui-top-context">
              <span>{@context}{context_mark(@context)}</span>
            </span>
          <% true -> %>
        <% end %>
      </div>
      <.usage_line
        :if={@usage && !@offline && !@framed}
        window="week"
        percent={@usage[:week]}
        on_click={@on_usage}
      />
      <div :if={(!@usage || @offline) && !@framed} class="ui-top-rule" />
      {render_slot(@inner_block)}
    </div>
    """
  end

  # The parent object goes somewhere; an action — `+ New` — opens where it is.
  defp context_mark("+" <> _action), do: nil
  defp context_mark(_parent), do: " ›"

  @doc "The crossed-out signal beside *Not connected* (`docs/design/ui.md` § Connection state)."
  def offline_mark(assigns) do
    ~H"""
    <svg class="ui-offline-mark" viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
      <path
        d="M2 6.5a9 9 0 0 1 12 0M4.5 9a5.5 5.5 0 0 1 7 0M7 11.5a2 2 0 0 1 2 0"
        fill="none"
        stroke="currentColor"
        stroke-width="1.5"
        stroke-linecap="round"
      />
      <path d="M2.5 2.5l11 11" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" />
    </svg>
    """
  end

  attr :on_title, :any, required: true
  attr :offline, :boolean, required: true
  slot :inner_block, required: true

  defp title_block(%{on_title: nil} = assigns) do
    ~H"""
    <div class="ui-top-title">{render_slot(@inner_block)}</div>
    """
  end

  defp title_block(assigns) do
    ~H"""
    <button type="button" class="ui-top-title" phx-click={@on_title} disabled={@offline}>
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc """
  The queue button (`navigation/QueueButton`): the fixed left slot of every phone top bar. It
  always goes to the queue and shows how many decisions wait, amber when any do. Never a back
  arrow.
  """
  attr :count, :integer, default: 0
  attr :navigate, :string, default: "/"

  def queue_button(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={["ui-queue-btn", @count > 0 && "ui-queue-btn--waiting"]}
      aria-label={"Queue, #{@count} waiting"}
    >
      <span class="ui-queue-pill">
        <span class="ui-queue-back" aria-hidden="true">‹</span>
        <svg
          width="16"
          height="16"
          viewBox="0 0 16 16"
          fill="none"
          stroke="currentColor"
          stroke-width="1.5"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <path d="M2 9.5h3.2l1 2h3.6l1-2H14" /><path d="M2 9.5 3.8 3.5h8.4L14 9.5v3H2z" />
        </svg>
        <span class="ui-queue-count">{@count}</span>
      </span>
    </.link>
    """
  end

  @doc """
  A usage hairline (`navigation/UsageLine`, `docs/design/capacity.md` § Two objects): the 5-hour
  window 3px above the top bar, the week 2px below it. Quiet ink under 80 %, the warning colour
  from 80, danger from 95 — **never the accent**, which means *waits on you*.

  A `nil` percent is a set in which nothing reported: the band keeps its height and draws
  neither track nor fill.
  """
  attr :id, :string, default: nil
  attr :percent, :any, default: nil, doc: "0–100, or nil when nothing reported"
  attr :window, :string, default: "5h", values: ~w(5h week)
  attr :on_click, :any, default: nil

  def usage_line(%{percent: nil} = assigns) do
    ~H"""
    <div
      id={@id}
      class={["ui-usage ui-usage--empty", @window == "week" && "ui-usage--week"]}
      phx-click={@on_click}
      aria-hidden="true"
    />
    """
  end

  def usage_line(assigns) do
    ~H"""
    <div
      id={@id}
      class={["ui-usage", @window == "week" && "ui-usage--week"]}
      role="meter"
      aria-valuenow={@percent}
      aria-valuemin="0"
      aria-valuemax="100"
      aria-label={if @window == "week", do: "Weekly usage", else: "5-hour usage"}
      phx-click={@on_click}
    >
      <div
        class={["ui-usage-fill", "ui-usage-fill--#{usage_tone(@percent)}"]}
        style={"width: #{min(@percent, 100)}%"}
      />
    </div>
    """
  end

  @doc """
  The tone of a usage figure: `:quiet` under 80, `:warning` from 80, `:danger` from 95
  (`docs/design/capacity.md` § Two objects). The desktop digits take the same tone.
  """
  @spec usage_tone(number) :: :quiet | :warning | :danger
  def usage_tone(percent) when percent >= 95, do: :danger
  def usage_tone(percent) when percent >= 80, do: :warning
  def usage_tone(_percent), do: :quiet

  @doc """
  The bottom strip (`navigation/BottomStrip`): the views of the object on screen, equal-width tabs
  with grey count bubbles. **Navigation only** — never a decision, never amber. At most five.
  **A count of zero is drawn muted, never hidden**, so the tabs never move; a tab with no count
  (`nil`) draws none.

  Each `:tab` is a link (`patch`, `navigate` or `href`); the one whose `label` is `active` is
  marked `aria-current="page"`.
  """
  attr :active, :string, default: nil
  attr :rest, :global

  slot :tab, required: true do
    attr :label, :string, required: true
    attr :count, :any
    attr :patch, :string
    attr :navigate, :string
    attr :href, :string
    attr :id, :string
  end

  def bottom_strip(assigns) do
    ~H"""
    <nav class="ui-strip" {@rest}>
      <.link
        :for={tab <- @tab}
        id={tab[:id]}
        patch={tab[:patch]}
        navigate={tab[:navigate]}
        href={tab[:href]}
        class="ui-strip-tab"
        aria-current={tab.label == @active && "page"}
      >
        {tab.label}<.count_bubble :if={tab[:count] != nil} value={tab.count} muted={tab.count == 0} />
      </.link>
    </nav>
    """
  end

  @doc """
  The strip's desktop form: the view tabs on the right of the title row, 32px, the active one on
  `--surface-2`. Same slots as `bottom_strip/1`; a count is plain text after the label, and a
  zero is muted rather than hidden, as on the strip.
  """
  attr :active, :string, default: nil
  attr :rest, :global

  slot :tab, required: true do
    attr :label, :string, required: true
    attr :count, :any
    attr :patch, :string
    attr :navigate, :string
    attr :href, :string
    attr :id, :string
  end

  def view_tabs(assigns) do
    ~H"""
    <nav class="ui-tabs" {@rest}>
      <.link
        :for={tab <- @tab}
        id={tab[:id]}
        patch={tab[:patch]}
        navigate={tab[:navigate]}
        href={tab[:href]}
        class="ui-tab"
        aria-current={tab.label == @active && "page"}
      >
        {tab.label}<span :if={tab[:count] != nil} class={tab.count == 0 && "ui-tab-zero"}>{tab.count}</span>
      </.link>
    </nav>
    """
  end
end
