defmodule ForgeWeb.WorkflowMap do
  @moduledoc """
  A workflow drawn for reading, never for editing (`docs/design/ui.md` § Workflow): the vertical
  flow a phone shows (`7d`) and the map a portrait or wide screen shows (`7g`, `7h`).

  **The map is SVG drawn on the server** from the parsed workflow: a box per state with its job and
  budget, the states left to right in the order the workflow reaches them (`order/1`), an edge to
  the next state on `done` alone as a straight arrow, every other edge as one arc per pair of
  states — a loop back below the boxes, a skip forward above, each at a depth of its own
  (`ForgeWeb.WorkflowMap.Arcs`) — a state's transitions to itself as a line in its box, approvals
  and queueing in the link colour, and the open tickets as dots on their states. A box is a link
  that filters the page's tickets to that state.
  """

  use ForgeWeb, :html

  alias ForgeCore.Workflow
  alias ForgeCore.Workflow.{State, Transition}
  alias ForgeWeb.{Format, Topology}
  alias ForgeWeb.WorkflowMap.Arcs

  @doc """
  What a state's job is, in a few words: its prompt's file and what it produces, `chat · brief.md`
  for a chat step, the commands a command state runs, or `no job`.
  """
  @spec job(State.t()) :: String.t()
  def job(%State{} = state) do
    cond do
      State.chat?(state) -> Enum.join(["chat" | state.produces], " · ")
      State.job?(state) -> arrow(Path.basename(state.prompt), state.produces)
      State.command?(state) -> "runs " <> Enum.map_join(state.invoke, ", ", & &1.command)
      true -> "no job"
    end
  end

  defp arrow(prompt, []), do: prompt
  defp arrow(prompt, produces), do: prompt <> " → " <> Enum.join(produces, ", ")

  @doc """
  What a state's job is, in words, for the phone's flow, which has the room the map's boxes do
  not: `runs triage.md · writes triage.md` rather than `triage.md → triage.md`, which only read
  once the convention was known.
  """
  @spec job_words(State.t()) :: String.t()
  def job_words(%State{} = state) do
    cond do
      State.chat?(state) -> writes("a chat", state.produces)
      State.job?(state) -> writes("runs " <> Path.basename(state.prompt), state.produces)
      State.command?(state) -> "runs " <> Enum.map_join(state.invoke, ", ", & &1.command)
      true -> "no job"
    end
  end

  defp writes(what, []), do: what
  defp writes(what, produces), do: what <> " · writes " <> Enum.join(produces, ", ")

  @doc "A state's budget: `10 turns · 0.2 w`, or nil when it has none."
  @spec budget(State.t(), :long | :short) :: String.t() | nil
  def budget(state, length \\ :long)
  def budget(%State{budget: nil}, _length), do: nil

  def budget(%State{budget: budget}, length) do
    turns = if length == :long, do: "#{budget.turns} turns", else: "#{budget.turns} t"
    Enum.join([turns, Format.windows(budget.tokens) || "—"], " · ")
  end

  @doc """
  The vertical flow (`7d`): each state with its mark, its job, its budget and where it goes on
  which outcome, approvals and queueing in the link colour.
  """
  attr :id, :string, required: true
  attr :workflow, Workflow, required: true
  attr :counts, :map, default: %{}, doc: "open tickets per state, the phone's only place for them"

  def flow(assigns) do
    assigns = assign(assigns, :rows, rows(assigns.workflow))

    ~H"""
    <ol id={@id} class="wf-flow">
      <li :for={row <- @rows} class={["wf-step", "wf-step--#{row.topology}"]}>
        <span class="wf-step-dot" aria-hidden="true" />
        <div class="wf-step-body">
          <div class="wf-step-head">
            <ForgeWeb.Indicators.state name={row.name} topology={row.topology} />
            <span :if={row.initial} class="wf-step-initial">initial</span>
            <span :if={@counts[row.name]} class="wf-step-count">
              {@counts[row.name]} open
            </span>
          </div>
          <div class="wf-step-job">{row.job}</div>
          <div :if={row.budget} class="wf-step-budget">{row.budget}</div>
          <div :for={t <- row.out} class="wf-step-out">
            → {t.to} <span class="wf-step-on">on {Transition.outcome(t)}</span>
            <span :if={t.approve != []} class="wf-step-link">
              · approves {Enum.join(t.approve, ", ")}
            </span>
            <span :if={Transition.queues?(t)} class="wf-step-link">· queues</span>
          </div>
          <div :if={row.out == [] and row.topology == :terminal} class="wf-step-on">terminal</div>
        </div>
      </li>
    </ol>
    """
  end

  defp rows(workflow) do
    for name <- Topology.order(workflow),
        state = Workflow.state(workflow, name),
        not is_nil(state) do
      %{
        name: name,
        initial: name == workflow.initial,
        topology: ForgeWeb.Topology.of(workflow, name),
        job: job_words(state),
        budget: budget(state),
        out: Workflow.transitions_from(workflow, name)
      }
    end
  end

  # -- the map ------------------------------------------------------------------------------

  @box_w 172
  @box_h 76
  # What a box grows by when any state retries itself: one more line of text.
  @retries_h 16
  @gap 40
  @pad 12
  # Clear space kept beyond the deepest arc on a side, and all there is on a side with none.
  @margin 10
  @bare 8
  # A state's name is cut to this many characters: 12.5px mono at 0.6em is 7.5px a character, and
  # the box is `@box_w` less its padding, the mark before the name and the count after it.
  @name_chars 18
  @name_chars_counted 15

  @doc """
  The map (`7g`, `7h`). `dots` is the open tickets per state, each `:waiting`, `:running`,
  `:stuck` or `:idle`; `filter` is the path a state's box links to, given the state's name, or
  nil for a map that filters nothing; `selected` is the state the tickets are filtered to.
  """
  attr :id, :string, required: true
  attr :workflow, Workflow, required: true
  attr :dots, :map, default: %{}
  attr :filter, :any, default: nil
  attr :selected, :string, default: nil

  def map(assigns) do
    names = Topology.order(assigns.workflow)
    index = names |> Enum.with_index() |> Map.new()
    {nexts, arcs, retries} = edges(assigns.workflow, names, index)

    width = @pad * 2 + length(names) * @box_w + max(length(names) - 1, 0) * @gap
    {above, below} = Arcs.reaches(arcs)
    top = if above > 0, do: above + @margin, else: @bare
    box_h = if retries == %{}, do: @box_h, else: @box_h + @retries_h
    bottom_edge = top + box_h

    arcs = Arcs.place(arcs, &x/1, @box_w, top, bottom_edge)

    assigns =
      assign(assigns,
        boxes:
          Enum.map(
            names,
            &box(assigns.workflow, &1, index[&1], top, box_h, assigns.dots, retries)
          ),
        edges: Enum.map(nexts, &next(&1, top, box_h)) ++ arcs,
        width: width,
        height: bottom_edge + if(below > 0, do: below + @margin, else: @bare)
      )

    ~H"""
    <div class="wf-map-scroll">
      <svg
        id={@id}
        class="wf-map"
        viewBox={"0 0 #{@width} #{@height}"}
        width={@width}
        height={@height}
        role="img"
        aria-label="The workflow's states, left to right"
      >
        <defs>
          <marker
            id={@id <> "-head"}
            viewBox="0 0 8 8"
            refX="7"
            refY="4"
            markerWidth="6"
            markerHeight="6"
            orient="auto-start-reverse"
          >
            <path d="M0,0 L8,4 L0,8 z" class="wf-map-head" />
          </marker>
        </defs>

        <g
          :for={edge <- @edges}
          class={["wf-map-edge", edge.link && "wf-map-edge--link"]}
          data-from={edge.from_name}
          data-to={edge.to_name}
        >
          <title :if={edge[:title]}>{edge.title}</title>
          <path d={edge.d} marker-end={"url(##{@id}-head)"} />
          <text
            :if={edge[:label]}
            x={edge.lx}
            y={edge.ly}
            text-anchor="middle"
            class="wf-map-label"
          >
            {edge.label}
          </text>
        </g>

        <.box
          :for={box <- @boxes}
          box={box}
          href={@filter && @filter.(box.name)}
          selected={@selected == box.name}
        />
      </svg>
    </div>
    """
  end

  attr :box, :map, required: true
  attr :href, :string, default: nil
  attr :selected, :boolean, default: false

  defp box(%{href: nil} = assigns) do
    ~H"""
    <g class={["wf-map-box", "wf-map-box--#{@box.topology}"]}>
      <.box_body box={@box} selected={@selected} />
    </g>
    """
  end

  # A link, so a state filters the tickets with the page's own address (`?state=`): an SVG `a`
  # carries `href` as an HTML one does, and LiveView patches it like any other.
  defp box(assigns) do
    ~H"""
    <a
      href={@href}
      data-phx-link="patch"
      data-phx-link-state="push"
      class={["wf-map-box", "wf-map-box--#{@box.topology}"]}
      aria-label={"Tickets in #{@box.name}"}
    >
      <.box_body box={@box} selected={@selected} />
    </a>
    """
  end

  attr :box, :map, required: true
  attr :selected, :boolean, required: true

  defp box_body(assigns) do
    ~H"""
    <title :if={@box.title}>{@box.title}</title>
    <rect
      x={@box.x}
      y={@box.y}
      width={@box.w}
      height={@box.h}
      rx="6"
      class={["wf-map-rect", @selected && "wf-map-rect--selected"]}
    />
    <text x={@box.x + 10} y={@box.y + 20} class="wf-map-name">
      <tspan class="wf-map-mark">{Topology.mark(@box.topology)}</tspan>
      {@box.label}
    </text>
    <%!-- How many open tickets rest here, in figures: the dots alone had to be counted. --%>
    <text
      :if={@box.dots != []}
      x={@box.x + @box.w - 10}
      y={@box.y + 20}
      text-anchor="end"
      class="wf-map-count"
    >
      {length(@box.dots)}
    </text>
    <text x={@box.x + 10} y={@box.y + 38} class="wf-map-job">{clip(@box.job, 24)}</text>
    <text x={@box.x + 10} y={@box.y + 54} class="wf-map-job">{@box.budget || "no budget"}</text>
    <%!-- A state that goes back to itself on an outcome says so here, not as an arc on the
          box: the outcomes are named on hover. --%>
    <text :if={@box.retries != []} x={@box.x + 10} y={@box.y + 70} class="wf-map-retries">
      retries on {length(@box.retries)} {if length(@box.retries) == 1, do: "outcome", else: "outcomes"}
    </text>
    <circle
      :for={{tone, i} <- Enum.with_index(Enum.take(@box.dots, 6))}
      cx={@box.x + 14 + i * 12}
      cy={@box.y + @box.h - 10}
      r="4"
      class={"wf-map-dot wf-map-dot--#{tone}"}
    >
      <title>{dot_word(tone)}</title>
    </circle>
    <text
      :if={length(@box.dots) > 6}
      x={@box.x + 14 + 6 * 12}
      y={@box.y + @box.h - 6}
      class="wf-map-more"
    >
      +{length(@box.dots) - 6}
    </text>
    """
  end

  defp dot_word(:waiting), do: "waiting on you"
  defp dot_word(:held), do: "on hold"
  defp dot_word(tone), do: to_string(tone)

  defp clip(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  defp box(workflow, name, i, top, h, dots, retries) do
    state = Workflow.state(workflow, name)
    dots = Map.get(dots, name, [])
    retried = Map.get(retries, name, [])
    label = clip(name, if(dots == [], do: @name_chars, else: @name_chars_counted))

    %{
      name: name,
      label: label,
      topology: ForgeWeb.Topology.of(workflow, name),
      job: job(state),
      budget: budget(state, :short),
      dots: dots,
      retries: retried,
      # What hovering a box says that its face does not: a name that was cut, and what it retries on.
      title:
        [
          label != name && name,
          retried != [] && "Retries on " <> Enum.join(retried, ", ")
        ]
        |> Enum.filter(& &1)
        |> Enum.join("\n")
        |> case do
          "" -> nil
          text -> text
        end,
      x: x(i),
      y: top,
      w: @box_w,
      h: h
    }
  end

  defp x(i), do: @pad + i * (@box_w + @gap)

  # Every edge between two drawn states, one per pair of states however many outcomes lead along it
  # (an edge whose source or target is not reached from `initial` has no place on the map and is
  # left out), as `{straight arrows, arcs, retries}`:
  #
  #   * a state's transitions to itself are not edges but its retries, by state;
  #   * an edge to the next state whose only outcome is `done` is the straight, unlabelled arrow;
  #   * any other edge is an arc — below if it goes back, above if it goes forward, which includes
  #     one to the next state that carries another outcome, since its label cannot fit the gap.
  defp edges(workflow, names, index) do
    placed =
      for edge <- Workflow.edges(workflow),
          from = index[edge.from],
          to = index[edge.to],
          not is_nil(from) and not is_nil(to),
          do: {from, to, edge}

    {loops, between} = Enum.split_with(placed, fn {from, to, _edge} -> from == to end)

    retries =
      loops
      |> Enum.group_by(fn {_from, _to, edge} -> edge.from end, fn {_from, _to, edge} ->
        Transition.outcome(edge)
      end)
      # `Enum.uniq/1` is an equivalent mutant for a state that runs something: the parser refuses a
      # second transition from it on one outcome ("more than one transition from \"a\" on \"x\""),
      # so its retries never repeat an outcome. A human state is not checked, and a workflow read
      # back from a pin is not parsed again, so it is kept: `retries on N outcomes` must not
      # over-count.
      |> Map.new(fn {name, outcomes} -> {name, Enum.uniq(outcomes)} end)

    pairs =
      between
      |> Enum.group_by(fn {from, to, _edge} -> {from, to} end, fn {_from, _to, edge} -> edge end)
      |> Enum.sort_by(fn {pair, _edges} -> pair end)
      |> Enum.map(fn {{from, to}, edges} ->
        %{
          from: from,
          to: to,
          from_name: Enum.at(names, from),
          to_name: Enum.at(names, to),
          outcomes: edges |> Enum.map(&Transition.outcome/1) |> Enum.uniq(),
          link: Enum.any?(edges, &(&1.approve != [] or Transition.queues?(&1)))
        }
      end)

    {nexts, arcs} =
      Enum.split_with(
        pairs,
        &(&1.to == &1.from + 1 and &1.outcomes == [Workflow.default_outcome()])
      )

    {nexts, arcs, retries}
  end

  defp next(edge, top, box_h) do
    y = top + div(box_h, 2)

    Map.merge(edge, %{
      d: "M#{x(edge.from) + @box_w},#{y} L#{x(edge.to) - 2},#{y}",
      label: nil
    })
  end
end
