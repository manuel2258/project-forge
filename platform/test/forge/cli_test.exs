defmodule Forge.CLITest do
  use Forge.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Artifacts, CLI, Projects, Tickets}

  test "resolves tickets, shows them and renders the queue" do
    {:ok, project} =
      register_owned!(%{
        name: "cli-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo()
      })

    user = user_fixture()
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})

    assert CLI.ticket("#{project.name}#1").id == ticket.id
    assert CLI.label(ticket) == "#{project.name}#1"

    shown = CLI.show(ticket)
    assert shown =~ "state: refining  status: active"
    assert shown =~ "refining #1  pending"
    assert shown =~ "ticket.admitted"

    assert CLI.queue() == "queue is empty"
    assert CLI.user(user: user.email).id == user.id
  end

  describe "a bare reference" do
    # `mix forge.answer 3` is the shorthand for the node an operator has one project on, and it
    # is only unambiguous there. With two projects the number names two different tickets, and
    # picking one of them is the shape of mistake nobody catches: the command reports success
    # against a ticket the operator was not looking at. Refusing is the whole feature.
    test "is refused when more than one project could mean it" do
      project_fixture()
      project_fixture()

      assert_raise Mix.Error, ~r/more than one project; use project#number/, fn ->
        CLI.ticket("1")
      end
    end

    test "is refused when there is no project at all" do
      assert_raise Mix.Error, ~r/no project registered; use project#number/, fn ->
        CLI.ticket("1")
      end
    end

    test "resolves when exactly one project could mean it" do
      project = project_fixture()
      ticket = ticket_fixture(%{project: project, number: 7})

      assert CLI.ticket("7").id == ticket.id
    end

    # The same rule for `--user`, and for the same reason: every operator action is recorded
    # against whoever took it, so guessing the actor falsifies the record rather than the output.
    test "a user is only implied when there is exactly one" do
      user_fixture()
      user_fixture()

      assert_raise Mix.Error, ~r/more than one user; pass --user EMAIL/, fn -> CLI.user([]) end
    end
  end

  describe "the queue" do
    # `CLI.queue/0` is the whole queue on a terminal, and the only test it had asserted the empty
    # string — which is the one path that renders no item at all. Each kind has its own line, each
    # line carries the detail the operator needs to act on without opening anything, and a clause
    # that dropped that detail would still print a plausible row. So every kind is built here and
    # its line asserted whole.
    test "every kind of decision gets a line that says what to do about it" do
      project = project_fixture()

      asking = ticket_fixture(%{project: project, number: 1, state: "planning"})
      ask(asking)

      approving = ticket_fixture(%{project: project, number: 2, state: "refining"})

      Repo.update!(
        Ecto.Changeset.change(approving,
          pending_transition: %{
            "from" => "refining",
            "to" => "planning",
            "approve" => ["refinement.md"]
          }
        )
      )

      stuck = ticket_fixture(%{project: project, number: 3, state: "implementing"})
      Repo.update!(Ecto.Changeset.change(stuck, status: :stuck))

      reviewing = ticket_fixture(%{project: project, number: 4, state: "review_ready"})

      # Older than everything above, and still last: an assumption is not waiting on anyone, so
      # it follows the decisions rather than being sorted in among them.
      assuming = ticket_fixture(%{project: project, number: 5, state: "planning"})
      assume(assuming)

      lines = String.split(CLI.queue(), "\n")

      assert line(lines, "QUESTION") ==
               "QUESTION  #{CLI.label(asking)}  [backend] Which backend? options: a | b (default a)"

      assert line(lines, "APPROVAL") ==
               "APPROVAL  #{CLI.label(approving)}  refining -> planning: approve refinement.md"

      # And `forge.show` names the same artifacts, from the same definition.
      assert CLI.show(Tickets.get!(approving.id)) =~
               "pending: refining -> planning needs approval of refinement.md"

      assert line(lines, "STUCK") ==
               "STUCK     #{CLI.label(stuck)}  in implementing; choose a transition with forge.transition"

      assert line(lines, "REVIEW") ==
               "REVIEW    #{CLI.label(reviewing)}  in review_ready; next: merged"

      assert List.last(lines) ==
               "ASSUMED   #{CLI.label(assuming)}  [naming] What is the table called? " <>
                 "assumed: scores (not waiting on you)"

      assert length(lines) == 5
    end
  end

  defp line(lines, prefix) do
    assert [line] = Enum.filter(lines, &String.starts_with?(&1, prefix))
    line
  end

  # A non-blocking question, asked a day ago: the assumption the agent carried on from.
  defp assume(ticket) do
    {:ok, version} =
      Artifacts.record_version(ticket.id, "plan.md", :document, :system, %{
        content: """
        ---
        outcome: done
        ---
        # Plan

        ```question
        key: naming
        text: What is the table called?
        options: [scores, highscores]
        default: scores
        blocking: false
        assumption: scores
        ```
        """
      })

    Repo.update_all(
      from(q in Forge.Artifacts.Question, where: q.artifact_version_id == ^version.id),
      set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -86_400, :second)]
    )
  end

  # A blocking question, written the way an agent writes one: in the document it produced.
  defp ask(ticket) do
    {:ok, _version} =
      Artifacts.record_version(ticket.id, "plan.md", :document, :system, %{
        content: """
        ---
        outcome: done
        ---
        # Plan

        ```question
        key: backend
        text: Which backend?
        options: [a, b]
        default: a
        blocking: true
        ```
        """
      })
  end
end
