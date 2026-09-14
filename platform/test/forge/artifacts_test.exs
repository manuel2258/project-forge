defmodule Forge.ArtifactsTest do
  @moduledoc """
  The two questions the operator pages ask of an artifact: where are its bytes, and can it ever
  be approved. Both have wrong answers that are invisible until a person is staring at them.
  """

  use Forge.DataCase, async: true

  import Forge.ForgeFixtures

  alias Forge.Artifacts
  alias ForgeCore.Workflow.Parser

  defp workflow(yaml), do: Parser.parse(yaml) |> then(fn {:ok, workflow} -> workflow end)

  describe "approvable/1" do
    test "names every artifact any transition can approve" do
      workflow =
        workflow("""
        version: 1
        initial: planning
        states:
          planning:
            prompt: agents/plan.md
            produces: [plan.md, changeset]
            budget: { turns: 1, cost: 0.1 }
          review_ready: {}
          merged: {}
        transitions:
          - { from: planning, to: review_ready, approve: [plan.md] }
          - { from: review_ready, to: merged, approve: [changeset] }
        limits: { ticket_cost: 1.0 }
        """)

      assert Artifacts.approvable(workflow) == MapSet.new(["plan.md", "changeset"])
    end

    # The t1 fixture's shape, and the one that put `◇ unapproved` in warning colour on every
    # artifact of every ticket in a workflow that approves nothing. See docs/design/ui.md.
    test "a workflow that approves nothing makes nothing approvable" do
      workflow =
        workflow("""
        version: 1
        initial: looping
        states:
          looping:
            prompt: agents/loop.md
            produces: [out.md]
            outcomes: [done, retry]
            budget: { turns: 3, cost: 0.1 }
          done_state: {}
        transitions:
          - { from: looping, to: looping, when: retry, max: 1 }
          - { from: looping, to: done_state, when: done }
        limits: { ticket_cost: 0.5 }
        """)

      assert Artifacts.approvable(workflow) == MapSet.new()
    end

    test "a ticket whose pinned workflow no longer parses approves nothing" do
      assert Artifacts.approvable(nil) == MapSet.new()
    end
  end

  describe "content/1" do
    test "a document carries its own bytes" do
      assert {:ok, "# Plan\n"} = Artifacts.content(%Artifacts.Version{content: "# Plan\n"})
    end

    test "a changeset is a commit and is never served as a file" do
      version = %Artifacts.Version{blob_uri: "git:" <> String.duplicate("a", 40)}
      assert {:error, :not_a_file} = Artifacts.content(version)
    end

    test "a row with neither content nor a resolvable uri is not found" do
      assert {:error, :not_found} = Artifacts.content(%Artifacts.Version{})
      assert {:error, :not_found} = Artifacts.content(%Artifacts.Version{blob_uri: "nonsense:x"})
    end

    # `Path.expand` is lexical and `File.read` follows links, so a link *inside* the data
    # directory pointing out passed the prefix check and its target was served. The sibling-path
    # test below never touched this.
    test "a symlink inside the data directory is refused rather than followed" do
      root = Path.expand(Forge.Jobs.config(:data_dir, "tmp/forge"))
      File.mkdir_p!(root)

      secret = Path.join(System.tmp_dir!(), "forge-outside-#{System.unique_integer([:positive])}")
      File.write!(secret, "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-would-leak\n")
      link = Path.join(root, "innocent-#{System.unique_integer([:positive])}.jsonl")
      File.ln_s!(secret, link)
      on_exit(fn -> File.rm(link) && File.rm(secret) end)

      version = %Artifacts.Version{blob_uri: "file://" <> link}
      assert {:error, :outside_data_dir} = Artifacts.content(version)
    end

    test "a plain file inside the data directory is served" do
      root = Path.expand(Forge.Jobs.config(:data_dir, "tmp/forge"))
      File.mkdir_p!(root)
      path = Path.join(root, "transcript-#{System.unique_integer([:positive])}.jsonl")
      File.write!(path, "from before the store existed\n")
      on_exit(fn -> File.rm(path) end)

      version = %Artifacts.Version{blob_uri: "file://" <> path}
      assert {:ok, "from before the store existed\n"} = Artifacts.content(version)
    end

    test "a file:// path outside the data directory is refused, not read" do
      outside = Path.join(System.tmp_dir!(), "forge-artifacts-test-#{System.unique_integer()}")
      File.write!(outside, "not yours\n")
      on_exit(fn -> File.rm(outside) end)

      version = %Artifacts.Version{blob_uri: "file://" <> outside}
      assert {:error, :outside_data_dir} = Artifacts.content(version)
    end
  end

  describe "written_by/1" do
    test "returns the versions a job authored, and not another author's" do
      ticket = ticket_fixture()
      job = job_fixture(%{ticket: ticket})

      {:ok, _} =
        Artifacts.record_version(ticket.id, "plan.md", :document, {:job, job.id}, %{
          content: "# Plan\n"
        })

      {:ok, _} =
        Artifacts.record_version(
          ticket.id,
          "other.md",
          :document,
          {:user, Ecto.UUID.generate()},
          %{
            content: "written by a person\n"
          }
        )

      assert [{artifact, version}] = Artifacts.written_by(job.id)
      assert artifact.name == "plan.md"
      assert version.version == 1
    end
  end
end
