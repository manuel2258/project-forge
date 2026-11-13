defmodule Forge.HarnessChainTest do
  @moduledoc """
  Which harness a job runs, and which model and effort it gets for that harness
  (`docs/design/workflow-grammar-v1.md` § Harness, § Model, § Effort).

  The chain is state, then project, then Claude Code; and a project holds a model and an effort
  for each harness, so setting Codex's never moves a Claude job and the other way round.
  """

  use Forge.DataCase, async: false

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Conversations, Jobs, Operator, Projects, Tickets}

  @workflow Path.expand("../../../core/test/fixtures/workflow_example.yml", __DIR__)

  setup do
    config = Application.get_env(:forge, Forge.Jobs)

    Application.put_env(
      :forge,
      Forge.Jobs,
      Keyword.put(config, :data_dir, tmp_dir("harness-chain-data"))
    )

    on_exit(fn -> Application.put_env(:forge, Forge.Jobs, config) end)

    # A repository behind it, which opening a conversation (and admitting a ticket) needs.
    bare = seeded_repo()
    name = "chain#{System.unique_integer([:positive])}"
    {:ok, project} = register_owned!(%{name: name, repo_path: bare, default_branch: "main"})

    %{
      project: project,
      admin: member_fixture(project, :admin),
      member: member_fixture(project, :member)
    }
  end

  describe "resolve_harness/2" do
    test "the state's, else the project's, else Claude Code", %{project: project} do
      assert Jobs.resolve_harness(nil, project.id) == "claude_code"
      assert Jobs.resolve_harness("codex", project.id) == "codex"

      {:ok, project} = Projects.set_harness(project, "codex")
      assert Jobs.resolve_harness(nil, project.id) == "codex"
      # A state that names one beats the project's, either way round.
      assert Jobs.resolve_harness("claude_code", project.id) == "claude_code"
    end

    test "a project nobody has set anything on behaves as before", %{project: project} do
      assert project.harness == "claude_code"
      assert Jobs.harness(chat_fixture(%{project: project})) == "claude_code"
    end
  end

  describe "a job is made with its harness" do
    defp admit(project, user, yaml) do
      bare = seeded_repo(%{".forge/workflow.yml" => yaml})
      project = Forge.Repo.update!(Projects.Project.changeset(project, %{repo_path: bare}))
      {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
      [job] = Jobs.for_ticket(ticket.id)
      job
    end

    test "a workflow state's harness is the job's", %{project: project, member: member} do
      yaml =
        @workflow
        |> File.read!()
        |> String.replace("    env: refine\n", "    env: refine\n    harness: codex\n",
          global: false
        )

      assert admit(project, member, yaml).harness == "codex"
    end

    test "a state that names none takes the project's", %{project: project, member: member} do
      {:ok, project} = Projects.set_harness(project, "codex")
      assert admit(project, member, File.read!(@workflow)).harness == "codex"
    end

    test "and Claude Code when neither says", %{project: project, member: member} do
      assert admit(project, member, File.read!(@workflow)).harness == "claude_code"
    end

    test "a conversation is opened on the one picked, else the project's", %{project: project} do
      {:ok, plain} = Conversations.open(project, "hello")
      assert plain.harness == "claude_code"

      {:ok, picked} = Conversations.open(project, "hello", harness: "codex")
      assert picked.harness == "codex"

      {:ok, project} = Projects.set_harness(project, "codex")
      {:ok, defaulted} = Conversations.open(project, "hello")
      assert defaulted.harness == "codex"

      {:ok, back} = Conversations.open(project, "hello", harness: "claude_code")
      assert back.harness == "claude_code"
    end

    test "a harness nobody knows is refused, not opened", %{project: project} do
      assert {:error, :unknown_harness} = Conversations.open(project, "hello", harness: "codx")
      # Not a string at all is not a choice, as for the model: the project's.
      assert {:ok, chat} = Conversations.open(project, "hello", harness: %{"x" => "y"})
      assert chat.harness == "claude_code"
    end
  end

  describe "model and effort per harness" do
    test "each harness reads its own dials of the project", %{project: project} do
      {:ok, project} = Projects.set_model(project, "opus")
      {:ok, project} = Projects.set_effort(project, "high")
      {:ok, project} = Projects.set_codex_model(project, "gpt-x")
      {:ok, project} = Projects.set_codex_effort(project, "medium")

      claude = chat_fixture(%{project: project})
      codex = chat_fixture(%{project: project, harness: "codex"})

      assert {Jobs.model_for(claude), Jobs.effort_for(claude)} == {"opus", "high"}
      assert {Jobs.model_for(codex), Jobs.effort_for(codex)} == {"gpt-x", "medium"}
    end

    test "a project that set only the other harness's dials leaves this one on the machine's",
         %{project: project} do
      {:ok, project} = Projects.set_codex_model(project, "gpt-x")
      {:ok, project} = Projects.set_effort(project, "low")

      claude = chat_fixture(%{project: project})
      codex = chat_fixture(%{project: project, harness: "codex"})

      assert Jobs.model_for(claude) == nil
      assert Jobs.effort_for(codex) == nil
    end

    test "the job's own, picked when it was opened, still comes first", %{project: project} do
      {:ok, project} = Projects.set_codex_model(project, "gpt-x")
      chat = chat_fixture(%{project: project, harness: "codex", model: "gpt-y", effort: "low"})

      assert {Jobs.model_for(chat), Jobs.effort_for(chat)} == {"gpt-y", "low"}
    end

    test "a cleared Codex model is Codex's own default, not an empty string", %{project: project} do
      {:ok, project} = Projects.set_codex_model(project, "gpt-x")
      {:ok, project} = Projects.set_codex_model(project, "  ")
      assert project.codex_model == nil
    end
  end

  describe "who may set them" do
    test "the project's harness and Codex's dials are an admin's", ctx do
      %{project: project, admin: admin, member: member} = ctx

      assert {:error, :forbidden} = Operator.set_harness(project, member, "codex")
      assert {:error, :forbidden} = Operator.set_codex_model(project, member, "gpt-x")
      assert {:error, :forbidden} = Operator.set_codex_effort(project, member, "high")

      assert %{harness: "claude_code", codex_model: nil, codex_effort: nil} =
               Projects.get!(project.id)

      assert {:ok, _} = Operator.set_harness(project, admin, "codex")
      assert {:ok, _} = Operator.set_codex_model(project, admin, "gpt-x")
      assert {:ok, _} = Operator.set_codex_effort(project, admin, "high")

      assert %{harness: "codex", codex_model: "gpt-x", codex_effort: "high"} =
               Projects.get!(project.id)
    end

    test "a harness the registry does not list is refused", %{project: project, admin: admin} do
      assert {:error, %Ecto.Changeset{errors: [harness: _]}} =
               Operator.set_harness(project, admin, "codx")

      assert Projects.get!(project.id).harness == "claude_code"
    end
  end
end
