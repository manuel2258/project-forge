defmodule ForgeWorker.Job.LinesTest do
  @moduledoc """
  The tail of a command's log (`ForgeWorker.Job.Lines`): driven by the test, which polls it
  directly and holds the clock, so nothing waits for a tick.
  """

  use ExUnit.Case, async: true

  import ForgeWorker.Fixtures, only: [sealed_secrets: 2, tmp_dir: 1]

  alias ForgeWorker.Job.Lines

  setup do
    path = Path.join(tmp_dir("lines"), "command.log")
    {:ok, now} = Agent.start_link(fn -> 100 end)

    {:ok, tailer} =
      Lines.start_link(
        job_id: "j1",
        path: path,
        link: self(),
        clock: fn -> Agent.get(now, & &1) end,
        poll_ms: :infinity,
        batch: 3
      )

    %{tailer: tailer, path: path, now: now}
  end

  defp append(path, text), do: File.write!(path, text, [:append])

  test "says it is there, and sends what is written in order, with the time it was seen",
       %{tailer: tailer, path: path, now: now} do
    assert_receive {:tailer, "j1", ^tailer}

    append(path, "one\ntwo\n")
    Lines.poll(tailer)
    assert_receive {:lines, "j1", 0, [[100, "one"], [100, "two"]]}

    Agent.update(now, &(&1 + 40))
    append(path, "three\n")
    Lines.poll(tailer)
    assert_receive {:lines, "j1", 2, [[140, "three"]]}
  end

  test "a line waits for its newline, and the last read delivers one that never got it",
       %{tailer: tailer, path: path} do
    append(path, "whole\npart")
    Lines.poll(tailer)
    assert_receive {:lines, "j1", 0, [[100, "whole"]]}

    append(path, "ial")
    Lines.poll(tailer)
    refute_receive {:lines, _job, _from, _lines}, 50

    assert {:ok, [100, 100]} = Lines.finish(tailer)
    assert_receive {:lines, "j1", 1, [[100, "partial"]]}
  end

  test "nothing is sent before the file exists, and a log that ends in a newline has no extra line",
       %{tailer: tailer, path: path} do
    Lines.poll(tailer)
    refute_receive {:lines, _job, _from, _lines}, 50

    append(path, "a\n")
    assert {:ok, [100]} = Lines.finish(tailer)
  end

  test "a batch is at most the batch size, and the indexes run on", %{tailer: tailer, path: path} do
    append(path, "1\n2\n3\n4\n5\n")
    Lines.poll(tailer)

    assert_receive {:lines, "j1", 0, [[_, "1"], [_, "2"], [_, "3"]]}
    assert_receive {:lines, "j1", 3, [[_, "4"], [_, "5"]]}
  end

  test "a secret's value is masked in the line, and not in the file", %{path: path} do
    job_id = ForgeWorker.Fixtures.uuid()
    secrets = sealed_secrets(%{"TOKEN" => "hunter2"}, job_id)

    {:ok, tailer} =
      Lines.start_link(
        job_id: job_id,
        path: path,
        link: self(),
        clock: fn -> 0 end,
        secrets: secrets,
        poll_ms: :infinity
      )

    append(path, "the token is hunter2 today\n")
    Lines.poll(tailer)

    assert_receive {:lines, ^job_id, 0, [[0, "the token is [secret TOKEN] today"]]}
    assert File.read!(path) =~ "hunter2"
  end

  test "bytes that are not text are replaced and a line is cut at 4 KiB, live only",
       %{tailer: tailer, path: path} do
    long = String.duplicate("é", 3_000)
    append(path, <<"bad ", 255, " byte\n">> <> long <> "\n")
    Lines.poll(tailer)

    assert_receive {:lines, "j1", 0, [[_, first], [_, second]]}
    assert first == "bad � byte"
    assert String.valid?(second)
    assert byte_size(second) <= 4096
    assert byte_size(second) > 4090
    assert File.read!(path) =~ <<255>>
  end

  test "a resend says every line again from the first", %{tailer: tailer, path: path} do
    append(path, "a\nb\nc\nd\n")
    Lines.poll(tailer)
    assert_receive {:lines, "j1", 0, _}
    assert_receive {:lines, "j1", 3, _}

    Lines.resend(tailer)
    assert_receive {:lines, "j1", 0, [[_, "a"], [_, "b"], [_, "c"]]}
    assert_receive {:lines, "j1", 3, [[_, "d"]]}
  end

  test "counts lines as the log's own file does" do
    assert Lines.count("") == 0
    assert Lines.count("a\n") == 1
    assert Lines.count("a") == 1
    assert Lines.count("a\n\nb\n") == 3
  end

  test "closing a tailer that is gone is nothing", %{tailer: tailer} do
    assert Lines.close(tailer) == :ok
    assert Lines.close(tailer) == :ok
    assert Lines.close(nil) == :ok
  end

  test "a line cut in the middle of a character is cut before it", %{tailer: tailer, path: path} do
    append(path, String.duplicate("a", 4095) <> "é" <> "\n")
    Lines.poll(tailer)

    assert_receive {:lines, "j1", 0, [[_, line]]}
    assert line == String.duplicate("a", 4095)
  end

  test "its own tick reads the file, and a message it was not sent is ignored",
       %{tailer: tailer, path: path} do
    append(path, "by itself\n")

    send(tailer, :poll)
    send(tailer, :something_else)
    :sys.get_state(tailer)

    assert_receive {:lines, "j1", 0, [[100, "by itself"]]}
  end

  test "it schedules its next read when it is given an interval", %{path: path} do
    {:ok, tailer} =
      Lines.start_link(
        job_id: "j2",
        path: path,
        link: self(),
        clock: fn -> 7 end,
        poll_ms: 5
      )

    append(path, "tick\n")
    assert_receive {:lines, "j2", 0, [[7, "tick"]]}
    assert :ok = Lines.close(tailer)
  end

  test "a partial line is not a line until it ends, even across a resend",
       %{tailer: tailer, path: path} do
    append(path, "one\nhalf")
    Lines.poll(tailer)
    assert_receive {:lines, "j1", 0, [[_, "one"]]}

    Lines.resend(tailer)
    assert_receive {:lines, "j1", 0, [[_, "one"]]}
    refute_receive {:lines, "j1", _from, [[_, "half"]]}, 20
  end

  # What a resend says again is what the platform can hold, so a command that printed more keeps
  # no more than that in memory, and the times of every line are still there for the blob.
  test "keeps only the last lines the platform holds, and resends from the first of them",
       %{tailer: tailer, path: path} do
    cap = ForgeCore.Explore.max_live_lines()
    total = cap + 50
    append(path, Enum.map(0..(total - 1), &["l", Integer.to_string(&1), "\n"]))
    Lines.poll(tailer)
    flush()

    Lines.resend(tailer)
    # The first thing said is from the first line kept, not from 0.
    assert_receive {:lines, "j1", from, [[100, first] | _rest]}
    assert {from, first} == {50, "l50"}

    assert {:ok, times} = Lines.finish(tailer)
    assert length(times) == total
  end

  test "a line that has not ended after 64 KiB is held to 64 KiB, and is still one line when it ends",
       %{tailer: tailer, path: path} do
    append(path, String.duplicate("x", 70 * 1024))
    Lines.poll(tailer)
    refute_receive {:lines, "j1", _from, _lines}, 50

    # What is held while it waits for its newline is the bound: 64 KiB, not the 70 that were written.
    assert byte_size(:sys.get_state(tailer).partial) == 64 * 1024

    append(path, String.duplicate("y", 70 * 1024) <> "\nnext\n")
    Lines.poll(tailer)

    # One line (cut at 4 KiB as every live line is), and the next is number 1: the log has two lines,
    # so the times line up with them.
    assert_receive {:lines, "j1", 0, [[100, text], [100, "next"]]}
    assert byte_size(text) == 4096
    assert {:ok, [100, 100]} = Lines.finish(tailer)
  end

  defp flush do
    receive do
      {:lines, _job, _from, _lines} -> flush()
    after
      0 -> :ok
    end
  end
end
