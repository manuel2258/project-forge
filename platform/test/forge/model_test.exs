defmodule Forge.ModelTest do
  @moduledoc """
  Which model the work runs on.

  The chain is the whole feature: a workflow state's, then the project's, then the machine's.
  Every link is tested from the outside — `model_for/1` is what the assignment asks — because the
  failure mode is silent: a job that runs on the wrong model produces work, just not the work
  that was paid for.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Conversations, Jobs, Projects}
  alias Forge.Jobs.Job

  setup do
    {:ok, project} =
      Projects.register(%{
        name: "model-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo()
      })

    %{project: project}
  end

  describe "a project's default" do
    test "is set and cleared, and empty means cleared", %{project: project} do
      assert {:ok, project} = Projects.set_model(project, "opus")
      assert project.model == "opus"

      # Not "the model named empty string": cleared, which resolves to the machine's.
      assert {:ok, project} = Projects.set_model(project, "   ")
      assert is_nil(project.model)
    end

    # Names change faster than the platform. A validator that knew them would refuse a model
    # released last week — refusing work for being newer than the code.
    test "any non-empty name is accepted", %{project: project} do
      assert {:ok, project} = Projects.set_model(project, "claude-something-not-released-yet")
      assert project.model == "claude-something-not-released-yet"
    end
  end

  describe "a conversation" do
    test "runs on the model it was opened with", %{project: project} do
      {:ok, _project} = Projects.set_model(project, "sonnet")
      {:ok, chat} = Conversations.open(project, "hello", model: "opus")

      assert chat.model == "opus"
      assert Jobs.model_for(chat) == "opus"
    end

    test "falls back to the project's when it named none", %{project: project} do
      {:ok, project} = Projects.set_model(project, "sonnet")
      {:ok, chat} = Conversations.open(project, "hello")

      assert is_nil(chat.model)
      assert Jobs.model_for(chat) == "sonnet"
    end

    # Nil at the end of the chain is not "no model": it is the machine's, which is the
    # platform-wide setting the worker was built with.
    test "falls through to the machine's when nothing says", %{project: project} do
      {:ok, chat} = Conversations.open(project, "hello")

      assert is_nil(Jobs.model_for(chat))
    end

    test "an empty choice is the project's, not a model named nothing", %{project: project} do
      {:ok, project} = Projects.set_model(project, "haiku")
      {:ok, chat} = Conversations.open(project, "hello", model: "  ")

      assert is_nil(chat.model)
      assert Jobs.model_for(chat) == "haiku"
    end
  end

  # Everything that already existed keeps working, and keeps running on the machine's model.
  # Both columns are nullable and null is the bottom of the chain, so a row written before any of
  # this resolves exactly as it did.
  describe "what was already there" do
    test "a spec stored before the field existed has no model, and no opinion", %{
      project: project
    } do
      ticket = ticket_fixture(%{project: project})

      # Exactly the shape on disk for every job created before this: no `model` key at all.
      job = job_fixture(%{ticket: ticket, spec: %{"prompt" => "agents/refine.md"}})

      assert is_nil(Jobs.spec(job).model)
      assert is_nil(Jobs.model_for(job))
    end

    test "a project written before the column existed reads as no default", %{project: project} do
      assert is_nil(project.model)
      assert is_nil(Jobs.model_for(chat_fixture(%{project: project})))
    end

    # A workflow pinned before `model` was a key still parses: it is stored as the raw map and
    # re-parsed, so a key nothing ever set is simply absent. Stripped from the map here, because
    # that is exactly what every workflow pinned before this change looks like.
    test "a workflow pinned before the key existed still parses", %{project: project} do
      ticket = ticket_fixture(%{project: project})

      without_model =
        update_in(ticket.workflow, ["states"], fn states ->
          Map.new(states, fn {name, state} -> {name, Map.delete(state, "model")} end)
        end)

      assert {:ok, workflow} = ForgeCore.Workflow.Parser.from_map(without_model)
      assert Enum.all?(Map.values(workflow.states), &is_nil(&1.model))
    end
  end

  describe "a workflow job" do
    test "runs on its state's model, over the project's", %{project: project} do
      {:ok, _project} = Projects.set_model(project, "sonnet")
      ticket = ticket_fixture(%{project: project})
      job = job_fixture(%{ticket: ticket, spec: %{"model" => "opus"}})

      assert Jobs.model_for(job) == "opus"
    end

    test "falls back to the project's when its state named none", %{project: project} do
      {:ok, _project} = Projects.set_model(project, "sonnet")
      ticket = ticket_fixture(%{project: project})
      job = job_fixture(%{ticket: ticket, spec: %{}})

      assert Jobs.model_for(job) == "sonnet"
    end

    # The stored spec keeps what the *state* declared, which is pinned with the workflow. The
    # project's default is not pinned, so it is read when the job runs rather than when it was
    # created — a job made a week ago should use the project's answer now.
    test "the project's answer is read when the job runs, not when it was created", %{
      project: project
    } do
      ticket = ticket_fixture(%{project: project})
      job = job_fixture(%{ticket: ticket, spec: %{}})

      assert is_nil(Jobs.model_for(job))

      {:ok, _project} = Projects.set_model(project, "haiku")

      assert Jobs.model_for(Repo.get!(Job, job.id)) == "haiku"
    end
  end
end
