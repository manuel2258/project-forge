defmodule ForgeCore.CommandStepsTest do
  use ExUnit.Case, async: true

  alias ForgeCore.CommandSteps

  test "the steps are in the order a command takes them, with the remainder last" do
    assert CommandSteps.names() ==
             ~w(snapshot fetch reset own devshell script ignored hand_back keep upload discard sweep other)

    assert Enum.all?(CommandSteps.names(), &(CommandSteps.label(&1) != &1))
    assert CommandSteps.label("mystery") == "mystery"
  end

  test "a skipped step says why, in words, and a build not kept says so" do
    assert CommandSteps.skip_sentence("no_source") == "no copy to start from"
    assert CommandSteps.skip_sentence("not_kept") == "nothing kept"
    assert CommandSteps.skip_sentence("timeout") == "nothing kept: it was stopped by its timeout"
    assert CommandSteps.skip_sentence("mystery") == "mystery"
    assert "status" in CommandSteps.skip_reasons()
  end

  describe "sanitize/1" do
    test "keeps a measured step and a skipped one, and the snapshot's source" do
      assert CommandSteps.sanitize([
               %{"name" => "snapshot", "at" => 5, "ms" => 7, "source" => "copy", "extra" => 1},
               %{"name" => "keep", "at" => 9, "skipped" => "status"},
               %{"name" => "script", "at" => 6, "ms" => 0}
             ]) == [
               %{"name" => "snapshot", "at" => 5, "ms" => 7, "source" => "copy"},
               %{"name" => "keep", "at" => 9, "skipped" => "status"},
               %{"name" => "script", "at" => 6, "ms" => 0}
             ]
    end

    test "drops a name it does not know, a number that is not whole and a skip it cannot say" do
      assert CommandSteps.sanitize([
               %{"name" => "teleport", "ms" => 1},
               %{"name" => "fetch", "ms" => -1},
               %{"name" => "fetch", "ms" => 1.5},
               %{"name" => "fetch", "skipped" => "because"},
               %{"name" => "fetch"},
               "fetch",
               %{"name" => "reset", "at" => -4, "ms" => 3, "source" => "copy"}
             ]) == [%{"name" => "reset", "ms" => 3}]
    end

    test "a skip wins over a duration, so a step that did not happen is never a zero" do
      assert CommandSteps.sanitize([
               %{"name" => "devshell", "at" => 1, "ms" => 0, "skipped" => "no_env"}
             ]) == [%{"name" => "devshell", "at" => 1, "skipped" => "no_env"}]
    end

    test "is bounded, and nil when nothing is left or the report is not a list" do
      many = for _n <- 1..50, do: %{"name" => "fetch", "ms" => 1}
      assert length(CommandSteps.sanitize(many)) == 20
      assert CommandSteps.sanitize([]) == nil
      assert CommandSteps.sanitize([%{"name" => "x"}]) == nil
      assert CommandSteps.sanitize(nil) == nil
      assert CommandSteps.sanitize(%{"name" => "fetch", "ms" => 1}) == nil
    end
  end

  test "the longest step is the one with the most time, and never the remainder" do
    steps = [
      %{"name" => "fetch", "ms" => 10},
      %{"name" => "script", "ms" => 300},
      %{"name" => "keep", "skipped" => "status"},
      %{"name" => "other", "ms" => 900}
    ]

    assert CommandSteps.longest(steps) == "script"
    assert CommandSteps.longest([%{"name" => "keep", "skipped" => "status"}]) == nil
    assert CommandSteps.longest([]) == nil
  end

  test "the total is what the durations add up to, a skip adding nothing" do
    assert CommandSteps.total([
             %{"name" => "fetch", "ms" => 10},
             %{"name" => "keep", "skipped" => "status"},
             %{"name" => "other", "ms" => 5}
           ]) == 15
  end
end
