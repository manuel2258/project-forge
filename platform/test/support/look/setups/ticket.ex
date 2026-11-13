defmodule Forge.Look.Setups.Ticket do
  @moduledoc """
  A project with one member and one ticket holding a document: enough for the queue, the project
  page and the ticket page to have something to draw. The member owns a credential in the
  project's pool that has reported both windows, 42 % of the five-hour and 18 % of the week, so
  the usage lines, the digits and the usage panel draw figures. Users: `member` (a project admin).
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

    reported!(project, member)

    %{
      users: %{"member" => member},
      paths: %{
        "queue" => "/",
        "project" => "/projects/#{project.name}",
        "ticket" => "/tickets/#{project.name}/#{ticket.number}"
      }
    }
  end

  # A credential of the member's, in the pool, whose last report named both windows: what a
  # worker sends from a harness's rate-limit event. The job is a conversation because it is the
  # smallest thing that can carry a credential.
  defp reported!(project, member) do
    credential = pool!(project, credential_fixture(member))
    chat = chat_fixture(%{project: project})
    {:ok, _} = chat |> Ecto.Changeset.change(credential_id: credential.id) |> Forge.Repo.update()
    now = System.os_time(:second)

    :ok =
      Forge.Jobs.record_harness_event(chat.id, %{
        type: "job.harness.rate_limit",
        payload: %{
          status: "allowed",
          rate_limit_type: "five_hour",
          utilization: 0.42,
          resets_at: now + 2 * 3600,
          windows: %{
            "five_hour" => %{"utilization" => 0.42, "resets_at" => now + 2 * 3600},
            "seven_day" => %{"utilization" => 0.18, "resets_at" => now + 4 * 86_400}
          }
        }
      })
  end
end
