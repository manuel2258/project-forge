defmodule ForgeWeb.Transcript do
  @moduledoc """
  A conversation's transcript: each turn in the order it happened (`docs/design/ui.md` § Talk).

  Every text block is its own box, full width on both sides — the person's on `base-200`, the
  agent's on `base-100` with a border — and a micro label heads each speaker's run. What the
  agent did sits between its boxes as action lines (`ForgeWeb.Actions`): every line while the
  turn is open, and each run folded into one line once it has ended, with a failure kept visible
  beneath the fold.

  **A notice is the platform's own line**, standing where the turn it is about stands and wearing
  neither side's label: a turn whose work did not reach the branch
  (`docs/design/ui.md` § Talk).

  **A message keeps the line breaks it was written with.** The body is Markdown, which joins
  single newlines into one paragraph; the `msg` class restores them (`app.css`). That is a rule of
  the transcript's styles and nothing else — a document is rendered as a document.
  """

  use Phoenix.Component

  import ForgeWeb.Actions, only: [run: 1]

  alias ForgeWeb.{Actions, Format, Markdown}

  attr :messages, :list, required: true
  attr :live, :boolean, required: true, doc: "whether the conversation is live"
  attr :now, :any, required: true, doc: "the moment ages are measured from"

  def transcript(assigns) do
    assigns = assign(assigns, entries: entries(assigns.messages))

    ~H"""
    <li
      :for={{message, index, labelled?} <- @entries}
      class="flex flex-col gap-2"
      id={"said-#{index}"}
    >
      <div
        :if={labelled? and message.role != :notice}
        class="flex items-baseline gap-2 font-mono text-[11px] tracking-[.14em] uppercase opacity-50"
      >
        <%= if message.role == :user do %>
          <span>you</span>
          <span :if={not message.delivered} class="opacity-80">· queued</span>
        <% else %>
          <span>agent</span>
          <span :if={message[:turn]}>· turn {message.turn}</span>
        <% end %>
        <span>· {Format.ago(message.at, @now)}</span>
      </div>

      <div :if={message.role == :user} class="rounded-box bg-base-200 px-4 py-3" data-said="you">
        <div class="doc msg text-sm/[1.6] break-words">{Markdown.to_html(message.text)}</div>
      </div>

      <.turn
        :if={message.role == :assistant}
        message={message}
        index={index}
        folded={message.turn != nil or not @live}
      />

      <%!-- Neither side's: the platform saying this turn's work is not on the branch, which
            otherwise only the machine's log says (`docs/design/conversations.md` § Commits). --%>
      <p
        :if={message.role == :notice}
        class="chat-uncommitted flex gap-2 text-sm/[1.55] text-warning"
        data-said="forge"
      >
        <span aria-hidden="true">⚠</span>
        <span>{message.text}</span>
      </p>
    </li>
    """
  end

  # Each message with its place and whether it starts a speaker's run.
  defp entries(messages) do
    messages
    |> Enum.with_index()
    |> Enum.map_reduce(nil, fn {message, index}, previous ->
      {{message, index, message.role != previous}, message.role}
    end)
    |> elem(0)
  end

  attr :message, :map, required: true
  attr :index, :integer, required: true
  attr :folded, :boolean, required: true

  defp turn(assigns) do
    todos = assigns.message.items |> actions() |> latest_todo()

    assigns =
      assign(assigns,
        segments: segments(assigns.message.items),
        todo: todos,
        todo_at: first_todo_id(assigns.message.items)
      )

    ~H"""
    <%= for {segment, position} <- Enum.with_index(@segments) do %>
      <div
        :if={match?({:text, _}, segment)}
        class="rounded-box border border-base-300 bg-base-100 px-4 py-3"
        data-said="agent"
      >
        <div class="doc msg text-sm/[1.6] break-words">{Markdown.to_html(elem(segment, 1))}</div>
      </div>
      <.run
        :if={match?({:actions, _}, segment)}
        id={"run-#{@index}-#{position}"}
        actions={elem(segment, 1)}
        folded={@folded}
        todo={@todo}
        todo_at={@todo_at}
      />
    <% end %>
    """
  end

  # Text blocks one by one, and the calls between two of them as one run.
  defp segments(items) do
    items
    |> Enum.chunk_by(&match?({:text, _}, &1))
    |> Enum.flat_map(fn
      [{:text, _} | _] = texts ->
        for {:text, text} <- texts, String.trim(text) != "", do: {:text, text}

      actions ->
        [{:actions, Enum.map(actions, &elem(&1, 1))}]
    end)
  end

  defp actions(items), do: for({:action, action} <- items, do: action)

  # A turn's plan is drawn once, at its first `TodoWrite`, as its latest version: the plan
  # redrawn in place rather than repeated every time the agent ticks an item.
  defp latest_todo(actions) do
    case actions |> Enum.filter(&(Actions.kind(&1) == :todo)) |> List.last() do
      nil -> []
      action -> Actions.todos(action)
    end
  end

  defp first_todo_id(items) do
    Enum.find_value(items, fn
      {:action, %{name: "TodoWrite", id: id}} -> id
      _other -> nil
    end)
  end

  @doc """
  The agent's latest plan anywhere in the conversation, for the line above the now line: where
  it is in its own plan, visible without scrolling.
  """
  @spec plan([map()]) :: [map()]
  def plan(messages) do
    messages
    |> Enum.flat_map(fn
      %{role: :assistant, items: items} -> actions(items)
      _user -> []
    end)
    |> latest_todo()
  end
end
