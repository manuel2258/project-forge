defmodule ForgeWeb.Operator.Components do
  @moduledoc """
  The shapes a person decides with: answer rows, questions, approvals and transitions.

  The affordance rule governs all of them — a border means you can tap it. Identifiers are plain
  mono text with no box; the only bordered shapes here are the ones that commit something. A
  filled button appears in exactly one place, beside a free-text field, because that is the only
  case where the operator has typed something to send. See `docs/design/ui.md`.
  """
  use ForgeWeb, :html

  import ForgeWeb.Indicators

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
          No worker is connected, so there is nothing to offer. Type a name, or leave it for {@fallback}.
        <% else %>
          Offered by the workers connected now.
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

    group("Aliases", aliases) ++ group("Models", models) ++ group("Set", kept(offered, value))
  end

  defp group(_name, []), do: []
  defp group(name, options), do: [{name, options}]

  defp kept(offered, value) when is_binary(value) and value != "" do
    if value in offered.aliases or Enum.any?(offered.models, &(&1.id == value)),
      do: [],
      else: [{value, value}]
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
  attr :height, :string, default: "60vh", doc: "max height; the pane scrolls past it"
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def scroll_pane(assigns) do
    ~H"""
    <div class="relative">
      <div
        id={@id}
        phx-hook=".StickToBottom"
        class={["overflow-y-auto overscroll-contain", @class]}
        style={"max-height: #{@height}"}
      >
        {render_slot(@inner_block)}
      </div>

      <%!-- Only while there is something below: a control that is always there is a control
            nobody reads. --%>
      <button
        id={@id <> "-below"}
        type="button"
        hidden
        class="absolute right-3 bottom-3 min-h-[46px] rounded-field border border-base-300 bg-base-100 px-3 font-mono text-[12.5px] shadow-none hover:border-base-content/30"
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
  The one shape in the queue that commits something: 52px, label left, `›` right, sends on tap.
  """
  attr :rest, :global,
    include:
      ~w(phx-click phx-value-ticket phx-value-key phx-value-choice
                                   phx-value-to phx-value-version phx-disable-with type name value form)

  attr :class, :string, default: nil
  slot :inner_block, required: true

  def answer_row(assigns) do
    ~H"""
    <button
      type="button"
      class={[
        "flex h-[52px] w-full items-center justify-between gap-3 rounded-field",
        "border border-base-300 bg-base-200 px-4 text-left",
        "hover:border-base-content/30",
        @class
      ]}
      {@rest}
    >
      <span class="text-sm font-medium">{render_slot(@inner_block)}</span>
      <span aria-hidden="true" class="opacity-40">›</span>
    </button>
    """
  end

  @doc """
  One question: its anchor, its options as stacked rows, and free text as a peer of the options.

  Free text is always a valid answer and is labelled as always open — never an escape hatch
  behind a link.
  """
  attr :question, :map, required: true
  attr :ticket_id, :string, required: true

  def question_card(assigns) do
    ~H"""
    <div class="flex flex-col gap-[11px]" id={"question-#{@question.id}"}>
      <blockquote
        :if={@question.anchor}
        class="border-l-2 border-accent bg-accent/10 py-1 pl-3 text-sm/[1.55] opacity-80"
      >
        {@question.anchor}
      </blockquote>

      <p class="text-sm/[1.55]">{@question.text}</p>

      <div class="flex flex-col gap-2">
        <.answer_row
          :for={option <- @question.options}
          phx-click="answer"
          phx-disable-with="Sending…"
          phx-value-ticket={@ticket_id}
          phx-value-key={@question.key}
          phx-value-choice={option}
          class="h-12"
        >
          {option}
          <span
            :if={option == @question.default}
            class="ml-2 font-mono text-[11px] tracking-[.14em] uppercase opacity-50"
          >
            recommended
          </span>
        </.answer_row>
      </div>

      <form phx-submit="answer_text" class="flex gap-2">
        <input type="hidden" name="ticket" value={@ticket_id} />
        <input type="hidden" name="key" value={@question.key} />
        <input
          type="text"
          name="text"
          placeholder="or answer in your own words"
          class="h-12 w-full rounded-field border border-base-300 bg-transparent px-3 text-sm placeholder:opacity-40 focus:outline-none focus:border-base-content/40"
          required
        />
        <button
          type="submit"
          phx-disable-with="…"
          class="h-12 shrink-0 rounded-field bg-base-content px-4 text-sm font-medium text-base-100"
        >
          Send
        </button>
      </form>
    </div>
    """
  end

  @doc """
  An approval. The version is inside the button label, because approval attaches to an exact
  version and never to whatever is latest.
  """
  attr :ticket, :map, required: true
  attr :pending, :map, required: true
  attr :approve, :list, default: [], doc: "`{name, version}` pairs the approval pins"

  def approval_card(assigns) do
    ~H"""
    <div class="flex flex-col gap-[11px]" id={"approval-#{@ticket.id}"}>
      <p class="text-sm/[1.55] opacity-70">
        Approving pins
        <%= for {{name, version}, i} <- Enum.with_index(@approve) do %>
          <span :if={i > 0}>, </span><span class="font-mono text-[12.5px]">{name} v{version}</span>
        <% end %>
        at <span class="font-mono text-[12.5px]">{@pending["to"]}</span>. A later edit does not
        inherit this approval.
      </p>

      <form phx-submit="decide" class="flex flex-col gap-2">
        <input type="hidden" name="ticket" value={@ticket.id} />
        <input
          type="text"
          name="comment"
          placeholder="comment (optional)"
          class="h-12 w-full rounded-field border border-base-300 bg-transparent px-3 text-sm placeholder:opacity-40 focus:outline-none focus:border-base-content/40"
        />
        <button
          type="submit"
          name="decision"
          value="approved"
          phx-disable-with="Sending…"
          class="flex h-[52px] w-full items-center justify-between gap-3 rounded-field border border-base-300 bg-base-200 px-4 text-left hover:border-base-content/30"
        >
          <span class="text-sm font-medium">{approve_label(@approve)}</span>
          <span aria-hidden="true" class="opacity-40">›</span>
        </button>
        <button
          type="submit"
          name="decision"
          value="rejected"
          phx-disable-with="Sending…"
          class="flex h-12 w-full items-center px-4 text-left text-sm opacity-60 hover:opacity-100"
        >
          Reject
        </button>
      </form>
    </div>
    """
  end

  defp approve_label([]), do: "Approve"
  defp approve_label([{name, version}]), do: "Approve #{name} v#{version}"
  defp approve_label(pairs), do: "Approve #{length(pairs)} versions"

  @doc """
  Open ticket proposals, each with the two things a person can do about it.

  Not a queue item, and that is the decision rather than an omission: the queue is for what will
  not move until someone acts, and a proposal blocks nothing — no job waits on it and no ticket
  is stuck behind it (`docs/design/ticket-proposals.md` § Where it surfaces). Eighteen jobs
  proposing two each is how the queue's promise that you can reach the end of it stops being
  true, and it would be spent on the one class of item that could have waited.

  `Accept` carries the verb and the `›`, like every affordance that commits; `Decline` is the
  quiet one beside it, as `Reject` is on an approval.
  """
  attr :proposals, :list, required: true

  def proposals(assigns) do
    ~H"""
    <div :for={p <- @proposals} class="border-b border-base-300/60 py-[18px]">
      <div class="flex items-baseline gap-2">
        <h3 class="text-sm font-medium">{p.title || "Could not be read"}</h3>
        <span class="font-mono text-[11px] opacity-50">{p.file}</span>
      </div>

      <p class="mt-1 text-[12.5px]/[1.5] opacity-70 whitespace-pre-line">{p.body}</p>

      <p class="mt-1 font-mono text-[11px] opacity-50">
        proposed by
        <.link
          :if={p.ticket_number}
          navigate={~p"/tickets/#{p.project}/#{p.ticket_number}"}
          class="hover:underline"
        >
          ticket {p.ticket_number}
        </.link>
        <span :if={is_nil(p.ticket_number)}>a conversation</span>
      </p>

      <form phx-submit="decide_proposal" class="mt-3 flex flex-col gap-2">
        <input type="hidden" name="version_id" value={p.version_id} />
        <input
          type="text"
          name="comment"
          placeholder="comment (optional)"
          class="h-12 w-full rounded-field border border-base-300 bg-transparent px-3 text-sm placeholder:opacity-40 focus:outline-none focus:border-base-content/40"
        />
        <button
          :if={p.readable}
          type="submit"
          name="decision"
          value="accepted"
          phx-disable-with="Admitting…"
          class="flex h-[52px] w-full items-center justify-between gap-3 rounded-field border border-base-300 bg-base-200 px-4 text-left hover:border-base-content/30"
        >
          <span class="text-sm font-medium">Accept as a ticket</span>
          <span aria-hidden="true" class="opacity-40">›</span>
        </button>
        <p :if={not p.readable} class="text-[12.5px] opacity-60">
          This cannot be read as a proposal, so it cannot be admitted. Decline it.
        </p>
        <button
          type="submit"
          name="decision"
          value="declined"
          phx-disable-with="Sending…"
          class="flex h-12 w-full items-center px-4 text-left text-sm opacity-60 hover:opacity-100"
        >
          Decline
        </button>
      </form>
    </div>
    """
  end

  @doc """
  The transitions a person may take. Each carries a verb: `Move to planning ›`, never `→ planning`.
  """
  attr :ticket, :map, required: true
  attr :transitions, :list, required: true

  def transition_card(assigns) do
    ~H"""
    <div class="flex flex-col gap-2" id={"transitions-#{@ticket.id}"}>
      <.answer_row
        :for={to <- @transitions}
        phx-click="transition"
        phx-disable-with="Sending…"
        phx-value-ticket={@ticket.id}
        phx-value-to={to}
      >
        Move to {to}
      </.answer_row>
    </div>
    """
  end

  @doc "The mono footer of identifiers under a queue item."
  attr :project, :string, required: true
  attr :ticket, :map, required: true
  attr :topology, :atom, default: :unknown
  attr :artifact, :string, default: nil
  attr :version, :integer, default: nil

  def identifiers(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-x-2 gap-y-1 font-mono text-[12.5px] opacity-60">
      <.link navigate={~p"/tickets/#{@project}/#{@ticket.number}"} class="hover:opacity-100">
        {@project}#{@ticket.number}
      </.link>
      <span aria-hidden="true">·</span>
      <.state name={@ticket.state} topology={@topology} />
      <span :if={@artifact} aria-hidden="true">·</span>
      <%!-- Every artifact name in the product links to its exact version; see
            docs/design/ui.md § Addressable artifact versions. --%>
      <.link
        :if={@artifact}
        href={~p"/tickets/#{@project}/#{@ticket.number}/artifacts/#{@artifact}/#{@version}"}
        class="hover:opacity-100"
      >
        {@artifact} v{@version}
      </.link>
    </div>
    """
  end

  @doc "A ticket as an identifier plus its title, for the board and lists."
  attr :ticket, :map, required: true
  attr :project, :string, required: true

  def ticket_link(assigns) do
    ~H"""
    <.link
      navigate={~p"/tickets/#{@project}/#{@ticket.number}"}
      class="flex min-h-[46px] flex-col justify-center gap-0.5"
    >
      <span class="font-mono text-[11px] opacity-60">{@project}#{@ticket.number}</span>
      <span class="text-[13px] leading-snug">{@ticket.title}</span>
    </.link>
    """
  end

  @doc """
  One `label / value` row of a facts rail. Nine of these were written out by hand across the
  ticket, job, review and project pages before it existed.
  """
  attr :label, :string, required: true
  attr :value, :string, default: nil, doc: "the value, when it is plain text"
  slot :inner_block, doc: "the value, when it is markup"

  def fact(assigns) do
    ~H"""
    <div class="flex min-w-0 justify-between gap-3">
      <dt class="opacity-50">{@label}</dt>
      <dd class="truncate font-mono">{@value}{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  @doc """
  A value worth copying, with a button that copies it.

  Used wherever the product hands the operator something to paste elsewhere: a clone URL, and the
  one-time URL carrying a freshly issued token. The value stays visible and selectable — the
  button is a convenience over it, never the only way to get at it, because the clipboard API
  needs a secure context and a LAN address over plain http is not one.
  """
  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, default: nil

  def copyable(assigns) do
    ~H"""
    <div>
      <p :if={@label} class="font-mono text-[11px] tracking-[.14em] uppercase opacity-50">
        {@label}
      </p>
      <div class={["flex items-stretch gap-2", @label && "mt-2"]}>
        <div class="min-w-0 flex-1 rounded-box bg-base-200 px-4 py-3">
          <p id={@id} class="font-mono text-[12.5px] break-all">{@value}</p>
        </div>
        <button
          type="button"
          id={@id <> "-copy"}
          phx-hook=".CopyToClipboard"
          data-target={@id}
          class="min-h-[46px] shrink-0 rounded-field border border-base-300 px-3 text-sm hover:border-base-content/30"
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
end
