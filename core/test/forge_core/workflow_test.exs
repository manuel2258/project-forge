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

    # Agents copy the stored names they read in the backlog; the person then read
    # `proposal-proposal-…` on six of one project's ten open proposals.
    test "a file already named with the prefix is stored under one prefix, not two" do
      assert Workflow.proposal_artifact("score-table.md") == "proposal-score-table.md"
      assert Workflow.proposal_artifact("proposal-score-table.md") == "proposal-score-table.md"
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

    # `$` matches before a final newline; a name must end where the string does.
    test "a name does not end in a newline" do
      refute Workflow.valid_name?("plan.md\n")
      refute Workflow.valid_name?("feature\n")
      refute Workflow.valid_name?("\nfeature")
    end
  end

  describe "the markers a produces entry may carry" do
    test "a presentation is its name and a bang" do
      assert Workflow.presentation?("deck.md!")
      refute Workflow.presentation?("deck.md")
      refute Workflow.presentation?("shots/*")
      refute Workflow.presentation?(Workflow.changeset_artifact())
      refute Workflow.presentation?(nil)
    end

    test "the marker is the declaration and never the filename" do
      assert Workflow.presentation_name("deck.md!") == "deck.md"
      assert Workflow.presentation_name("deck.md") == "deck.md"
    end

    # A presentation is a document in every respect but the kind it is recorded under, which is
    # what lets the worker collect it, parse it and read its outcome knowing nothing of the marker.
    test "a presentation is a document and a group is not" do
      assert Workflow.document?("deck.md!")
      assert Workflow.document?("deck.md")
      refute Workflow.document?("shots/*")
      refute Workflow.document?(Workflow.changeset_artifact())
    end

    test "produced_name strips whichever marker the entry carries, and nothing else" do
      assert Workflow.produced_name("deck.md!") == "deck.md"
      assert Workflow.produced_name("shots/*") == "shots"
      assert Workflow.produced_name("plan.md") == "plan.md"
      assert Workflow.produced_name(Workflow.changeset_artifact()) == "changeset"
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

  describe "parse_bytes/1" do
    # One byte is absurd and a size, and it is the boundary `> 0` is guarding: a mutation to `> 1`
    # refuses it. Whether it is a ceiling a job may have is `enough_memory?/1`'s question, not this.
    test "a bare integer is bytes, and every binary unit multiplies" do
      for {written, bytes} <- [
            {1, 1},
            {"1", 1},
            {512, 512},
            {"512B", 512},
            {"2KiB", 2048},
            {"1MiB", 1_048_576},
            {"1GiB", 1_073_741_824},
            {"1TiB", 1_099_511_627_776}
          ] do
        assert Resources.parse_bytes(written) == {:ok, bytes}, "#{inspect(written)}"
      end

      assert Resources.parse_bytes(0) == :error
    end
  end

  describe "the minimum ceiling" do
    test "is 512 MiB, and a sentence that names it" do
      assert Resources.minimum_memory() == 536_870_912

      assert Resources.too_little_memory() ==
               "must be at least 512MiB, the least a job can run in"

      # And as a form says it, beside the other fields it refuses.
      assert Resources.memory_refused() ==
               "memory must be at least 512MiB, the least a job can run in"
    end

    # Both sides of the boundary, and what is not a number at all: the worker asks this of what
    # arrives over the wire, where a string is as likely as anything.
    test "a job may have the minimum and not a byte less" do
      assert Resources.enough_memory?(536_870_912)
      assert Resources.enough_memory?(8 * 1024 ** 3)
      refute Resources.enough_memory?(536_870_911)
      refute Resources.enough_memory?(2)
      refute Resources.enough_memory?(0)
      refute Resources.enough_memory?("536870912")
      refute Resources.enough_memory?(536_870_912.0)
      refute Resources.enough_memory?(nil)
    end
  end

  describe "size/1" do
    test "the largest unit that divides exactly, spaced for reading" do
      assert Resources.size(2 * 1024 ** 3) == "2 GiB"
      assert Resources.size(512 * 1024 ** 2) == "512 MiB"
      assert Resources.size(2) == "2 B"
      assert Resources.size(2210 * 1024 ** 2) == "2210 MiB"
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

  # `docs/design/workflow-grammar-v1.md` § Inputs. The flow this was written for: a review that
  # sends work back with its reasons, a build that fails, and a tester who writes a note. Each
  # reason is read by a state that also runs before any reason exists.
  describe "produced?/2" do
    defp workflow_producing(produces) do
      %Workflow{
        initial: "a",
        transitions: [],
        limits: nil,
        states: %{
          "a" => %State{name: "a", produces: ["notes.md"]},
          "b" => %State{name: "b", produces: produces}
        }
      }
    end

    # `producers/2` compares raw entries; this is the question the merge rule asks, in which a
    # marked entry (`!` on a presentation, `/*` on a group) is the document it names.
    test "a marked entry produces the document it names" do
      assert Workflow.produced?(workflow_producing(["commit-message"]), "commit-message")
      assert Workflow.produced?(workflow_producing(["commit-message!"]), "commit-message")
      assert Workflow.produced?(workflow_producing(["shots/*"]), "shots")
    end

    test "nothing produces what no state names" do
      refute Workflow.produced?(workflow_producing(["plan.md"]), "commit-message")
      refute Workflow.produced?(workflow_producing(["commit-message.md"]), "commit-message")
    end
  end

  describe "required_input?/3" do
    setup do
      yaml = """
      version: 1
      initial: refining
      states:
        refining:
          prompt: r.md
          inputs: [ticket]
          produces: [refinement.md]
          budget: { turns: 1, cost: 1 }
        planning:
          prompt: p.md
          inputs: [ticket, refinement.md, implementation.md]
          produces: [plan.md]
          budget: { turns: 1, cost: 1 }
        implementing:
          prompt: i.md
          inputs: [plan.md, review.md, test-report.md]
          produces: [implementation.md, changeset]
          outcomes: [done, plan_invalid]
          budget: { turns: 1, cost: 1 }
        reviewing:
          prompt: v.md
          inputs: [plan.md, implementation.md, changeset]
          produces: [review.md, commit-message]
          outcomes: [done, changes_requested]
          budget: { turns: 1, cost: 1 }
        human_testing:
          produces: [test-report.md]
        merged:
          on_enter: merge
      transitions:
        - { from: refining, to: planning, approve: [refinement.md] }
        - { from: planning, to: implementing }
        - { from: implementing, to: reviewing }
        - { from: implementing, to: planning, when: plan_invalid, max: 2 }
        - { from: reviewing, to: human_testing }
        - { from: reviewing, to: implementing, when: changes_requested, max: 3 }
        - { from: human_testing, to: merged, approve: [changeset] }
        - { from: human_testing, to: implementing }
      limits:
        ticket_cost: 10
      """

      %{workflow: ForgeCore.Workflow.Parser.parse!(yaml)}
    end

    test "an input every way in passes the producer of is required", %{workflow: workflow} do
      assert Workflow.required_input?(workflow, "planning", "refinement.md")
      assert Workflow.required_input?(workflow, "implementing", "plan.md")
      assert Workflow.required_input?(workflow, "reviewing", "implementation.md")
    end

    test "a reason a later state sends back is optional", %{workflow: workflow} do
      refute Workflow.required_input?(workflow, "implementing", "review.md")
      refute Workflow.required_input?(workflow, "planning", "implementation.md")
    end

    # Dominance, not reachability: `test-report.md`'s producer comes before `implementing` on one
    # way in, and a person may leave it unwritten on that way too.
    test "a document a person writes is never required", %{workflow: workflow} do
      refute Workflow.required_input?(workflow, "implementing", "test-report.md")
    end

    test "the ticket and the changeset always exist", %{workflow: workflow} do
      assert Workflow.required_input?(workflow, "refining", "ticket")
      assert Workflow.required_input?(workflow, "reviewing", "changeset")
      # Where no state that commits dominates it: the branch exists from admission.
      assert Workflow.required_input?(workflow, "planning", "changeset")
    end

    # The case the one above cannot tell apart from "no producer on this way in": here the human
    # state is on every way in, and it still guarantees nothing.
    test "a person's document is optional even where every way in passes them" do
      yaml = """
      version: 1
      initial: a
      states:
        a:
          prompt: a.md
          budget: { turns: 1, cost: 1 }
        h:
          produces: [note.md]
        c:
          prompt: c.md
          inputs: [note.md]
          budget: { turns: 1, cost: 1 }
      transitions:
        - { from: a, to: h }
        - { from: h, to: c }
      limits:
        ticket_cost: 1
      """

      refute yaml
             |> ForgeCore.Workflow.Parser.parse!()
             |> Workflow.required_input?("c", "note.md")
    end

    # A job that ended on an engine outcome may not have written what it declares — a missing
    # document is `error` — so a state reached that way reads it as optional. The declared
    # outcome and the default guarantee it: the job could not have ended on them without it.
    test "an edge a producer leaves on an engine outcome guarantees nothing" do
      yaml = """
      version: 1
      initial: implementing
      states:
        implementing:
          prompt: i.md
          produces: [implementation.md]
          outcomes: [done, stuck]
          budget: { turns: 1, cost: 1 }
        triage:
          prompt: t.md
          inputs: [implementation.md]
          budget: { turns: 1, cost: 1 }
        after_stuck:
          prompt: s.md
          inputs: [implementation.md]
          budget: { turns: 1, cost: 1 }
        done: {}
      transitions:
        - { from: implementing, to: triage, when: error }
        - { from: implementing, to: after_stuck, when: stuck }
        - { from: implementing, to: done }
        - { from: triage, to: done }
        - { from: after_stuck, to: done }
      limits:
        ticket_cost: 1
      """

      workflow = ForgeCore.Workflow.Parser.parse!(yaml)

      refute Workflow.required_input?(workflow, "triage", "implementation.md")
      assert Workflow.required_input?(workflow, "after_stuck", "implementation.md")
    end

    # A job reads its inputs before it writes anything, so its own earlier output is there only
    # from its second run on.
    test "a state reading what it wrote last time finds nothing the first time" do
      yaml = """
      version: 1
      initial: a
      states:
        a:
          prompt: a.md
          inputs: [notes.md]
          produces: [notes.md]
          outcomes: [done, again]
          budget: { turns: 1, cost: 1 }
        b: {}
      transitions:
        - { from: a, to: b }
        - { from: a, to: a, when: again }
      limits:
        ticket_cost: 1
      """

      refute yaml
             |> ForgeCore.Workflow.Parser.parse!()
             |> Workflow.required_input?("a", "notes.md")
    end

    # A producer on only one of two ways in guarantees nothing on the other.
    test "one way in that skips the producer makes it optional" do
      yaml = """
      version: 1
      initial: a
      states:
        a:
          prompt: a.md
          produces: [x.md]
          outcomes: [done, skip]
          budget: { turns: 1, cost: 1 }
        b:
          prompt: b.md
          produces: [y.md]
          budget: { turns: 1, cost: 1 }
        c:
          prompt: c.md
          inputs: [y.md]
          budget: { turns: 1, cost: 1 }
      transitions:
        - { from: a, to: b }
        - { from: a, to: c, when: skip }
        - { from: b, to: c }
      limits:
        ticket_cost: 1
      """

      workflow = ForgeCore.Workflow.Parser.parse!(yaml)
      refute Workflow.required_input?(workflow, "c", "y.md")
      assert Workflow.required_input?(workflow, "b", "x.md")
    end
  end
end
