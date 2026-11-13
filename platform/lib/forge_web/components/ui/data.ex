defmodule ForgeWeb.UI.Data do
  @moduledoc """
  The data primitives (`docs/design/ui/design_system/components/data/`, `docs/design/ui.md`
  § Components): the ticket's context card, the list row, the workflow track, a state with its
  mark, a diff's size, an object's kind, a count, an eyebrow and a list of facts.

  Styles are in `assets/css/components.css` under the same names.
  """
  use Phoenix.Component

  @doc """
  The ticket an item is about (`data/ContextCard`): id, title, type, where it is in its workflow,
  and the facts that set the stakes. Opens every queue item.

  With `navigate` **the card is the ticket's link**, whole, with a trailing `›`: a bordered card
  that did nothing, over a 13px link that did what it should, was two affordances and the large one
  a lie (`docs/design/ui.md` § The affordance rule). Nothing inside it commits, so it may be one.
  """
  attr :id, :string, default: nil, doc: "the element's id"
  attr :ref, :string, required: true, doc: "the ticket's reference, e.g. game#39"
  attr :title, :string, required: true
  attr :type, :string, default: nil
  attr :steps, :list, default: nil
  attr :current, :integer, default: 0
  attr :next, :integer, default: nil
  attr :facts, :list, default: []
  attr :waiting, :boolean, default: false, doc: "the ticket waits on a person: its step is amber"
  attr :navigate, :string, default: nil, doc: "the ticket's page: the whole card links there"
  attr :rest, :global

  def context_card(%{navigate: path} = assigns) when is_binary(path) do
    ~H"""
    <.link id={@id} navigate={@navigate} class="ui-context ui-context--link" {@rest}>
      <.context_body {assigns} />
    </.link>
    """
  end

  def context_card(assigns) do
    ~H"""
    <div id={@id} class="ui-context" {@rest}>
      <.context_body {assigns} />
    </div>
    """
  end

  defp context_body(assigns) do
    ~H"""
    <div class="ui-context-head">
      <span class="ui-context-id">{@ref}</span>
      <span class="ui-context-title">{@title}</span>
      <span :if={@type} class="ui-type-badge">{@type}</span>
      <span :if={@navigate} class="ui-context-go" aria-hidden="true">›</span>
    </div>
    <.workflow_track
      :if={@steps}
      steps={@steps}
      current={@current}
      next={@next}
      waiting={@waiting}
    />
    <div :if={@facts != []} class="ui-context-facts">
      <span :for={fact <- @facts}>{fact}</span>
    </div>
    """
  end

  @doc """
  The list row (`data/ListRow`) for tickets, chats, machines, templates and queue items: an
  optional kicker, the title, a mono meta line, and what happened last, in words.

  `edge` marks the row on its left: `accent` waits on you, `danger` is broken, `ink` is selected.
  A `navigate`, `patch` or `href` makes the whole row the link — so nothing inside it may commit
  (`docs/design/ui.md` § The affordance rule). The `:trailing` slot replaces the ›.
  """
  attr :id, :string, default: nil
  attr :title, :string, required: true
  attr :kicker, :string, default: nil

  attr :age, :string,
    default: nil,
    doc: "the kicker's age, right-aligned and never wrapped: the kicker's text gives way first"

  attr :latest, :string, default: nil
  attr :latest_tone, :string, default: nil, values: [nil, "accent", "warning", "danger"]
  attr :edge, :string, default: nil, values: [nil, "accent"]
  attr :selected, :boolean, default: false
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :href, :string, default: nil
  attr :chevron, :boolean, default: true
  attr :rest, :global

  slot :meta
  slot :trailing

  def list_row(assigns) do
    assigns =
      assign(assigns, :class, [
        "ui-row",
        assigns.edge && "ui-row--#{assigns.edge}",
        assigns.selected && "ui-row--selected"
      ])

    ~H"""
    <%= if @navigate || @patch || @href do %>
      <.link id={@id} navigate={@navigate} patch={@patch} href={@href} class={@class} {@rest}>
        <.row_body
          title={@title}
          kicker={@kicker}
          age={@age}
          latest={@latest}
          latest_tone={@latest_tone}
          chevron={@chevron}
          meta={@meta}
          trailing={@trailing}
        />
      </.link>
    <% else %>
      <div id={@id} class={@class} {@rest}>
        <.row_body
          title={@title}
          kicker={@kicker}
          age={@age}
          latest={@latest}
          latest_tone={@latest_tone}
          chevron={@chevron}
          meta={@meta}
          trailing={@trailing}
        />
      </div>
    <% end %>
    """
  end

  attr :title, :string, required: true
  attr :kicker, :string, required: true
  attr :age, :string, required: true
  attr :latest, :string, required: true
  attr :latest_tone, :string, required: true
  attr :chevron, :boolean, required: true
  attr :meta, :list, required: true
  attr :trailing, :list, required: true

  defp row_body(assigns) do
    ~H"""
    <div class="ui-row-body">
      <div :if={@kicker && !@age} class="ui-row-kicker">{@kicker}</div>
      <div :if={@kicker && @age} class="ui-row-kicker ui-row-kicker--aged">
        <span class="ui-row-kicker-text">{@kicker}</span>
        <span class="ui-row-age">{@age}</span>
      </div>
      <span class="ui-row-title">{@title}</span>
      <div :if={@meta != []} class="ui-row-meta">{render_slot(@meta)}</div>
      <span :if={@latest} class={["ui-row-latest", @latest_tone && "ui-row-latest--#{@latest_tone}"]}>
        {@latest}
      </span>
    </div>
    {render_slot(@trailing)}
    <span :if={@trailing == [] && @chevron} class="ui-row-chevron" aria-hidden="true">›</span>
    """
  end

  @doc """
  Where a ticket is in its workflow (`data/WorkflowTrack`): the steps before `current` at 50 % ink,
  `current` in full ink — amber only when the ticket `waiting` on a person (`docs/design/ui.md`
  § Colour: amber's value is its scarcity) — `next`, the step the decision on screen leads to, at
  30 %, the rest at 12 %. `compact` draws 8px ticks for a list row, with no labels and no `next`.
  Each step carries its name as a `title`: below 768px the labels are not drawn.
  """
  attr :steps, :list, required: true
  attr :current, :integer, default: 0
  attr :next, :integer, default: nil
  attr :compact, :boolean, default: false
  attr :waiting, :boolean, default: false, doc: "a person is waited on: the current step is amber"

  def workflow_track(%{compact: true} = assigns) do
    ~H"""
    <span class={["ui-track ui-track--compact", @waiting && "ui-track--waiting"]} aria-hidden="true">
      <span
        :for={{_step, i} <- Enum.with_index(@steps)}
        class={["ui-track-tick", tick_class(i, @current)]}
      />
    </span>
    """
  end

  def workflow_track(assigns) do
    ~H"""
    <div class={["ui-track", @waiting && "ui-track--waiting"]}>
      <div
        :for={{step, i} <- Enum.with_index(@steps)}
        class={["ui-track-step", "ui-track-step--#{step_position(i, @current, @next)}"]}
        aria-current={i == @current && "step"}
        title={step}
      >
        <span class="ui-track-bar" />
        <span class="ui-track-label">{step}</span>
      </div>
    </div>
    """
  end

  @doc """
  A step's place relative to the ticket's: `:done`, `:current`, `:next` or `:rest`.
  """
  @spec step_position(non_neg_integer, integer, integer | nil) :: :done | :current | :next | :rest
  def step_position(i, current, _next) when i < current, do: :done
  def step_position(i, current, _next) when i == current, do: :current
  def step_position(i, _current, next) when i == next, do: :next
  def step_position(_i, _current, _next), do: :rest

  defp tick_class(i, current) do
    case step_position(i, current, nil) do
      :done -> "ui-track-tick--done"
      :current -> "ui-track-tick--current"
      :rest -> nil
    end
  end

  @states ~w(running waiting step stuck idle)

  @doc """
  A status word with its mark (`data/StateLabel`, `docs/design/ui.md` § Marks): ▸ running (info),
  ● waiting on you (amber), ● a step (link), ● stuck (amber, since it waits on you), ○ idle. Mono, for sublines and
  rows. The marks are `ForgeWeb.Topology.mark/1`'s — running is a job state's, the three dots a
  human state's, idle a terminal one's — so a word and a workflow state cannot draw one meaning
  two ways. A workflow state itself is drawn by `ForgeWeb.Indicators.state/1`, from its topology.
  """
  attr :state, :string, default: "step", values: @states
  attr :rest, :global
  slot :inner_block, required: true

  def state_label(assigns) do
    assigns = assign(assigns, :mark, ForgeWeb.Topology.mark(topology(assigns.state)))

    ~H"""
    <span class={["ui-state", "ui-state--#{@state}"]} {@rest}><span
      class="ui-state-mark"
      aria-hidden="true"
    >{@mark}</span> {render_slot(@inner_block)}</span>
    """
  end

  defp topology("running"), do: :job
  defp topology("idle"), do: :terminal
  defp topology(_waiting_step_or_stuck), do: :human

  @doc """
  A change's size (`data/DiffStat`): +added in green, −removed in red, mono; `bar` adds the
  ratio, `files` the count of files.
  """
  attr :added, :integer, default: 0
  attr :removed, :integer, default: 0
  attr :files, :integer, default: nil
  attr :bar, :boolean, default: false

  def diff_stat(assigns) do
    total = max(assigns.added + assigns.removed, 1)

    assigns =
      assign(assigns,
        added_width: assigns.added / total * 100,
        removed_width: assigns.removed / total * 100
      )

    ~H"""
    <span class="ui-diffstat">
      <span class="ui-diffstat-add">+{@added}</span><span class="ui-diffstat-del">−{@removed}</span>
      <span :if={@bar} class="ui-diffstat-bar" aria-hidden="true">
        <span class="ui-diffstat-add" style={"width: #{@added_width}%"} /><span
          class="ui-diffstat-del"
          style={"width: #{@removed_width}%"}
        />
      </span>
      <span :if={@files} class="ui-diffstat-files">
        · {@files} {if @files == 1, do: "file", else: "files"}
      </span>
    </span>
    """
  end

  @kinds %{"doc" => "md", "changeset" => "±", "branch" => "⑂", "release" => "⇡"}

  @doc """
  An object's kind (`data/TypeIcon`): a 26px tile tinted at 16 % of the kind's colour, with a mono
  glyph — `md` a document, `±` a changeset, `⑂` a branch, `⇡` a release. `label`
  replaces the glyph; a glyph of more than one character is drawn smaller.
  """
  attr :kind, :string, default: "doc", values: Map.keys(@kinds)
  attr :label, :string, default: nil

  def type_icon(assigns) do
    assigns = assign(assigns, :glyph, assigns.label || Map.fetch!(@kinds, assigns.kind))

    ~H"""
    <span
      class={["ui-kind", "ui-kind--#{@kind}", String.length(@glyph) > 1 && "ui-kind--word"]}
      aria-hidden="true"
    >{@glyph}</span>
    """
  end

  @doc """
  A count in a tab or a nav item (`data/CountBubble`). Grey; `tone="accent"` only for a count of
  things that wait on the reader — the queue button, a projects row's waiting count.
  """
  attr :value, :any, required: true
  attr :tone, :string, default: "neutral", values: ~w(neutral accent)
  attr :muted, :boolean, default: false, doc: "a zero that is drawn rather than hidden"

  def count_bubble(assigns) do
    ~H"""
    <span class={["ui-count", @tone == "accent" && "ui-count--accent", @muted && "ui-count--muted"]}>{@value}</span>
    """
  end

  @doc """
  A section label (`data/Eyebrow`): mono, upper case by CSS, +.14em. Names a group, never a page.
  An identifier inside it — a branch, a sha, a path — goes in a `<span class="ui-id">`, which the
  CSS leaves as the system named it.
  """
  attr :tone, :string, default: nil, values: [nil, "accent", "success"]
  attr :rest, :global
  slot :inner_block, required: true

  def eyebrow(assigns) do
    ~H"""
    <span class={["ui-eyebrow", @tone && "ui-eyebrow--#{@tone}"]} {@rest}>{render_slot(@inner_block)}</span>
    """
  end

  @doc """
  Key and value facts for details panels and desktop rails (`data/FactList`), the values in mono.
  Each `:fact` names its `label` and may carry a `tone`: warning, danger, success or info.
  """
  attr :dense, :boolean, default: false
  attr :rest, :global

  slot :fact do
    attr :label, :string, required: true
    attr :tone, :string
  end

  def fact_list(assigns) do
    ~H"""
    <dl class={["ui-facts", @dense && "ui-facts--dense"]} {@rest}>
      <div :for={fact <- @fact} class="ui-fact">
        <dt class="ui-fact-key">{fact.label}</dt>
        <dd class={["ui-fact-value", fact[:tone] && "ui-fact-value--#{fact.tone}"]}>
          {render_slot(fact)}
        </dd>
      </div>
    </dl>
    """
  end
end
