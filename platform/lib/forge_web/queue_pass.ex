defmodule ForgeWeb.QueuePass do
  @moduledoc """
  One pass through the queue (`docs/design/ui.md` § The queue): the items in the order the person
  meets them, the one on screen, what they decided in it and what they left for later.

  **The pass is the page's**, and nothing of it is recorded: reloading starts a new one in the
  queue's own order. Pure, so the rules below are tested without a page:

  - **Later** sends the item on screen to the end of the pass and shows the next one. What was
    left for later is not met again on the way: it waits at the end of the pass, under *Back to
    it*, so the pass ends however often Later is pressed.
  - **Deciding** marks the item decided — it stays in the pass, dimmed, for the rest of it — and
    shows the next item after it that is neither decided nor left for later, or the end.
  - **Jumping** to an item — from *All*, the list column or *Back to it* — shows it, whatever it
    is; deciding it there moves on from where it stands.
  - **The queue does not rearrange itself under a thumb.** An item that arrives joins the end. One
    that stops waiting while it is on screen stays drawn, marked `gone`, until the person moves
    on; one that stops waiting anywhere else simply leaves. A decided item stays. A decided item
    that is waiting again — a ticket stuck a second time, a chat asking again — is a new
    interruption: undecided, at the end.
  - At the end of the pass, the first item that arrives is the one on screen.
  """

  @type key :: String.t()
  @type t :: %__MODULE__{
          order: [key()],
          items: %{key() => map()},
          current: key() | nil,
          decided: MapSet.t(key()),
          later: MapSet.t(key())
        }

  defstruct order: [], items: %{}, current: nil, decided: MapSet.new(), later: MapSet.new()

  @doc "A new pass over `items`, in their order, keyed by `key`; the first one on screen."
  @spec new([map()], (map() -> key())) :: t()
  def new(items, key) do
    keys = Enum.map(items, key)
    %__MODULE__{order: keys, items: Map.new(items, &{key.(&1), &1}), current: List.first(keys)}
  end

  @doc """
  The queue read again, merged into the pass by the rules in the moduledoc: what is still waiting
  is redrawn from `items`, what arrived joins the end, and nothing already in the pass moves.
  """
  @spec merge(t(), [map()], (map() -> key())) :: t()
  def merge(%__MODULE__{} = pass, items, key) do
    fresh = Map.new(items, &{key.(&1), &1})
    arrived = for item <- items, k = key.(item), k not in pass.order, do: k
    again = again(pass, fresh)
    order = Enum.filter(pass.order, &kept?(pass, fresh, again, &1)) ++ again ++ arrived

    %{
      pass
      | order: order,
        items: Map.new(order, &{&1, fresh[&1] || Map.put(pass.items[&1], :gone, true)}),
        current: pass.current || List.first(again ++ arrived),
        decided: MapSet.difference(pass.decided, MapSet.new(again))
    }
  end

  # A decided item waiting again since a later moment than the one decided is a new interruption:
  # it leaves the decided set and goes to the end like anything that arrives.
  defp again(pass, fresh) do
    for k <- pass.order,
        MapSet.member?(pass.decided, k),
        item = fresh[k],
        DateTime.after?(item.since, pass.items[k].since),
        do: k
  end

  # Still waiting, decided here, or on screen: what stays where it is.
  defp kept?(pass, fresh, again, k) do
    k not in again and
      (Map.has_key?(fresh, k) or MapSet.member?(pass.decided, k) or k == pass.current)
  end

  @doc "The item on screen, or nil at the end of the pass."
  @spec current(t()) :: map() | nil
  def current(%__MODULE__{current: nil}), do: nil
  def current(%__MODULE__{current: key, items: items}), do: Map.get(items, key)

  @doc "The item on screen is decided: it stays in the pass, and the next undecided one shows."
  @spec decide(t()) :: t()
  def decide(%__MODULE__{current: nil} = pass), do: pass

  def decide(%__MODULE__{current: key} = pass) do
    pass = %{pass | decided: MapSet.put(pass.decided, key)}
    %{pass | current: next(pass, key)}
  end

  @doc """
  The item on screen goes to the end of the pass, and the next one shows. With nothing after it,
  the pass ends and the item is left for later.
  """
  @spec later(t()) :: t()
  def later(%__MODULE__{current: nil} = pass), do: pass

  def later(%__MODULE__{current: key} = pass) do
    %{
      pass
      | order: List.delete(pass.order, key) ++ [key],
        later: MapSet.put(pass.later, key),
        current: next(pass, key)
    }
    |> leave(key)
  end

  @doc "Shows `key`, when it is in the pass; `\"end\"` shows the end. Anything else changes nothing."
  @spec jump(t(), String.t()) :: t()
  def jump(%__MODULE__{current: from} = pass, "end"), do: leave(%{pass | current: nil}, from)

  def jump(%__MODULE__{current: from} = pass, key) do
    if key in pass.order, do: leave(%{pass | current: key}, from), else: pass
  end

  # An item that stopped waiting while on screen was kept only until the person moved on: once
  # they have, it goes, unless they decided it here.
  defp leave(%__MODULE__{current: key} = pass, key), do: pass
  defp leave(pass, nil), do: pass

  defp leave(pass, key) do
    if Map.get(pass.items[key], :gone) && not MapSet.member?(pass.decided, key),
      do: %{pass | order: List.delete(pass.order, key), items: Map.delete(pass.items, key)},
      else: pass
  end

  @doc "Whether `key` was decided in this pass."
  @spec decided?(t(), key()) :: boolean()
  def decided?(%__MODULE__{decided: decided}, key), do: MapSet.member?(decided, key)

  @doc "The items still waiting in the pass: neither decided nor gone, in the pass's order."
  @spec left(t()) :: [map()]
  def left(%__MODULE__{} = pass) do
    for k <- pass.order,
        not MapSet.member?(pass.decided, k),
        item = pass.items[k],
        not Map.get(item, :gone, false),
        do: item
  end

  @doc "Where the item on screen is in the pass, from 1; nil at the end."
  @spec position(t()) :: pos_integer() | nil
  def position(%__MODULE__{current: nil}), do: nil

  def position(%__MODULE__{current: key, order: order}),
    do: Enum.find_index(order, &(&1 == key)) + 1

  # The first item after `key`, in the order as it stands, neither decided nor left for later.
  defp next(%__MODULE__{order: order, decided: decided, later: later}, key) do
    order
    |> Enum.drop_while(&(&1 != key))
    |> Enum.drop(1)
    |> Enum.find(&(not MapSet.member?(decided, &1) and not MapSet.member?(later, &1)))
  end
end
