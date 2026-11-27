defmodule ForgeWorker.Explore.HoldsTest do
  @moduledoc """
  The timer that lets go of a copy nobody is looking at any more (`ForgeWorker.Explore.Holds`):
  driven by the test, which sends the tick itself and never waits for one.
  """

  use ExUnit.Case, async: false

  import ForgeWorker.Fixtures, only: [tmp_dir: 1, uuid: 0]

  alias ForgeWorker.Explore.Holds
  alias ForgeWorker.Job.CommandCopy

  @ticket "5f0a6d1e-0000-4000-8000-0000000000d1"

  setup do
    root = tmp_dir("holds-root")
    tree = tmp_dir("holds-tree")
    File.write!(Path.join(tree, "built"), "first")
    key = %{ticket: @ticket, epoch: 0}
    first = uuid()

    {:ok, _size, _folders} = CommandCopy.keep(root, key, tree, %{"job_id" => first})
    {:ok, _dir} = CommandCopy.open(root, @ticket, first)
    {:ok, _size, _folders} = CommandCopy.keep(root, key, tree, %{"job_id" => uuid()})

    %{root: root, first: first, aside: CommandCopy.held_path(root, @ticket, first)}
  end

  defp start(root) do
    start_supervised!({Holds, name: :holds_under_test, root: root, every_ms: :infinity})
  end

  test "a tick releases a moved-aside copy whose hold has lapsed", %{
    root: root,
    first: first,
    aside: aside
  } do
    holds = start(root)
    assert File.dir?(aside)

    send(holds, :release)
    :sys.get_state(holds)
    assert File.dir?(aside), "the hold is ten minutes old at most, so it is kept"

    File.touch!(CommandCopy.hold_path(root, @ticket, first), System.os_time(:second) - 700)
    send(holds, :release)
    :sys.get_state(holds)

    refute File.exists?(aside)
    refute File.exists?(CommandCopy.hold_path(root, @ticket, first))
  end

  test "it schedules the next tick when it is given an interval, and ignores what it is not sent",
       %{root: root} do
    holds =
      start_supervised!(
        {Holds, name: :holds_scheduled, root: root, every_ms: 600_000},
        id: :scheduled
      )

    send(holds, :something_else)
    assert %{every_ms: 600_000} = :sys.get_state(holds)
  end
end
