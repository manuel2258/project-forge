defmodule ForgeWeb.Conversations do
  @moduledoc """
  How a conversation is drawn in a list.

  `/chats` and a ticket's page draw a list of conversations through `list/1`; a project's Chats
  (`7c`) draws its own rows. All three read the conversations, their order and which are live
  from `Forge.Conversations.summaries/1`, so what differs between them is which conversations,
  not the order they come in (`docs/design/ui.md` § Chats).
  """

  use Phoenix.Component
  use ForgeWeb, :verified_routes

  import ForgeWeb.Indicators
  import ForgeWeb.UI.Decisions, only: [confirm: 1]

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
          phx-hook="ForgeWeb.UI.Forms.Composer"
          phx-debounce="200"
          data-newline-on={ForgeWeb.UI.Forms.newline_on(@enter)}
          data-max-lines="6"
          placeholder={@placeholder}
          class="min-h-[46px] w-full min-w-0 resize-none rounded-card border border-border bg-bg px-3 py-[11px] text-sm/[1.6]"
          {@rest}
        >{@value}</textarea>
        <button
          :if={@send}
          type="submit"
          aria-label="Send"
          class="flex size-[46px] shrink-0 items-center justify-center rounded-md bg-ink text-bg"
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

  @doc """
  What ending a conversation asks before it happens, from every surface that offers it.

  With a name, the confirm says which conversation it will end: a list can move a row under a
  finger, and ending deletes the branch, so the wrong one is lost work.
  """
  @spec ending_confirm(String.t()) :: String.t()
  def ending_confirm(name \\ "this conversation"),
    do:
      "End #{name}? The last turn finishes, the machine is released, and " <>
        @ending_rule <> " — merge first what you want to keep."

  attr :summaries, :list, required: true
  attr :now, :any, required: true
  attr :project, :boolean, default: true, doc: "name the project; false on a project's own page"
  attr :empty, :string, default: "No conversations yet."

  attr :heading, :string,
    default: "h2",
    doc: "the tag of the section headings, one level under the page's own"

  attr :ending, :string,
    default: nil,
    doc: "event to send to end a live conversation from the row; no control without it"

  @doc """
  A list of conversations: the live ones in a section of their own above, then the rest.

  The summaries arrive in the order `Conversations.summaries/1` gives, and each part keeps it.
  With nothing live there is no section and no heading, and the list is just the list.
  """
  def list(assigns) do
    {live, earlier} = Enum.split_with(assigns.summaries, & &1.live)
    assigns = assign(assigns, live: live, earlier: earlier)

    ~H"""
    <p :if={@summaries == []} class="mt-3 text-sm opacity-60">{@empty}</p>

    <section :if={@live != []} id="conversations-live">
      <.dynamic_tag
        tag_name={@heading}
        class="mt-5 font-mono text-[11px] tracking-[.14em] uppercase opacity-60"
      >
        Live · {length(@live)}
      </.dynamic_tag>
      <.rows summaries={@live} now={@now} project={@project} ending={@ending} />
    </section>

    <section :if={@live != [] and @earlier != []} id="conversations-earlier">
      <.dynamic_tag
        tag_name={@heading}
        class="mt-5 font-mono text-[11px] tracking-[.14em] uppercase opacity-60"
      >
        Earlier
      </.dynamic_tag>
      <.rows summaries={@earlier} now={@now} project={@project} ending={@ending} />
    </section>

    <.rows
      :if={@live == [] and @earlier != []}
      summaries={@earlier}
      now={@now}
      project={@project}
      ending={@ending}
    />
    """
  end

  attr :summaries, :list, required: true
  attr :now, :any, required: true
  attr :project, :boolean, required: true
  attr :ending, :string, default: nil

  defp rows(assigns) do
    ~H"""
    <ol class="chat-rows">
      <li :for={summary <- @summaries} id={"conversation-#{summary.chat.id}"} class="chat-row">
        <%!-- The row goes to one place, and the control that ends the conversation is beside it
              rather than inside it: `ui.md` § The affordance rule — a navigation target never
              encloses something that commits, or reading and ending become one gesture. --%>
        <.link navigate={~p"/chats/#{summary.chat.id}"} class="chat-row-link">
          <span class="chat-row-head">
            <span class="chat-row-title">{title(summary)}</span>
            <%!-- When it was last used, which is what the list is ordered by; a live one's in the
                  colour of running. --%>
            <span class={["chat-row-at", summary.live && "chat-row-at--live"]}>
              <span :if={summary.live} aria-hidden="true">▸</span> {Format.ago(summary.at, @now)}
            </span>
          </span>

          <span class="chat-row-where">
            <span :if={@project}>{summary.project.name}</span>
            <span :if={@project and summary.ticket} aria-hidden="true">·</span>
            <span :if={summary.ticket}>#{summary.ticket.number}{step(summary)}</span>
            <span :if={summary.waiting} class="text-accent">· waiting on you</span>
            <.job_status :if={not summary.live} status={summary.chat.status} />
          </span>

          <%!-- The last thing said, which is what tells one conversation from another at a glance
                once the title has said what it started as. --%>
          <span class="chat-row-said">
            <span class="text-ink-3">{speaker(summary.said)}</span>
            {said(summary.said)}
          </span>

          <span class="chat-row-figures">
            {summary.chat.turns} {noun(summary.chat.turns, "turn")} · {Format.windows(
              summary.chat.usage
            ) || "—"}
          </span>
        </.link>

        <%!-- Only a live one, and worded as the conversation's own page words it: a
              conversation cannot be deleted at all (`conversations.md` § Lifetime), so the
              affordance a list can offer is the one that stops it costing something — which
              also deletes its branch, and the confirm says so. The confirm names this row's
              conversation, from the same summary as `phx-value-id`, so the two cannot name
              different ones. HEEx escapes the attribute, so a message cannot close it. --%>
        <%!-- A quiet word in danger ink at the row's top right, beside the time: a full button
              on a line of its own made every live row 56px taller (UX pass, B17). --%>
        <.confirm
          :if={@ending && summary.live}
          id={"chat-end-#{summary.chat.id}"}
          label="End"
          act="End it"
          sentence={ending_confirm(name(summary, @project))}
          trigger="quiet"
          class="chat-row-end"
          phx-click={@ending}
          phx-value-id={summary.chat.id}
        />
      </li>
    </ol>
    """
  end

  # What a row is called: `Forge.Conversations.title/3`, from what the summary already holds.
  defp title(summary),
    do: Forge.Conversations.title(summary.chat, summary.ticket, Map.get(summary, :first))

  # A step's conversation names its step after the ticket's number.
  defp step(%{chat: %{state: state}}) when is_binary(state), do: " " <> state
  defp step(_summary), do: ""

  # Project where the list names it, the ticket's number, and the start of the last thing said.
  defp name(summary, project?) do
    [
      project? && summary.project.name,
      summary.ticket && "##{summary.ticket.number}",
      summary.said && ~s("#{said(summary.said)}")
    ]
    |> Enum.filter(& &1)
    |> case do
      [] -> "this conversation"
      parts -> Enum.join(parts, " ")
    end
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
