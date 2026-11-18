defmodule Forge.ArtifactsTest do
  @moduledoc """
  The two questions the operator pages ask of an artifact: where are its bytes, and can it ever
  be approved. Both have wrong answers that are invisible until a person is staring at them.
  """

  use Forge.DataCase, async: true

  import Forge.ForgeFixtures
  import Forge.AccountsFixtures

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
            budget: { turns: 1, tokens: 20k }
          review_ready: {}
          merged: {}
        transitions:
          - { from: planning, to: review_ready, approve: [plan.md] }
          - { from: review_ready, to: merged, approve: [changeset] }
        limits: { ticket_tokens: 200k }
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
            budget: { turns: 3, tokens: 20k }
          done_state: {}
        transitions:
          - { from: looping, to: looping, when: retry, max: 1 }
          - { from: looping, to: done_state, when: done }
        limits: { ticket_tokens: 100k }
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

      secret =
        Path.join(
          System.tmp_dir!(),
          "#{System.pid()}-forge-outside-#{System.unique_integer([:positive])}"
        )

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
      outside =
        Path.join(
          System.tmp_dir!(),
          "#{System.pid()}-forge-artifacts-test-#{System.unique_integer()}"
        )

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

    # What a reopened project chat is handed of its own work (`conversations.md` § Context). The
    # scope is the whole of the question: a conversation's documents are nobody's ticket's, and a
    # ticket's are not the conversation's, even when the names are the same.
    test "a conversation's own scope is its own documents, and only those" do
      chat = chat_fixture()
      ticket = ticket_fixture()

      {:ok, _v1} =
        Artifacts.record_version({:job, chat.id}, "notes.md", :document, :system, %{
          content: "# One\n"
        })

      {:ok, _v2} =
        Artifacts.record_version({:job, chat.id}, "notes.md", :document, :system, %{
          content: "# Two\n"
        })

      {:ok, _theirs} =
        Artifacts.record_version(ticket.id, "notes.md", :document, :system, %{
          content: "# The ticket's\n"
        })

      assert [%{name: "notes.md", version: 2, content: "# Two\n"}] =
               Artifacts.latest_documents({:job, chat.id})

      assert [%{content: "# The ticket's\n"}] = Artifacts.latest_documents(ticket.id)
    end
  end

  describe "scope" do
    test "a conversation's artifact belongs to the chat and not to any ticket" do
      chat = chat_fixture()

      {:ok, version} =
        Artifacts.record_version({:job, chat.id}, "notes.md", :document, {:job, chat.id}, %{
          content: "# Notes\n"
        })

      assert artifact = Artifacts.find({:job, chat.id}, "notes.md")
      assert artifact.job_id == chat.id
      assert is_nil(artifact.ticket_id)
      assert [%{id: id}] = Artifacts.versions({:job, chat.id}, "notes.md")
      assert id == version.id
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

      assert first.artifact_id == second.artifact_id
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

      assert [%{content: "a"}] = Artifacts.versions({:job, a.id}, "notes.md")
      assert [%{content: "b"}] = Artifacts.versions({:job, b.id}, "notes.md")
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

  # What a ticket's record of approvals says now, read as one history across versions
  # (`docs/design/workflow-grammar-v1.md` § Merging, *What follows the rebase*).
  describe "changeset_decision/1" do
    @t0 ~U[2026-01-01 10:00:00Z]

    defp versions!(ticket, count) do
      for n <- 1..count do
        {:ok, version} =
          Artifacts.record_version(ticket.id, "changeset", :blob, :system, %{
            blob_uri: "git:" <> String.duplicate("#{n}", 40)
          })

        version
      end
    end

    # Rows with a clock of their own: `inserted_at` is whole seconds, so the order a test needs is
    # set, not waited for.
    defp decide!(version, decision, seconds, opts \\ []) do
      user = user_fixture()

      Forge.Repo.insert!(%Forge.Artifacts.Approval{
        artifact_version_id: version.id,
        user_id: user.id,
        decision: decision,
        transition: %{"from" => "a", "to" => "b"},
        inserted_at: DateTime.add(@t0, seconds),
        withdrawn_at: opts[:withdrawn]
      })
    end

    test "is none when nobody decided, whatever else the ticket has" do
      ticket = ticket_fixture()
      versions!(ticket, 2)

      assert Artifacts.changeset_decision(ticket.id) == :none
      assert Artifacts.standing_changeset_approval(ticket.id) == nil
    end

    test "stands on an approval, and withdrawing it takes that away" do
      ticket = ticket_fixture()
      [v1] = versions!(ticket, 1)
      approval = decide!(v1, :approved, 0)

      assert Artifacts.changeset_decision(ticket.id) == :stands
      assert Artifacts.standing_changeset_approval(ticket.id).id == approval.id

      {:ok, _changes} =
        Ecto.Multi.new() |> Artifacts.put_withdrawal([approval.id]) |> Forge.Repo.transaction()

      assert Artifacts.changeset_decision(ticket.id) == :withdrawn
      assert Artifacts.standing_changeset_approval(ticket.id) == nil
    end

    test "a later version's rejection cancels an earlier version's approval" do
      ticket = ticket_fixture()
      [v1, v2] = versions!(ticket, 2)
      decide!(v1, :approved, 0)
      decide!(v2, :rejected, 10)

      assert Artifacts.changeset_decision(ticket.id) == :rejected
    end

    test "the latest version decides, not the latest clock" do
      ticket = ticket_fixture()
      [v1, v2] = versions!(ticket, 2)
      # The earlier version's row carries the later time: a decision on v2 is still the later one.
      decide!(v1, :rejected, 100)
      decide!(v2, :approved, 0)

      assert Artifacts.changeset_decision(ticket.id) == :stands
    end

    test "an approval of an earlier version stands while a later one has no decision" do
      ticket = ticket_fixture()
      [v1, _v2] = versions!(ticket, 2)
      decide!(v1, :approved, 0)

      assert Artifacts.changeset_decision(ticket.id) == :stands
    end

    test "within one version the later decision wins, and a tie goes against the approval" do
      ticket = ticket_fixture()
      [v1] = versions!(ticket, 1)
      decide!(v1, :rejected, 0)
      decide!(v1, :approved, 5)
      assert Artifacts.changeset_decision(ticket.id) == :stands

      decide!(v1, :rejected, 5)
      assert Artifacts.changeset_decision(ticket.id) == :rejected
    end

    test "an approval given again after a withdrawal counts again" do
      ticket = ticket_fixture()
      [v1] = versions!(ticket, 1)
      decide!(v1, :approved, 0, withdrawn: ~U[2026-01-01 10:00:00.000000Z])
      assert Artifacts.changeset_decision(ticket.id) == :withdrawn

      decide!(v1, :approved, 0)
      assert Artifacts.changeset_decision(ticket.id) == :stands
    end

    test "reads this ticket's changeset and no other artifact or ticket" do
      ticket = ticket_fixture()
      other = ticket_fixture()
      [v1] = versions!(ticket, 1)
      [o1] = versions!(other, 1)
      decide!(o1, :approved, 0)

      {:ok, doc} =
        Artifacts.record_version(ticket.id, "commit-message", :document, :system, %{content: "x"})

      decide!(doc, :approved, 0)

      assert Artifacts.changeset_decision(ticket.id) == :none
      assert Artifacts.changeset_decision(other.id) == :stands
      assert v1.version == 1
    end
  end
end
