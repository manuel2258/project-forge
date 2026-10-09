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
      budget: { turns: 5, cost: 1.00 }
    review_ready: {}
  transitions:
    - { from: INITIAL, to: review_ready }
  limits: { ticket_cost: 5.00 }
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
    Admit.run([project.name, "Lost slot", "--type", "bug", "--user", user.email])

    assert [%{ticket_type: "bug", state: "fixing"}] = Tickets.list(project)
  end

  test "without --type, a project with several says which there are", %{
    project: project,
    user: user
  } do
    assert_raise Mix.Error,
                 "it has more than one ticket type, so one must be chosen: bug, feature",
                 fn -> Admit.run([project.name, "Lost slot", "--user", user.email]) end
  end
end
