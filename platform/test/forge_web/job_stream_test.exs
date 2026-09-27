defmodule ForgeWeb.JobStreamTest do
  @moduledoc """
  How a page adds an event heard on a job's topic to the log it holds: in `seq` order, and once.
  """

  use ExUnit.Case, async: true

  alias Forge.Events.Event
  alias ForgeWeb.JobStream

  defp event(seq, type \\ "job.harness.text"), do: %Event{seq: seq, type: type, payload: %{}}

  test "appends an event numbered after the last one held" do
    assert {:ok, [%{seq: 1}, %{seq: 2}]} = JobStream.add([event(1)], event(2))
    assert {:ok, [%{seq: 7}]} = JobStream.add([], event(7))
  end

  # Two events written in different transactions can be announced in the other order. The one
  # heard second is not dropped for having the lower number; it goes where its number says.
  test "puts an event heard out of order where its number says" do
    assert {:ok, events} = JobStream.add([event(1), event(3)], event(2))
    assert Enum.map(events, & &1.seq) == [1, 2, 3]
  end

  # Read with the log and broadcast as well.
  test "skips an event it already holds" do
    assert JobStream.add([event(1), event(2), event(3)], event(2)) == :seen
  end

  test "streams the harness's events and nothing else" do
    assert JobStream.streamed?(event(1, "job.harness.tool_use"))
    assert JobStream.streamed?(event(1, "job.harness.finished"))
    refute JobStream.streamed?(event(1, "chat.turn"))
    refute JobStream.streamed?(event(1, "job.waiting"))
  end
end
