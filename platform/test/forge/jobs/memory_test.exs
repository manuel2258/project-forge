defmodule Forge.Jobs.MemoryTest do
  @moduledoc """
  Whether memory was a job's trouble, and the words for it (`docs/design/capacity.md` § Memory,
  which a job holds rather than spends): which events count, which trouble is the worst, and what
  a figure the worker sent that is not one does to the line — nothing.
  """

  use ExUnit.Case, async: true

  alias Forge.Events.Event
  alias Forge.Jobs.Memory

  @gib 1024 ** 3

  defp memory(what, fields \\ %{}) do
    %Event{
      type: "job.harness.memory",
      payload:
        Map.merge(
          %{"what" => what, "ceiling" => 2 * @gib, "peak" => @gib, "oom_kills" => 0},
          fields
        )
    }
  end

  defp finished(memory),
    do: %Event{type: "job.finished", payload: %{"harness" => %{"memory" => memory}}}

  defp turn(memory), do: %Event{type: "chat.turn", payload: %{"turn" => 1, "memory" => memory}}

  describe "trouble/1" do
    test "is nil for a job whose memory was fine" do
      assert Memory.trouble([]) == nil

      # Read and fine: a run that ended with a peak and no kill, a turn the same.
      quiet = %{"ceiling" => 2 * @gib, "peak" => @gib, "oom_kills" => 0}
      assert Memory.trouble([finished(quiet), turn(quiet)]) == nil
      assert Memory.trouble([%Event{type: "job.harness.text", payload: %{"text" => "hi"}}]) == nil
    end

    test "an OOM kill is the worst, with every kill counted and the highest peak" do
      events = [
        memory("ceiling", %{"peak" => 2 * @gib}),
        memory("pressure", %{"pressure" => 40.0}),
        memory("oom_kill", %{"oom_kills" => 1, "new_kills" => 1}),
        memory("oom_kill", %{"oom_kills" => 2, "new_kills" => 1, "peak" => @gib})
      ]

      assert Memory.trouble(events) ==
               %{what: :oom_kill, oom_kills: 2, peak: 2 * @gib, ceiling: 2 * @gib}
    end

    test "thrashing outranks only having reached the ceiling" do
      assert %{what: :pressure} =
               Memory.trouble([memory("ceiling"), memory("pressure"), memory("ceiling")])

      assert %{what: :ceiling, oom_kills: 0} = Memory.trouble([memory("ceiling")])
    end

    # A harness killed for memory takes its cgroup with it, and the kill no sample saw is on the
    # summary the run ended with — or a turn's.
    test "counts a kill that only a run's or a turn's summary reports" do
      killed = %{"ceiling" => 2 * @gib, "peak" => 2 * @gib, "oom_kills" => 1}

      assert %{what: :oom_kill, oom_kills: 1, peak: 2_147_483_648} =
               Memory.trouble([finished(killed)])

      assert %{what: :oom_kill, oom_kills: 3} =
               Memory.trouble([turn(%{killed | "oom_kills" => 3}), memory("ceiling")])
    end

    # The worker wrote every figure.
    test "a figure that is not a number of bytes is left out, not raised on" do
      events = [
        memory("oom_kill", %{"oom_kills" => "many", "peak" => "lots", "ceiling" => 0}),
        memory("ceiling", %{"peak" => -1, "ceiling" => "2G"}),
        memory("something new", %{"peak" => @gib, "ceiling" => nil})
      ]

      assert Memory.trouble(events) == %{what: :ceiling, oom_kills: 0, peak: @gib, ceiling: nil}

      assert Memory.trouble([memory("something new", %{"oom_kills" => 1})]) |> Map.get(:what) ==
               :oom_kill
    end
  end

  describe "words/1" do
    test "says the trouble, then the peak against the ceiling" do
      assert Memory.words(%{what: :oom_kill, oom_kills: 2, peak: 2 * @gib, ceiling: 2 * @gib}) ==
               "2 OOM kills · peak 2.0 GiB of 2 GiB"

      assert Memory.words(%{what: :oom_kill, oom_kills: 1, peak: @gib, ceiling: 2 * @gib}) ==
               "1 OOM kill · peak 1.0 GiB of 2 GiB"

      assert Memory.words(%{what: :pressure, oom_kills: 0, peak: 2 * @gib, ceiling: 2 * @gib}) ==
               "thrashing at its ceiling · peak 2.0 GiB of 2 GiB"

      assert Memory.words(%{
               what: :ceiling,
               oom_kills: 0,
               peak: 2 * @gib,
               ceiling: 2210 * 1024 ** 2
             }) ==
               "reached its ceiling · peak 2.0 GiB of 2210 MiB"
    end

    test "says what figures it has, and no more" do
      assert Memory.words(%{what: :ceiling, oom_kills: 0, peak: @gib, ceiling: nil}) ==
               "reached its ceiling · peak 1.0 GiB"

      assert Memory.words(%{what: :oom_kill, oom_kills: 1, peak: nil, ceiling: 2 * @gib}) ==
               "1 OOM kill"
    end
  end

  describe "sentence/1" do
    test "says each event as a sentence" do
      assert Memory.sentence(memory("oom_kill", %{"oom_kills" => 1}).payload) ==
               "a process was killed for memory (1 OOM kill · peak 1.0 GiB of 2 GiB)"

      assert Memory.sentence(memory("ceiling").payload) ==
               "reached its memory ceiling (peak 1.0 GiB of 2 GiB)"

      assert Memory.sentence(memory("pressure", %{"pressure" => 35.25}).payload) ==
               "thrashing at its memory ceiling (full pressure 35.3% · peak 1.0 GiB of 2 GiB)"

      assert Memory.sentence(%{"what" => "ceiling"}) == "reached its memory ceiling"
      assert Memory.sentence(%{"what" => "new", "peak" => @gib}) == "memory: new (peak 1.0 GiB)"
      assert Memory.sentence(%{}) == "memory: ?"
    end
  end

  describe "snapshot/1" do
    # 2026-09-29's first chat: a ceiling of two bytes, and a job that could not exec in it.
    test "says what the job holds against its ceiling, and any pressure or kill" do
      assert Memory.snapshot(%{"current" => 0, "ceiling" => 2, "pressure" => 100.0}) ==
               "memory 0.0 GiB of 2 B · full pressure 100.0%"

      assert Memory.snapshot(%{"current" => @gib, "ceiling" => 2 * @gib, "pressure" => 0.0}) ==
               "memory 1.0 GiB of 2 GiB"

      assert Memory.snapshot(%{"current" => @gib, "oom_kills" => 2}) ==
               "memory 1.0 GiB · 2 OOM kills"
    end

    test "is nil with nothing read" do
      assert Memory.snapshot(nil) == nil
      assert Memory.snapshot(%{}) == nil
      assert Memory.snapshot(%{"current" => "x", "pressure" => "y"}) == nil
    end
  end
end
