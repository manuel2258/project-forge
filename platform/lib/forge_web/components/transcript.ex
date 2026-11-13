defmodule ForgeWeb.Transcript do
  @moduledoc """
  A conversation's transcript: each turn in the order it happened (`docs/design/ui.md` § Talk).

  Every text block is its own box, full width on both sides — the person's on `surface-2`, the
  agent's on `surface-1`, without a border, since nothing in it is tapped — and a micro label
  heads each speaker's run. What the agent did sits between its boxes as action lines
  (`ForgeWeb.Actions`): every line while the turn is open, and each run folded into one line once
  it has ended, with a failure kept visible beneath the fold.

  **A notice is the platform's own line**, standing where the turn it is about stands and wearing
  neither side's label: a turn whose work did not reach the branch
  (`docs/design/ui.md` § Talk).

  **A message keeps the line breaks it was written with.** The body is Markdown, which joins
  single newlines into one paragraph; the `msg` class restores them (`doc.css`). That is a rule of
  the transcript's styles and nothing else — a document is rendered as a document.
  """

  use Phoenix.Component

  import ForgeWeb.Actions, only: [run: 1]

  alias ForgeWeb.{Actions, Format, Markdown}

  attr :messages, :list, required: true
  attr :live, :boolean, required: true, doc: "whether the conversation is live"
  attr :now, :any, required: true, doc: "the moment ages are measured from"

  attr :refs, :map,
    default: %{},
    doc: "`resolve/3`'s answer: what each text's images and links mean, by `{index, position}`"

  attr :banded, :boolean,
    default: false,
    doc: "whether the dock's plan band is drawn: the open turn's checklist is then the band's"

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

      <div :if={message.role == :user} class="rounded-card bg-surface-2 px-4 py-3" data-said="you">
        <div class="doc msg text-sm/[1.6] break-words">
          {Markdown.to_html(message.text, Map.get(@refs, {index, :user}, %{}))}
        </div>
      </div>

      <.turn
        :if={message.role == :assistant}
        message={message}
        refs={@refs}
        index={index}
        folded={message.turn != nil or not @live}
        banded={@banded}
      />

      <%!-- Neither side's: the platform saying this turn's work is not on the branch, which
            otherwise only the machine's log says (`docs/design/conversations.md` § Commits).
            `chat-uncommitted` carries no styling — it is how a test names this line. --%>
      <p :if={message.role == :notice} class="chat-uncommitted text-sm/[1.55] text-warning">
        {message.text}
      </p>
    </li>
    """
  end

  @doc """
  What the images and links in the messages mean, by `{index, position}` — `:user` for a person's
  message and the segment's position for an agent's — resolved together, in the number of queries
  one text would cost, against the moment each message stands in for (`docs/design/conversations.md`
  § References in messages): a person's message the versions recorded before it was sent, a reply
  whose turn is recorded up to and including that record, and a reply still streaming what exists
  now. Called by the page when the log changes, never by a template.
  """
  @spec resolve([map()], Forge.References.scope(), String.t()) :: map()
  def resolve(messages, scope, chat_id) do
    texts =
      for {message, index} <- Enum.with_index(messages), {position, text} <- texts(message) do
        {{index, position}, moment(message, chat_id), Markdown.references(Markdown.parse(text))}
      end

    Forge.References.resolve(scope, texts)
  end

  defp texts(%{role: :user, text: text}), do: [{:user, text}]

  defp texts(%{role: :assistant, items: items}),
    do: items |> segments() |> Enum.with_index() |> then(&for({{:text, t}, i} <- &1, do: {i, t}))

  defp texts(_notice), do: []

  defp moment(%{role: :user, id: id, at: at}, chat_id),
    do: %{at: at, job: chat_id, turn_seq: String.to_integer(id)}

  defp moment(%{recorded: %{at: at, seq: seq}}, chat_id),
    do: %{at: at, job: chat_id, turn_seq: seq}

  defp moment(_streaming, _chat_id), do: %{at: :now, job: nil, turn_seq: nil}

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
  attr :refs, :map, required: true
  attr :banded, :boolean, default: false

  defp turn(assigns) do
    todos = assigns.message.items |> actions() |> latest_todo()

    assigns =
      assign(assigns,
        segments: segments(assigns.message.items),
        todo: todos,
        # While the turn is open and the dock draws its plan band, the band is the plan: the
        # checklist drawn here as well made the plan three times on one screen (UX pass, B16). A
        # `todo_at` no call has draws no checklist; an ended turn keeps its own.
        todo_at:
          if(assigns.banded and not assigns.folded,
            do: :in_band,
            else: first_todo_id(assigns.message.items)
          )
      )

    ~H"""
    <%= for {segment, position} <- Enum.with_index(@segments) do %>
      <div
        :if={match?({:text, _}, segment)}
        class="rounded-card bg-surface-1 px-4 py-3"
        data-said="agent"
      >
        <div class="doc msg text-sm/[1.6] break-words">
          {Markdown.to_html(asked(elem(segment, 1)), Map.get(@refs, {@index, position}, %{}))}
        </div>
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

  @doc """
  An agent's text with each ```question block it asked in drawn as what it asks — the question and
  its options, quoted — rather than as the block's YAML: the answer is the card in the dock, and
  the bubble only says what was asked. The blocks replaced are the ones `ForgeCore.Document`
  reads as questions, cut at the lines its own scan found them on
  (`ForgeCore.Document.question_spans/1`), so a fence the parser does not read as a question — one
  inside another code block — stays as written, and no question's words land on another block.
  Left as it stands when the questions do not parse.
  """
  @spec asked(String.t()) :: String.t()
  def asked(text) do
    # No fence without three backticks: most of what an agent says is not parsed at all. Dropping
    # the check is an equivalent mutant — the parser finds no question there either.
    with true <- String.contains?(text, "```"),
         {:ok, %{questions: [_ | _] = questions}} <-
           ForgeCore.Document.parse(text, blocking: :always) do
      at = Map.new(questions, &{&1.line, &1})
      spans = Map.new(ForgeCore.Document.question_spans(text))

      text
      |> String.replace_prefix("\uFEFF", "")
      |> String.split(~r/\r?\n/)
      |> Enum.with_index(1)
      |> Enum.reduce({[], 0}, &replace_line(&1, &2, at, spans))
      |> elem(0)
      |> Enum.reverse()
      |> Enum.join("\n")
    else
      _none -> text
    end
  end

  # A question's opening line becomes what it asks, and the rest of its span is dropped.
  defp replace_line({line, number}, {out, skip_to}, at, spans) do
    cond do
      number <= skip_to -> {out, skip_to}
      Map.has_key?(at, number) -> {[said(at[number]) | out], Map.fetch!(spans, number)}
      true -> {[line | out], skip_to}
    end
  end

  defp said(%{text: text, options: options}) do
    labels = Enum.map_join(options, " · ", & &1.label)
    if labels == "", do: "> **Asked:** #{text}", else: "> **Asked:** #{text}\n>\n> #{labels}"
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
