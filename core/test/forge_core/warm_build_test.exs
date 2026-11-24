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
             "size" => 10
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
               "size" => nil
             }

    assert WarmBuild.sanitize(%{"source" => "moon", "kept" => "yes", "unkept" => "x"}) == nil

    assert WarmBuild.sanitize(%{"kept" => false, "unkept" => "nonsense"}) == %{
             "source" => nil,
             "from" => nil,
             "kept" => false,
             "unkept" => nil,
             "size" => nil
           }

    assert WarmBuild.sanitize(%{"kept" => true, "size" => -1}) == %{
             "source" => nil,
             "from" => nil,
             "kept" => true,
             "unkept" => nil,
             "size" => nil
           }

    assert WarmBuild.sanitize(nil) == nil
    assert WarmBuild.sanitize("x") == nil
  end
end
