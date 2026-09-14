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
end
