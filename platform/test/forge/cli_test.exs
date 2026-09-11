defmodule Forge.CLITest do
  use Forge.DataCase, async: false

  import Forge.AccountsFixtures
  import Forge.GitFixtures

  alias Forge.{CLI, Projects, Tickets}

  test "resolves tickets, shows them and renders the queue" do
    {:ok, project} =
      Projects.register(%{
        name: "cli-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo()
      })

    user = user_fixture()
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})

    assert CLI.ticket("#{project.name}#1").id == ticket.id
    assert CLI.label(ticket) == "#{project.name}#1"

    shown = CLI.show(ticket)
    assert shown =~ "state: refined  status: active"
    assert shown =~ "refined #1  pending"
    assert shown =~ "ticket.admitted"

    assert CLI.queue() == "queue is empty"
    assert CLI.user(user: user.email).id == user.id
  end
end
