defmodule ForgeWeb.Sheet do
  @moduledoc """
  A bottom sheet: a native `<dialog>` drawn with daisyUI's `modal modal-bottom`
  (`docs/design/ui.md` § The phone).

  **Opened with `showModal()` from a dispatched event** — `open/1` — and closed by Escape, a tap
  on the backdrop, or navigating. Focus and inertness come from the element rather than from code:
  a modal dialog makes the rest of the page inert and traps focus by itself, and Escape is the
  browser's. What code does is the two things the element does not: close when the page
  navigates, and keep LiveView from closing it on every patch — the server never renders `open`,
  so without `JS.ignore_attributes/1` each update would take it away again.

  Two things use it: the phone's More sheet, and a work screen's details sheet, which at `lg` is
  not a sheet at all but the rail beside the body (`rail`).
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc "The command that opens the sheet `id`."
  @spec open(String.t()) :: JS.t()
  def open(id), do: JS.dispatch("forge:sheet-open", to: "#" <> id)

  attr :id, :string, required: true
  attr :label, :string, required: true, doc: "what the sheet is, for assistive technology"

  attr :rail, :boolean,
    default: false,
    doc: "drawn in place as a 21rem rail at `lg` and up, and a sheet only below it"

  slot :inner_block, required: true

  def sheet(assigns) do
    ~H"""
    <dialog
      id={@id}
      aria-label={@label}
      phx-hook=".Sheet"
      phx-mounted={JS.ignore_attributes(["open"])}
      data-rail={@rail && "lg"}
      class={[
        "modal modal-bottom",
        @rail && "lg:contents lg:visible lg:pointer-events-auto"
      ]}
    >
      <div class={[
        "modal-box max-h-[85dvh] shadow-none border border-b-0 border-base-300 px-5 pt-3",
        "pb-[calc(1rem+env(safe-area-inset-bottom))]",
        @rail &&
          "lg:block lg:max-h-none lg:w-[21rem] lg:max-w-none lg:shrink-0 lg:translate-none lg:scale-100 lg:opacity-100 lg:overflow-y-auto lg:rounded-none lg:border-0 lg:border-l lg:bg-transparent lg:p-0 lg:pl-8"
      ]}>
        <div
          class={["mx-auto mb-2 h-1 w-10 rounded-full bg-base-300", @rail && "lg:hidden"]}
          aria-hidden="true"
        />
        {render_slot(@inner_block)}
      </div>
      <%!-- The backdrop is a form that closes the dialog: daisyUI's pattern, and the browser's
            own `method="dialog"` rather than a handler. --%>
      <form method="dialog" class={["modal-backdrop", @rail && "lg:hidden"]}>
        <button type="submit" aria-label="Close">close</button>
      </form>
    </dialog>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Sheet">
      export default {
        mounted() {
          // A rail at `lg` is not a sheet there, so asking it to open is not asking anything.
          this.wide = this.el.dataset.rail ? window.matchMedia("(min-width: 64rem)") : null

          this.open = () => {
            if (this.wide?.matches || this.el.open) return
            this.el.showModal()
          }

          this.close = () => { if (this.el.open) this.el.close() }

          this.el.addEventListener("forge:sheet-open", this.open)
          // Widening past `lg` turns the sheet back into the rail; a modal left open would sit
          // over the page it is now part of.
          this.wide?.addEventListener("change", this.close)
          // Navigating closes it: a sheet is where you choose where to go, not where you stay.
          window.addEventListener("phx:page-loading-start", this.close)
          this.el.addEventListener("click", (event) => {
            if (event.target.closest("a[href]")) this.close()
          })
        },

        destroyed() {
          this.wide?.removeEventListener("change", this.close)
          window.removeEventListener("phx:page-loading-start", this.close)
        }
      }
    </script>
    """
  end
end
