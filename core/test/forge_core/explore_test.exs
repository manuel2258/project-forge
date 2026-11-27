defmodule ForgeCore.ExploreTest do
  use ExUnit.Case, async: true

  alias ForgeCore.Explore

  test "the limits are the ones the refinement fixed" do
    assert Explore.page_size() == 200
    assert Explore.text_limit() == 1024 * 1024
    assert Explore.hold_ms() == 10 * 60 * 1000
    assert Explore.answer_ms() == 15_000
    assert Explore.max_live_lines() == 20_000
    assert Explore.ops() == ~w(list file hash download)
  end

  test "every error word has its own sentence, and a word it does not know is its own" do
    sentences = Enum.map(Explore.errors(), &Explore.sentence/1)
    assert sentences == Enum.uniq(sentences)
    assert Explore.sentence(:machine_not_answering) == "The machine did not answer in 15 seconds"
    assert Explore.sentence("mystery") == "mystery"
    assert Explore.worker_errors() -- Explore.errors() == []
  end

  describe "path_ok?/1" do
    test "accepts the root and a path of plain components" do
      assert Explore.path_ok?("")
      assert Explore.path_ok?("a")
      assert Explore.path_ok?("a/b c/.hidden/..x")
    end

    test "refuses .., ., an empty component, an absolute path and a NUL" do
      for path <- ["..", "a/../b", "/a", "a//b", "a/", ".", "a/./b", "a\0b", "../x", "a/.."] do
        refute Explore.path_ok?(path), inspect(path)
      end
    end

    test "refuses what is not a string" do
      refute Explore.path_ok?(nil)
      refute Explore.path_ok?(["a"])
    end
  end

  test "a path's components" do
    assert Explore.components("") == []
    assert Explore.components("a/b") == ["a", "b"]
  end
end
