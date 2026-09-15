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

  describe "latest_documents/1" do
    # Only a ticket chat's assignment reaches this, and no test assigned one — so an `order_by`
    # on a column that does not exist compiled, passed the whole suite, and failed at the
    # database in front of an operator. `artifact_versions` has `inserted_at` only: a version is
    # immutable, so its schema says `updated_at: false`.
    test "returns the latest version of every document, and actually runs" do
      ticket = ticket_fixture()

      {:ok, _v1} =
        Artifacts.record_version(ticket.id, "plan.md", :document, :system, %{content: "# One\n"})

      {:ok, _v2} =
        Artifacts.record_version(ticket.id, "plan.md", :document, :system, %{content: "# Two\n"})

      {:ok, _other} =
        Artifacts.record_version(ticket.id, "notes.md", :document, :system, %{content: "notes\n"})

      documents = Artifacts.latest_documents(ticket.id)

      assert length(documents) == 2
      assert %{version: 2, content: "# Two\n"} = Enum.find(documents, &(&1.name == "plan.md"))
      assert %{version: 1} = Enum.find(documents, &(&1.name == "notes.md"))
    end

    test "a blob is not a document, and is not inlined into a prompt" do
      ticket = ticket_fixture()

      {:ok, _} =
        Artifacts.record_version(ticket.id, "t.jsonl", :blob, :system, %{blob_uri: "store:k"})

      assert Artifacts.latest_documents(ticket.id) == []
    end

    test "a ticket with nothing written has no documents" do
      assert Artifacts.latest_documents(ticket_fixture().id) == []
    end
  end

  describe "scope" do
    test "a conversation's artifact belongs to the chat and not to any ticket" do
      chat = chat_fixture()

      {:ok, version} =
        Artifacts.record_version({:job, chat.id}, "notes.md", :document, {:job, chat.id}, %{
          content: "# Notes\n"
        })

      assert [artifact] = Artifacts.list_for_job(chat.id)
      assert artifact.job_id == chat.id
      assert is_nil(artifact.ticket_id)
      assert Artifacts.latest_for_job(chat.id, "notes.md").id == version.id
    end

    test "writing the same name twice is a second version, not a second artifact" do
      chat = chat_fixture()

      {:ok, first} =
        Artifacts.record_version({:job, chat.id}, "notes.md", :document, :system, %{
          content: "# One\n"
        })

      {:ok, second} =
        Artifacts.record_version({:job, chat.id}, "notes.md", :document, :system, %{
          content: "# Two\n"
        })

      assert length(Artifacts.list_for_job(chat.id)) == 1
      assert first.version == 1
      assert second.version == 2
    end

    # The lookup above is what normally prevents a duplicate, so this goes around it and inserts
    # directly — which is what a second concurrent writer does. `unique_index([:ticket_id, :name])`
    # stops constraining anything once ticket_id can be null, because Postgres treats NULLs as
    # distinct and every chat row satisfies it; without the partial index on the chat side there
    # is no backstop at all, and a conversation ends up with two `notes.md`.
    test "the database refuses a second artifact of one name on a conversation" do
      chat = chat_fixture()

      insert = fn ->
        Repo.insert(
          Forge.Artifacts.Artifact.changeset(%Forge.Artifacts.Artifact{}, %{
            job_id: chat.id,
            name: "notes.md",
            kind: :document
          })
        )
      end

      assert {:ok, _artifact} = insert.()
      assert {:error, changeset} = insert.()
      assert errors_on(changeset).job_id == ["has already been taken"]
    end

    test "two conversations may each have an artifact of the same name" do
      a = chat_fixture()
      b = chat_fixture()

      {:ok, _} =
        Artifacts.record_version({:job, a.id}, "notes.md", :document, :system, %{content: "a"})

      {:ok, _} =
        Artifacts.record_version({:job, b.id}, "notes.md", :document, :system, %{content: "b"})

      assert Artifacts.latest_for_job(a.id, "notes.md").content == "a"
      assert Artifacts.latest_for_job(b.id, "notes.md").content == "b"
    end

    test "a ticket's artifacts are unchanged, and a bare id still means the ticket" do
      ticket = ticket_fixture()

      {:ok, _} =
        Artifacts.record_version(ticket.id, "plan.md", :document, :system, %{content: "# P\n"})

      {:ok, _} =
        Artifacts.record_version({:ticket, ticket.id}, "plan.md", :document, :system, %{
          content: "# Q\n"
        })

      assert [artifact] = Artifacts.list(ticket.id)
      assert artifact.ticket_id == ticket.id
      assert is_nil(artifact.job_id)
      assert Artifacts.latest(ticket.id, "plan.md").version == 2
    end

    test "an artifact belonging to both, or to neither, is refused" do
      ticket = ticket_fixture()
      chat = chat_fixture()

      assert {:error, changeset} =
               Repo.insert(
                 Forge.Artifacts.Artifact.changeset(%Forge.Artifacts.Artifact{}, %{
                   ticket_id: ticket.id,
                   job_id: chat.id,
                   name: "notes.md",
                   kind: :document
                 })
               )

      assert errors_on(changeset).job_id == ["an artifact belongs to one of a ticket and a chat"]

      assert {:error, neither} =
               Repo.insert(
                 Forge.Artifacts.Artifact.changeset(%Forge.Artifacts.Artifact{}, %{
                   name: "notes.md",
                   kind: :document
                 })
               )

      assert errors_on(neither).ticket_id == ["an artifact belongs to a ticket or a chat"]
    end
  end
end
