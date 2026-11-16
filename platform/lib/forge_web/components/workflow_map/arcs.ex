defmodule ForgeWeb.WorkflowMap.Arcs do
  @moduledoc """
  The arcs of the workflow map (`docs/design/ui.md` § Workflow → how the arcs are drawn): where
  each one runs, at what depth, and where its label goes. Pure geometry — no markup, no
  processes — so a test can ask of the numbers what the page's overlap would look like.

  An arc is one pair of states, however many outcomes lead along it. It runs from the box it
  leaves, down (a loop back) or up (a skip forward) to a horizontal at its **depth**, along to
  the box it enters and back to it, with small rounded corners:

    * **Depth.** Two arcs on the same side *overlap* when their spans cross — sharing only an end
      box is not overlapping, since they anchor on opposite halves of it. Arcs are placed shortest
      first, then leftmost, and each goes one band deeper than the deepest arc already placed that
      it overlaps. So overlapping arcs never share a depth, and a shorter arc is inside (shallower
      than) a longer one it overlaps. A band is `@band` pixels.
    * **Anchors.** An arc leaves and enters a box on the half facing it: the right half at its
      left end, the left half at its right end. Arcs sharing a half are spaced apart, deeper ones
      nearer the box's centre, so nested arcs do not cross where they share a box.
    * **Labels.** A label sits in its own band, inside its arc, in the widest stretch of its
      horizontal run that no deeper arc's vertical crosses. It is as wide as its characters times
      `@char`, and is cut with "…" to what the stretch holds, or not drawn if not even "…" fits.
      The arc's whole text is the arc's to say on hover, so a cut loses nothing.
  """

  # One band of depth, in pixels: the horizontal of depth `d` is `d * @band` from the box's edge.
  @band 20
  # A rounded corner's radius, and the label's margin either side of a deeper arc's vertical.
  @corner 6
  @stroke 2
  @clear 5
  # How far from the box's centre the first anchor is, how far from its edge the last may be, and
  # the widest gap between two anchors on one half.
  @inset 10
  @edge 14
  @step 12
  # The label's width per character: the 10px mono face is 0.6em wide and the rest is margin.
  @char 6.2

  @type arc :: %{
          required(:from) => non_neg_integer(),
          required(:to) => non_neg_integer(),
          required(:outcomes) => [String.t()],
          optional(atom()) => term()
        }

  @doc "The height of one band of depth, in pixels."
  @spec band() :: pos_integer()
  def band, do: @band

  @doc "The width one character of a label is given, in pixels."
  @spec char_width() :: float()
  def char_width, do: @char

  @doc """
  Places `arcs`, each `%{from:, to:, outcomes:}` between box indices, on boxes `x.(i)` pixels from
  the left, `box_w` wide, whose top edge is `top` and whose bottom edge is `bottom`. Returns each
  arc with `side` (`:above` for a skip, `:below` for a loop back), `depth`, `d` (its path), `label`
  (what is drawn, or nil), `lx` and `ly` (where), `title` (the whole text) and `left`/`right`,
  the anchors' x.
  """
  @spec place([arc()], (non_neg_integer() -> number()), pos_integer(), number(), number()) ::
          [map()]
  def place(arcs, x, box_w, top, bottom) do
    sided = arcs |> sides() |> Enum.flat_map(&anchored(&1, x, box_w))

    for arc <- sided do
      edge = if arc.side == :above, do: top, else: bottom
      deeper = Enum.filter(sided, &(&1.side == arc.side and &1.depth > arc.depth))
      arc |> Map.merge(path(arc, edge)) |> Map.merge(label(arc, edge, deeper))
    end
  end

  @doc """
  How far above and below the boxes the arcs of `arcs` reach, `{above, below}`, in pixels: what the
  map has to leave room for before it knows where the boxes are.
  """
  @spec reaches([arc()]) :: {non_neg_integer(), non_neg_integer()}
  def reaches(arcs) do
    [above, below] =
      for side <- sides(arcs), do: @band * Enum.max([0 | Enum.map(side, & &1.depth)])

    {above, below}
  end

  # The arcs of each side, `[above, below]`, each with its span and depth.
  defp sides(arcs) do
    sided =
      for arc <- arcs do
        {l, r} = {min(arc.from, arc.to), max(arc.from, arc.to)}
        Map.merge(arc, %{side: if(arc.to > arc.from, do: :above, else: :below), l: l, r: r})
      end

    for side <- [:above, :below], do: sided |> Enum.filter(&(&1.side == side)) |> depths()
  end

  # -- depth ------------------------------------------------------------------------------------

  defp depths(arcs) do
    arcs
    |> Enum.sort_by(&{&1.r - &1.l, &1.l, &1.r})
    |> Enum.reduce([], fn arc, placed ->
      under = for other <- placed, overlap?(arc, other), do: other.depth
      [Map.put(arc, :depth, 1 + Enum.max([0 | under])) | placed]
    end)
    |> Enum.reverse()
  end

  defp overlap?(a, b), do: a.l < b.r and b.l < a.r

  # -- anchors ----------------------------------------------------------------------------------

  # The x each end of an arc is at. Per box and half, the deepest arc is nearest the centre.
  defp anchored(arcs, x, box_w) do
    lefts = Enum.group_by(arcs, & &1.l)
    rights = Enum.group_by(arcs, & &1.r)

    Enum.map(arcs, fn arc ->
      Map.merge(arc, %{
        left: anchor(Map.fetch!(lefts, arc.l), arc, x.(arc.l), box_w, 1),
        right: anchor(Map.fetch!(rights, arc.r), arc, x.(arc.r), box_w, -1)
      })
    end)
  end

  # `sign` is 1 on a box's right half (an arc's left end) and -1 on its left half (its right end).
  defp anchor(sharing, arc, box_x, box_w, sign) do
    room = box_w / 2 - @inset - @edge
    step = if length(sharing) > 1, do: min(@step, room / (length(sharing) - 1)), else: @step

    k =
      sharing
      |> Enum.sort_by(&{-&1.depth, &1.l, &1.r})
      |> Enum.find_index(&(&1.l == arc.l and &1.r == arc.r))

    Float.round(box_x + box_w / 2 + sign * (@inset + k * step), 1)
  end

  # -- the path ---------------------------------------------------------------------------------

  # From the box it leaves to the box it enters, the arrowhead at the end. `sign` is down (1) for a
  # loop back and up (-1) for a skip; the arc leaves from `from` and enters at `to`.
  defp path(arc, edge) do
    sign = if arc.side == :below, do: 1, else: -1
    y = edge + sign * arc.depth * @band

    {start, finish} =
      if arc.side == :above, do: {arc.left, arc.right}, else: {arc.right, arc.left}

    run = if finish > start, do: 1, else: -1

    d =
      [
        "M#{n(start)},#{n(edge)}",
        "V#{n(y - sign * @corner)}",
        "Q#{n(start)},#{n(y)} #{n(start + run * @corner)},#{n(y)}",
        "H#{n(finish - run * @corner)}",
        "Q#{n(finish)},#{n(y)} #{n(finish)},#{n(y - sign * @corner)}",
        "V#{n(edge + sign * 2)}"
      ]
      |> Enum.join(" ")

    %{d: d, y: y}
  end

  # -- the label --------------------------------------------------------------------------------

  defp label(arc, edge, deeper) do
    title = "on " <> Enum.join(arc.outcomes, ", ")
    y = edge + if(arc.side == :below, do: 1, else: -1) * arc.depth * @band
    ly = if arc.side == :below, do: y - 4, else: y + 12

    # The run, less its corners (and the stroke's breadth beside them), less every deeper arc's
    # vertical crossing it.
    run = {arc.left + @corner + @stroke, arc.right - @corner - @stroke}

    {from, upto} =
      deeper
      |> Enum.flat_map(&[&1.left, &1.right])
      |> Enum.sort()
      |> Enum.reduce([run], fn vx, stretches ->
        Enum.flat_map(stretches, &cut(&1, vx - @clear, vx + @clear))
      end)
      |> Enum.max_by(fn {a, b} -> b - a end, fn -> {arc.left, arc.left} end)

    fits = max(trunc((upto - from) / @char), 0)
    text = clip(title, fits)

    %{
      title: title,
      label: text,
      lx: (from + upto) / 2,
      ly: ly
    }
  end

  defp cut({a, b}, from, upto) when upto <= a or from >= b, do: [{a, b}]

  defp cut({a, b}, from, upto),
    do: Enum.filter([{a, min(b, from)}, {max(a, upto), b}], fn {s, e} -> e > s end)

  defp clip(text, fits) do
    cond do
      String.length(text) <= fits -> text
      fits >= 2 -> String.slice(text, 0, fits - 1) <> "…"
      fits == 1 -> "…"
      true -> nil
    end
  end

  # Whole numbers as such and the rest to one place: the path is read by a person's browser and
  # by a test that adds it up.
  defp n(number) when is_integer(number), do: Integer.to_string(number)
  defp n(number), do: :erlang.float_to_binary(number * 1.0, decimals: 1)
end
