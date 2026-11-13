defmodule Forge.Look.Setups.TicketViews do
  @moduledoc """
  The ticket's views (`docs/design/ui.md` § The ticket): a ticket done and merged (`5g`), one with
  a job running and nothing waiting (`5d`, `6d`), one waiting on a document's approval with
  documents in every group (`6a`, and the wide column of `16i`), one stuck with its ways forward,
  and a release with what merged since the previous one (`21e`).

  Users: `member`. Paths: `done`, `running`, `docs`, `stuck`, `release`. Made from fixtures — no
  repository, so Changes says the branch is not there.
  """

  @behaviour Forge.Look.Setups

  import Ecto.Query, only: [from: 2]
  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.TicketFixtures

  alias Forge.Repo
  alias Forge.Tickets.Ticket

  @impl true
  def build do
    member = user_fixture()
    project = project_fixture(%{name: "look-views"}) |> join!(member)

    ticket =
      &ticket_fixture(Map.merge(%{project: project, branch: "ticket/#{&1}", number: &1}, &2))

    previous =
      ticket.(30, %{title: "0.31.0", workflow: Map.put(workflow_map(), "release", true)})

    Repo.update_all(from(t in Ticket, where: t.id == ^previous.id),
      set: [status: :done, updated_at: DateTime.add(DateTime.utc_now(:second), -5 * 86_400)]
    )

    done = done!(ticket.(38, %{title: "Show the score on the end screen", state: "merged"}))
    running = running_ticket!(ticket.(41, %{title: "Persist the high score table"}))
    docs = docs_ticket!(ticket.(42, %{title: "Pause menu keyboard navigation"}), member)
    stuck = stuck!(ticket.(44, %{title: "Replace the font atlas with a single SDF texture"}))

    merged!(ticket.(39, %{title: "Sound toggle in settings", state: "merged"}), 86_400)

    release =
      ticket.(46, %{
        title: "0.32.0",
        body: "Everything merged since 0.31. Leave the font atlas out, it's still in review.",
        workflow: Map.put(workflow_map(), "release", true)
      })

    running!(release, ["git log --oneline 0.31.0..main"])

    path = &"/tickets/#{project.name}/#{&1.number}"

    %{
      users: %{"member" => member},
      paths: %{
        "done" => path.(done),
        "running" => path.(running),
        "docs" => path.(docs),
        "stuck" => path.(stuck),
        "release" => path.(release)
      }
    }
  end

  defp done!(ticket) do
    for state <- ~w(refining planning implementing verifying), do: ran!(ticket, state)
    merged!(ticket, 2 * 86_400)
  end

  defp running_ticket!(ticket) do
    ticket = ticket |> Ecto.Changeset.change(state: "implementing") |> Repo.update!()
    refining = ran!(ticket, "refining")
    planning = ran!(ticket, "planning")

    wrote!(
      ticket,
      "refinement.md",
      "---\noutcome: done\n---\n# Refinement\n",
      {:job, refining.id}
    )

    wrote!(ticket, "plan.md", "# Plan\n\nStore scores in a table.\n", {:job, planning.id})

    running!(ticket, [
      "mix test test/game/scores_test.exs",
      "sed -n 1,40p lib/game/scores.ex",
      "mix test test/game/scores_test.exs"
    ])

    ticket
  end

  defp docs_ticket!(ticket, member) do
    ticket = ticket |> Ecto.Changeset.change(state: "planning") |> Repo.update!()
    refining = ran!(ticket, "refining")
    planning = ran!(ticket, "planning")
    wrote!(ticket, "brief.md", "# Brief\n\nPause from the keyboard.\n", {:user, member.id})
    wrote!(ticket, "triage.log", "triaged: ready\n", {:job, refining.id})
    wrote!(ticket, "plan.md", "# Plan\n\nA first plan.\n", {:job, planning.id})

    wrote!(
      ticket,
      "plan.md",
      "# Plan\n\nEscape opens the pause menu; arrows move between its rows.\n",
      {:job, planning.id}
    )

    pending!(ticket, "implementing", ["plan.md"])
  end

  defp stuck!(ticket) do
    ran!(ticket, "refining", %{outcome: :budget_exhausted, exhausted: :turns})
    wrote!(ticket, "refinement.md", "---\noutcome: done\n---\n# Refinement\n")
    {:ok, stuck} = Forge.Engine.stick(ticket, "it ran out of turns")
    stuck
  end
end
