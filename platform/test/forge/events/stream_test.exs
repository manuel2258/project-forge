defmodule Forge.Events.StreamTest do
  @moduledoc """
  A job's stream read from the database (`Forge.Events.Stream`): the newest page below a position, a
  call and its result one entry whichever pages they fall on, a result with no call never paired
  (SQL `=` and `ForgeWeb.WorkScreen.entries/2` must agree), and the figures a page is headed by
  counted where they are.
  """

  use Forge.DataCase, async: true

  import Forge.ForgeFixtures

  alias Forge.Events
  alias Forge.Events.Stream

  setup do
    %{job: job_fixture()}
  end

  defp record(job, type, payload) do
    {:ok, event} =
      Events.append(type, {:job, job.id}, %{
        job_id: job.id,
        ticket_id: job.ticket_id,
        payload: payload
      })

    event
  end

  defp say(job, text), do: record(job, "job.harness.text", %{"text" => text})
  defp call(job, id), do: record(job, "job.harness.tool_use", %{"id" => id, "name" => "Bash"})

  defp result(job, id, error? \\ false),
    do: record(job, "job.harness.tool_result", %{"tool_use_id" => id, "is_error" => error?})

  defp seqs(%{events: events}), do: Enum.map(events, & &1.seq)

  describe "page/4" do
    test "is the newest `limit` entries in `seq` order, and says whether older ones wait", %{
      job: job
    } do
      events = for n <- 1..7, do: say(job, "#{n}")

      assert %{more: true} = page = Stream.page(job.id, nil, 3, false)
      assert seqs(page) == events |> Enum.take(-3) |> Enum.map(& &1.seq)

      assert %{more: false} = all = Stream.page(job.id, nil, 7, false)
      assert length(all.events) == 7
      assert %{events: [], more: false} = Stream.page(job.id, 1, 3, false)
    end

    test "below a position reads only what is older than it", %{job: job} do
      events = for n <- 1..10, do: say(job, "#{n}")
      before = Enum.at(events, 6).seq

      page = Stream.page(job.id, before, 3, false)

      assert seqs(page) == events |> Enum.slice(3, 3) |> Enum.map(& &1.seq)
      assert page.more
    end

    test "leaves out notices unless they are shown", %{job: job} do
      one = say(job, "one")
      notice = record(job, "job.harness.notice", %{"subtype" => "plugin_install"})
      two = say(job, "two")

      assert seqs(Stream.page(job.id, nil, 10, false)) == [one.seq, two.seq]
      assert seqs(Stream.page(job.id, nil, 10, true)) == [one.seq, notice.seq, two.seq]
    end

    test "never reads the unlisted", %{job: job} do
      one = say(job, "one")
      record(job, "job.archive_read", %{})
      assert seqs(Stream.page(job.id, nil, 10, true)) == [one.seq]
    end

    # A result whose call is on an older page is read with the call, and the call's page reads the
    # result wherever it is.
    test "a result goes with its call's page, and is not read on a page the call is not on", %{
      job: job
    } do
      call = call(job, "c1")
      between = for n <- 1..4, do: say(job, "between #{n}")
      result = result(job, "c1")
      after_it = for n <- 1..3, do: say(job, "after #{n}")

      # The newest three entries are after the result: the result is no entry and not read.
      newest = Stream.page(job.id, nil, 3, false)
      assert seqs(newest) == Enum.map(after_it, & &1.seq)

      # Four entries down: back across the result, which sits above the call, not below: the page
      # that reaches the call has the result, though the result is above the position it was asked
      # below.
      older = Stream.page(job.id, hd(after_it).seq, 5, false)

      assert older.events |> Enum.map(& &1.seq) |> Enum.sort() ==
               Enum.sort([call.seq, result.seq | Enum.map(between, & &1.seq)])

      # Asked below the result, the call's page still brings the result from above the position.
      below = Stream.page(job.id, result.seq, 5, false)
      assert call.seq in seqs(below)
      assert result.seq in seqs(below)
    end

    # The result is above the range's oldest entry and its call below it: it is the call's page's.
    test "a result above the range whose call is below it is not read with the range", %{job: job} do
      call = call(job, "c1")
      older = say(job, "older")
      oldest_kept = say(job, "oldest kept")
      result = result(job, "c1")
      newest = say(job, "newest")

      page = Stream.page(job.id, nil, 2, false)

      assert seqs(page) == [oldest_kept.seq, newest.seq]
      assert page.more
      refute result.seq in seqs(page)
      assert call.seq < older.seq
    end

    test "a result with no call, or no call id, is an entry of its own", %{job: job} do
      lost = result(job, "never-called")
      no_id = record(job, "job.harness.tool_result", %{"is_error" => false})
      unnamed = record(job, "job.harness.tool_use", %{"name" => "Bash"})

      assert seqs(Stream.page(job.id, nil, 10, false)) == [lost.seq, no_id.seq, unnamed.seq]
      assert Stream.count(job.id) == 3
    end
  end

  describe "from/3 and newer/4" do
    test "from reads everything up from a position, and whether anything is older", %{job: job} do
      events = for n <- 1..5, do: say(job, "#{n}")

      assert %{more: true} = from = Stream.from(job.id, Enum.at(events, 2).seq, false)
      assert seqs(from) == events |> Enum.drop(2) |> Enum.map(& &1.seq)
      assert %{more: false} = Stream.from(job.id, hd(events).seq, false)
    end

    test "newer is what arrived above what is held, a result of an older call left to its page",
         %{
           job: job
         } do
      old_call = call(job, "old")
      held = say(job, "held")
      newest = say(job, "newest")
      stray = result(job, "old")

      assert Enum.map(Stream.newer(job.id, held.seq, held.seq, false), & &1.seq) == [newest.seq]

      # Held back to the call, its result is what it is waiting for.
      assert Enum.map(Stream.newer(job.id, held.seq, old_call.seq, false), & &1.seq) ==
               [newest.seq, stray.seq]
    end
  end

  describe "the figures" do
    test "count is entries without notices, a call and its result one, a lone result one", %{
      job: job
    } do
      call(job, "b1")
      result(job, "b1")
      notice = record(job, "job.harness.notice", %{"subtype" => "plugin_install"})
      result(job, "lost")
      say(job, "words")

      assert Stream.count(job.id) == 3
      # How many, and the newest of them: not the newest event, which `say` and `result` moved.
      assert Stream.notice_figures(job.id) == {1, notice.seq}
      assert Stream.notice_figures(job_fixture().id) == {0, 0}
      assert Stream.raw_count(job.id) == 5
    end

    test "failures counts a call whose result is an error, and an event that ends in error", %{
      job: job
    } do
      assert Stream.failures(job.id) == {0, nil}

      call(job, "ok")
      result(job, "ok")
      bad = call(job, "bad")
      result(job, "bad", true)
      error = record(job, "job.harness.error", %{})
      worse = call(job, "worse")
      result(job, "worse", true)
      lonely = result(job, "lonely", true)

      # A lone failing result has no call to stand at; it is not counted as an entry's failure.
      assert Stream.failures(job.id) == {3, bad.seq}
      assert error.seq < worse.seq and lonely.seq > worse.seq
    end

    test "call_exists? never matches a missing id", %{job: job} do
      call(job, "c1")
      assert Stream.call_exists?(job.id, "c1")
      refute Stream.call_exists?(job.id, "c2")
    end

    test "latest_todo is the newest TodoWrite, a subagent's apart", %{job: job} do
      assert Stream.latest_todo(job.id, false) == nil

      record(job, "job.harness.tool_use", %{"id" => "a", "name" => "TodoWrite"})
      top = record(job, "job.harness.tool_use", %{"id" => "b", "name" => "TodoWrite"})

      sub =
        record(job, "job.harness.tool_use", %{
          "id" => "c",
          "name" => "TodoWrite",
          "parent_tool_use_id" => "t"
        })

      assert Stream.latest_todo(job.id, false).seq == sub.seq
      assert Stream.latest_todo(job.id, true).seq == top.seq
    end
  end

  describe "the raw log" do
    test "pages every listed event, nothing paired and nothing hidden", %{job: job} do
      events = for n <- 1..6, do: say(job, "#{n}")
      record(job, "job.harness.notice", %{})

      assert %{more: true} = page = Stream.raw_page(job.id, nil, 3)
      assert length(page.events) == 3
      assert %{more: false} = Stream.raw_page(job.id, nil, 7)
      assert seqs(Stream.raw_from(job.id, Enum.at(events, 4).seq)) |> length() == 3
      assert Stream.raw_from(job.id, hd(events).seq).more == false
    end
  end
end
