defmodule ForgeWeb.QueuePassTest do
  @moduledoc """
  The pass's rules, without a page (`ForgeWeb.QueuePass`, `docs/design/ui.md` § The queue): Later
  goes to the end, deciding moves on, the end is reached, and the queue read again never moves
  what is already in the pass.
  """

  use ExUnit.Case, async: true

  alias ForgeWeb.QueuePass

  defp item(key, minutes \\ 0),
    do: %{key: key, since: DateTime.add(~U[2026-11-10 09:00:00Z], minutes, :minute)}

  defp pass(keys), do: QueuePass.new(Enum.map(keys, &item/1), & &1.key)
  defp merge(pass, items), do: QueuePass.merge(pass, items, & &1.key)

  test "a new pass opens on the first item, and an empty one at the end" do
    assert pass(~w(a b)).current == "a"
    assert pass([]).current == nil
    assert QueuePass.position(pass(~w(a b))) == 1
    assert QueuePass.position(pass([])) == nil
  end

  test "Later sends the item to the end and shows the next one" do
    pass = QueuePass.later(pass(~w(a b c)))

    assert pass.order == ~w(b c a)
    assert pass.current == "b"
    assert QueuePass.position(pass) == 1
  end

  # What was left for later is not met again on the way, so pressing Later on everything ends the
  # pass rather than going round it for ever.
  test "Later on every item ends the pass, each left for later" do
    pass = pass(~w(a b)) |> QueuePass.later() |> QueuePass.later()

    assert pass.current == nil
    assert Enum.map(QueuePass.left(pass), & &1.key) == ~w(a b)
  end

  test "deciding keeps the item, decided, and shows the next undecided one" do
    pass = pass(~w(a b c)) |> QueuePass.jump("b") |> QueuePass.decide()

    assert pass.current == "c"
    assert pass.order == ~w(a b c)
    assert QueuePass.decided?(pass, "b")
    refute QueuePass.decided?(pass, "a")

    # Deciding the last one ends the pass, with what was skipped by the jump still left.
    pass = QueuePass.decide(pass)
    assert pass.current == nil
    assert Enum.map(QueuePass.left(pass), & &1.key) == ~w(a)
  end

  # Back to an earlier item from the list, deciding it moves on past what was decided since.
  test "deciding moves past what is already decided" do
    pass = pass(~w(a b c)) |> QueuePass.jump("b") |> QueuePass.decide() |> QueuePass.jump("a")

    assert QueuePass.decide(pass).current == "c"
  end

  test "deciding moves past what was left for later" do
    pass = pass(~w(a b c)) |> QueuePass.later() |> QueuePass.decide()

    assert pass.order == ~w(b c a)
    assert pass.current == "c"
    assert pass |> QueuePass.decide() |> Map.get(:current) == nil
  end

  test "a jump shows an item in the pass, or the end, and ignores anything else" do
    pass = pass(~w(a b))

    assert QueuePass.jump(pass, "b").current == "b"
    assert QueuePass.jump(pass, "end").current == nil
    assert QueuePass.jump(pass, "zzz") == pass
  end

  test "nothing happens at the end of the pass" do
    pass = QueuePass.jump(pass(~w(a)), "end")

    assert QueuePass.later(pass) == pass
    assert QueuePass.decide(pass) == pass
    assert QueuePass.current(pass) == nil
  end

  describe "the queue read again" do
    test "what arrives joins the end, and the item on screen stays" do
      pass = pass(~w(a b)) |> QueuePass.jump("b") |> merge([item("c"), item("a"), item("b")])

      assert pass.order == ~w(a b c)
      assert pass.current == "b"
    end

    # Answered on another device while on screen: still drawn, marked gone, until the person
    # moves on — and then it leaves.
    test "the item on screen stays when it stops waiting, marked gone" do
      pass = pass(~w(a b)) |> merge([item("b")])

      assert pass.order == ~w(a b)
      assert QueuePass.current(pass).gone

      # Moving on is when it goes — by Later, or by a jump.
      assert pass |> QueuePass.later() |> Map.get(:order) == ~w(b)
      assert pass |> QueuePass.jump("b") |> Map.get(:order) == ~w(b)
      assert pass |> QueuePass.jump("a") |> Map.get(:order) == ~w(a b)
      # Drawn, but no longer waiting: not among what is left.
      assert pass |> QueuePass.left() |> Enum.map(& &1.key) == ~w(b)
    end

    # Decided, it stopped waiting and is marked gone; visited again from the list, moving on from
    # it does not take it out of the pass.
    test "a decided item that stopped waiting stays when the person moves on from it" do
      pass = pass(~w(a b)) |> QueuePass.decide() |> merge([item("b")])
      assert pass.items["a"].gone

      pass = pass |> QueuePass.jump("a") |> QueuePass.jump("b")
      assert pass.order == ~w(a b)
      assert QueuePass.decided?(pass, "a")
    end

    test "an item that stops waiting off screen leaves, and a decided one stays" do
      pass = pass(~w(a b c)) |> QueuePass.decide() |> merge([item("b")])

      assert pass.order == ~w(a b)
      assert pass.current == "b"
      assert QueuePass.decided?(pass, "a")
      assert QueuePass.left(pass) |> Enum.map(& &1.key) == ~w(b)
    end

    test "a decided item waiting again since later is a new interruption, at the end" do
      pass = pass(~w(a b)) |> QueuePass.decide() |> merge([item("a", 5), item("b")])

      assert pass.order == ~w(b a)
      refute QueuePass.decided?(pass, "a")

      # Waiting since the same moment is the one decided, read before it went.
      same = pass(~w(a b)) |> QueuePass.decide() |> merge([item("a"), item("b")])
      assert QueuePass.decided?(same, "a")
      assert same.order == ~w(a b)
    end

    test "at the end of the pass, what arrives is shown" do
      pass = pass(~w(a)) |> QueuePass.decide() |> merge([item("z")])

      assert pass.current == "z"
      assert pass.order == ~w(a z)
    end
  end
end
