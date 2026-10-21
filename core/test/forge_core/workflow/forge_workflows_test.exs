defmodule ForgeCore.Workflow.ForgeWorkflowsTest do
  @moduledoc """
  This repository's own workflows, through the real parser and the real import resolver.

  Nothing else in the suite reads `.forge/`: every other test builds a workflow of its own, so an
  edit to the files forge actually runs its tickets on was checked by nobody until a ticket was
  admitted. `WorkerProtocolTest` reads `flake.nix` for the same reason — a fact two files have to
  agree on needs a test that opens both.
  """

  use ExUnit.Case, async: true

  alias ForgeCore.Workflow
  alias ForgeCore.Workflow.{Parser, State}

  @forge Path.expand("../../../../.forge", __DIR__)

  defp read_library(path) do
    case File.read(Path.join(@forge, path)) do
      {:ok, content} -> {:ok, content}
      {:error, _reason} -> :error
    end
  end

  defp workflow(type) do
    yaml = File.read!(Path.join([@forge, "workflows", "#{type}.yml"]))
    Parser.parse!(yaml, read_library: &read_library/1)
  end

  defp types do
    @forge
    |> Path.join("workflows/*.yml")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".yml"))
  end

  test "every workflow this repository runs its tickets on parses" do
    refute types() == []

    for type <- types() do
      assert %Workflow{} = workflow(type), type
    end
  end

  # The ticket this state was built for: a presentation is written before the person deciding sees
  # the page, so `presenting` is on the way to `review_ready` and not beside it. An edge that
  # reached `review_ready` from anywhere else would route past it without failing anything else.
  for type <- ["dev", "bug"] do
    test "a #{type} ticket reaches review only through presenting" do
      workflow = workflow(unquote(type))

      assert for(t <- workflow.transitions, t.to == "review_ready", do: t.from) == ["presenting"]

      presenting = Workflow.state(workflow, "presenting")
      assert Enum.any?(presenting.produces, &Workflow.presentation?/1)
      assert State.optional?(presenting, "presentation.md")
    end
  end
end
