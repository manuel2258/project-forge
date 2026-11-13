defmodule ForgeWeb.TitleMenu do
  @moduledoc """
  The title menu (`19b`, `docs/design/ui.md` § The title menu): every top-level place with its
  state, so the menu doubles as an overview, and at its foot the account, Accounts for a node
  admin, signing out, and the version as the last line. The theme is on You.

  Drawn inside the frame's drop panel, only while it is open: its figures are
  `ForgeWeb.Frame`'s, read when it opened.
  """

  use ForgeWeb, :html

  attr :menu, :map, required: true, doc: "the figures `ForgeWeb.Frame` read when the menu opened"
  attr :count, :integer, required: true, doc: "the queue button's count"
  attr :capacity, :map, required: true
  attr :current, :atom, default: nil, doc: "the top-level page on screen"
  attr :user, :map, required: true

  def menu(assigns) do
    ~H"""
    <nav class="frame-menu" aria-label="Places">
      <.place navigate={~p"/"} label="Queue" current={@current == :queue}>
        <span class={@count > 0 && "frame-menu-waiting"}>{@count} {noun(@count, "decision")}</span>
      </.place>
      <.place navigate={~p"/projects"} label="Projects" current={@current == :projects}>
        {projects(@menu)}
      </.place>
      <.place navigate={~p"/chats"} label="Chats" current={@current == :chats}>
        {chats(@menu.chats)}
      </.place>
      <.place navigate={~p"/workers"} label="Machines" current={@current == :machines}>
        {machines(@menu)}
      </.place>
      <%!-- Opens the usage panel in place of the menu: on a phone the two lines are display-only,
            too thin to hit on purpose, and this row is the way in (UX pass, A3). The panel's
            *Details ›* goes on to the page. --%>
      <button
        id="menu-usage"
        type="button"
        class="frame-menu-row frame-menu-place"
        phx-click="frame:usage"
        aria-current={@current == :usage && "page"}
      >
        <.place_text label="Usage" current={@current == :usage}>{usage(@capacity)}</.place_text>
      </button>
    </nav>

    <div class="frame-menu-foot">
      <.link navigate={~p"/users/settings"} class="frame-menu-row">
        <span class="frame-menu-account">{@user.email}</span>
        <span aria-hidden="true" class="frame-menu-chevron">›</span>
      </.link>
      <.link
        :if={@menu.accounts}
        id="menu-accounts"
        navigate={~p"/accounts"}
        class="frame-menu-row"
      >
        <span>Accounts</span>
        <span class="frame-menu-state">{@menu.accounts} waiting ›</span>
      </.link>
      <.link href={~p"/users/log-out"} method="delete" class="frame-menu-row">Sign out</.link>
      <p id="menu-version" class="frame-menu-version">forge {Layouts.version()}</p>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :navigate, :string, required: true
  attr :current, :boolean, default: false
  slot :inner_block, required: true

  defp place(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="frame-menu-row frame-menu-place"
      aria-current={@current && "page"}
    >
      <.place_text label={@label} current={@current}>{render_slot(@inner_block)}</.place_text>
    </.link>
    """
  end

  attr :label, :string, required: true
  attr :current, :boolean, required: true
  slot :inner_block, required: true

  defp place_text(assigns) do
    ~H"""
    <span class="frame-menu-label">{@label}</span>
    <span class="frame-menu-state">{render_slot(@inner_block)}</span>
    <span aria-hidden="true" class="frame-menu-chevron">›</span>
    """
  end

  # Each place's state in words a person reads without a key (UX pass, A11, A17): `2 projects ·
  # 1 waits on you`, `1 live of 2`, `none yet` rather than `0 busy · 0 idle`, and no
  # `5h — · week —` when nothing has been reported.
  # The projects page's own subline, from the one function, so the two never count differently.
  defp projects(%{projects: n, waiting: w}), do: ForgeWeb.ProjectRows.summary(n, w)

  defp chats(%{total: 0}), do: "none yet"
  defp chats(%{live: 0, total: total}), do: "#{total}"
  defp chats(%{live: live, total: total}), do: "▸ #{live} live of #{total}"

  defp machines(%{busy: 0, idle: 0}), do: "none yet"
  defp machines(%{busy: busy, idle: 0}), do: "#{busy} busy"
  defp machines(%{busy: busy, idle: idle}), do: "#{busy} busy · #{idle} idle"

  # The two windows in one line, `5h 42% · week 18%`.
  defp usage(capacity) do
    if ForgeWeb.Capacity.percent(capacity["five_hour"]) ||
         ForgeWeb.Capacity.percent(capacity["seven_day"]),
       do:
         "5h #{ForgeWeb.Capacity.shown(capacity["five_hour"])} · week " <>
           ForgeWeb.Capacity.shown(capacity["seven_day"]),
       else: "no figures yet"
  end

  defp noun(1, word), do: word
  defp noun(_n, word), do: word <> "s"
end
