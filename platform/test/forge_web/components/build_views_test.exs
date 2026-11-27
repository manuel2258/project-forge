defmodule ForgeWeb.BuildViewsTest do
  @moduledoc """
  The words and numbers of a command's steps and log, and the addresses of the explorer
  (`docs/design/ui.md` § The job page, § The explorer): the rules that need no page to be seen.
  """

  use ExUnit.Case, async: true

  alias ForgeWeb.BuildViews

  describe "log_rows/2" do
    test "marks a silence of ten seconds or more, and not one of nine" do
      rows =
        BuildViews.log_rows([{0, "a"}, {9_000, "b"}, {19_000, "c"}, {61_000, "d"}])

      assert Enum.map(rows, & &1.silence) == [nil, nil, 10_000, 42_000]
    end

    test "opens a minute at the first row of it, for a phone's divider" do
      rows =
        BuildViews.log_rows([
          {0, "a"},
          {59_999, "b"},
          {60_000, "c"},
          {61_000, "d"},
          {180_000, "e"}
        ])

      assert Enum.map(rows, & &1.minute) == ["+0 min", nil, "+1 min", nil, "+3 min"]
    end

    test "numbers the rows from where the page starts" do
      assert [%{n: 1_000}, %{n: 1_001}] = BuildViews.log_rows([{1, "a"}, {2, "b"}], 1_000)
    end

    test "says nothing of time for a line that has none" do
      rows = BuildViews.log_rows([{nil, "a"}, {nil, "b"}])
      assert Enum.all?(rows, &(&1.ms == nil and &1.minute == nil and &1.silence == nil))
    end

    test "a line with no time does not break the silence that follows a timed one" do
      rows = BuildViews.log_rows([{0, "a"}, {nil, "b"}, {20_000, "c"}])
      assert Enum.map(rows, & &1.silence) == [nil, nil, 20_000]
    end
  end

  test "a silence is said in seconds, and in minutes once it is long" do
    assert BuildViews.silence(10_000) == "+10 s"
    assert BuildViews.silence(42_900) == "+42 s"
    assert BuildViews.silence(200_000) == "+3 min 20 s"
  end

  test "a time since the command started" do
    assert BuildViews.since(12_345) == "12.3 s"
    assert BuildViews.since(125_000) == "2:05"
    assert BuildViews.since(3_725_000) == "1:02:05"
  end

  test "a duration" do
    assert BuildViews.ms_label(40) == "40 ms"
    assert BuildViews.ms_label(1_200) == "1.2 s"
    assert BuildViews.ms_label(184_000) == "3 min 4 s"
    assert BuildViews.ms_label(3_900_000) == "1 h 5 min"
  end

  test "a size in the units a truncated file's sentence uses" do
    assert BuildViews.iec(1_048_576) == "1 MiB"
    assert BuildViews.iec(41_943_040) == "40 MiB"
    assert BuildViews.iec(512) == "512 B"
  end

  describe "text drawn from bytes" do
    test "replaces what is not valid text, and NUL" do
      assert BuildViews.shown(<<"a", 0xFF, "b", 0, "c">>) == "a�b�c"
      assert BuildViews.shown(nil) == ""
    end
  end

  describe "the path in an address" do
    test "text goes as `path`, bytes that are not text as `path64`, the root as nothing" do
      assert BuildViews.path_query("") == []
      assert BuildViews.path_query("a/b") == [path: "a/b"]
      assert [path64: encoded] = BuildViews.path_query(<<0xFF, 0xFE>>)
      assert Base.url_decode64!(encoded, padding: false) == <<0xFF, 0xFE>>
    end

    test "is read back from either, and refused as nil when it is neither" do
      assert BuildViews.path_param(%{}) == ""
      assert BuildViews.path_param(%{"path" => "a/b"}) == "a/b"

      assert BuildViews.path_param(%{"path64" => Base.url_encode64(<<255>>, padding: false)}) ==
               <<255>>

      assert BuildViews.path_param(%{"path64" => "!!"}) == nil
      assert BuildViews.path_param(%{"path" => ["a"]}) == nil
    end

    test "the parent of a path" do
      assert BuildViews.parent("a/b/c") == "a/b"
      assert BuildViews.parent("a") == ""
    end
  end
end
