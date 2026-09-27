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
  alias ForgeCore.Workflow.{Defaults, Limits, Resources, State}

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

  # What a conversation writes in `out/` is a document by being there — nothing declared it — so
  # the names a workflow may not produce are the names it may not write, and the name rule is
  # the validator's. Each refused name is one whose row or file the platform owns: writing it
  # would be a new version of the ticket's body, of its answers, of its changeset, or a document
  # passing itself off as a proposal.
  describe "the names a conversation may write a document under" do
    test "an ordinary name is allowed" do
      for name <- ["plan.md", "notes", "design-v2.md", "0_readme.txt"] do
        assert Workflow.document_name_error(name) == nil, name
      end
    end

    test "a name that is not one path segment is refused" do
      for name <- ["..", ".hidden", "a/b.md", "with space.md", "", "-dash.md"] do
        assert Workflow.document_name_error(name) =~ "single path segment", inspect(name)
      end
    end

    test "the names the platform keeps for itself are refused, each for its reason" do
      for name <- ["ticket", "answers.md", "changeset"] do
        assert Workflow.document_name_error(name) =~ "is reserved", name
      end

      for name <- ["proposals", "proposal-score-table.md"] do
        assert Workflow.document_name_error(name) =~ "reserved for ticket proposals", name
      end

      # The whole prefix, not only the transcripts that exist: a name taken before the job's
      # transcript is recorded leaves that job unable to record its result.
      for name <- ["transcript-refining-1.jsonl", "transcript-notes.md"] do
        assert Workflow.document_name_error(name) =~ "reserved for job transcripts", name
      end

      assert Workflow.document_name_error("transcripts.md") == nil
    end

    # One definition: the validator's rule is this function, so the two cannot drift apart.
    test "the rule is the validator's" do
      refute Workflow.valid_name?("..")
      refute Workflow.valid_name?(nil)
      assert Workflow.valid_name?("plan.md")
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

  describe "humanize/1" do
    # A form offering `8GiB` and filling itself with `8589934592` is a form arguing with its own
    # label, and the number it writes is the one nobody would type.
    test "the largest unit that divides exactly" do
      assert Resources.humanize(8 * 1024 * 1024 * 1024) == "8GiB"
      assert Resources.humanize(2 * 1024 * 1024) == "2MiB"
      assert Resources.humanize(1024) == "1KiB"
      assert Resources.humanize(512) == "512B"
    end

    # A figure no larger unit divides comes back in bytes rather than being rounded into a lie.
    # `B` is what makes the function total, and it is why there is no fallback branch.
    test "a size no larger unit divides keeps every byte" do
      assert Resources.humanize(1_500_000_000) == "1500000000B"
      assert Resources.parse_bytes(Resources.humanize(1_500_000_000)) == {:ok, 1_500_000_000}
    end

    # The round trip is the whole point: what this writes into a field must be something
    # `parse_bytes/1` reads back as the same number.
    test "whatever it writes, the parser reads back unchanged" do
      for bytes <- [1, 512, 1024, 2_200 * 1024 * 1024, 8 * 1024 * 1024 * 1024, 1_500_000_000] do
        assert Resources.parse_bytes(Resources.humanize(bytes)) == {:ok, bytes}
      end
    end
  end

  describe "gib/1" do
    test "gibibytes to one decimal, and a dash for a figure nobody has" do
      assert Resources.gib(8 * 1024 ** 3) == "8.0 GiB"
      assert Resources.gib(8_000_000_000) == "7.5 GiB"
      assert Resources.gib(0) == "0.0 GiB"
      assert Resources.gib(nil) == "—"
    end
  end

  describe "resources/2" do
    setup do
      %{
        workflow: %Workflow{
          initial: "a",
          transitions: [],
          limits: %Limits{ticket_cost: 1},
          defaults: %Defaults{resources: %Resources{memory: 100, cpu: 1}},
          states: %{
            "both" => %State{name: "both", resources: %Resources{memory: 900, cpu: 9}},
            "memory_only" => %State{name: "memory_only", resources: %Resources{memory: 900}},
            "cpu_only" => %State{name: "cpu_only", resources: %Resources{cpu: 9}},
            "neither" => %State{name: "neither"},
            "human" => %State{name: "human"}
          }
        }
      }
    end

    test "the state wins where it declares", %{workflow: workflow} do
      assert Workflow.resources(workflow, "both") == %Resources{memory: 900, cpu: 9}
    end

    # The half that is easy to get backwards. A merge of whole values would let the defaults
    # overwrite what the state said, or let a state declaring one field blank the other.
    test "each field falls back on its own", %{workflow: workflow} do
      assert Workflow.resources(workflow, "memory_only") == %Resources{memory: 900, cpu: 1}
      assert Workflow.resources(workflow, "cpu_only") == %Resources{memory: 100, cpu: 9}
    end

    test "a state declaring nothing takes the defaults whole", %{workflow: workflow} do
      assert Workflow.resources(workflow, "neither") == %Resources{memory: 100, cpu: 1}
    end

    # Not an error and not a crash: a caller asking about a state that is gone — a workflow
    # re-pinned under it, a name off a wire — gets what a state declaring nothing gets, and the
    # platform supplies the rest either way.
    test "a state that does not exist resolves to the defaults", %{workflow: workflow} do
      assert Workflow.resources(workflow, "vanished") == %Resources{memory: 100, cpu: 1}
    end

    test "with no defaults either, both fields stay nil for the platform to fill" do
      workflow = %Workflow{
        initial: "a",
        transitions: [],
        limits: %Limits{ticket_cost: 1},
        states: %{"a" => %State{name: "a"}}
      }

      assert Workflow.resources(workflow, "a") == %Resources{memory: nil, cpu: nil}
    end
  end
end
