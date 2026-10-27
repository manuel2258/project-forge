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

  import ForgeWeb.Indicators

  alias ForgeWeb.Operator.Drafts
  alias ForgeWeb.WorkScreen

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
  The shape that commits something on a single tap — a transition, running a state again: 52px,
  label left, `›` right, sends on tap. A question's options are not this shape: they lock an
  answer in and the form's Send commits (`ForgeWeb.Operator.QuestionForm`).
  """
  attr :rest, :global,
    include: ~w(phx-click phx-value-ticket phx-value-to phx-disable-with type name value form)

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
  An approval. The version is inside the button label, because approval attaches to an exact
  version and never to whatever is latest.

  **It shows what it approves** (`docs/design/ui.md` § The queue item): each pinned document
  rendered, under its name and version, in a box that scrolls inside itself, between the sentence
  and Approve. A blob is its name, linked; a changeset is not drawn, since `href` is nil for it —
  the diff is its rendering, linked beside the card in the queue and on Decide, and on the same
  page as the card on the Changes tab and the review page.

  The comment is a box Enter breaks a line in: as a one-line input, Enter submitted the form with
  its first button, and the first button is Approve (`docs/design/ui.md` § The affordance rule).
  """
  attr :ticket, :map, required: true
  attr :pending, :map, required: true
  attr :approve, :list, default: [], doc: "what the approval pins, each built by `pinned/4`"
  attr :drafts, :map, required: true, doc: "the page's `:drafts` assign"

  attr :commit_message, :any,
    default: nil,
    doc: "the `commit-message` version a merging approval will commit, or nil when there is none"

  def approval_card(assigns) do
    # One name for the draft, because three places have to agree on it: the form's `id`, the
    # hidden field the change event carries it in, and the lookup the box is drawn from. Three
    # interpolated literals is three chances for the draft to stop coming back, silently.
    #
    # **Whether this approval merges is asked of the ticket's workflow**, not passed in, so every
    # page that draws this card agrees without being told: the card is the one place all four
    # approval surfaces share — the review page, the queue, Decide and the Changes tab — and
    # showing the message on one of them meant the other three approved text nobody had seen.
    # `Forge.Engine.approval_merges?/1` is the one definition, and it asks what the entry action
    # asks rather than guessing from the names the approval pins.
    assigns =
      assigns
      |> assign(:draft, "approve-#{assigns.ticket.id}")
      |> assign(:merges, Forge.Engine.approval_merges?(assigns.ticket))

    ~H"""
    <div class="flex flex-col gap-[11px]" id={"approval-#{@ticket.id}"}>
      <p class="text-sm/[1.55] opacity-70">
        Approving pins
        <%= for {pin, i} <- Enum.with_index(@approve) do %>
          <span :if={i > 0}>, </span><span class="font-mono text-[12.5px]">{pin.name} v{pin.version}</span>
        <% end %>
        at <span class="font-mono text-[12.5px]">{@pending["to"]}</span>. A later edit does not
        inherit this approval.
      </p>

      <section
        :for={pin <- @approve}
        :if={pin.href}
        id={"approving-#{@ticket.id}-#{pin.name}"}
        class="flex min-w-0 flex-col"
      >
        <.link
          href={pin.href}
          class="flex min-h-[46px] items-center gap-2 self-start font-mono text-[12.5px] hover:underline"
        >
          <ForgeWeb.FileType.file_icon artifact={pin} />
          {pin.name} <span class="opacity-60">v{pin.version}</span>
        </.link>
        <div
          :if={pin.body}
          tabindex="0"
          aria-label={"#{pin.name} v#{pin.version}"}
          class="max-h-[50vh] min-w-0 overflow-y-auto overscroll-contain rounded-box bg-base-200 px-4 py-3"
        >
          <ForgeWeb.FileType.document_body body={pin.body} />
        </div>
      </section>

      <%!-- What the merge will commit, read-only, directly above the control that approves it
            (`docs/design/ui.md` § Changes). --%>
      <WorkScreen.commit_message
        :if={@merges}
        version={@commit_message}
        id={commit_message_id(@ticket)}
      />

      <%!-- `id` and `phx-change` are what make the comment survive a reconnect: without both of
            them the client has no form to copy and replay, and the new mount draws the box
            empty (`ForgeWeb.Operator.Drafts`). --%>
      <form
        id={@draft}
        phx-change="draft:change"
        phx-submit="decide"
        class="flex flex-col gap-2"
      >
        <input type="hidden" name="draft" value={@draft} />
        <input type="hidden" name="ticket" value={@ticket.id} />
        <ForgeWeb.Conversations.message_box
          id={"approval-comment-#{@ticket.id}"}
          name="comment"
          value={Drafts.field(@drafts, @draft, "comment")}
          enter={:newline}
          placeholder="comment (optional)"
          aria-label="Comment on this approval"
        />
        <button
          :if={not (@merges and is_nil(@commit_message))}
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

  @doc """
  The id of the block an approval card draws the commit message in, from the one definition the
  card itself draws it under: a test that looked for a second copy of this string would pass
  while the operator saw nothing.
  """
  @spec commit_message_id(map()) :: String.t()
  def commit_message_id(%{id: id}), do: "approving-#{id}-commit-message"

  defp approve_label([]), do: "Approve"
  defp approve_label([pin]), do: "Approve #{pin.name} v#{pin.version}"
  defp approve_label(pins), do: "Approve #{length(pins)} versions"

  @doc """
  One version an approval pins, as `approval_card/1` draws it: `%{name, kind, version, href,
  body}`, `kind` read from what the version holds, since a pin is built from a version alone.
  `href` is the version's address, and nil for the changeset, whose rendering is the diff on
  `…/review` rather than anything at an artifact address; `body` is the document as
  `ForgeWeb.FileType.render_document/2` draws it, and nil for anything that is not one — a blob
  is never laid out.

  Rendered here, when the page loads, and not in the card, which is drawn again on every change.
  """
  @spec pinned(String.t(), map(), String.t(), map()) :: map()
  def pinned(project, ticket, name, version) do
    changeset? = name == ForgeCore.Workflow.changeset_artifact()

    %{
      name: name,
      kind: if(is_binary(version.content), do: :document, else: :blob),
      version: version.version,
      href:
        if(not changeset?,
          do: ~p"/tickets/#{project}/#{ticket.number}/artifacts/#{name}/#{version.version}"
        ),
      body:
        if(is_binary(version.content),
          do: ForgeWeb.FileType.render_document(name, version.content)
        )
    }
  end

  @doc """
  Open ticket proposals, each with the two things a person can do about it.

  Not a queue item, and that is the decision rather than an omission: the queue is for what will
  not move until someone acts, and a proposal blocks nothing — no job waits on it and no ticket
  is stuck behind it (`docs/design/ticket-proposals.md` § Where it surfaces). Eighteen jobs
  proposing two each is how the queue's promise that you can reach the end of it stops being
  true, and it would be spent on the one class of item that could have waited.

  `Accept` carries the verb and the `›`, like every affordance that commits; `Decline` is the
  quiet one beside it, as `Reject` is on an approval.

  `types` is the project's ticket types when there is a choice to make — `%{name, parses}` each —
  and empty otherwise. The type a proposal suggests is preselected only if it is one of them now; a
  suggestion that is not is said, and nothing is preselected (`docs/design/ticket-types.md`
  § Proposals). A type whose workflow does not parse is offered marked as such, as on the ticket
  form.
  """
  attr :proposals, :list, required: true
  attr :types, :list, default: []
  attr :drafts, :map, required: true, doc: "the page's `:drafts` assign"

  def proposals(assigns) do
    ~H"""
    <div :for={p <- @proposals} class="border-b border-base-300/60 py-[18px]">
      <div class="flex items-baseline gap-2">
        <h3 class="text-sm font-medium">{p.title || "Could not be read"}</h3>
        <span class="font-mono text-[11px] opacity-50">{p.file}</span>
      </div>

      <p class="mt-1 text-[12.5px]/[1.5] opacity-70 whitespace-pre-line">{p.body}</p>

      <%!-- Only where there is a type to choose: a project without types mentions none. --%>
      <p :if={p[:suggested] && @types != []} class="mt-1 font-mono text-[11px] opacity-60">
        {suggestion(p.suggested, @types)}
      </p>

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

      <form
        id={"propose-#{p.version_id}"}
        phx-change="draft:change"
        phx-submit="decide_proposal"
        class="mt-3 flex flex-col gap-2"
      >
        <input type="hidden" name="draft" value={"propose-#{p.version_id}"} />
        <input type="hidden" name="version_id" value={p.version_id} />
        <%!-- The chosen type is part of the draft too: a reconnect that put the comment back and
              not the choice would still have taken something nobody was told about. --%>
        <select
          :if={@types != [] and p.readable}
          name="ticket_type"
          aria-label="Ticket type"
          class="select w-full"
        >
          <option value="">Choose a type</option>
          <option
            :for={type <- @types}
            value={type.name}
            selected={type.name == chosen(@drafts, p)}
          >
            {if type.parses, do: type.name, else: "#{type.name} — does not parse"}
          </option>
        </select>
        <%!-- Enter breaks a line: as a one-line input it submitted with the first button, which
              is Accept (`docs/design/ui.md` § The affordance rule). --%>
        <ForgeWeb.Conversations.message_box
          id={"proposal-comment-#{p.version_id}"}
          name="comment"
          value={Drafts.field(@drafts, "propose-#{p.version_id}", "comment")}
          enter={:newline}
          placeholder="comment (optional)"
          aria-label="Comment on this proposal"
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

  @doc """
  Runs the state the ticket rests in again (`docs/design/ui.md` § Decide and Timeline): after a
  failure, or after a success whose documents a person wants done afresh. An answer row, because
  it commits something — it spends a job.
  """
  attr :ticket, :map, required: true

  def retry_row(assigns) do
    ~H"""
    <.answer_row
      id={"retry-#{@ticket.id}"}
      phx-click="retry"
      phx-disable-with="Starting…"
      phx-value-ticket={@ticket.id}
    >
      Run {@ticket.state} again
    </.answer_row>
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
        class="w-full rounded-field border border-base-300 bg-transparent px-3 py-2 text-sm placeholder:opacity-40 focus:outline-none focus:border-base-content/40"
      >{Drafts.field(@drafts, @draft, "content", @latest && @latest.content)}</textarea>
      <button
        type="submit"
        phx-disable-with="Saving…"
        class="h-12 self-end rounded-field bg-base-content px-4 text-sm font-medium text-base-100"
      >
        Save {@name}
      </button>
    </form>
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
  A secret shown the one time it can be: only its hash is kept, so nothing can draw it again. A
  freshly issued git token on project settings, and a freshly minted machine's environment on the
  workers page (`docs/design/ui.md` § Project settings, § The workers page) — one block, so the
  two cannot come to say different things about what happens once it is dismissed.

  `note` follows the sentence every one of them says; the inner block is the value and whatever
  goes after it; *Done* sends `done`, whose handler drops the value from the page.
  """
  attr :id, :string, required: true
  attr :done, :string, required: true, doc: "the event Done sends"
  slot :note
  slot :inner_block, required: true

  def shown_once(assigns) do
    ~H"""
    <section id={@id} class="mt-6 rounded-box border border-success p-4">
      <h2 class="font-mono text-[11px] tracking-[.14em] uppercase text-success">
        Copy this now
      </h2>
      <p class="mt-2 text-sm/[1.55] opacity-80">
        Only its hash is kept, so this is the one time it can be shown. {render_slot(@note)}
      </p>
      {render_slot(@inner_block)}
      <button
        type="button"
        phx-click={@done}
        class="mt-3 flex min-h-[46px] items-center text-sm text-primary hover:underline"
      >
        Done
      </button>
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
        <div class="min-w-0 flex-1 rounded-box bg-base-200 px-4 py-3">
          <%!-- A `pre`, because the formatter leaves its content alone: a value laid out on lines
                of its own would be drawn with the template's indentation in front of it. --%>
          <pre :if={@multiline} id={@id} class="font-mono text-[12.5px] whitespace-pre-wrap break-all">{@value}</pre>
          <p :if={not @multiline} id={@id} class="font-mono text-[12.5px] break-all">{@value}</p>
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

  # What a proposal's suggested type is, against the types there are to choose between — drawn
  # only when there are some.
  defp suggestion(type, types) do
    if type in Enum.map(types, & &1.name),
      do: "suggests #{type}",
      else: "suggests #{type}, which is not a type here"
  end

  # The version a document editor was drawn from, as its hidden field carries it: `"0"` when
  # there is none, so a first write and a write over somebody else's first write are told apart.
  defp version_of(nil), do: "0"
  defp version_of(%{version: version}), do: to_string(version)

  # The type a proposal's select is drawn on: what the person chose if they chose, and the
  # suggestion until they do. `Drafts.field/4` cannot carry the fallback here, because choosing
  # the empty option is a choice — *Choose a type*, deliberately back to nothing — and a draft
  # holding `""` must beat the suggestion rather than fall through to it.
  defp chosen(drafts, proposal) do
    case Drafts.field(drafts, "propose-#{proposal.version_id}", "ticket_type", nil) do
      nil -> proposal[:suggested]
      type -> type
    end
  end
end
