defmodule Forge.SchemasTest do
  use Forge.DataCase, async: true

  import Forge.ForgeFixtures

  alias Forge.Artifacts.{Answer, Approval, Question, Version}
  alias Forge.Jobs.Job
  alias Forge.Tickets.Ticket

  describe "tickets" do
    test "are unique per project and number" do
      ticket = ticket_fixture()

      assert {:error, changeset} =
               Repo.insert(
                 Ticket.admit_changeset(%Ticket{}, %{
                   project_id: ticket.project_id,
                   number: ticket.number,
                   title: "dup",
                   base_commit: "b",
                   branch: "ticket/x",
                   workflow: %{},
                   workflow_commit: "b",
                   state: "refining"
                 })
               )

      assert %{project_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "default to active with zero cost" do
      ticket = ticket_fixture()
      assert ticket.status == :active
      assert Decimal.equal?(ticket.cost_usd, 0)
    end
  end

  describe "jobs" do
    test "are unique per ticket, state and attempt" do
      job = job_fixture()

      changeset =
        Job.create_changeset(%Job{}, %{
          ticket_id: job.ticket_id,
          state: job.state,
          attempt: 1,
          spec: %{}
        })

      assert {:error, changeset} = Repo.insert(changeset)
      assert %{ticket_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "carry an outcome exactly when finished" do
      job = job_fixture()

      assert %{outcome: ["is required once finished"]} =
               errors_on(Job.progress_changeset(job, %{status: :finished}))

      assert %{outcome: ["only a finished job has an outcome"]} =
               errors_on(Job.progress_changeset(job, %{status: :running, outcome: :converged}))

      assert {:ok, %Job{outcome: :converged}} =
               Repo.update(Job.progress_changeset(job, %{status: :finished, outcome: :converged}))
    end

    test "the spec is not castable after creation" do
      job = job_fixture()
      changeset = Job.progress_changeset(job, %{status: :running, spec: %{"prompt" => "other"}})
      refute Map.has_key?(changeset.changes, :spec)
    end
  end

  describe "artifact versions" do
    test "require an author of a known kind and content or a blob, not both" do
      base = %{artifact_id: Ecto.UUID.generate(), version: 1, content_hash: "h"}

      assert %{author: [_]} =
               errors_on(
                 Version.changeset(%Version{}, Map.put(base, :author, %{"kind" => "elf"}))
               )

      author = %{"kind" => "user", "id" => Ecto.UUID.generate()}

      assert %{content: ["either content or blob_uri is required"]} =
               errors_on(Version.changeset(%Version{}, Map.put(base, :author, author)))

      both =
        base |> Map.put(:author, author) |> Map.put(:content, "x") |> Map.put(:blob_uri, "s3://x")

      assert %{content: ["content and blob_uri are exclusive"]} =
               errors_on(Version.changeset(%Version{}, both))
    end

    test "are unique per artifact and version" do
      version = version_fixture()
      artifact = Repo.get!(Forge.Artifacts.Artifact, version.artifact_id)

      assert_raise Ecto.InvalidChangesetError, fn ->
        version_fixture(%{artifact: artifact, version: 1})
      end

      assert %Version{version: 2} = version_fixture(%{artifact: artifact, version: 2})
    end

    test "can never be updated or deleted" do
      version = version_fixture()

      assert_raise Postgrex.Error, ~r/artifact_versions is append-only/, fn ->
        Repo.update!(Ecto.Changeset.change(version, content: "tampered"))
      end

      assert_raise Postgrex.Error, ~r/artifact_versions is append-only/, fn ->
        Repo.delete!(version)
      end
    end
  end

  describe "questions, answers and approvals" do
    test "a question maps from the core struct and is unique per version and key" do
      version = version_fixture()

      {:ok, document} =
        ForgeCore.Document.parse(
          File.read!(Path.expand("../../../core/test/fixtures/document_example.md", __DIR__))
        )

      [core_question | _] = document.questions

      attrs = Question.attrs_from_core(core_question, version.id)

      assert {:ok, %Question{key: "storage-backend", line: 9, options: ["local-file", "sqlite"]}} =
               Repo.insert(Question.changeset(%Question{}, attrs))

      assert {:error, changeset} = Repo.insert(Question.changeset(%Question{}, attrs))
      assert %{artifact_version_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "an answer needs a choice or text" do
      assert %{choice: ["either a choice or free text is required"]} =
               errors_on(
                 Answer.changeset(%Answer{}, %{
                   question_id: "q",
                   user_id: "u",
                   artifact_version_id: "v"
                 })
               )
    end

    test "an approval names its transition" do
      assert %{transition: [_]} =
               errors_on(
                 Approval.changeset(%Approval{}, %{
                   artifact_version_id: "v",
                   user_id: "u",
                   decision: :approved,
                   transition: %{"from" => "a"}
                 })
               )
    end
  end
end
