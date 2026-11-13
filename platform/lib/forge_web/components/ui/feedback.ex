defmodule ForgeWeb.UI.Feedback do
  @moduledoc """
  The feedback primitives (`docs/design/ui/design_system/components/feedback/`,
  `docs/design/ui.md` § Transient states, § Sheets): a notice that stays, a toast that passes, and
  the bottom sheet.

  Styles are in `assets/css/components.css` under the same names.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  An inline consequence or problem (`feedback/Notice`), inside the panel or page it concerns:
  open questions that will stay unanswered, a branch that does not merge cleanly. Not a toast; it
  stays. `accent` leads its title with an amber ◆ and is for what waits on you; `warning` is a
  consequence that waits on nobody — "1 open question will stay unanswered" — and leads its title
  with `△` in warning (`docs/design/ui.md` § Colour).
  """
  attr :tone, :string, default: "accent", values: ~w(accent warning danger neutral)
  attr :title, :string, default: nil
  attr :rest, :global
  slot :inner_block

  def notice(assigns) do
    ~H"""
    <div class={["ui-notice", @tone != "accent" && "ui-notice--#{@tone}"]} {@rest}>
      <div :if={@title} class="ui-notice-head">
        <span :if={@tone == "accent"} class="ui-notice-diamond" aria-hidden="true" />
        <span class="ui-notice-title">{@title}</span>
      </div>
      <div :if={@inner_block != []} class="ui-notice-body">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  @doc """
  A refusal, drawn where the person acted (`docs/design/ui.md` § Errors stay where you acted): in
  red, in the server's words, inside the panel or under the field or message it belongs to.
  **Never a toast and never timed**: it stays until the next action replaces it or the cause goes.
  **Every refusal drawn in place is this one**, so they all read alike: a test reads the web layer's
  source and fails on an alert drawn any other way. `class` places it — a margin, a grid span —
  and never recolours it.
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def error_note(assigns) do
    ~H"""
    <p id={@id} role="alert" class={["ui-error-note", @class]} {@rest}>{render_slot(@inner_block)}</p>
    """
  end

  @doc """
  A passing confirmation after an action (`feedback/Toast`): a dark pill floating above the strip,
  `bottom` pixels from the foot of the window. **No buttons and `pointer-events: none`** — it can
  never be tapped by a thumb that meant what was under it — and it is announced, not focused.
  Never an error that needs action, never in the decision row's place.
  """
  attr :id, :string, default: nil
  attr :title, :string, required: true
  attr :detail, :string, default: nil
  attr :bottom, :integer, default: 84
  attr :rest, :global

  def toast(assigns) do
    ~H"""
    <div
      id={@id}
      role="status"
      class="ui-toast pointer-events-none"
      style={"bottom: #{@bottom}px"}
      {@rest}
    >
      <span class="ui-toast-mark" aria-hidden="true">✓</span>
      <span class="ui-toast-text">
        <span class="ui-toast-title">{@title}</span>
        <span :if={@detail} class="ui-toast-detail">{@detail}</span>
      </span>
    </div>
    """
  end

  @doc "The command that opens the sheet `id`."
  @spec open_sheet(String.t()) :: JS.t()
  def open_sheet(id), do: JS.dispatch("forge:sheet-open", to: "#" <> id)

  @doc """
  The bottom sheet (`feedback/Sheet`), only for things opened from the bottom of the screen —
  `+ New`, *All items*, the workflow map; what drops from a bar is a `drop_panel/1`.

  A native `<dialog>`, full-screen and transparent, with the sheet at its foot over a scrim.
  **Opened with `showModal()` from a dispatched event** — `open_sheet/1` — and closed by Escape, a
  tap on the scrim, or navigating. Focus and inertness come from the element rather than from
  code: a modal dialog makes the rest of the page inert and traps focus by itself, and Escape is
  the browser's. What code does is the two things the element does not: close when the page
  navigates, and keep LiveView from closing it on every patch — the server never renders `open`,
  so without `JS.ignore_attributes/1` each update would take it away again.

  **It opens with the focus on the sheet itself**, not its first row: `showModal()` focuses the
  dialog's first focusable descendant otherwise, and a first row that opens wearing the focus
  ring reads as already chosen (UX pass, A22). Tab still reaches every row from there. **A sheet
  whose first act is typing names its field** (`focus`, a selector inside it): with a fine pointer
  the field takes the focus once the sheet is open, as the branch sheet's search did before A22;
  on touch it does not, since a keyboard sliding up over the list it filters is not what a tap
  on *Branch* asked for (UX re-check #10).
  """
  attr :id, :string, required: true
  attr :label, :string, required: true, doc: "what the sheet is, for assistive technology"
  attr :title, :string, default: nil

  attr :focus, :string,
    default: nil,
    doc: "a selector inside the sheet for the field that takes the focus with a fine pointer"

  slot :inner_block, required: true

  def sheet(assigns) do
    ~H"""
    <dialog
      id={@id}
      aria-label={@label}
      phx-hook=".Sheet"
      data-focus={@focus}
      phx-mounted={JS.ignore_attributes(["open"])}
      class="fixed inset-0 m-0 size-full max-h-none max-w-none flex-col justify-end border-0 bg-overlay p-0 text-ink open:flex backdrop:bg-transparent"
    >
      <div class="ui-sheet" tabindex="-1" autofocus>
        <div class="ui-sheet-handle" aria-hidden="true" />
        <span :if={@title} class="ui-sheet-title">{@title}</span>
        {render_slot(@inner_block)}
      </div>
      <%!-- The scrim is a form that closes the dialog, filling the dialog behind the sheet: the
            browser's own `method="dialog"` rather than a handler. --%>
      <form method="dialog" class="absolute inset-0">
        <button type="submit" aria-label="Close" class="size-full cursor-default opacity-0">
          close
        </button>
      </form>
    </dialog>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Sheet">
      export default {
        mounted() {
          this.open = () => {
            if (this.el.open) return
            this.el.showModal()
            const field = this.el.dataset.focus && this.el.querySelector(this.el.dataset.focus)
            if (field && window.matchMedia("(pointer: fine)").matches) field.focus()
          }

          this.close = () => { if (this.el.open) this.el.close() }

          this.el.addEventListener("forge:sheet-open", this.open)
          // Navigating closes it: a sheet is where you choose where to go, not where you stay.
          window.addEventListener("phx:page-loading-start", this.close)
          this.el.addEventListener("click", (event) => {
            if (event.target.closest("a[href]")) this.close()
          })
        },

        destroyed() {
          window.removeEventListener("phx:page-loading-start", this.close)
        }
      }
    </script>
    """
  end
end
