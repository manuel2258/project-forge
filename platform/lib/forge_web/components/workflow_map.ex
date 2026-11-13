defmodule ForgeWeb.WorkflowMap do
  @moduledoc """
  A workflow drawn for reading, never for editing (`docs/design/ui.md` § Workflow): the vertical
  flow a phone shows (`7d`) and the map a portrait or wide screen shows (`7g`, `7h`).

  **The map is SVG drawn on the server** from the parsed workflow: a box per state with its job and
  budget, the states left to right in the order the workflow reaches them (`order/1`), an edge to
  the next state as a straight arrow, a skip forward as an arc above and a loop back as an arc
  below, approvals and queueing in the link colour, and the open tickets as dots on their states.
  A box is a link that filters the page's tickets to that state.
  """

  use ForgeWeb, :html

  alias ForgeCore.Workflow
  alias ForgeCore.Workflow.{State, Transition}
  alias ForgeWeb.{Format, Topology}

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
  @gap 40
  @pad 12
  @arc 34

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
    edges = edges(assigns.workflow, index)

    width = @pad * 2 + length(names) * @box_w + max(length(names) - 1, 0) * @gap
    top = if Enum.any?(edges, &(&1.shape == :skip)), do: @arc + 14, else: 8
    bottom = if Enum.any?(edges, &(&1.shape == :back)), do: @arc + 14, else: 8

    assigns =
      assign(assigns,
        boxes: Enum.map(names, &box(assigns.workflow, &1, index[&1], top, assigns.dots)),
        edges: Enum.map(edges, &place(&1, top)),
        width: width,
        height: top + @box_h + bottom
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

        <g :for={edge <- @edges} class={["wf-map-edge", edge.link && "wf-map-edge--link"]}>
          <path d={edge.d} marker-end={"url(##{@id}-head)"} />
          <text :if={edge.label} x={edge.lx} y={edge.ly} text-anchor="middle" class="wf-map-label">
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
      {@box.name}
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
  defp dot_word(tone), do: to_string(tone)

  defp clip(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  defp box(workflow, name, i, top, dots) do
    state = Workflow.state(workflow, name)

    %{
      name: name,
      topology: ForgeWeb.Topology.of(workflow, name),
      job: job(state),
      budget: budget(state, :short),
      dots: Map.get(dots, name, []),
      x: x(i),
      y: top,
      w: @box_w,
      h: @box_h
    }
  end

  defp x(i), do: @pad + i * (@box_w + @gap)

  # Each edge between two drawn states, with the shape its two places give it. An edge whose
  # source or target is not reached from `initial` has no place on the map and is left out.
  defp edges(workflow, index) do
    for edge <- Workflow.edges(workflow),
        from = index[edge.from],
        to = index[edge.to],
        not is_nil(from) and not is_nil(to) do
      %{
        from: from,
        to: to,
        shape:
          cond do
            to == from + 1 -> :next
            to > from -> :skip
            true -> :back
          end,
        outcome: Transition.outcome(edge),
        link: edge.approve != [] or Transition.queues?(edge)
      }
    end
    |> Enum.uniq_by(&{&1.from, &1.to, &1.shape})
  end

  defp place(%{shape: :next} = edge, top) do
    y = top + div(@box_h, 2)
    x1 = x(edge.from) + @box_w
    x2 = x(edge.to)

    %{
      d: "M#{x1},#{y} L#{x2 - 2},#{y}",
      label: nil,
      lx: 0,
      ly: 0,
      link: edge.link
    }
  end

  defp place(%{shape: :skip} = edge, top) do
    x1 = x(edge.from) + div(@box_w, 2)
    x2 = x(edge.to) + div(@box_w, 2)
    y = top

    %{
      d: "M#{x1},#{y} C#{x1},#{y - @arc} #{x2},#{y - @arc} #{x2},#{y - 2}",
      label: "on #{edge.outcome}, skips",
      lx: div(x1 + x2, 2),
      ly: y - @arc + 12,
      link: edge.link
    }
  end

  defp place(%{shape: :back} = edge, top) do
    x1 = x(edge.from) + div(@box_w, 2) + 10
    x2 = x(edge.to) + div(@box_w, 2) - 10
    y = top + @box_h

    %{
      d: "M#{x1},#{y} C#{x1},#{y + @arc} #{x2},#{y + @arc} #{x2},#{y + 2}",
      label: "on #{edge.outcome}, back",
      lx: div(x1 + x2, 2),
      ly: y + @arc - 4,
      link: edge.link
    }
  end
end
