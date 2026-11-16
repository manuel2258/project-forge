defmodule Mix.Tasks.Forge.AdmitTest do
  @moduledoc """
  `mix forge.admit` takes the ticket type with `--type`, and says why it refuses in the sentence
  the ticket form uses (`docs/design/ticket-types.md` § Admission).
  """

  use Forge.DataCase, async: false

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.Tickets
  alias Mix.Tasks.Forge.Admit

  @workflow """
  version: 1
  initial: INITIAL
  states:
    INITIAL:
      prompt: agents/implement.md
      inputs: [ticket]
      produces: [changeset]
      budget: { turns: 5, tokens: 200k }
    review_ready: {}
  transitions:
    - { from: INITIAL, to: review_ready }
  limits: { ticket_tokens: 1M }
  """

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    repo =
      seeded_repo(%{
        ".forge/workflow.yml" => nil,
        ".forge/workflows/bug.yml" => String.replace(@workflow, "INITIAL", "fixing"),
        ".forge/workflows/feature.yml" => String.replace(@workflow, "INITIAL", "building")
      })

    {:ok, project} =
      register_owned!(%{name: "admit-#{System.unique_integer([:positive])}", repo_path: repo})

    %{project: project, user: user_fixture()}
  end

  test "--type admits as that type", %{project: project, user: user} do
    Admit.run([project.name, "Lost slot", "--start", "--type", "bug", "--user", user.email])

    assert [%{ticket_type: "bug", state: "fixing"}] = Tickets.list(project)
  end

  test "without --type, a project with several says which there are", %{
    project: project,
    user: user
  } do
    assert_raise Mix.Error,
                 "it has more than one ticket type, so one must be chosen: bug, feature",
                 fn -> Admit.run([project.name, "Lost slot", "--start", "--user", user.email]) end
  end

  test "--type naming the release is refused, saying who starts one", %{
    project: project,
    user: user
  } do
    commit_to_default(project, %{
      ".forge/workflows/bug.yml" =>
        "release: true\n" <> String.replace(@workflow, "INITIAL", "fixing")
    })

    assert_raise Mix.Error, ~r/bug is this project's release.*Release on the project page/, fn ->
      Admit.run([project.name, "Lost slot", "--start", "--type", "bug", "--user", user.email])
    end

    assert Tickets.list(project) == []
  end

  describe "start or hold" do
    test "exactly one of --start and --hold is required, and nothing is admitted without it", %{
      project: project,
      user: user
    } do
      base = [project.name, "Lost slot", "--type", "bug", "--user", user.email]

      for flags <- [[], ["--start", "--hold"]] do
        assert_raise Mix.Error, ~r/exactly one/, fn -> Admit.run(base ++ flags) end
      end

      assert Tickets.list(project) == []
    end

    test "--hold admits on hold, with nothing made, into the milestone --milestone names", %{
      project: project,
      user: user
    } do
      {:ok, _} = Forge.Milestones.create(project, %{name: "0.4"}, :system)

      Admit.run([
        project.name,
        "Idea",
        "--hold",
        "--milestone",
        "0.4",
        "--type",
        "bug",
        "--user",
        user.email
      ])

      assert [%{held_at: held_at, milestone_id: milestone_id} = ticket] = Tickets.list(project)
      assert held_at
      assert milestone_id
      assert Forge.Jobs.for_ticket(ticket.id) == []
      assert_received {:mix_shell, :info, [message]}
      assert message =~ "on hold"
    end

    test "--start admits and creates its first job; an unknown milestone is refused", %{
      project: project,
      user: user
    } do
      assert_raise Mix.Error, ~r/unknown milestone Nope/, fn ->
        Admit.run([
          project.name,
          "Idea",
          "--start",
          "--milestone",
          "Nope",
          "--type",
          "bug",
          "--user",
          user.email
        ])
      end

      Admit.run([project.name, "Idea", "--start", "--type", "bug", "--user", user.email])
      assert [ticket] = Tickets.list(project)
      assert [%{status: :pending}] = Forge.Jobs.for_ticket(ticket.id)
      refute ticket.held_at
    end
  end
end
