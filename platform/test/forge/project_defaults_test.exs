defmodule Forge.ProjectDefaultsTest do
  @moduledoc """
  A project's default model and effort set together, and what "the machine's" model was last seen
  to be (`docs/design/ui.md` § Model and effort).

  Project settings has one Save for both dials, so the write is one: both columns and an event
  for each, or nothing. And the page says what an unset model resolves to only from what a
  harness reported, scoped to this project and to the time since its model last changed.
  """

  use Forge.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Forge.ForgeFixtures
  import Forge.SettingsFixtures

  alias Forge.Events.Event
  alias Forge.{Operator, Projects}

  setup do
    project = project_fixture()
    %{project: project, admin: member_fixture(project, :admin)}
  end

  # A job per attempt: a ticket holds one job per state and attempt.
  defp job!(ticket, attrs \\ []),
    do:
      job_fixture(
        Enum.into(attrs, %{ticket: ticket, attempt: System.unique_integer([:positive])})
      )

  defp events(type), do: Repo.all(from e in Event, where: e.type == ^type, order_by: e.seq)

  describe "set_defaults/3" do
    test "writes both and logs both, naming the person and the project", ctx do
      %{project: project, admin: admin} = ctx

      assert {:ok, project} =
               Operator.set_defaults(project, admin, %{model: "opus", effort: "high"})

      assert %{model: "opus", effort: "high"} = Projects.get!(project.id)

      assert [model] = events("project.model_set")
      assert [effort] = events("project.effort_set")

      for event <- [model, effort] do
        assert event.actor == %{"kind" => "user", "id" => admin.id}
        assert event.project_id == project.id
      end

      assert model.payload == %{"project" => project.name, "model" => "opus"}
      assert effort.payload == %{"project" => project.name, "effort" => "high"}
    end

    # The two dials go in one transaction. Written as two, whichever went first would be saved
    # before the other was refused: half of what the person pressed Save on. Both directions,
    # because two writes in either order fail one of them.
    test "a refused effort leaves the model as it was, and logs nothing", ctx do
      %{project: project, admin: admin} = ctx
      {:ok, project} = Projects.set_defaults(project, %{model: "haiku", effort: "low"})

      assert {:error, _reason} =
               Operator.set_defaults(project, admin, %{model: "opus", effort: ["not", "text"]})

      assert %{model: "haiku", effort: "low"} = Projects.get!(project.id)
      assert [_the_setup_only] = events("project.model_set")
      assert [_the_setup_only] = events("project.effort_set")
    end

    test "a refused model leaves the effort as it was, and logs nothing", ctx do
      %{project: project, admin: admin} = ctx
      {:ok, project} = Projects.set_defaults(project, %{model: "haiku", effort: "low"})

      assert {:error, _reason} =
               Operator.set_defaults(project, admin, %{model: ["not", "text"], effort: "max"})

      assert %{model: "haiku", effort: "low"} = Projects.get!(project.id)
      assert [_the_setup_only] = events("project.model_set")
      assert [_the_setup_only] = events("project.effort_set")
    end

    test "names only the dials it was given", %{project: project, admin: admin} do
      {:ok, project} = Projects.set_effort(project, "low")

      assert {:ok, _project} = Operator.set_defaults(project, admin, %{model: "opus"})

      assert %{model: "opus", effort: "low"} = Projects.get!(project.id)
      assert [_set_up] = events("project.effort_set")
    end

    # It is the settings page's door to the projects table, so nothing else is reachable
    # through it: a hand-sent event cannot rename the project or move its repository.
    test "reaches nothing but the two dials", %{project: project, admin: admin} do
      assert {:ok, _project} =
               Operator.set_defaults(project, admin, %{
                 model: "opus",
                 name: "renamed",
                 repo_path: "/elsewhere"
               })

      assert %{name: name, repo_path: path} = Projects.get!(project.id)
      assert name == project.name
      assert path == project.repo_path
    end

    test "is refused to a member who is not an admin", %{project: project} do
      member = member_fixture(project, :member)

      assert {:error, :forbidden} =
               Operator.set_defaults(project, member, %{model: "opus", effort: "max"})

      assert %{model: nil, effort: nil} = Projects.get!(project.id)
      assert events("project.model_set") == []
    end
  end

  describe "observed_model/1" do
    test "is nothing while no job has started", %{project: project} do
      assert Projects.observed_model(project) == nil
    end

    test "is what the newest job that named no model started on", %{project: project} do
      ticket = ticket_fixture(%{project: project})
      harness_started!(job!(ticket), "claude-older")
      harness_started!(job!(ticket), "claude-newer")

      assert %{model: "claude-newer", at: %DateTime{}} = Projects.observed_model(project)
    end

    # A state that named its own model, or a chat opened with one, says nothing about the
    # machine's: it ran on what it was told.
    test "ignores a job or a chat that named its own model", %{project: project} do
      ticket = ticket_fixture(%{project: project})
      harness_started!(job!(ticket), "claude-machine")

      named = job!(ticket, spec: %{"prompt" => "x", "model" => "opus"})
      harness_started!(named, "claude-opus-resolved")
      harness_started!(chat_fixture(%{project: project, model: "haiku"}), "claude-haiku-resolved")

      assert %{model: "claude-machine"} = Projects.observed_model(project)
    end

    test "is this project's alone", %{project: project} do
      ticket = ticket_fixture(%{project: project})
      harness_started!(job!(ticket), "claude-ours")

      elsewhere = ticket_fixture(%{project: project_fixture()})
      harness_started!(job!(elsewhere), "claude-theirs")

      assert %{model: "claude-ours"} = Projects.observed_model(project)
    end

    # Before the default changed, a job with no model of its own ran on the project's model, not
    # the machine's; while the project names one, nothing can be observed of the machine's.
    test "counts only what started since the project's model last changed", ctx do
      %{project: project, admin: admin} = ctx
      ticket = ticket_fixture(%{project: project})
      harness_started!(job!(ticket), "claude-before")

      {:ok, project} = Operator.set_defaults(project, admin, %{model: "opus"})
      harness_started!(job!(ticket), "claude-opus-resolved")
      assert Projects.observed_model(project) == nil

      {:ok, project} = Operator.set_defaults(project, admin, %{model: ""})
      assert Projects.observed_model(project) == nil

      harness_started!(job!(ticket), "claude-after")
      assert %{model: "claude-after"} = Projects.observed_model(project)
    end

    # Model changes logged before the event carried the project's id are found by its name.
    test "reads an older model change by the project's name", %{project: project} do
      ticket = ticket_fixture(%{project: project})
      harness_started!(job!(ticket), "claude-before")

      {:ok, _} =
        Forge.Events.append("project.model_set", :system, %{
          payload: %{"project" => project.name, "model" => nil}
        })

      assert Projects.observed_model(project) == nil
    end

    test "ignores a start that named no model", %{project: project} do
      ticket = ticket_fixture(%{project: project})
      harness_started!(job!(ticket), "claude-said")
      harness_started!(job!(ticket), "")

      assert %{model: "claude-said"} = Projects.observed_model(project)
    end
  end
end
