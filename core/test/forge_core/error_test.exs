defmodule ForgeCore.ErrorTest do
  @moduledoc """
  Errors are how a workflow or a document tells a person what is wrong with it, so the shape of
  the line matters. `join/2`'s root case was covered; `format/1`'s was not, and the two are the
  same rule at the two ends of the same path.
  """

  use ExUnit.Case, async: true

  alias ForgeCore.Error

  describe "join/2" do
    test "omits the dot at the root" do
      assert Error.join("", "states") == "states"
    end

    test "indexes a list with brackets and nests with a dot" do
      assert Error.join("states", "refining") == "states.refining"
      assert Error.join("question", 0) == "question[0]"
      assert Error.join("states.refining", "budget") == "states.refining.budget"
    end
  end

  describe "format/1" do
    # An error about the document as a whole has no path, and must not be rendered with a bare
    # leading colon. `Parser.parse!/2` on invalid YAML raises with exactly this line, so the
    # failure is visible to whoever is being told their workflow will not parse.
    test "an error at the root is its message, with nothing in front of it" do
      assert Error.format([Error.new("", "invalid YAML: unexpected end")]) ==
               "invalid YAML: unexpected end"
    end

    test "an error with a path names it first" do
      assert Error.format([
               Error.new("states.refining.budget.cost", "must be a non-negative number")
             ]) ==
               "states.refining.budget.cost: must be a non-negative number"
    end

    # An error about part of a definition a library supplied: the path is into the library, and a
    # line that did not say so would send the reader to a file that does not contain it.
    test "an error from a library names the library first" do
      error = %{
        Error.new("states.implementing.budget.turns", "must be positive")
        | file: "common.yml"
      }

      assert Error.format([error]) ==
               "common.yml: states.implementing.budget.turns: must be positive"

      assert Error.format([%{Error.new("", "invalid YAML: x") | file: "common.yml"}]) ==
               "common.yml: invalid YAML: x"
    end

    test "one line per error, in the order given" do
      assert Error.format([Error.new("version", "is required"), Error.new("", "and one more")]) ==
               "version: is required\nand one more"
    end

    test "nothing wrong is nothing said" do
      assert Error.format([]) == ""
    end
  end

  describe "to_text/1" do
    test "errors are their formatted lines" do
      assert Error.to_text([Error.new("a", "is wrong"), Error.new("b", "too")]) ==
               "a: is wrong\nb: too"
    end

    test "text is itself, and anything else is inspected" do
      assert Error.to_text("is not UTF-8") == "is not UTF-8"
      assert Error.to_text({:parse_error, [:x]}) == "{:parse_error, [:x]}"
    end
  end
end
