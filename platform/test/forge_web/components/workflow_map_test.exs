defmodule ForgeWeb.WorkflowMapTest do
  @moduledoc """
  The workflow drawn for reading (`docs/design/ui.md` § Workflow): the order its states are drawn
  in, the vertical flow and the map — which edge is an arc above, which below, which is in the
  link colour, and which state's box a ticket's dot sits on.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ForgeCore.Workflow.Parser
  alias ForgeWeb.WorkflowMap
  alias ForgeWeb.WorkflowMap.Arcs

  @example Path.expand("../../../../core/test/fixtures/workflow_example.yml", __DIR__)

  defp example do
    {:ok, workflow} = Parser.parse(File.read!(@example))
    workflow
  end

  test "states are drawn in the order the workflow reaches them, not the alphabet's" do
    assert ForgeWeb.Topology.order(example()) ==
             ["refining", "planning", "implementing", "verifying", "review_ready", "merged"]
  end

  # An integrating state is reached by a conflict and nothing else, so a walk of the declared
  # transitions alone would leave it off the map.
  test "a state only a conflict reaches is in the order, after the merge" do
    {:ok, workflow} = Parser.parse(Forge.GitFixtures.conflict_workflow(:b))

    assert ForgeWeb.Topology.order(workflow) == [
             "implementing",
             "review_ready",
             "merged",
             "integrating"
           ]
  end

  test "the flow says each state's job, budget and where it goes, approvals in the link colour" do
    html =
      render_component(&WorkflowMap.flow/1,
        id: "flow",
        workflow: example(),
        counts: %{"planning" => 2}
      )

    # In words, not the map's `refine.md → refinement.md`.
    assert html =~ "runs refine.md · writes refinement.md"
    # The open tickets per state, which the phone has nowhere else to see.
    assert html =~ ~r/class="wf-step-count"[^>]*>\s*2 open/
    assert length(Regex.scan(~r/wf-step-count/, html)) == 1
    assert html =~ "20 turns"
    assert html =~ "on plan_invalid"
    assert html =~ ~r/class="wf-step-link"[^>]*>\s*· approves refinement.md/
    assert html =~ "initial"
    assert html =~ "no job"
  end

  test "a loop back is an arc below, labelled; a forward step is not labelled" do
    html = render_component(&WorkflowMap.map/1, id: "m", workflow: example())

    # The side an arc is on says which way it goes, so the label does not.
    assert html =~ "on plan_invalid<"
    assert html =~ "on tests_failed<"
    refute html =~ ", back"
    refute html =~ "skips"
    # The approvals are the link colour, the rest are not.
    assert length(Regex.scan(~r/wf-map-edge wf-map-edge--link/, html)) == 2
  end

  test "a skip forward is an arc above" do
    {:ok, workflow} =
      Parser.parse("""
      version: 1
      initial: a
      states:
        a:
          prompt: agents/a.md
          inputs: [ticket]
          produces: [a.md]
          outcomes: [done, trivial]
          budget: { turns: 5, tokens: 20k }
        b: { prompt: agents/b.md, inputs: [a.md], produces: [b.md], budget: { turns: 5, tokens: 20k } }
        c: {}
      transitions:
        - { from: a, to: b }
        - { from: a, to: c, when: trivial }
        - { from: b, to: c }
      limits: { ticket_tokens: 200k }
      """)

    map = draw(workflow)
    assert [skip] = Enum.filter(map.edges, &(&1.from == "a" and &1.to == "c"))
    assert skip.label == "on trivial"
    assert skip.side == :above
    refute html_of(workflow) =~ "skips"
  end

  # -- the arcs (ticket 48) -------------------------------------------------------------------

  @dev Path.expand("../../../../.forge/workflows/dev.yml", __DIR__)
  @forge Path.expand("../../../../.forge", __DIR__)

  # This repository's own workflow, read with its library as the parser's tests read it.
  defp dev, do: parse_dev(File.read!(@dev))

  # `dev.yml` with the `budget_exhausted` edges `7a68029` took out of it put back: one arc that
  # carries two outcomes (`reviewing → presenting` on `done` and `budget_exhausted`) and states that
  # retry on two. Those are the shapes the tests below were written on, and the real file no longer
  # has them; the rest of what is drawn is still this repository's workflow.
  defp dev_with_budget_edges do
    edges = """
      - { from: planning,     to: planning,     when: budget_exhausted,  max: 1 }
      - { from: implementing, to: implementing, when: budget_exhausted,  max: 1 }
      - { from: reviewing,    to: presenting,   when: budget_exhausted }
      - { from: presenting,   to: presenting,   when: budget_exhausted,  max: 1 }

    limits:
    """

    [head, tail] = String.split(File.read!(@dev), "\nlimits:\n", parts: 2)
    parse_dev(head <> "\n" <> edges <> tail)
  end

  defp parse_dev(text) do
    opts = [
      prompt_exists: &File.exists?(Path.join(@forge, &1)),
      file_exists: &File.exists?(Path.join(Path.dirname(@forge), &1)),
      read_library: fn path ->
        case File.read(Path.join(@forge, path)) do
          {:ok, text} -> {:ok, text}
          {:error, _reason} -> :error
        end
      end
    ]

    {:ok, workflow} = Parser.parse(text, opts)
    workflow
  end

  defp fixture do
    {:ok, workflow} = Parser.parse(Forge.Look.Setups.Project.dev_workflow())
    workflow
  end

  # `n` job states, each reaching the next on `done`, the last reaching `end`, and `extra` as
  # `{from, to, outcome}`: the shapes the map has to untangle, made to order.
  defp chain(n, extra) do
    states =
      for i <- 0..(n - 1) do
        outcomes = Enum.uniq(["done" | for({^i, _to, outcome} <- extra, do: outcome)])

        """
          s#{i}:
            prompt: agents/s#{i}.md
            inputs: [ticket]
            produces: [s#{i}.md]
            outcomes: [#{Enum.join(outcomes, ", ")}]
            budget: { turns: 5, tokens: 20k }
        """
      end

    next =
      for i <- 0..(n - 1),
          do: "  - { from: s#{i}, to: #{if i == n - 1, do: "end", else: "s#{i + 1}"} }"

    more =
      for {from, to, outcome} <- extra, do: "  - { from: s#{from}, to: s#{to}, when: #{outcome} }"

    yaml =
      "version: 1\ninitial: s0\nstates:\n" <>
        Enum.join(states) <>
        "  end: {}\ntransitions:\n" <>
        Enum.join(next ++ more, "\n") <> "\nlimits: { ticket_tokens: 200k }\n"

    {:ok, workflow} = Parser.parse(yaml)
    workflow
  end

  defp long(name), do: String.pad_trailing(name, 40, "x")

  defp html_of(workflow, opts \\ []),
    do: render_component(&WorkflowMap.map/1, [id: "m", workflow: workflow] ++ opts)

  # The map as numbers: every box, every edge with its path as segments, and every label as the
  # rectangle it covers, so that "nothing overlaps" is asked of what is drawn and not of how it
  # was computed. The width of a character is the one the drawing assumes (`Arcs.char_width/0`).
  defp draw(workflow, opts \\ []) do
    doc = workflow |> html_of(opts) |> Floki.parse_fragment!()
    num = &(&1 |> Floki.attribute(&2) |> hd() |> parse_number())

    boxes =
      for rect <- Floki.find(doc, "rect.wf-map-rect") do
        x = num.(rect, "x")
        y = num.(rect, "y")
        %{rect: {x, y, x + num.(rect, "width"), y + num.(rect, "height")}}
      end

    top = boxes |> Enum.map(fn %{rect: {_x1, y1, _x2, _y2}} -> y1 end) |> Enum.min()

    edges =
      for g <- Floki.find(doc, "g.wf-map-edge") do
        [d] = g |> Floki.find("path") |> Floki.attribute("d")
        label = g |> Floki.find("text.wf-map-label") |> List.first()
        segments = segments(d)

        %{
          from: g |> Floki.attribute("data-from") |> hd(),
          to: g |> Floki.attribute("data-to") |> hd(),
          d: d,
          segments: segments,
          head: head(d),
          link: "wf-map-edge--link" in (g |> Floki.attribute("class") |> hd() |> String.split()),
          title: g |> Floki.find("title") |> Floki.text(),
          label: label && Floki.text(label) |> String.trim(),
          label_rect: label && label_rect(label),
          side: if(label && num.(label, "y") < top, do: :above, else: :below),
          level: level(segments)
        }
      end

    %{boxes: boxes, edges: edges, html: Floki.raw_html(doc)}
  end

  defp parse_number(text), do: text |> Float.parse() |> elem(0)

  defp label_rect(label) do
    [x] = Floki.attribute(label, "x")
    [y] = Floki.attribute(label, "y")
    {x, y} = {parse_number(x), parse_number(y)}
    half = String.length(label |> Floki.text() |> String.trim()) * Arcs.char_width() / 2
    {x - half, y - 8, x + half, y + 3}
  end

  # A path of `M`, `V`, `H`, `L` and `Q` as the rectangles its strokes cover (1.2px wide, the
  # curve's control box standing for the curve).
  defp segments(d) do
    ~r/([MVHLQ])([^MVHLQ]*)/
    |> Regex.scan(d)
    |> Enum.reduce({nil, []}, fn [_all, cmd, args], {at, acc} ->
      nums = args |> String.split(~r/[ ,]/, trim: true) |> Enum.map(&parse_number/1)

      {to, points} =
        case {cmd, nums} do
          {"M", [x, y]} -> {{x, y}, []}
          {"V", [y]} -> {{elem(at, 0), y}, [at, {elem(at, 0), y}]}
          {"H", [x]} -> {{x, elem(at, 1)}, [at, {x, elem(at, 1)}]}
          {"L", [x, y]} -> {{x, y}, [at, {x, y}]}
          {"Q", [cx, cy, x, y]} -> {{x, y}, [at, {cx, cy}, {x, y}]}
        end

      {to, if(points == [], do: acc, else: acc ++ [points])}
    end)
    |> elem(1)
    |> Enum.map(fn points ->
      {xs, ys} = {Enum.map(points, &elem(&1, 0)), Enum.map(points, &elem(&1, 1))}
      {Enum.min(xs) - 0.6, Enum.min(ys) - 0.6, Enum.max(xs) + 0.6, Enum.max(ys) + 0.6}
    end)
  end

  # The arrowhead of an arc: 7.2px long and 7.2 wide, lying back along the last vertical from the
  # tip at the box. A straight arrow has no vertical, and its head is not asked about.
  defp head(d) do
    case Regex.run(~r/Q\S+ (\S+),(\S+) V(\S+)$/, d) do
      [_all, x, from, tip] ->
        {x, from, tip} = {parse_number(x), parse_number(from), parse_number(tip)}
        back = if from > tip, do: tip + 7.2, else: tip - 7.2
        {x - 3.6, min(tip, back), x + 3.6, max(tip, back)}

      nil ->
        nil
    end
  end

  # The depth of an arc is the y of its horizontal: the second segment's far end.
  defp level(segments) do
    {_x1, y1, _x2, y2} = Enum.at(segments, 1, hd(segments))
    {y1, y2}
  end

  defp overlap?({ax1, ay1, ax2, ay2}, {bx1, by1, bx2, by2}),
    do: ax1 < bx2 and bx1 < ax2 and ay1 < by2 and by1 < ay2

  defp assert_nothing_overlaps(%{boxes: boxes, edges: edges}, name) do
    labelled =
      for %{label: label, label_rect: rect} = edge <- edges, label != nil, do: {edge, rect}

    for {edge, rect} <- labelled do
      who = "#{name}: the label of #{edge.from} → #{edge.to} (#{edge.label})"

      for %{rect: box} <- boxes, do: refute(overlap?(rect, box), "#{who} is on a box")

      for other <- edges, segment <- other.segments ++ List.wrap(other.head) do
        refute overlap?(rect, segment),
               "#{who} is on an arc or its arrowhead: #{other.from} → #{other.to}"
      end
    end

    for {a, i} <- Enum.with_index(labelled), {b, j} <- Enum.with_index(labelled), i < j do
      {ea, ra} = a
      {eb, rb} = b

      refute overlap?(ra, rb),
             "#{name}: the labels of #{ea.from} → #{ea.to} and #{eb.from} → #{eb.to} overlap"
    end
  end

  defp workflows do
    [
      {"this repository's dev.yml", dev()},
      {"the look's dev type", fixture()},
      {"twenty loops back onto one state, 40-character outcomes",
       chain(21, for(i <- 1..20, do: {i, 0, long("loop_#{i}_")}))},
      # Each loop reaches back over three states: every one crosses its neighbours.
      {"crossing loops", chain(12, for(i <- 3..11, do: {i, i - 3, "back_#{i}"}))},
      # Short loops side by side at one depth, whose labels cannot fit their arcs.
      {"adjacent loops with long outcomes",
       chain(6, for(i <- 1..5, do: {i, i - 1, long("outcome_#{i}_")}))},
      {"forward skips as well",
       chain(8, [{0, 3, "skip_a"}, {1, 4, "skip_b"}, {2, 7, long("skip_")}, {6, 2, "back_a"}])}
    ]
  end

  test "no label is on another label, an arc or a box, however tangled the workflow" do
    for {name, workflow} <- workflows() do
      map = draw(workflow)
      assert map.edges != []
      assert_nothing_overlaps(map, name)
    end
  end

  test "every edge between two states is drawn once, and none from a state to itself" do
    for {name, workflow} <- workflows() do
      order = ForgeWeb.Topology.order(workflow)

      pairs =
        for edge <- ForgeCore.Workflow.edges(workflow),
            edge.from != edge.to,
            edge.from in order and edge.to in order,
            uniq: true,
            do: {edge.from, edge.to}

      drawn = for edge <- draw(workflow).edges, do: {edge.from, edge.to}

      assert Enum.sort(drawn) == Enum.sort(pairs), "#{name}: an edge is missing or drawn twice"
    end
  end

  test "overlapping arcs on one side are at different depths, the shorter one shallower" do
    for {name, workflow} <- workflows() do
      map = draw(workflow)
      index = workflow |> ForgeWeb.Topology.order() |> Enum.with_index() |> Map.new()

      arcs =
        for edge <- map.edges, edge.label != nil do
          {l, r} = Enum.min_max([index[edge.from], index[edge.to]])
          %{l: l, r: r, side: edge.side, level: edge.level, edge: edge}
        end

      for a <- arcs, b <- arcs, a != b, a.side == b.side, a.l < b.r and b.l < a.r do
        assert a.level != b.level,
               "#{name}: #{a.edge.from} → #{a.edge.to} and #{b.edge.from} → #{b.edge.to} share a depth"

        # Further from the boxes is deeper, above or below.
        deeper? = fn x, y ->
          if x.side == :below, do: x.level > y.level, else: x.level < y.level
        end

        if a.r - a.l < b.r - b.l,
          do: assert(deeper?.(b, a), "#{name}: a longer arc is inside a shorter one")
      end
    end
  end

  # Two outcomes on one edge: this repository's own workflow has none now (`reviewing` used to
  # reach `presenting` on `done` and on `budget_exhausted`, until a job that runs out stuck its
  # ticket for a person), so a workflow of the test's own has it.
  test "two outcomes on one edge are one arc, labelled with both" do
    assert [arc] =
             Enum.filter(
               draw(chain(3, [{0, 1, "trivial"}])).edges,
               &(&1.from == "s0" and &1.to == "s1")
             )

    assert arc.label == "on done, trivial"
    assert arc.title == "on done, trivial"

    assert [arc] =
             Enum.filter(
               draw(dev_with_budget_edges()).edges,
               &(&1.from == "reviewing" and &1.to == "presenting")
             )

    assert arc.label == "on done, budget_exhausted"
    assert arc.title == "on done, budget_exhausted"
  end

  # The edge to the next state is straight and bare on `done` alone; with any other outcome its
  # label cannot fit the gap, so it is an arc above, and there is no straight arrow as well.
  test "an arrow to the next state is straight only when its sole outcome is done" do
    map = draw(dev_with_budget_edges())

    for {from, to} <- [{"refining", "planning"}, {"planning", "implementing"}] do
      assert [edge] = Enum.filter(map.edges, &(&1.from == from and &1.to == to))
      assert edge.d =~ " L"
      assert edge.label == nil
    end

    # With a second outcome the label cannot fit the gap, so it is an arc above and no straight
    # arrow as well.
    skipping = draw(chain(3, [{0, 1, "trivial"}]))
    assert [edge] = Enum.filter(skipping.edges, &(&1.from == "s0" and &1.to == "s1"))
    refute edge.d =~ " L"
    assert edge.side == :above
  end

  test "a state that goes back to itself says so in its box and is drawn no arc" do
    html = html_of(dev_with_budget_edges())

    assert html =~ ~r/retries on\s+1 outcome\s*</
    # In the order the edges are declared, and the restored ones come last.
    assert html =~ "Retries on did_not_converge, budget_exhausted"
    refute Enum.any?(draw(dev()).edges, &(&1.from == &1.to))
    refute Enum.any?(draw(dev_with_budget_edges()).edges, &(&1.from == &1.to))

    # Several outcomes on one state's own loop are counted.
    two = html_of(chain(2, [{0, 0, "tired"}, {0, 0, "lost"}]))
    assert two =~ ~r/retries on\s+2 outcomes/

    # Every box grows for the line when any state has one, and none grows when none does.
    heights = fn html ->
      html
      |> Floki.parse_fragment!()
      |> Floki.find("rect.wf-map-rect")
      |> Floki.attribute("height")
      |> Enum.uniq()
    end

    assert [_one] = heights.(html)
    assert heights.(html) != heights.(html_of(example()))
    refute html_of(example()) =~ "retries on"
  end

  test "a label too long for its arc is cut, and the whole of it is the arc's hover" do
    map = draw(chain(6, for(i <- 1..5, do: {i, i - 1, long("outcome_#{i}_")})))
    cut = Enum.filter(map.edges, &(&1.label != nil and String.ends_with?(&1.label, "…")))

    assert cut != []

    for edge <- cut do
      assert String.starts_with?(edge.title, "on outcome_")
      assert String.length(edge.title) > String.length(edge.label)
    end

    # A label that fits is whole.
    whole = draw(example()).edges |> Enum.filter(&(&1.label != nil))
    refute Enum.any?(whole, &String.ends_with?(&1.label, "…"))
  end

  # -- where an arc leaves and enters a box ---------------------------------------------------

  defp place(arcs), do: Arcs.place(arcs, fn i -> 12 + i * 212 end, 172, 50, 126)

  defp arc(from, to), do: %{from: from, to: to, outcomes: ["o#{from}_#{to}"]}

  test "nested arcs that share a box leave it a step apart, the deeper one nearer the centre" do
    # Both loops leave box 0's right half; the longer one is deeper, and so is nearer its centre
    # (12 + 86) so that it does not cross the shorter one's leg where they share the box.
    [short, long] = place([arc(1, 0), arc(2, 0)]) |> Enum.sort_by(& &1.from)

    assert {short.depth, long.depth} == {1, 2}
    assert long.left == 108.0
    assert short.left == 120.0
  end

  test "arcs crowding one half of a box are squeezed to fit it, never spread past its edge" do
    placed = place(for(i <- 1..20, do: arc(i, 0)))
    anchors = Enum.map(placed, & &1.left)

    assert length(Enum.uniq(anchors)) == 20
    # Box 0 runs from 12 to 184.
    assert Enum.all?(anchors, &(&1 > 12 and &1 < 184))
  end

  test "arcs that only share an end box do not overlap, so they share a depth" do
    placed = place([arc(1, 0), arc(2, 1)])
    assert Enum.map(placed, & &1.depth) == [1, 1]

    # And above the boxes, the same.
    assert [1, 1] == place([arc(0, 2), arc(2, 4)]) |> Enum.map(& &1.depth)
  end

  test "an approval is the link colour as well as a queueing edge, and nothing else is" do
    links = fn workflow ->
      for edge <- draw(workflow).edges, edge.link, do: {edge.from, edge.to}
    end

    # `refining → planning` approves and does not queue; `rebasing → merged` queues and does not
    # approve; `review_ready → merged` does both.
    assert {"refining", "planning"} in links.(dev())
    assert {"rebasing", "merged"} in links.(dev())
    assert {"review_ready", "merged"} in links.(dev())
    refute {"checking", "implementing"} in links.(dev())
    refute {"reviewing", "presenting"} in links.(dev())
  end

  # -- what is cut ----------------------------------------------------------------------------

  test "a state's name and its job are cut to the characters the box has" do
    {:ok, workflow} =
      Parser.parse("""
      version: 1
      initial: #{String.duplicate("a", 40)}
      states:
        #{String.duplicate("a", 40)}:
          prompt: agents/a.md
          inputs: [ticket]
          produces: [#{String.duplicate("d", 40)}.md]
          budget: { turns: 5, tokens: 20k }
        end: {}
      transitions:
        - { from: #{String.duplicate("a", 40)}, to: end }
      limits: { ticket_tokens: 200k }
      """)

    doc = workflow |> html_of() |> Floki.parse_fragment!()

    name =
      doc
      |> Floki.find("text.wf-map-name")
      |> List.first()
      |> Floki.text()
      |> String.replace(~r/[▸\s]/u, "")

    job = doc |> Floki.find("text.wf-map-job") |> List.first() |> Floki.text()

    # Eighteen characters of name with no count beside it, and twenty-four of the job: the last is
    # the ellipsis in both.
    assert String.length(name) == 18 and String.ends_with?(name, "…")
    assert String.length(job) == 24 and String.ends_with?(job, "…")

    # With a count in the box, three characters fewer of the name.
    counted =
      html_of(workflow, dots: %{String.duplicate("a", 40) => [:running]})
      |> Floki.parse_fragment!()
      |> Floki.find("text.wf-map-name")
      |> List.first()
      |> Floki.text()
      |> String.replace(~r/[▸\s]/u, "")

    assert String.length(counted) == 15
  end

  test "a name of exactly the characters the box has is whole, and one more is cut" do
    names = fn name ->
      {:ok, workflow} =
        Parser.parse("""
        version: 1
        initial: #{name}
        states:
          #{name}:
            prompt: agents/a.md
            inputs: [ticket]
            produces: [a.md]
            budget: { turns: 5, tokens: 20k }
        transitions: []
        limits: { ticket_tokens: 200k }
        """)

      workflow
      |> html_of()
      |> Floki.parse_fragment!()
      |> Floki.find("text.wf-map-name")
      |> Floki.text()
      |> String.replace(~r/[▸\s]/u, "")
    end

    assert names.(String.duplicate("a", 18)) == String.duplicate("a", 18)
    assert names.(String.duplicate("a", 19)) == String.duplicate("a", 17) <> "…"
  end

  test "the map grows taller for every loop and does not grow wider" do
    few = chain(21, for(i <- 1..2, do: {i, 0, "loop_#{i}"}))
    many = chain(21, for(i <- 1..20, do: {i, 0, "loop_#{i}"}))
    size = fn workflow -> Regex.run(~r/viewBox="0 0 (\d+) (\d+)"/, html_of(workflow)) end

    assert [_, w_few, h_few] = size.(few)
    assert [_, w_many, h_many] = size.(many)
    assert w_few == w_many
    assert String.to_integer(h_many) > String.to_integer(h_few)
  end

  test "a state's name is cut to fit its box, and the whole of it is said on hover" do
    {:ok, workflow} =
      Parser.parse("""
      version: 1
      initial: #{String.duplicate("a", 40)}
      states:
        #{String.duplicate("a", 40)}:
          prompt: agents/a.md
          inputs: [ticket]
          produces: [a.md]
          budget: { turns: 5, tokens: 20k }
      transitions: []
      limits: { ticket_tokens: 200k }
      """)

    html = html_of(workflow, filter: &"/p?state=#{&1}")

    assert html =~ ~s(aria-label="Tickets in #{String.duplicate("a", 40)}")
    assert html =~ ~r/<title[^>]*>#{String.duplicate("a", 40)}<\/title>/
    drawn = html |> Floki.parse_fragment!() |> Floki.find("text.wf-map-name") |> Floki.text()
    assert drawn =~ "…"
    refute drawn =~ String.duplicate("a", 40)
  end

  test "a ticket's dot is on its state's box, and a state links to the tickets in it" do
    html =
      render_component(&WorkflowMap.map/1,
        id: "m",
        workflow: example(),
        dots: %{"planning" => [:waiting, :running]},
        selected: "planning",
        filter: &"/projects/p?state=#{&1}"
      )

    assert length(Regex.scan(~r/wf-map-dot wf-map-dot--waiting/, html)) == 1
    assert length(Regex.scan(~r/wf-map-dot wf-map-dot--running/, html)) == 1
    # The box says how many in figures, and a dot says what it is on hover.
    assert html =~ ~r/class="wf-map-count"[^>]*>\s*2\s*</
    assert length(Regex.scan(~r/wf-map-count/, html)) == 1
    assert html =~ "<title>waiting on you</title>"
    assert html =~ ~s(href="/projects/p?state=planning")
    assert html =~ "wf-map-rect--selected"
  end
end
