defmodule ForgeCore.WarmBuildTest do
  use ExUnit.Case, async: true

  alias ForgeCore.WarmBuild

  test "every source has a phrase and a first line, and a word that is not one has neither" do
    assert Enum.map(WarmBuild.sources(), &WarmBuild.source_phrase/1) == [
             "this ticket's warm build",
             "the ticket's volume",
             "the project's seed",
             "a fresh clone"
           ]

    assert WarmBuild.source_phrase("elsewhere") == nil

    assert WarmBuild.source_line("copy", "job-7") ==
             "forge: started from this ticket's warm build, left by job job-7"

    assert WarmBuild.source_line("ticket", nil) == "forge: started from the ticket's volume"
    assert WarmBuild.source_line("seed", nil) == "forge: started from the project's seed"
    assert WarmBuild.source_line("clone", nil) == "forge: started from a fresh clone"
  end

  test "every reason has its own sentence" do
    sentences = Enum.map(WarmBuild.reasons(), &WarmBuild.reason_sentence/1)
    assert sentences == Enum.uniq(sentences)
    assert WarmBuild.reason_sentence("mystery") == "mystery"
  end

  test "the last line says kept, or not and why" do
    assert WarmBuild.kept_line(true, nil) == "forge: kept this build as the ticket's warm build"

    assert WarmBuild.kept_line(false, "timeout") ==
             "forge: did not keep this build as the ticket's warm build: " <>
               "it was stopped by its timeout"
  end

  test "the two sentences a person reads are exact" do
    assert WarmBuild.wait_sentence() ==
             "Waiting for the machine that holds this ticket's warm build: up to two minutes, " <>
               "then any machine with room."

    assert WarmBuild.no_copy_sentence() ==
             "No warm build yet: the first command that keeps its build leaves one."
  end

  test "sanitize keeps what it knows and drops what it does not" do
    assert WarmBuild.sanitize(%{
             "source" => "copy",
             "from" => "j1",
             "kept" => true,
             "unkept" => "timeout",
             "size" => 10,
             "extra" => 1
           }) == %{
             "source" => "copy",
             "from" => "j1",
             "kept" => true,
             "unkept" => nil,
             "size" => 10,
             "folders" => nil
           }

    assert WarmBuild.sanitize(%{
             "source" => "seed",
             "from" => "j1",
             "kept" => false,
             "unkept" => "status",
             "size" => 4
           }) ==
             %{
               "source" => "seed",
               "from" => nil,
               "kept" => false,
               "unkept" => "status",
               "size" => nil,
               "folders" => nil
             }

    assert WarmBuild.sanitize(%{"source" => "moon", "kept" => "yes", "unkept" => "x"}) == nil

    assert WarmBuild.sanitize(%{"kept" => false, "unkept" => "nonsense"}) == %{
             "source" => nil,
             "from" => nil,
             "kept" => false,
             "unkept" => nil,
             "size" => nil,
             "folders" => nil
           }

    assert WarmBuild.sanitize(%{"kept" => true, "size" => -1}) == %{
             "source" => nil,
             "from" => nil,
             "kept" => true,
             "unkept" => nil,
             "size" => nil,
             "folders" => nil
           }

    assert WarmBuild.sanitize(nil) == nil
    assert WarmBuild.sanitize("x") == nil
  end

  describe "the sizes of the ignored folders" do
    test "are kept for a kept build, bounded, and dropped for one that is not" do
      folders = %{
        "folders" => [
          %{"path" => "target", "bytes" => 9},
          %{"path_base64" => Base.encode64(<<255, 1>>), "bytes" => 3}
        ],
        "more" => %{"count" => 2, "bytes" => 5},
        "loose" => %{"count" => 1, "bytes" => 1},
        "rest" => 7
      }

      assert WarmBuild.sanitize(%{"kept" => true, "size" => 25, "folders" => folders})["folders"] ==
               folders

      assert WarmBuild.sanitize(%{"kept" => false, "unkept" => "status", "folders" => folders})[
               "folders"
             ] == nil
    end

    test "never hold more than the cap, nor a path that is empty, or a size that is not a count" do
      many = for n <- 1..60, do: %{"path" => "d#{n}", "bytes" => n}

      cleaned =
        WarmBuild.folders(%{
          "folders" =>
            [
              %{"path" => "", "bytes" => 1},
              %{"path" => "x", "bytes" => -1},
              %{"path" => "y", "bytes" => "1"},
              %{"path_base64" => "not base64!", "bytes" => 1},
              %{"path" => <<255>>, "bytes" => 1}
            ] ++ many,
          "more" => %{"count" => -1, "bytes" => 1},
          "rest" => "lots"
        })

      assert length(cleaned["folders"]) == WarmBuild.max_folders()
      assert Enum.all?(cleaned["folders"], &(&1["path"] =~ ~r/\Ad\d+\z/))
      assert cleaned["more"] == %{"count" => 0, "bytes" => 0}
      assert cleaned["loose"] == %{"count" => 0, "bytes" => 0}
      assert cleaned["rest"] == 0
    end

    test "are nil for anything that is not a record, and the missing record has a sentence" do
      assert WarmBuild.folders(nil) == nil
      assert WarmBuild.folders(%{"folders" => "x"}) == nil
      assert WarmBuild.no_folders_sentence() == "kept by a release that saved no folder sizes"
    end
  end
end
