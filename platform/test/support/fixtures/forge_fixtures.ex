defmodule Forge.ForgeFixtures do
  @moduledoc "Rows for tests: a project, an admitted ticket, a job, an artifact with a version."

  alias Forge.Repo

  @workflow_fixture Path.expand("../../../../core/test/fixtures/workflow_example.yml", __DIR__)

  def workflow_map do
    {:ok, map} = YamlElixir.read_from_string(File.read!(@workflow_fixture))
    map
  end

  def project_fixture(attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "game-#{System.unique_integer([:positive])}",
        repo_path: "/srv/git/game.git"
      })

    Repo.insert!(Forge.Projects.Project.changeset(%Forge.Projects.Project{}, attrs))
  end

  def ticket_fixture(attrs \\ %{}) do
    project = Map.get_lazy(attrs, :project, fn -> project_fixture() end)

    attrs =
      attrs
      |> Map.delete(:project)
      |> Enum.into(%{
        project_id: project.id,
        number: System.unique_integer([:positive]),
        title: "Persist the high score table",
        body: "Scores vanish on restart.",
        base_commit: String.duplicate("a", 40),
        branch: "ticket/1",
        workflow: workflow_map(),
        workflow_commit: String.duplicate("a", 40),
        state: "refined"
      })

    Repo.insert!(Forge.Tickets.Ticket.admit_changeset(%Forge.Tickets.Ticket{}, attrs))
  end

  def job_fixture(attrs \\ %{}) do
    ticket = Map.get_lazy(attrs, :ticket, fn -> ticket_fixture() end)

    attrs =
      attrs
      |> Map.delete(:ticket)
      |> Enum.into(%{
        ticket_id: ticket.id,
        state: ticket.state,
        attempt: 1,
        spec: %{"prompt" => "agents/refine.md"}
      })

    Repo.insert!(Forge.Jobs.Job.create_changeset(%Forge.Jobs.Job{}, attrs))
  end

  def artifact_fixture(attrs \\ %{}) do
    ticket = Map.get_lazy(attrs, :ticket, fn -> ticket_fixture() end)

    attrs =
      attrs
      |> Map.delete(:ticket)
      |> Enum.into(%{ticket_id: ticket.id, name: "refinement.md", kind: :document})

    Repo.insert!(Forge.Artifacts.Artifact.changeset(%Forge.Artifacts.Artifact{}, attrs))
  end

  def version_fixture(attrs \\ %{}) do
    artifact = Map.get_lazy(attrs, :artifact, fn -> artifact_fixture() end)

    attrs =
      attrs
      |> Map.delete(:artifact)
      |> Enum.into(%{
        artifact_id: artifact.id,
        version: 1,
        author: %{"kind" => "job", "id" => Ecto.UUID.generate()},
        content: "---\noutcome: done\n---\n# Refinement\n",
        content_hash: "sha256:" <> String.duplicate("0", 64)
      })

    Repo.insert!(Forge.Artifacts.Version.changeset(%Forge.Artifacts.Version{}, attrs))
  end
end
