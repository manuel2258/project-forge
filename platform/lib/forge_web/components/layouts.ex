defmodule ForgeWeb.Layouts do
  @moduledoc """
  The frame every signed-in page is drawn in (`app/1`), the sign-in screens' own (`sign_in/1`),
  and the root template (`docs/design/ui.md` § The frame).
  """
  use ForgeWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  alias ForgeWeb.{Capacity, TitleMenu, UsagePanel}

  @doc """
  The frame every signed-in page is drawn in (`docs/design/ui.md` § The frame): the usage lines,
  the top bar on a phone and the header and title row on a desktop, the object's decision row,
  the content — the page's only scroller — the composer, and the strip of the object's views.
  `ForgeWeb.Frame` reads what it draws; a page passes `frame={@frame}` and `capacity={@capacity}`
  and says what it is.

  **One frame, two arrangements, one order.** Below 768px the top bar and the strip; from 768 the
  56px header and the title row, whose tabs are the same `views` the strip draws. Wide screens add
  the `list` and `aside` columns either side of the content and never move a block above another.

  **The title is a control.** On a top-level page (`top_level`) it is the switch that drops the
  title menu; on a page with `details` it drops those; elsewhere it is plain text. Each drop
  panel is the frame's: open state is `@frame.open`, and `frame:*` events change it.

  `fill` is for a page whose content holds a scroller of its own — a conversation's transcript,
  a ticket's tab body — which then gets the content's whole height rather than its own.

  ## Examples

      <Layouts.app flash={@flash} current_scope={@current_scope} frame={@frame}
        capacity={@capacity} title="Projects" top_level={:projects}
        context={{"+ New", ~p"/projects/new"}}>
        …
      </Layouts.app>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_scope, :map, required: true
  attr :frame, :map, required: true, doc: "`ForgeWeb.Frame`'s assign"
  attr :capacity, :map, default: %{}, doc: "`ForgeWeb.Capacity`'s assign: the usage lines"

  attr :title, :string, required: true

  attr :subline, :string,
    default: nil,
    doc: "mono, under the title: the object's number and state"

  attr :context, :any,
    default: nil,
    doc: """
    `{label, path}`: the parent object, the right end of the top bar — or `{label, %JS{}}`, an
    action there that opens in place (the queue's *All N*), drawn on the phone only
    """

  attr :back, :any,
    default: nil,
    doc: "`{label, path}`: the title row's back link on a desktop; the context's when not given"

  attr :section, :string,
    default: nil,
    doc: """
    the place the page belongs to, the desktop switch's label: a chat is under Chats, a machine
    under Machines; a top-level page's own title, and Projects, when not given
    """

  attr :top_level, :atom,
    default: nil,
    values: [nil, :queue, :projects, :chats, :machines, :usage],
    doc: "which top-level page this is: its title is then the switch that drops the title menu"

  attr :views, :list,
    default: [],
    doc: "the object's views, `%{key, label, count, patch | navigate}`: the strip and the tabs"

  attr :view, :string, default: nil, doc: "the key of the view on screen"

  attr :measure, :any,
    default: "34rem",
    doc: "max width of the content column, or nil for all of it. See docs/design/ui.md."

  attr :fill, :boolean,
    default: false,
    doc: "the content is one scroller of the page's own, given the whole height"

  attr :resizable, :boolean,
    default: false,
    doc: """
    the context column is the person's to resize from 1440px, by a handle on the line between it
    and the content: a ticket's and a chat's pages only (`docs/design/ui.md` § Three layouts)
    """

  slot :details, doc: "the object's details, dropped from its title"
  slot :decision, doc: "the decision row, pinned under the top bar"
  slot :composer, doc: "what sits under the content: a conversation's composer"
  slot :list, doc: "the list column, on the left on a wide screen"
  slot :aside, doc: "the context column, on the right on a wide screen"
  slot :inner_block, required: true

  def app(assigns) do
    assigns =
      assign(assigns,
        back: assigns.back || (assigns.top_level == nil && assigns.context),
        open: assigns.frame.open,
        on_title: title_event(assigns.top_level, assigns.details)
      )

    ~H"""
    <div id="frame" phx-hook=".ViewportFrame" class={["frame", @fill && "frame--fill"]}>
      <%!-- The connection's state is drawn on the bars themselves (`docs/design/ui.md`
            § Connection state): LiveView runs these bindings after its own half-second grace,
            and the `Connection` hook (`assets/js/connection.js`) does the rest. --%>
      <div
        id="frame-top"
        class="frame-top"
        phx-hook="Connection"
        phx-disconnected={JS.dispatch("forge:connection-lost")}
        phx-connected={JS.dispatch("forge:connection-back")}
      >
        <.usage_line
          id="usage-5h"
          window="5h"
          percent={Capacity.percent(@capacity["five_hour"])}
          on_click="frame:usage"
        />
        <.top_bar
          id="top-bar"
          framed
          title={@title}
          queue={@top_level != :queue}
          queue_count={@frame.count}
          context={@context && elem(@context, 0)}
          context_path={@context && is_binary(elem(@context, 1)) && elem(@context, 1)}
          context_click={@context && match?(%JS{}, elem(@context, 1)) && elem(@context, 1)}
          menu={@on_title != nil}
          menu_open={@open in [:menu, :details]}
          on_title={@on_title}
        >
          <:subline :if={@subline}>{@subline}</:subline>
        </.top_bar>
        <.desktop_header
          frame={@frame}
          capacity={@capacity}
          switch={@section || if(@top_level, do: @title, else: "Projects")}
          user={@current_scope.user}
        />
        <.usage_line
          id="usage-week"
          window="week"
          percent={Capacity.percent(@capacity["seven_day"])}
          on_click="frame:usage"
        />
        <%!-- With no column either side, the title starts where the content does: the row is
              capped and centred by the same measure as the body (UX re-check #16). --%>
        <div
          id="title-row"
          class={["frame-title-row", (@list == [] and @aside == []) && "frame-title-row--measured"]}
          style={(@list == [] and @aside == [] and @measure) && "--frame-measure: #{@measure}"}
        >
          <div class="frame-heading">
            <.link :if={@back} navigate={elem(@back, 1)} class="frame-back">
              ‹ {elem(@back, 0)}
            </.link>
            <div class="frame-heading-line">
              <h1 class="frame-h1">
                <button :if={@details != []} type="button" phx-click="frame:details">
                  {@title}<span class="frame-h1-menu" aria-hidden="true">{if @open == :details,
                    do: "▴",
                    else: "▾"}</span>
                </button>
                <span :if={@details == []}>{@title}</span>
              </h1>
              <span :if={@subline} class="frame-subline">{@subline}</span>
            </div>
          </div>
          <%!-- A top-level page's context is an action, `+ New`, and has no back link to be: on
                a desktop it is the title row's, on the right. --%>
          <.link
            :if={@top_level && @context && is_binary(elem(@context, 1))}
            navigate={elem(@context, 1)}
            class="frame-context"
          >
            {elem(@context, 0)}
          </.link>
          <.view_tabs :if={@views != []} active={active_label(@views, @view)} aria-label="Views">
            <:tab
              :for={view <- @views}
              label={view.label}
              count={view[:count]}
              patch={view[:patch]}
              navigate={view[:navigate]}
            />
          </.view_tabs>
        </div>

        <div
          :if={@open == :menu}
          class="frame-drop frame-drop--menu"
          phx-window-keydown="frame:close"
          phx-key="Escape"
        >
          <.drop_panel id="title-menu" on_close="frame:close">
            <TitleMenu.menu
              menu={@frame.menu}
              count={@frame.count}
              capacity={@capacity}
              current={@top_level}
              user={@current_scope.user}
            />
            <.handle />
          </.drop_panel>
        </div>

        <%!-- Drawn whether open or not, hidden while folded: the details are part of the page,
              and a form in them keeps what was typed when it folds. --%>
        <div
          :if={@details != []}
          class="frame-drop frame-drop--details"
          hidden={@open != :details}
          phx-window-keydown={@open == :details && "frame:close"}
          phx-key="Escape"
        >
          <.drop_panel id="frame-details" on_close="frame:close">
            {render_slot(@details)}
            <.handle />
          </.drop_panel>
        </div>

        <div
          :if={@open == :usage}
          class="frame-drop frame-drop--usage"
          phx-window-keydown="frame:close"
          phx-key="Escape"
        >
          <.drop_panel on_close="frame:close">
            <UsagePanel.panel capacity={@capacity} viewer={@current_scope.user} />
            <.handle />
          </.drop_panel>
        </div>
      </div>

      <div :if={@decision != []} class="frame-decision">{render_slot(@decision)}</div>

      <main id="frame-content" class="frame-content" data-scroller>
        <div class={["frame-columns", (@resizable and @aside != []) && "frame-columns--resizable"]}>
          <aside :if={@list != []} class="frame-list">{render_slot(@list)}</aside>
          <%!-- The content and what sits under it share one column: from 768px the composer,
                the question card and a dock are as wide as the content, and centred with it where the page
                has a measure,
                and on a wide screen they stop where the columns either side begin
                (`docs/design/ui.md` § Three layouts). --%>
          <div class="frame-main" style={@measure && "--frame-measure: #{@measure}"}>
            <div class="frame-body">
              {render_slot(@inner_block)}
            </div>
            <div :if={@composer != []} class="frame-composer">{render_slot(@composer)}</div>
          </div>
          <%!-- The line between the content and the column, drawn from 1440px: a separator that
                resizes the column, by pointer or arrow keys (`.AsideResize`, below). Its value is
                the hook's to keep current, so a patch leaves those two alone. --%>
          <div
            :if={@resizable and @aside != []}
            id="frame-aside-handle"
            class="frame-aside-handle"
            role="separator"
            aria-orientation="vertical"
            aria-controls="frame-aside"
            aria-label="Resize the side column"
            aria-valuemin="360"
            tabindex="0"
            phx-hook=".AsideResize"
            phx-mounted={JS.ignore_attributes(["aria-valuenow", "aria-valuemax"])}
          />
          <aside :if={@aside != []} id={@resizable && "frame-aside"} class="frame-aside">
            {render_slot(@aside)}
          </aside>
        </div>
      </main>

      <div :if={@views != []} class="frame-strip">
        <.bottom_strip active={active_label(@views, @view)} aria-label="Views">
          <:tab
            :for={view <- @views}
            :if={view[:phone] != false}
            id={"tab-#{view.key}"}
            label={view.label}
            count={view[:count]}
            patch={view[:patch]}
            navigate={view[:navigate]}
          />
        </.bottom_strip>
      </div>
    </div>

    <%!-- The width is one value for every ticket and chat, in this browser (`forge:aside-width`),
          set as `--frame-aside-width` on `<html>`, which LiveView never patches: it survives a
          patch, a live navigation and a reconnect, and `root.html.heex` applies it before first
          paint so a reload does not jump. Nothing here reaches the server. The limits are the
          stylesheet's (`clamp()` in `frame.css`), so a width stored from a larger window is held
          to them whatever it says; this hook only keeps its own writes inside them and the
          separator's `aria-valuenow` true. --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".AsideResize">
      const KEY = "forge:aside-width"
      const MIN = 360
      const MIN_MAIN_REM = 34

      export default {
        mounted() {
          const root = document.documentElement
          const columns = this.el.parentElement
          const aside = () => document.getElementById("frame-aside")
          const rem = () => parseFloat(getComputedStyle(root).fontSize) || 16
          const max = () => Math.max(MIN, Math.floor(columns.getBoundingClientRect().width - MIN_MAIN_REM * rem()))
          const drawn = () => Math.round(aside().getBoundingClientRect().width)

          this.sync = () => {
            this.el.setAttribute("aria-valuenow", String(drawn()))
            this.el.setAttribute("aria-valuemax", String(max()))
          }

          const set = (px) => {
            root.style.setProperty("--frame-aside-width", `${Math.min(Math.max(Math.round(px), MIN), max())}px`)
            this.sync()
          }

          const store = () => {
            try { localStorage.setItem(KEY, String(drawn())) } catch (_) {}
          }

          this.stop = null

          this.el.addEventListener("pointerdown", (down) => {
            if (down.button !== 0) return
            down.preventDefault()
            // A second press before the first is released (two fingers) ends the first drag, and
            // each drag's `stop` removes its own listeners: the column would otherwise follow the
            // pointer with nothing held. Either alone is enough, so removing only one of the two
            // changes nothing a test can see; removing both is what the browser test catches.
            this.stop?.()
            // The column's right edge stays where it is; its left edge follows the pointer. Listening
            // on the window rather than capturing the pointer keeps a drag going over the content.
            const right = aside().getBoundingClientRect().right
            this.el.setAttribute("data-dragging", "")

            const move = (event) => set(right - event.clientX)
            const stop = () => {
              window.removeEventListener("pointermove", move)
              window.removeEventListener("pointerup", stop)
              window.removeEventListener("pointercancel", stop)
              this.el.removeAttribute("data-dragging")
              if (this.stop === stop) this.stop = null
              store()
            }
            this.stop = stop

            window.addEventListener("pointermove", move)
            window.addEventListener("pointerup", stop)
            window.addEventListener("pointercancel", stop)
          })

          this.el.addEventListener("dblclick", () => {
            root.style.removeProperty("--frame-aside-width")
            try { localStorage.removeItem(KEY) } catch (_) {}
            this.sync()
          })

          // The line moves with the arrow it points along: left widens the column.
          this.el.addEventListener("keydown", (event) => {
            const step = event.shiftKey ? 64 : 16
            const by = {ArrowLeft: step, ArrowRight: -step}[event.key]
            if (by === undefined) return
            event.preventDefault()
            set(drawn() + by)
            store()
          })

          this.observer = new ResizeObserver(() => this.sync())
          this.observer.observe(columns)
          this.sync()
        },

        destroyed() {
          this.observer?.disconnect()
          this.stop?.()
        }
      }
    </script>

    <%!-- The viewport the frame fills. Where the browser honours the viewport's
          `interactive-widget=resizes-content`, the layout viewport shrinks with the on-screen
          keyboard and `100dvh` is already right. Where it does not — Safari — the keyboard
          covers the bottom of a layout viewport that stays the same height, and what is left
          above it is the visual viewport: so the frame is sized to that, and moved to where it
          is, and the composer rises with the keyboard instead of going under it. --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ViewportFrame">
      export default {
        mounted() {
          const viewport = window.visualViewport
          if (!viewport) return

          this.fit = () => {
            const covered = window.innerHeight - viewport.height > 1

            this.el.style.height = covered ? `${viewport.height}px` : ""
            this.el.style.transform = covered ? `translateY(${viewport.offsetTop}px)` : ""
          }

          viewport.addEventListener("resize", this.fit)
          viewport.addEventListener("scroll", this.fit)
          this.fit()
        },

        destroyed() {
          window.visualViewport?.removeEventListener("resize", this.fit)
          window.visualViewport?.removeEventListener("scroll", this.fit)
        }
      }
    </script>

    <.device count={@frame.count} tidy />
    <.toasts flash={@flash} />
    """
  end

  defp title_event(top_level, _details) when top_level != nil, do: "frame:menu"
  defp title_event(nil, []), do: nil
  defp title_event(nil, _details), do: "frame:details"

  defp active_label(views, key) do
    Enum.find_value(views, fn view -> view.key == key && view.label end)
  end

  # The handle at a drop panel's foot: one of the three ways to fold it.
  defp handle(assigns) do
    ~H"""
    <button type="button" class="frame-handle" phx-click="frame:close" aria-label="Fold">
      <span aria-hidden="true" />
    </button>
    """
  end

  attr :frame, :map, required: true
  attr :capacity, :map, required: true
  attr :switch, :string, required: true
  attr :user, :map, required: true

  # The desktop header, 56px: the wordmark and the release, the title menu's switch, the queue
  # with its count, the usage digits and the account. Hidden below 768px, where the top bar is.
  defp desktop_header(assigns) do
    ~H"""
    <header id="desktop-header" class="frame-header">
      <div class="frame-brand">
        <.link navigate={~p"/"} class="frame-wordmark">forge</.link>
        <%!-- The release this node runs, to report and to see a deploy took. Read, never
              clicked, so it is outside the wordmark's link. --%>
        <span id="forge-version" class="frame-version">{version()}</span>
      </div>
      <%!-- Shown only while the connection is lost, in the header's own height. --%>
      <span class="frame-offline" role="status">
        <.offline_mark /> <span class="frame-offline-title">Not connected</span>
        <span class="frame-offline-line" data-connection-line></span>
      </span>
      <button
        type="button"
        class="frame-switch"
        phx-click="frame:menu"
        aria-expanded={to_string(@frame.open == :menu)}
      >
        {@switch}<span aria-hidden="true">{if @frame.open == :menu, do: "▴", else: "▾"}</span>
      </button>
      <.link navigate={~p"/"} class="frame-queue">
        Queue
        <.count_bubble value={@frame.count} tone={if @frame.count > 0, do: "accent", else: "neutral"} />
      </.link>
      <span class="frame-header-gap" />
      <.link
        :if={@capacity["five_hour"] || @capacity["seven_day"]}
        id="usage-digits"
        navigate={~p"/usage"}
        class="frame-digits"
      >
        <.digit window={@capacity["five_hour"]} /> 5h · <.digit window={@capacity["seven_day"]} /> wk
      </.link>
      <%!-- The address's local part: the whole of it in mono was the widest thing in the header.
            The full address is its title. --%>
      <.link navigate={~p"/users/settings"} class="frame-account" title={@user.email}>
        {@user.email |> String.split("@") |> hd()}
      </.link>
    </header>
    """
  end

  attr :window, :map, default: nil

  # A digit takes its line's colour: quiet, then warning from 80, danger from 95.
  defp digit(assigns) do
    assigns = assign(assigns, :percent, Capacity.percent(assigns.window))

    ~H"""
    <span class={@percent && "frame-digit--#{usage_tone(@percent)}"}>{Capacity.shown(@window)}</span>
    """
  end

  @doc """
  The frame of the sign-in screens — logging in, a link opened, an account waiting for approval
  (`docs/design/ui.md` § Signing in): the wordmark and the page, and no usage lines, no queue and
  no version, because nobody signed in yet is told anything about the node.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  slot :inner_block, required: true

  def sign_in(assigns) do
    ~H"""
    <main id="sign-in" class="sign-in">
      <div class="sign-in-body">
        <p class="sign-in-wordmark">forge</p>
        {render_slot(@inner_block)}
      </div>
    </main>
    <.device count={0} />
    <.toasts flash={@flash} />
    """
  end

  # The top bar's ground in each theme, the one place the page writes the two values: the meta's
  # data attributes, which the theme script picks from. They are `--bg` of `assets/css/tokens.css`,
  # as hex because a bar outside the page cannot read an `oklch()`; `installed_app_test.exs` checks
  # both against the top bar's computed colour. The manifest, a static file, holds the dark one
  # twice more (`background_color`, `theme_color`), and `device_controller_test.exs` holds those
  # equal to this.
  @bar_colors %{dark: "#0d0b0f", light: "#fafdff"}

  @doc "The `theme-color` of each theme, as the meta carries them (`ui.md` § The installed app)."
  @spec bar_colors() :: %{dark: String.t(), light: String.t()}
  def bar_colors, do: @bar_colors

  @doc """
  The theme, before first paint: the `theme-color` meta and the script that sets `data-theme` and
  keeps the meta in step with it. Rendered by the root layout and by the offline page, which is
  why it is a component and not written twice.
  """
  def theme_script(assigns) do
    assigns = assign(assigns, :colors, @bar_colors)

    ~H"""
    <meta
      name="theme-color"
      content={@colors.dark}
      data-dark={@colors.dark}
      data-light={@colors.light}
    />
    <script>
      (() => {
        const systemTheme = () => matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";

        // The browser's and the phone's bar take the top bar's ground in the theme being shown
        // (`docs/design/ui.md` § The installed app); the two values are the meta's own.
        const paintBar = () => {
          const meta = document.querySelector('meta[name="theme-color"]');
          if (meta) meta.setAttribute("content", meta.dataset[document.documentElement.getAttribute("data-theme")] || meta.dataset.dark);
        };

        const setTheme = (theme) => {
          if (theme === "system") {
            localStorage.removeItem("phx:theme");
            document.documentElement.setAttribute("data-theme", systemTheme());
            document.documentElement.setAttribute("data-theme-source", "system");
          } else {
            localStorage.setItem("phx:theme", theme);
            document.documentElement.setAttribute("data-theme", theme);
            document.documentElement.setAttribute("data-theme-source", "user");
          }
          paintBar();
        };
        if (!document.documentElement.hasAttribute("data-theme")) {
          setTheme(localStorage.getItem("phx:theme") || "system");
        }
        // The width a person dragged a ticket's or a chat's side column to, applied before first
        // paint so a reload does not jump (`Layouts`' `.AsideResize`). The stylesheet holds it to
        // its limits, so a value that no longer fits is harmless; one that is not a whole number
        // is ignored.
        try {
          const aside = localStorage.getItem("forge:aside-width");
          if (/^[1-9][0-9]{0,5}$/.test(aside)) {
            document.documentElement.style.setProperty("--frame-aside-width", aside + "px");
          }
        } catch (_) {}
        window.addEventListener("storage", (e) => e.key === "phx:theme" && setTheme(e.newValue || "system"));
        window.addEventListener("phx:set-theme", (e) => setTheme(e.target.dataset.phxTheme));

        matchMedia("(prefers-color-scheme: dark)").addEventListener("change", (e) => {
          if (document.documentElement.getAttribute("data-theme-source") === "system") {
            document.documentElement.setAttribute("data-theme", systemTheme());
            paintBar();
          }
        });
      })();
    </script>
    """
  end

  @doc """
  The frame's one element for the installed app: the icon's badge and the tidying of notifications
  (`.Device`, `docs/design/ui.md` § The installed app). `count` is the queue button's figure; the
  sign-in frame draws `0`, so signing out clears the badge, and asks for no tidying.
  """
  attr :count, :integer, required: true
  attr :tidy, :boolean, default: false

  def device(assigns) do
    ~H"""
    <span id="device" phx-hook=".Device" data-count={@count} data-tidy={@tidy && "true"} hidden></span>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Device">
      // One request to tidy per full load, and another whenever the page comes back into view or
      // the count changes: a live navigation mounts this again and asks for nothing. The worker
      // does the tidying (`sw.js`); this only asks.
      let asked = false
      let timer = null

      const setBadge = (value) => {
        const count = Number(value)
        // `count < 0` is an equivalent mutant: the server draws a count, which is never negative.
        if (!Number.isFinite(count) || count < 0) return
        try {
          const call = count > 0 ? navigator.setAppBadge?.(count) : navigator.clearAppBadge?.()
          Promise.resolve(call).catch(() => {})
        } catch (_) {}
      }

      const askToTidy = () => {
        if (!("serviceWorker" in navigator) || document.visibilityState !== "visible") return
        clearTimeout(timer)
        timer = setTimeout(() => {
          navigator.serviceWorker.ready
            .then((registration) => registration.active?.postMessage({type: "tidy"}))
            .catch(() => {})
        }, 300)
      }

      document.addEventListener("visibilitychange", () => {
        if (document.visibilityState === "visible" && document.getElementById("device")?.dataset.tidy) askToTidy()
      })

      export default {
        mounted() {
          setBadge(this.el.dataset.count)
          this.count = this.el.dataset.count
          if (this.el.dataset.tidy && !asked) {
            asked = true
            askToTidy()
          }
        },

        updated() {
          setBadge(this.el.dataset.count)
          if (this.el.dataset.tidy && this.el.dataset.count !== this.count) askToTidy()
          this.count = this.el.dataset.count
        }
      }
    </script>
    """
  end

  @doc "The release this node runs: the platform application's version, which is `VERSION`'s."
  @spec version() :: String.t()
  def version, do: Forge.Changelog.running()

  @doc """
  The toast (`docs/design/ui.md` § Toasts): the `:info` flash, drawn as one `feedback/Toast`
  above the strip, title and detail split on the first newline (`ForgeWeb.Toast`). **One at a
  time**: there is one `:info` flash, so the newest replaces the last.

  It clears itself after `--toast-life`: the `.Toast` hook fades it and pushes
  `lv:clear-flash`, so the flash goes on the server too and a reconnect does not draw it again.
  No failure is ever drawn here, nor anywhere in the frame: each is drawn where it was made
  (§ Errors stay where you acted).
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  def toasts(assigns) do
    message = Phoenix.Flash.get(assigns.flash, :info)
    {title, detail} = if message, do: ForgeWeb.Toast.split(message), else: {nil, nil}
    assigns = assign(assigns, message: message, title: title, detail: detail)

    ~H"""
    <div id="toasts" aria-live="polite">
      <div :if={@message} id="toast" phx-hook=".Toast" data-message={@message}>
        <.toast title={@title} detail={@detail} />
      </div>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Toast">
      // The toast's life is the token's (`--toast-life`), read here so there is one number. It
      // fades out over its last 200 ms, then the flash is cleared on the server. A toast whose
      // message changes while it shows is the newest one, and starts its life again.
      const seconds = (value) => {
        const n = parseFloat(value)
        if (!Number.isFinite(n)) return 4000
        return value.trim().endsWith("ms") ? n : n * 1000
      }

      export default {
        mounted() { this.arm() },

        updated() {
          if (this.el.dataset.message !== this.message) this.arm()
        },

        destroyed() { this.disarm() },

        arm() {
          this.disarm()
          this.message = this.el.dataset.message
          this.el.classList.remove("toast--leaving")
          const life = seconds(getComputedStyle(document.documentElement).getPropertyValue("--toast-life"))
          this.fade = setTimeout(() => this.el.classList.add("toast--leaving"), Math.max(life - 200, 0))
          this.timer = setTimeout(() => {
            try { this.pushEvent("lv:clear-flash", {key: "info"}) } catch (_) { this.el.hidden = true }
          }, life)
        },

        disarm() {
          clearTimeout(this.fade)
          clearTimeout(this.timer)
        }
      }
    </script>
    """
  end
end
