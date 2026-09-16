defmodule ForgeCore.WorkflowTest do
  @moduledoc """
  What `ForgeCore.Workflow` serves as documents, and what it answers about a parsed definition.

  The documents half is the part that had nothing checking it. `docs/design/workflow-grammar-v1.md`
  opens by saying "This file is compiled into the release … and serves it as `grammar/0`", the
  whole justification being that a copy "would drift from the validator the first time either
  changed". Nothing asserted the served bytes were that file, so the note's claim rested on
  itself.
  """

  use ExUnit.Case, async: true

  alias ForgeCore.Workflow

  describe "the names ticket proposals reserve" do
    # The prefix is the discriminator: a job-scoped artifact is a proposal because its name
    # carries it, and nothing else says so. `proposal_artifact/1` and `proposal?/1` moving apart
    # would mean proposals written under one name and looked for under another, which shows up
    # as no proposals at all rather than as an error.
    test "a stored proposal is recognised as one" do
      assert Workflow.proposal_artifact("score-table.md") |> Workflow.proposal?()
    end

    test "the agent's own filename survives the prefixing" do
      assert Workflow.proposal_artifact("score-table.md") =~ "score-table.md"
    end

    test "an ordinary artifact name is not a proposal" do
      refute Workflow.proposal?("plan.md")
      refute Workflow.proposal?(Workflow.ticket_artifact())
      refute Workflow.proposal?(Workflow.changeset_artifact())
    end

    # Both are path segments the platform writes into a job directory, so a name that collided
    # with something already there would overwrite it.
    test "the two directories are distinct single path segments" do
      for dir <- [Workflow.proposals_dir(), Workflow.tickets_dir()] do
        assert dir != ""
        refute String.contains?(dir, "/")
      end

      refute Workflow.proposals_dir() == Workflow.tickets_dir()
    end
  end

  describe "the documents handed to an agent" do
    test "the grammar is the design note itself, not a copy of it" do
      grammar = Workflow.grammar()

      assert String.starts_with?(grammar, "# Workflow grammar v1")

      # Byte-for-byte the file on disk. A copy that had drifted would still start with the same
      # heading, so the heading alone is not the check.
      path = Path.join(__DIR__, "../../../docs/design/workflow-grammar-v1.md")
      assert grammar == File.read!(path)
    end

    test "the grammar is not the platform overview, and neither is the other" do
      # They are two different documents with two different jobs; serving one as the other is a
      # single-word edit that nothing else would notice.
      refute Workflow.grammar() == Workflow.platform_overview()
      assert String.starts_with?(Workflow.platform_overview(), "#")
    end

    # `Dir.prepare/3` writes these into `$FORGE_JOB/platform/` for every job and conversation.
    # Dropping one is invisible — the job directory still looks normal — and a bootstrapping
    # conversation asked to write `.forge/workflow.yml` then has nothing to write it from.
    test "both documents are shipped into every job directory, under their names" do
      docs = Workflow.platform_docs()

      assert Enum.map(docs, &elem(&1, 0)) == ["platform.md", "workflow-grammar.md"]

      assert {"workflow-grammar.md", grammar} = List.keyfind(docs, "workflow-grammar.md", 0)
      assert grammar == Workflow.grammar()

      assert {"platform.md", platform} = List.keyfind(docs, "platform.md", 0)
      assert platform == Workflow.platform_overview()
    end

    test "every shipped document has content" do
      for {name, content} <- Workflow.platform_docs() do
        assert byte_size(content) > 0, "#{name} is empty"
      end
    end
  end
end
