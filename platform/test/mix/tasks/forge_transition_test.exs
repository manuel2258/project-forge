defmodule Mix.Tasks.Forge.TransitionTest do
  @moduledoc """
  `mix forge.transition` reaches a jump through the operation a click does, and says why it is
  refused in the sentence the page and the API use (`docs/design/workflow-grammar-v1.md` § Jumping).
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures
  import Forge.MergeFixtures

  alias Forge.{Jobs, Repo, Tickets}
  alias Mix.Tasks.Forge.Transition

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    {:ok, project} =
      register_owned!(%{
        name: "tr-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo(jump_files())
      })

    user = member_fixture(project)
    funded!(project)
    {:ok, ticket} = Tickets.admit(project, %{title: "Jump", body: "."}, {:user, user.id})

    for job <- Jobs.for_ticket(ticket.id) do
      job |> Ecto.Changeset.change(status: :finished, outcome: :converged) |> Repo.update!()
    end

    ticket |> Ecto.Changeset.change(status: :stuck) |> Repo.update!()
    %{project: project, user: user, ticket: ticket}
  end

  test "a state no transition leads to is taken as a jump", %{
    project: project,
    user: user,
    ticket: ticket
  } do
    # `refining` has an edge to `planning` only, so `review_ready` is reached by a jump.
    Transition.run(["#{project.name}##{ticket.number}", "review_ready", "--user", user.email])

    assert_received {:mix_shell, :info, [message]}
    assert message =~ "is now in review_ready"
    assert Tickets.get!(ticket.id).state == "review_ready"
  end

  test "a refusal is said in words and not as a term", %{
    project: project,
    user: user,
    ticket: ticket
  } do
    error =
      assert_raise Mix.Error, fn ->
        Transition.run(["#{project.name}##{ticket.number}", "implementing", "--user", user.email])
      end

    assert error.message =~ "has no version yet"
    refute error.message =~ "{:missing_input"
    assert Tickets.get!(ticket.id).state == "refining"
  end
end
