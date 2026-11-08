defmodule Forge.Look.Setups.Ticket do
  @moduledoc """
  A project with one member and one ticket holding a document: enough for the queue, the project
  page and the ticket page to have something to draw. Users: `member` (a project admin).
  Paths: `queue`, `project`, `ticket`.
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures

  @impl true
  def build do
    member = user_fixture()
    project = project_fixture(%{name: "look-game"}) |> join!(member)
    ticket = ticket_fixture(%{project: project, title: "Persist the high score table"})

    {:ok, _} =
      Forge.Artifacts.record_version(ticket.id, "refinement.md", :document, :system, %{
        content: "---\noutcome: done\n---\n# Refinement\n\nScores should survive a restart.\n"
      })

    %{
      users: %{"member" => member},
      paths: %{
        "queue" => "/",
        "project" => "/projects/#{project.name}",
        "ticket" => "/tickets/#{project.name}/#{ticket.number}"
      }
    }
  end
end
