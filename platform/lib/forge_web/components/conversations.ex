defmodule ForgeWeb.Conversations do
  @moduledoc """
  How a conversation is drawn in a list.

  Two surfaces show one — `/chats` and a project's page — so there is one of this rather than
  two. What differs between them is which conversations, not what a row looks like.
  """

  use Phoenix.Component
  use ForgeWeb, :verified_routes

  import ForgeWeb.Indicators

  alias ForgeWeb.Format

  @doc """
  The box you say things in, wherever a message is typed (`docs/design/ui.md` § Talk).

  **Enter sends where the primary pointer is fine; on a coarse one it is a new line**, and only
  Send sends. A phone keyboard has no shift-enter, so a composer that sent on Enter there could
  not take a second line — and a message typed on a phone is shaped by its line breaks. The
  query is on the element (`data-newline-on`) rather than inside the hook, so it can be read in
  the markup. The hint names the gesture and is drawn only for a fine pointer, which is the only
  one it is true for — by `pointer-coarse:hidden`, the same query written as CSS, since a media
  query cannot be read from an attribute. The two say `(pointer: coarse)` and must keep saying
  the same thing.

  It grows from `rows` lines to six and then scrolls inside itself. With `send`, a 46px Send
  square sits beside it, labelled for assistive technology.

  **With `enter: :newline` Enter is a new line at every pointer, and there is no hint**: the box
  is one field of a form that holds more — a question's own words, an approval's comment — and
  only that form's button sends (`docs/design/ui.md` § The affordance rule). The query becomes
  `all`, which every pointer matches, so it is the same hook reading the same attribute.
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, default: ""
  attr :rows, :string, default: "1"
  attr :placeholder, :string, default: "Say something"
  attr :label, :string, default: nil
  attr :send, :boolean, default: false, doc: "draw the Send square beside the box"
  attr :enter, :atom, values: [:send, :newline], default: :send
  attr :rest, :global, doc: "for the box itself — an `aria-label` where there is no `label`"

  def message_box(assigns) do
    ~H"""
    <div>
      <label :if={@label} for={@id} class="text-sm font-medium">{@label}</label>
      <div class={["flex items-end gap-2", @label && "mt-2"]}>
        <textarea
          id={@id}
          name={@name}
          rows={@rows}
          phx-hook=".Composer"
          phx-debounce="200"
          data-newline-on={if @enter == :newline, do: "all", else: "(pointer: coarse)"}
          data-max-lines="6"
          placeholder={@placeholder}
          class="min-h-[46px] w-full min-w-0 resize-none rounded-box border border-base-300 bg-base-100 px-3 py-[11px] text-sm/[1.6]"
          {@rest}
        >{@value}</textarea>
        <button
          :if={@send}
          type="submit"
          aria-label="Send"
          class="flex size-[46px] shrink-0 items-center justify-center rounded-field bg-base-content text-base-100"
        >
          <span aria-hidden="true" class="text-lg leading-none">↑</span>
        </button>
      </div>
      <p
        :if={@enter == :send}
        class="mt-1 font-mono text-[11px] opacity-40 pointer-coarse:hidden"
        data-hint
      >
        Enter sends · shift-enter for a new line
      </p>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Composer">
      export default {
        mounted() {
          this.coarse = window.matchMedia(this.el.dataset.newlineOn)

          this.el.addEventListener("keydown", (event) => {
            if (event.key !== "Enter" || event.shiftKey) return

            // An input method editor uses Enter to commit the character being composed. Sending
            // then would send half a word, so composition always wins.
            if (event.isComposing || event.keyCode === 229) return

            // A phone, or a box that is one field of a larger form (`all`): Enter is how a line
            // is ended, and Send is how a message is sent. No ExUnit test can press a key, so
            // deleting this line fails nothing there; what the tests pin is the query it reads,
            // `data-newline-on`.
            if (this.coarse.matches) return

            event.preventDefault()
            this.el.form?.requestSubmit()
          })

          this.el.addEventListener("input", () => this.fit())
          this.fit()
        },

        updated() { this.fit() },

        // From one line to six, then it scrolls inside itself.
        fit() {
          const style = getComputedStyle(this.el)
          const edges = parseFloat(style.paddingTop) + parseFloat(style.paddingBottom) +
            parseFloat(style.borderTopWidth) + parseFloat(style.borderBottomWidth)
          const most = parseFloat(style.lineHeight) * Number(this.el.dataset.maxLines) + edges

          this.el.style.height = "auto"
          const wanted = this.el.scrollHeight + parseFloat(style.borderTopWidth) +
            parseFloat(style.borderBottomWidth)
          this.el.style.height = `${Math.min(wanted, most)}px`
          this.el.style.overflowY = wanted > most ? "auto" : "hidden"
        }
      }
    </script>
    """
  end

  @ending_rule "its branch is deleted unless it would not merge cleanly"

  @doc """
  What ending a conversation does to its branch, as a clause for a sentence to carry.

  One definition, because ending deletes the branch (`conversations.md` § Lifetime) and every
  surface that offers ending says so: the confirm on the list and the page, and the page's own
  line beside *End it*. Two wordings of the rule would be one of them understating it.
  """
  @spec ending_rule() :: String.t()
  def ending_rule, do: @ending_rule

  @doc "What ending a conversation asks before it happens, from every surface that offers it."
  @spec ending_confirm() :: String.t()
  def ending_confirm,
    do:
      "End this conversation? The last turn finishes, the machine is released, and " <>
        @ending_rule <> " — merge first what you want to keep."

  attr :summaries, :list, required: true
  attr :now, :any, required: true
  attr :project, :boolean, default: true, doc: "name the project; false on a project's own page"
  attr :empty, :string, default: "No conversations yet."

  attr :ending, :string,
    default: nil,
    doc: "event to send to end a live conversation from the row; no control without it"

  def list(assigns) do
    ~H"""
    <p :if={@summaries == []} class="mt-3 text-sm opacity-60">{@empty}</p>

    <ol :if={@summaries != []} class="mt-3 flex flex-col">
      <li :for={summary <- @summaries} class="flex items-start gap-4 border-t border-base-300">
        <%!-- The row goes to one place, and the control that ends the conversation is beside it
              rather than inside it: `ui.md` § The affordance rule — a navigation target never
              encloses something that commits, or reading and ending become one gesture. --%>
        <.link
          navigate={~p"/chats/#{summary.chat.id}"}
          class="flex min-w-0 flex-1 flex-col gap-[6px] py-[15px] hover:opacity-100"
        >
          <div class="flex items-start justify-between gap-4">
            <div class="flex flex-wrap items-center gap-2 font-mono text-[11px] tracking-[.14em] uppercase opacity-70">
              <span :if={@project}>{summary.project.name}</span>
              <span :if={@project and summary.ticket} aria-hidden="true">·</span>
              <span :if={summary.ticket}>#{summary.ticket.number}</span>
              <span :if={summary.waiting} class="text-accent">· waiting on you</span>
              <.job_status :if={not summary.live} status={summary.chat.status} />
            </div>
            <span class="shrink-0 font-mono text-[12.5px] opacity-50">
              {Format.ago(summary.chat.inserted_at, @now)}
            </span>
          </div>

          <%!-- The last thing said, which is what tells one conversation from another — a chat
                has no title, and the first message is often not what it became about. --%>
          <p class="text-sm/[1.5] opacity-80">
            <span class="opacity-50">{speaker(summary.said)}</span>
            {said(summary.said)}
          </p>

          <div class="font-mono text-[11px] opacity-50">
            {summary.chat.turns} {noun(summary.chat.turns, "turn")} · {Format.windows(
              summary.chat.cost_usd
            ) || "—"}
          </div>
        </.link>

        <%!-- Only a live one, and worded as the conversation's own page words it: a
              conversation cannot be deleted at all (`conversations.md` § Lifetime), so the
              affordance a list can offer is the one that stops it costing something — which
              also deletes its branch, and the confirm says so. --%>
        <button
          :if={@ending && summary.live}
          type="button"
          phx-click={@ending}
          phx-value-id={summary.chat.id}
          data-confirm={ending_confirm()}
          class="mt-[15px] min-h-[46px] shrink-0 text-sm text-primary hover:underline"
        >
          End
        </button>
      </li>
    </ol>
    """
  end

  defp speaker({:user, _text}), do: "you:"
  defp speaker({:agent, _text}), do: "agent:"
  defp speaker(nil), do: ""

  defp said(nil), do: "Nothing said yet."

  defp said({_role, text}) do
    text
    |> String.split("\n", trim: true)
    |> List.first()
    |> Kernel.||("")
    |> String.slice(0, 140)
  end

  defp noun(1, word), do: word
  defp noun(_count, word), do: word <> "s"
end
