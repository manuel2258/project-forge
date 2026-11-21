defmodule ForgeWeb.JobStreamTest do
  @moduledoc """
  How a page adds an event heard on a job's topic to the page of the stream it holds: in `seq`
  order, once, and counted — and which position a rejoin may carry
  (`docs/design/ui.md` § A reconnect is not a reload). Reading the pages is
  `ForgeWeb.PagedStreamsTest`'s.
  """

  use ExUnit.Case, async: true

  alias Forge.Events.Event
  alias ForgeWeb.JobStream

  defp event(seq, type \\ "job.harness.text"), do: %Event{seq: seq, type: type, payload: %{}}

  defp stream(events, more \\ false),
    do: %JobStream{job_id: "job", events: events, more: more, count: length(events)}

  defp seqs({:ok, %JobStream{events: events}}), do: Enum.map(events, & &1.seq)

  test "appends an event numbered after the last one held, and counts it" do
    assert {:ok, %JobStream{count: 2}} = added = JobStream.add(stream([event(1)]), event(2))
    assert seqs(added) == [1, 2]
    assert seqs(JobStream.add(stream([]), event(7))) == [7]
  end

  # Two events written in different transactions can be announced in the other order. The one
  # heard second is not dropped for having the lower number; it goes where its number says.
  test "puts an event heard out of order where its number says" do
    assert seqs(JobStream.add(stream([event(1), event(3)]), event(2))) == [1, 2, 3]
  end

  # Read with the page and broadcast as well.
  test "skips an event it already holds" do
    assert JobStream.add(stream([event(1), event(2), event(3)]), event(2)) == :seen
  end

  # Older entries wait unread: an event numbered below everything held is theirs, and is counted.
  test "counts, and does not hold, an event that belongs to a page not read" do
    assert {:ok, %JobStream{count: 3} = added} =
             JobStream.add(stream([event(10), event(11)], true), event(4))

    assert Enum.map(added.events, & &1.seq) == [10, 11]
    assert seqs(JobStream.add(stream([event(10), event(11)], false), event(4))) == [4, 10, 11]
  end

  test "counts a notice by itself, and not as an entry" do
    assert {:ok, %JobStream{count: 1, notice_count: 1}} =
             JobStream.add(stream([event(1)]), event(2, "job.harness.notice"))
  end

  test "a stream not opened is counted, and an event is counted once" do
    stream = %JobStream{job_id: "job", events: nil, count: 3, counted_to: 9}

    assert {:ok, %JobStream{count: 4, counted_to: 10, events: nil}} =
             JobStream.add(stream, event(10))

    assert JobStream.add(stream, event(9)) == :seen
  end

  test "streams the harness's events and nothing else" do
    assert JobStream.streamed?(event(1, "job.harness.tool_use"))
    assert JobStream.streamed?(event(1, "job.harness.finished"))
    refute JobStream.streamed?(event(1, "chat.turn"))
    refute JobStream.streamed?(event(1, "job.waiting"))
  end

  describe "the position a rejoin carries" do
    test "is a whole number above zero, of this job" do
      assert JobStream.reach("job:42", "job") == 42
      assert JobStream.reach("job:9223372036854775807", "job") == 9_223_372_036_854_775_807
    end

    test "is nothing for another job's, or for anything that is not one" do
      for value <- [
            "other:42",
            "job:0",
            "job:-3",
            "job:1.5",
            "job:4x",
            "job:+4",
            "job: 4",
            "job:9223372036854775808",
            "job:" <> String.duplicate("9", 25),
            "job",
            "42",
            "",
            nil,
            42,
            %{}
          ] do
        assert JobStream.reach(value, "job") == nil, inspect(value)
      end
    end

    test "is what the oldest held event says, or nothing" do
      assert JobStream.reach_of(stream([event(5), event(9)])) == "job:5"
      assert JobStream.reach_of(stream([])) == nil
      assert JobStream.reach_of(%JobStream{job_id: "job", events: nil}) == nil
    end
  end
end
