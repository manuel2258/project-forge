defmodule Forge.Jobs.LinesTest do
  @moduledoc """
  The live lines of a running command (`Forge.Jobs.Lines`): held in memory, in order, once each,
  bounded, dropped after the command ends, and never an event.
  """

  use ExUnit.Case, async: false

  alias Forge.Jobs.Lines

  setup do
    job_id = Ecto.UUID.generate()
    on_exit(fn -> Lines.drop(job_id) end)
    %{job: job_id}
  end

  test "lines are held in order with their times, and nothing is held for a command with none",
       %{job: job} do
    assert Lines.all(job) == nil

    Lines.put(job, 0, [[5, "first"], [9, "second"]])
    Lines.put(job, 2, [[12, "third"]])

    assert %{first: 0, total_seen: 3, lines: [[5, "first"], [9, "second"], [12, "third"]]} =
             Lines.all(job)
  end

  test "a line it already holds is dropped, so a worker that sends again from the first adds nothing",
       %{job: job} do
    Lines.subscribe(job)
    Lines.put(job, 0, [[1, "a"], [2, "b"]])
    assert_receive {:command_lines, ^job, 0, [[1, "a"], [2, "b"]]}

    Lines.put(job, 0, [[1, "a"], [2, "b"], [3, "c"]])

    assert_receive {:command_lines, ^job, 2, [[3, "c"]]}
    assert %{total_seen: 3, lines: [[1, "a"], [2, "b"], [3, "c"]]} = Lines.all(job)

    Lines.put(job, 0, [[1, "a"]])
    refute_receive {:command_lines, ^job, _, _}, 50
  end

  test "an entry that is not a line ends the batch, since every later number would be wrong",
       %{job: job} do
    Lines.put(job, 0, [[1, "ok"], "junk", [3, "never"]])
    Lines.put(job, 5, [[-1, "negative"]])
    Lines.put(job, 5, [[1, 7]])

    assert %{total_seen: 1, lines: [[1, "ok"]]} = Lines.all(job)
  end

  test "text that is not UTF-8 is replaced and a line is cut", %{job: job} do
    Lines.put(job, 0, [[1, <<"a", 255, "b">>], [2, String.duplicate("x", 20_000)]])

    assert %{lines: [[1, first], [2, second]]} = Lines.all(job)
    assert String.valid?(first)
    assert first =~ "a"
    assert byte_size(second) == 8_192
  end

  test "past the cap the oldest go, and the page is told where the held ones start", %{job: job} do
    max = Lines.max_lines()
    batch = for n <- 0..(max + 9), do: [n, "line #{n}"]
    Lines.put(job, 0, batch)

    assert %{first: 10, total_seen: total, lines: lines} = Lines.all(job)
    assert total == max + 10
    assert length(lines) == max
    assert hd(lines) == [10, "line 10"]
  end

  test "the cap is 20,000 lines, whatever the module says it is", %{job: job} do
    # Written out: a test that asked `max_lines/0` would follow the constant it is checking.
    Lines.put(job, 0, for(n <- 0..20_499, do: [n, "l#{n}"]))

    assert %{first: 500, total_seen: 20_500, lines: lines} = Lines.all(job)
    assert length(lines) == 20_000
    assert hd(lines) == [500, "l500"]
    assert Lines.max_lines() == 20_000
  end

  test "a worker that dropped its oldest lines resumes from the first it has, however far ahead",
       %{job: job} do
    Lines.subscribe(job)

    # A restarted platform holds nothing; the worker sends from the first line it kept.
    Lines.put(job, 10_000, [[1, "ten thousand"], [2, "next"]])

    assert_receive {:command_lines, ^job, 10_000, [[1, "ten thousand"], [2, "next"]]}
    assert %{first: 10_000, total_seen: 10_002, lines: [[1, _], [2, _]]} = Lines.all(job)

    # A long disconnect: more than the cap was printed while the worker was away, and it resumes from
    # the first line it kept, past the cap from what is held. It is believed, and what is held starts
    # there, so the lines after it are heard too (they once were refused for the rest of the run).
    cap = Lines.max_lines()
    Lines.put(job, 10_002 + cap + 1, [[3, "far ahead"]])
    assert %{first: first, total_seen: total, lines: [[3, "far ahead"]]} = Lines.all(job)
    assert first == 10_002 + cap + 1
    assert total == first + 1

    Lines.put(job, total, [[4, "and on"]])
    assert %{total_seen: after_it, lines: [[3, _], [4, "and on"]]} = Lines.all(job)
    assert after_it == total + 1
  end

  test "a restarted platform believes the line a long-running command's worker resumes from",
       %{job: job} do
    # More than twice the cap printed before the platform restarted: the worker has kept the last
    # 20,000 and sends from line 80,000, a gap that is far past the cap but is all there is to hold.
    Lines.put(job, 80_000, [[1, "eighty thousand"]])
    assert %{first: 80_000, total_seen: 80_001} = Lines.all(job)

    # A number nobody printed that many lines to reach is still no line.
    other = Ecto.UUID.generate()
    on_exit(fn -> Lines.drop(other) end)
    {micros, :ok} = :timer.tc(fn -> Lines.put(other, 1_000_000_000_001, [[1, "far"]]) end)
    assert micros < 1_000_000
    assert %{lines: [], total_seen: 0} = Lines.all(other)
  end

  test "a batch that starts past what is held is dropped, and a stray number costs nothing",
       %{job: job} do
    Lines.put(job, 0, [[1, "a"]])

    {micros, :ok} =
      :timer.tc(fn -> Lines.put(job, 1_000_000_000_000, [[2, "far"], [3, "off"]]) end)

    # A number past the furthest believed moves nothing, and the next ordinary line is still number 1.
    assert micros < 1_000_000
    assert %{first: 0, total_seen: 1, lines: [[1, "a"]]} = Lines.all(job)

    Lines.put(job, 1, [[4, "b"]])
    assert %{total_seen: 2, lines: [[1, "a"], [4, "b"]]} = Lines.all(job)

    # Another command's put is not held up by it.
    other = Ecto.UUID.generate()
    on_exit(fn -> Lines.drop(other) end)
    assert :ok = Lines.put(other, 0, [[1, "fine"]])
    assert %{total_seen: 1} = Lines.all(other)
  end

  test "dropping a command's lines leaves another's", %{job: job} do
    other = Ecto.UUID.generate()
    on_exit(fn -> Lines.drop(other) end)
    Lines.put(job, 0, [[1, "mine"]])
    Lines.put(other, 0, [[1, "theirs"]])

    Lines.drop(job)

    assert Lines.all(job) == nil
    assert %{lines: [[1, "theirs"]]} = Lines.all(other)
  end

  test "they are dropped after the command ends", %{job: job} do
    previous = Application.get_env(:forge, :command_lines_drop_ms)
    Application.put_env(:forge, :command_lines_drop_ms, 20)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:forge, :command_lines_drop_ms, previous),
        else: Application.delete_env(:forge, :command_lines_drop_ms)
    end)

    Lines.put(job, 0, [[1, "x"]])
    Lines.drop_later(job)

    assert wait_until(fn -> Lines.all(job) == nil end)
  end

  test "a batch that is not a list, or a start that is not a number, holds nothing", %{job: job} do
    Lines.put(job, 0, "lines")
    Lines.put(job, -1, [[1, "x"]])
    Lines.put(job, "0", [[1, "x"]])
    assert Lines.all(job) == nil
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && wait_until(fun, attempts - 1)
    end
  end
end
