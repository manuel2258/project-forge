defmodule ForgeWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use ForgeWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  The operator shell: a hairline-ruled top row on a laptop, a fixed bottom bar on a phone.

  There is no global page padding and no global measure — each route sets its own `measure`,
  because the queue deliberately does not widen and the board deliberately does not cap.

  ## Examples

      <Layouts.app flash={@flash} active={:queue} measure="34rem">
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :measure, :any,
    default: "34rem",
    doc: "max width of the content column, or nil for the full viewport. See docs/design/ui.md."

  attr :active, :atom, default: nil, doc: "which nav item is the current page"

  attr :nav, :boolean,
    default: true,
    doc: "false for a page a pending account may see, whose nav leads nowhere it may go"

  attr :queue_count, :integer, default: nil, doc: "decisions waiting, shown as the queue badge"

  attr :capacity, :map,
    default: nil,
    doc: "the top bar's window gauge, from `ForgeWeb.Capacity`; nil on a page that has none"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="hidden sm:flex items-center gap-6 border-b border-base-300 px-6 lg:px-[30px] h-14">
      <.link navigate={~p"/"} class="font-semibold -tracking-[.02em]">forge</.link>
      <nav :if={@nav} class="flex items-center gap-5 text-sm">
        <.nav_link navigate={~p"/"} active={@active == :queue} count={@queue_count}>Queue</.nav_link>
        <.nav_link navigate={~p"/board"} active={@active == :board}>Board</.nav_link>
        <%!-- Laptop only, and deliberately: the phone is where decisions are answered and a
              machine is never a decision. See docs/design/ui.md. --%>
        <.nav_link navigate={~p"/workers"} active={@active == :workers}>Workers</.nav_link>
        <%!-- Laptop only too, but for a different reason: a conversation that needs you is
              already in the queue. This is for finding one again, which is a laptop errand. --%>
        <.nav_link navigate={~p"/chats"} active={@active == :chats}>Chats</.nav_link>
      </nav>
      <div class="ml-auto flex items-center gap-4">
        <%!-- Nothing reported anywhere in the set draws nothing, not an empty gauge. --%>
        <.capacity_gauge :if={@capacity not in [nil, %{}]} capacity={@capacity} />
        <%!-- An action, not a destination, so it sits beside the theme toggle rather than among
              the nav items. A project is made rarely and from nowhere in particular; a ticket is
              always made for a project and lives on that project's page. See docs/design/ui.md
              § Creating things. --%>
        <.link
          :if={@current_scope && @nav}
          navigate={~p"/projects/new"}
          class="flex min-h-[46px] items-center rounded-field border border-base-300 px-3 text-sm hover:border-base-content/30"
        >
          New project
        </.link>
        <.theme_toggle />
        <%!-- Account governance, and the only thing `node_admin` unlocks. Beside the address
              rather than in the nav: it is not a place work happens, and most accounts never
              see it at all. Without it the perimeter's only surface is a URL you have to know,
              and nobody can discover that someone is waiting. --%>
        <.link
          :if={@current_scope && @current_scope.user.node_admin}
          navigate={~p"/accounts"}
          class="link link-hover text-sm opacity-70"
        >
          Accounts
        </.link>
        <div :if={@current_scope} class="flex items-center gap-3 text-sm">
          <.link navigate={~p"/users/settings"} class="link link-hover opacity-70">
            {@current_scope.user.email}
          </.link>
          <.link href={~p"/users/log-out"} method="delete" class="link link-hover opacity-70">
            Log out
          </.link>
        </div>
        <.link :if={!@current_scope} navigate={~p"/users/log-in"} class="link link-hover text-sm">
          Log in
        </.link>
      </div>
    </header>

    <main class={[
      "px-5 sm:px-6 lg:px-[30px] pt-6 sm:pt-8",
      "pb-[calc(4rem+56px+env(safe-area-inset-bottom))] sm:pb-16"
    ]}>
      <div class={@measure && "mx-auto"} style={@measure && "max-width: #{@measure}"}>
        {render_slot(@inner_block)}
      </div>
    </main>

    <nav
      :if={@nav}
      class={[
        "sm:hidden fixed inset-x-0 bottom-0 z-20 grid grid-cols-2",
        "border-t border-base-300 bg-base-100 pb-[env(safe-area-inset-bottom)]"
      ]}
    >
      <.bar_link navigate={~p"/"} active={@active == :queue} count={@queue_count}>Queue</.bar_link>
      <.bar_link navigate={~p"/board"} active={@active == :board}>Board</.bar_link>
    </nav>

    <.flash_group flash={@flash} />
    """
  end

  attr :capacity, :map, required: true

  # Per window, five-hour then weekly: ten ticks of mean utilization when any credential reported
  # one, and a countdown to the soonest reset whenever a window is known. Neutral, never accent —
  # time resolves it, not a person (`docs/design/capacity.md` § Two objects). What it averages over
  # is in the title, because a mean over the credentials that happened to report is a different
  # claim from one over all of them.
  defp capacity_gauge(assigns) do
    ~H"""
    <div id="capacity-gauge" class="flex items-center gap-4 font-mono text-[11.5px] opacity-70">
      <span
        :for={{type, label} <- [{"five_hour", "5h"}, {"seven_day", "week"}]}
        :if={@capacity[type]}
        id={"capacity-#{type}"}
        title={gauge_title(label, @capacity[type])}
        class="flex items-center gap-1.5"
      >
        <span>{label}</span>
        <span
          :if={@capacity[type].mean}
          class="flex gap-px"
          aria-label={"#{round(@capacity[type].mean * 100)}%"}
        >
          <span
            :for={tick <- 1..10}
            class={[
              "h-2.5 w-[3px] rounded-[1px]",
              if(tick <= round(@capacity[type].mean * 10),
                do: "bg-base-content",
                else: "bg-base-content/20"
              )
            ]}
          />
        </span>
        <span>{ForgeWeb.Format.until(@capacity[type].soonest)}</span>
      </span>
    </div>
    """
  end

  defp gauge_title(label, window) do
    figure = if window.mean, do: "#{round(window.mean * 100)}% used on average, ", else: ""

    "#{label} window: #{figure}#{window.reporting} of #{window.known} credentials reporting, " <>
      "soonest reset #{Calendar.strftime(window.soonest, "%a %H:%M")} UTC"
  end

  attr :navigate, :string, required: true
  attr :active, :boolean, default: false
  attr :count, :integer, default: nil
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={["flex items-center gap-2", @active || "opacity-60 hover:opacity-100"]}
      aria-current={@active && "page"}
    >
      {render_slot(@inner_block)}
      <span :if={@count && @count > 0} class="badge badge-accent badge-sm font-mono">{@count}</span>
    </.link>
    """
  end

  # 56px plus the safe-area inset, each item a full-height tap target: answering is a thumb action.
  attr :navigate, :string, required: true
  attr :active, :boolean, default: false
  attr :count, :integer, default: nil
  slot :inner_block, required: true

  defp bar_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "flex h-14 items-center justify-center gap-2 text-sm",
        @active || "opacity-60"
      ]}
      aria-current={@active && "page"}
    >
      {render_slot(@inner_block)}
      <span :if={@count && @count > 0} class="badge badge-accent badge-sm font-mono">{@count}</span>
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative flex flex-row items-center rounded-full border border-base-300">
      <div class="absolute w-1/3 h-full rounded-full bg-base-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left] motion-reduce:transition-none" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
