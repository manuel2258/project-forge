defmodule Forge.ForgeFixtures do
  @moduledoc "Rows for tests: a project, an admitted ticket, a job, an artifact with a version."

  alias Forge.Repo

  @workflow_fixture Path.expand("../../../../core/test/fixtures/workflow_example.yml", __DIR__)

  def workflow_map do
    {:ok, map} = YamlElixir.read_from_string(File.read!(@workflow_fixture))
    map
  end

  @doc """
  A project row, inserted rather than registered: nothing creates the repository this names.

  The path is deliberately one that does not exist — a test needing a real repository uses
  `Forge.GitFixtures.seeded_repo/1` — but it is under the temporary directory rather than
  `/srv/git`, so that a machine without `/srv` sees the same failure as one with it.
  """
  def project_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Enum.into(attrs, %{
        name: "game-#{n}",
        repo_path: Path.join(System.tmp_dir!(), "forge-unregistered-#{n}.git")
      })

    Repo.insert!(Forge.Projects.Project.changeset(%Forge.Projects.Project{}, attrs))
  end

  @doc """
  Registers a project owned by a freshly made user.

  For the many setups that need a project and do not care who owns it. `Projects.register/2`
  refuses a nil owner, because a project with no members is invisible to everyone — so a test
  that wants a *specific* owner passes one and does not come here.
  """
  def register_owned!(attrs) do
    {:ok, project} = Forge.Projects.register(attrs, Forge.AccountsFixtures.user_fixture())
    {:ok, project}
  end

  @doc """
  Joins a user to a project, admin by default.

  Explicit on purpose. A fixture that quietly made every user a member of every project would
  make a read-scoping leak invisible in exactly the tests written to catch one.
  """
  def join!(project, user, role \\ :admin) do
    Repo.insert!(
      Forge.Projects.Member.changeset(%Forge.Projects.Member{}, %{
        project_id: project.id,
        user_id: user.id,
        role: role
      })
    )

    project
  end

  @doc "Joins a user to the project a ticket belongs to."
  def join_ticket!(ticket, user, role \\ :admin) do
    join!(Forge.Projects.get!(ticket.project_id), user, role)
    ticket
  end

  @doc "An approved user who is already a member of `project`."
  def member_fixture(project, role \\ :admin) do
    user = Forge.AccountsFixtures.user_fixture()
    join!(project, user, role)
    user
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
        state: "refining"
      })

    Repo.insert!(Forge.Tickets.Ticket.admit_changeset(%Forge.Tickets.Ticket{}, attrs))
  end

  def job_fixture(attrs \\ %{}) do
    ticket = Map.get_lazy(attrs, :ticket, fn -> ticket_fixture() end)
    {status, attrs} = Map.pop(attrs, :status)

    attrs =
      attrs
      |> Map.delete(:ticket)
      |> Enum.into(%{
        ticket_id: ticket.id,
        project_id: ticket.project_id,
        state: ticket.state,
        attempt: 1,
        spec: %{"prompt" => "agents/refine.md"},
        memory_max: Forge.Jobs.default_resources().memory,
        cores: Forge.Jobs.default_resources().cores
      })

    %Forge.Jobs.Job{}
    |> Forge.Jobs.Job.create_changeset(attrs)
    |> Repo.insert!()
    |> with_status(status)
  end

  # `create_changeset/2` does not cast a status, on purpose: a job is created pending and gets
  # anywhere else through `progress_changeset/2`. A fixture that wants a running row has to go
  # the same way, or it silently gets a pending one and every test about running work is vacuous.
  defp with_status(job, nil), do: job

  defp with_status(job, status) do
    job
    |> Forge.Jobs.Job.progress_changeset(%{status: status})
    |> Repo.update!()
  end

  @doc """
  A conversation: a job with a kind, a project, and none of a workflow job's fields.

  `ticket_id` is left out unless a caller passes one — a project chat is the shape most likely
  to break a reader that assumes every job has a ticket.
  """
  def chat_fixture(attrs \\ %{}) do
    project =
      Map.get_lazy(attrs, :project, fn ->
        case Map.get(attrs, :ticket) do
          nil -> project_fixture()
          ticket -> Forge.Projects.get!(ticket.project_id)
        end
      end)

    {status, attrs} = Map.pop(attrs, :status)

    attrs =
      attrs
      |> Map.drop([:project, :ticket])
      |> Enum.into(%{
        kind: :chat,
        project_id: project.id,
        attempt: 1,
        memory_max: Forge.Jobs.default_resources().memory,
        cores: Forge.Jobs.default_resources().cores
      })

    %Forge.Jobs.Job{}
    |> Forge.Jobs.Job.create_changeset(attrs)
    |> Repo.insert!()
    |> with_status(status)
  end

  @doc """
  A proposal: a job-scoped document under the reserved name prefix, at version 1.

  `file` is the name the agent gave it; the stored artifact carries the prefix, which is what
  says a job-scoped artifact is a proposal at all.
  """
  def proposal_fixture(attrs \\ %{}) do
    job = Map.get_lazy(attrs, :job, fn -> job_fixture() end)
    file = Map.get(attrs, :file, "score-table.md")
    title = Map.get(attrs, :title, "Extract the score table")
    body = Map.get(attrs, :body, "The plan assumes a module that is not there.")
    content = Map.get(attrs, :content, "# #{title}\n\n#{body}")

    {:ok, version} =
      Forge.Artifacts.record_version(
        {:job, job.id},
        ForgeCore.Workflow.proposal_artifact(file),
        :document,
        {:job, job.id},
        %{content: content, parse: false}
      )

    version
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
