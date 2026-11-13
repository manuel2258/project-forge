defmodule ForgeWeb.Operator.Components do
  @moduledoc """
  The shapes a person decides with: answer rows, approvals and transitions. Questions are a form
  of their own, `ForgeWeb.Operator.QuestionForm`.

  The affordance rule governs all of them — a border means you can tap it. Identifiers are plain
  mono text with no box; the only bordered shapes here are the ones that commit something. A
  filled button commits what the operator prepared: the Send beside a free-text field, and the
  Send that closes a question form. See `docs/design/ui.md`.
  """
  use ForgeWeb, :html

  alias ForgeWeb.Operator.Drafts

  @doc """
  The field that picks a model, wherever one is picked.

  **A dropdown of what is connected.** The names are not written down anywhere in the product:
  each worker reports the aliases its harness resolves and the models its credential may use
  (`docs/design/worker-channel.md` § What a worker offers), and this shows the union. Because it
  is discovered on every worker join rather than authored here, a model released last week is in
  it as soon as a machine connects — which is what makes a closed list safe where a written-down
  one would not be.

  Aliases and ids are separate groups. `opus` floats to whatever the harness resolves it to,
  an id pins; showing them apart is what makes choosing between them deliberate rather than
  alphabetical.

  **Free text when there is nothing to offer**, which is a fleet with no worker connected. A
  select with one empty option would make configuring a project before starting a machine
  impossible, and that is the order a new operator does it in.

  A value already set that nothing currently offers stays in the list and stays selected. The
  worker that has it may be asleep rather than gone, and a form that silently dropped it would
  change a setting nobody touched.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :offered, :map, required: true, doc: "as `Forge.Workers.offered/1`"
  attr :label, :string, default: "Model"
  attr :fallback, :string, required: true, doc: "what an empty choice means, in words"

  def model_field(assigns) do
    assigns = assign(assigns, :options, options(assigns.offered, assigns.field.value))

    ~H"""
    <div>
      <.input :if={@options == []} field={@field} type="text" label={@label} autocomplete="off" />

      <.input
        :if={@options != []}
        field={@field}
        type="select"
        label={@label}
        options={[{"— #{@fallback} —", ""} | @options]}
      />

      <p class="mt-1.5 text-[12.5px] opacity-60">
        <%= if @options == [] do %>
          No credential in the pool lists a model and no machine is connected, so there is
          nothing to offer. Type a name, or leave it for {@fallback}.
        <% else %>
          The models the pool's credentials offer, and the aliases of the machines connected now.
        <% end %>
      </p>
    </div>
    """
  end

  @doc """
  The field that picks an effort, wherever one is picked.

  **The same shape as `model_field/1`, from the same source.** The harness driver declares the
  levels it takes and each worker reports them with its aliases
  (`docs/design/worker-channel.md` § What a worker offers); this shows the union across the
  workers connected now, in the order the harness gave them. None is written here, so the next
  harness's levels need no change to a form.

  **Free text when no connected worker offers a level.** That is decided by the levels reported
  and not by the option list, so a stored level does not turn the box into a select holding only
  itself: with nothing to choose between, a select is a box that cannot be typed in, and a project
  could not be configured before a machine exists.

  A value already set that nothing currently offers stays in the list, selected and marked "Set".
  The worker that has it may be asleep, or a later harness may have dropped it, and a form that
  silently dropped it would change a setting nobody touched.

  **An offer, not a gate.** The server stores a level that is not in the list
  (`docs/design/workflow-grammar-v1.md` § Effort), which is what lets a harness newer than its
  workers keep working. Empty means the next link in the chain, which is what `fallback` says in
  words.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :offered, :map, required: true, doc: "as `Forge.Workers.offered/1`"
  attr :label, :string, default: "Effort"
  attr :fallback, :string, required: true, doc: "what an empty choice means, in words"

  def effort_field(assigns) do
    levels = assigns.offered.efforts
    kept = group("Set", kept(levels, assigns.field.value))

    assigns =
      assigns
      |> assign(:free_text, levels == [])
      |> assign(:options, [{"— #{assigns.fallback} —", ""} | levels] ++ kept)

    ~H"""
    <div>
      <.input :if={@free_text} field={@field} type="text" label={@label} autocomplete="off" />

      <.input :if={!@free_text} field={@field} type="select" label={@label} options={@options} />

      <p class="mt-1.5 text-[12.5px] opacity-60">
        <%= if @free_text do %>
          How hard it thinks. No connected worker offers a level, so there is nothing to offer. Type one, or leave it for {@fallback}.
        <% else %>
          How hard it thinks. Offered by the workers connected now.
        <% end %>
      </p>
    </div>
    """
  end

  # Grouped for `options_for_select`, which renders a list of `{group, options}` as `<optgroup>`.
  # The set one is last and appears only when the fleet no longer offers it: it is not a group
  # anyone picks from, it is the reason the current value is still there to be seen.
  defp options(offered, value) do
    aliases = Enum.map(offered.aliases, &{&1, &1})
    models = Enum.map(offered.models, &{&1.name, &1.id})

    group("Aliases", aliases) ++
      group("Models", models) ++
      group("Set", kept(offered.aliases ++ Enum.map(offered.models, & &1.id), value))
  end

  defp group(_name, []), do: []
  defp group(name, options), do: [{name, options}]

  defp kept(offered, value) when is_binary(value) and value != "" do
    if value in offered, do: [], else: [{value, value}]
  end

  defp kept(_offered, _value), do: []

  @doc """
  A pane that scrolls inside itself instead of growing the page.

  Live output goes in one: a conversation's messages, a job's harness stream. `docs/design/ui.md`
  § Motion and structure sets what it must do — **it does not auto-scroll away from something you
  are reading.** Pinned to the bottom while you are at the bottom, still when you are not, and it
  says how much arrived beneath so the stillness is informative rather than a page that stopped
  working.

  The list inside carries `data-scroll-items`; its children are what gets counted.
  """
  attr :id, :string, required: true

  attr :height, :any,
    default: "60vh",
    doc: "max height; the pane scrolls past it. Nil fills what its flex parent leaves"

  attr :class, :string, default: nil
  slot :inner_block, required: true

  def scroll_pane(assigns) do
    ~H"""
    <div class={["relative", is_nil(@height) && "flex min-h-0 flex-1 flex-col"]}>
      <div
        id={@id}
        phx-hook=".StickToBottom"
        class={["overflow-y-auto overscroll-contain", is_nil(@height) && "min-h-0 flex-1", @class]}
        style={@height && "max-height: #{@height}"}
      >
        {render_slot(@inner_block)}
      </div>

      <%!-- Only while there is something below: a control that is always there is a control
            nobody reads. --%>
      <button
        id={@id <> "-below"}
        type="button"
        hidden
        class="absolute right-3 bottom-3 min-h-[46px] rounded-md border border-border bg-bg px-3 font-mono text-[12.5px] shadow-none hover:border-border-strong"
      ></button>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".StickToBottom">
      export default {
        slack: 24,

        atBottom() {
          return this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight <= this.slack
        },

        // How many items are past the bottom of what you can see. Measured rather than counted
        // from events, so it stays true after a reload, a resize, or a message that wrapped.
        below() {
          const list = this.el.querySelector("[data-scroll-items]")
          if (!list) return 0
          const fold = this.el.scrollTop + this.el.clientHeight
          return [...list.children].filter((item) => item.offsetTop + item.offsetHeight > fold).length
        },

        report() {
          const count = this.atBottom() ? 0 : this.below()
          this.badge.hidden = count === 0
          this.badge.textContent = count === 0 ? "" : `${count} below ↓`
        },

        toBottom() {
          this.el.scrollTop = this.el.scrollHeight
          this.report()
        },

        mounted() {
          this.badge = document.getElementById(this.el.id + "-below")
          this.el.addEventListener("scroll", () => this.report())
          this.badge.addEventListener("click", () => this.toBottom())
          this.toBottom()
        },

        // Whether you were at the bottom *before* the update is the only moment that can be
        // asked: afterwards the content is taller and the answer is always no.
        beforeUpdate() {
          this.pinned = this.atBottom()
        },

        updated() {
          if (this.pinned) this.toBottom()
          else this.report()
        }
      }
    </script>
    """
  end

  @doc """
  The id of the block an approval's panel draws the commit message in
  (`ForgeWeb.Operator.Decision`), from the one definition the panel itself draws it under: a test
  that looked for a second copy of this string would pass while the operator saw nothing.
  """
  @spec commit_message_id(map()) :: String.t()
  def commit_message_id(%{id: id}), do: "approving-#{id}-commit-message"

  @doc """
  Where a queued ticket stands in its project's merge queue, in the words a person reads: "2nd of
  5", "being merged now", "being integrated". `place` is one of `Forge.MergeQueue.places/1`.
  """
  @spec merge_queue_place(map()) :: String.t()
  def merge_queue_place(%{status: :merging}), do: "being merged now"
  def merge_queue_place(%{status: :integrating}), do: "being integrated"
  def merge_queue_place(%{index: index, total: total}), do: "#{ordinal(index)} of #{total}"

  @doc "What is happening to a queued ticket (`merge_queue_place/1`'s companion)."
  @spec merge_queue_doing(map()) :: String.t()
  def merge_queue_doing(%{status: :merging}), do: "being merged"
  def merge_queue_doing(%{status: :integrating}), do: "being integrated; it keeps its place"
  def merge_queue_doing(%{ahead: 0}), do: "next to be merged"
  def merge_queue_doing(%{ahead: ahead}), do: "waiting for #{ahead} ahead"

  defp ordinal(n) when rem(n, 100) in [11, 12, 13], do: "#{n}th"
  defp ordinal(n) when rem(n, 10) == 1, do: "#{n}st"
  defp ordinal(n) when rem(n, 10) == 2, do: "#{n}nd"
  defp ordinal(n) when rem(n, 10) == 3, do: "#{n}rd"
  defp ordinal(n), do: "#{n}th"

  @doc "What taking a ticket out of the merge queue does, said before it is done."
  @spec take_out_sentence() :: String.t()
  def take_out_sentence,
    do:
      "Take this ticket out of the merge queue? Its approval is withdrawn and it has to be " <>
        "approved again. An integration already running will finish, but will not merge."

  @doc """
  A ticket in the merge queue (`docs/design/ui.md` § Decide and Timeline): where it stands, what is
  happening to it, and *Take out of queue*, which is an unapproval. It stands where the approval
  card stood. The card goes only when the server says the ticket left the queue — pressing the
  button hides nothing — and the confirm says what an integration already running will do.
  """
  attr :ticket, :map, required: true
  attr :place, :map, required: true, doc: "the ticket's entry of `Forge.MergeQueue.places/1`"

  def merge_queue_card(assigns) do
    ~H"""
    <div id={"merge-queue-#{@ticket.id}"} class="flex flex-col gap-3">
      <p class="text-sm/[1.55]">
        <span class="font-medium">In the merge queue</span>
        · <span id="merge-queue-place">{merge_queue_place(@place)}</span>
      </p>
      <p id="merge-queue-doing" class="text-sm/[1.55] opacity-70">
        {String.capitalize(merge_queue_doing(@place))}.
      </p>
      <.confirm
        id={"take-out-#{@ticket.id}"}
        label="Take out of queue"
        act="Take it out"
        sentence={take_out_sentence()}
        size="md"
        fill
        phx-click="take-out"
        phx-disable-with="Taking out…"
        phx-value-ticket={@ticket.id}
      />
    </div>
    """
  end

  @doc """
  One document a human state declares, written by the person while the ticket rests there
  (`docs/design/ui.md` § Decide and Timeline): the latest version to start from, and a filled
  *Save* that records what was typed as a new version. Not a decision, so no accent.
  """
  attr :ticket, :map, required: true
  attr :name, :string, required: true
  attr :latest, :map, default: nil
  attr :drafts, :map, required: true, doc: "the page's `:drafts` assign"

  # `phx-debounce` here is an equivalent mutant: it decides how often the client pushes while
  # somebody is typing, and no ExUnit test can press a key. It matches `message_box/1`, which
  # every other box in the operator's surfaces is drawn with.
  def document_editor(assigns) do
    assigns = assign(assigns, :draft, "write-#{assigns.name}")

    ~H"""
    <%!-- The `id` is written out rather than drawn from `@draft`, which holds the same string:
          `main` writes it this way, and a form whose `id` line differs from `main`'s conflicts
          with any change `main` makes beside it — which is how this one line came to be
          resolved by hand on four separate turns. --%>
    <form
      phx-submit="write_document"
      phx-change="draft:change"
      id={"write-#{@name}"}
      class="flex flex-col gap-2"
    >
      <input type="hidden" name="draft" value={@draft} />
      <input type="hidden" name="ticket" value={@ticket.id} />
      <input type="hidden" name="name" value={@name} />
      <%!-- The version this box was drawn from, read back out of the draft once anything is
            typed: the draft holds every field of the form, so this stays the version the text
            was written against even after a later one arrives and the page reloads. The save is
            refused when it is no longer the latest (`ForgeWeb.Operator.Actions`). --%>
      <input
        type="hidden"
        name="base"
        value={Drafts.field(@drafts, @draft, "base", version_of(@latest))}
      />
      <label for={"write-#{@name}-content"} class="font-mono text-[12.5px]">
        {@name}
        <span :if={@latest} class="opacity-60">v{@latest.version}</span>
        <span :if={!@latest} class="opacity-60">not written yet</span>
      </label>
      <textarea
        id={"write-#{@name}-content"}
        name="content"
        rows="6"
        required
        phx-debounce="200"
        class="w-full rounded-md border border-border bg-transparent px-3 py-2 text-sm placeholder:opacity-40 focus:outline-none focus:border-border-strong"
      >{Drafts.field(@drafts, @draft, "content", @latest && @latest.content)}</textarea>
      <button
        type="submit"
        phx-disable-with="Saving…"
        class="h-12 self-end rounded-md bg-ink px-4 text-sm font-medium text-bg"
      >
        Save {@name}
      </button>
    </form>
    """
  end

  @doc """
  A secret shown the one time it can be: only its hash is kept, so nothing can draw it again. A
  freshly issued git token on project settings, and a freshly minted machine's environment on the
  machines page (`docs/design/ui.md` § Tokens, § Machines) — **one block, so the two cannot come
  to say different things** about what happens once it is dismissed: the same notice, the
  values to copy, and one button that drops it from the screen.
  """
  attr :id, :string, required: true
  attr :done, :string, required: true, doc: "the event the button sends"
  slot :note, doc: "what it is good for, after the notice's first sentence"
  slot :inner_block, required: true, doc: "the values to copy"

  def shown_once(assigns) do
    ~H"""
    <section id={@id} class="shown-once">
      <.notice tone="warning" title="Copy it now. It is not shown again.">
        Only its hash is kept. {render_slot(@note)}
      </.notice>
      <div class="shown-once-copies">{render_slot(@inner_block)}</div>
      <p class="shown-once-note">
        Leaving this page drops it from the screen. If you lose it, make another.
      </p>
      <.button type="button" variant="primary" size="xl" fill phx-click={@done}>
        I have copied it
      </.button>
    </section>
    """
  end

  @doc """
  A value worth copying, with a button that copies it.

  Used wherever the product hands the operator something to paste elsewhere: a clone URL, the
  one-time URL carrying a freshly issued token, and a freshly minted machine's environment. The
  value stays visible and selectable — the button is a convenience over it, never the only way to
  get at it, because the clipboard API needs a secure context and a LAN address over plain http is
  not one.

  `multiline` keeps the value's line breaks on screen, for a value that is a file: what is copied
  is its text either way.
  """
  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, default: nil
  attr :multiline, :boolean, default: false

  def copyable(assigns) do
    ~H"""
    <div>
      <p :if={@label} class="font-mono text-[11px] tracking-[.14em] uppercase opacity-50">
        {@label}
      </p>
      <div class={["flex items-stretch gap-2", @label && "mt-2"]}>
        <div class="min-w-0 flex-1 rounded-card bg-surface-2 px-4 py-3">
          <%!-- A `pre`, because the formatter leaves its content alone: a value laid out on lines
                of its own would be drawn with the template's indentation in front of it. --%>
          <pre :if={@multiline} id={@id} class="font-mono text-[12.5px] whitespace-pre-wrap break-all">{@value}</pre>
          <p :if={not @multiline} id={@id} class="font-mono text-[12.5px] [overflow-wrap:break-word]">
            {breakable(@value)}
          </p>
        </div>
        <button
          type="button"
          id={@id <> "-copy"}
          phx-hook=".CopyToClipboard"
          data-target={@id}
          class="min-h-[46px] shrink-0 rounded-md border border-border-control px-3 text-sm hover:bg-surface-2"
        >
          <span data-label>Copy</span>
        </button>
      </div>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyToClipboard">
      export default {
        mounted() {
          this.el.addEventListener("click", async () => {
            const source = document.getElementById(this.el.dataset.target)
            if (!source) return

            const label = this.el.querySelector("[data-label]")
            const text = source.textContent.trim()

            try {
              // The clipboard API needs a secure context — https, or localhost. Over plain http
              // on a LAN address it is simply absent, so the fallback selects the text and says
              // so rather than failing silently.
              await navigator.clipboard.writeText(text)
              label.textContent = "Copied"
            } catch {
              const range = document.createRange()
              range.selectNodeContents(source)
              const selection = window.getSelection()
              selection.removeAllRanges()
              selection.addRange(range)
              label.textContent = "Selected"
            }

            clearTimeout(this.reset)
            this.reset = setTimeout(() => { label.textContent = "Copy" }, 2000)
          })
        },

        destroyed() { clearTimeout(this.reset) }
      }
    </script>
    """
  end

  @doc """
  A one-line value that may break only after a `/` or a `:` — a URL, a path, a ref — and so is
  never cut inside `.git`, a word or after the hyphen of a project's name (UX pass, C3, D10; UX
  re-check #8). Escaped part by part, each part an `.ui-unbroken` inline block — the browser breaks
  a hyphen otherwise, and `white-space: nowrap` would let a part longer than the line (a token)
  run off the screen, where an inline block wraps inside itself only then — joined with `<wbr>`.
  Neither adds text: what is copied is the value. A value with spaces in it — a header line, a
  command — breaks at its spaces as text does, and is left as it is.
  """
  @spec breakable(String.t()) :: Phoenix.HTML.safe() | String.t()
  def breakable(value) do
    if String.match?(value, ~r/\s/), do: value, else: break_after_separators(value)
  end

  defp break_after_separators(value) do
    value
    |> String.split(~r{(?<=[/:])})
    |> Enum.map_join(
      "<wbr>",
      &~s(<span class="ui-unbroken">#{&1 |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()}</span>)
    )
    |> Phoenix.HTML.raw()
  end

  # The version a document editor was drawn from, as its hidden field carries it: `"0"` when
  # there is none, so a first write and a write over somebody else's first write are told apart.
  defp version_of(nil), do: "0"
  defp version_of(%{version: version}), do: to_string(version)
end
