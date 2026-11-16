defmodule Forge.Look.Setups.Milestones do
  @moduledoc """
  A project with milestones and tickets on hold (`docs/design/ui.md` § Milestones): a current
  milestone with held, in-flight and merged tickets, a second open one and a closed one, tickets in
  no milestone (one held), a held ticket with a run still going (Stop now) and one with a blocking
  question, a milestone of two hundred tickets for the phone, and one with a long hostile name.
  Users: `member` (a project admin), `newcomer` (in no project). Paths: `project`, `milestones`
  (the view, which holds the two-hundred milestone too), `held` (a held ticket with a run going),
  `asking` (a held ticket with a blocking question), `held_idle` (a held ticket that never
  started) and `new` (the ticket form).

  Every name is made up, and the markup in the hostile one is text.
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.TicketFixtures, only: [merged!: 2]

  alias Forge.{Engine, Milestones}

  @impl true
  def build do
    member = user_fixture()
    newcomer = user_fixture()
    project = project_fixture(%{name: "look-goals"}) |> join!(member)
    actor = {:user, member.id}

    {:ok, current} =
      Milestones.create(
        project,
        %{
          name: "0.4 · saves",
          description: "Scores and settings survive a restart, on every platform we ship."
        },
        actor
      )

    {:ok, next} = Milestones.create(project, %{name: "0.5 · sound", description: nil}, actor)

    {:ok, hostile} =
      Milestones.create(
        project,
        %{
          name: "<b>Bold</b> " <> String.duplicate("a very long milestone name ", 2),
          description: "<script>alert(1)</script> " <> String.duplicate("long words ", 40)
        },
        actor
      )

    {:ok, big} = Milestones.create(project, %{name: "2.0 · everything"}, actor)
    {:ok, closed} = Milestones.create(project, %{name: "0.1 · prototype"}, actor)
    {:ok, _} = Milestones.set_current(project.id, current.id, actor)

    held_idle = place!(project, "Persist the high score table", current, actor, held: true)
    running = place!(project, "Save settings to disk", current, actor, held: false)
    asking = place!(project, "Which file format for saves?", current, actor, held: false)
    merged = place!(project, "Add a save slot", current, actor, held: false)
    merged!(merged, 3600)
    place!(project, "Autosave every minute", current, actor, held: false)

    place!(project, "Mix the music down", next, actor, held: true)

    place!(project, "A title that never ends " <> String.duplicate("and on ", 30), hostile, actor,
      held: true
    )

    place!(project, "Sketch the first level", closed, actor, held: false)
    {:ok, _} = Milestones.close(project.id, closed.id, actor)

    place!(project, "Fix the pause menu", nil, actor, held: true)
    place!(project, "Rename the repository", nil, actor, held: false)

    for n <- 1..200,
        do: place!(project, "Backlog idea #{n}", big, actor, held: rem(n, 3) == 0)

    # A held ticket whose run is still going: Stop now is offered.
    Forge.ForgeFixtures.job_fixture(%{ticket: running, status: :running})
    {:ok, _held} = Engine.hold(running, actor)

    # A held ticket with a blocking question: a decision waits, so it is listed with what waits.
    Forge.TicketFixtures.wrote!(
      asking,
      "refinement.md",
      "---\noutcome: done\n---\n# Refinement\n\n```question\nkey: format\ntext: \"Which format?\"\noptions:\n  - label: \"JSON\"\n    detail: \"Readable.\"\n  - label: \"Binary\"\n    detail: \"Small.\"\nblocking: true\n```\n"
    )

    {:ok, _held} = Engine.hold(asking, actor)
    Forge.ForgeFixtures.job_fixture(%{ticket: asking, status: :waiting})

    base = "/projects/#{project.name}"

    %{
      users: %{"member" => member, "newcomer" => newcomer},
      paths: %{
        "project" => base,
        "milestones" => base <> "?view=milestones",
        "held" => "/tickets/#{project.name}/#{running.number}",
        "asking" => "/tickets/#{project.name}/#{asking.number}",
        "held_idle" => "/tickets/#{project.name}/#{held_idle.number}",
        "new" => "/tickets/new?project=#{project.name}"
      }
    }
  end

  # A ticket put in `milestone` (or none) and, when asked, on hold.
  defp place!(project, title, milestone, actor, held: held) do
    ticket = Forge.ForgeFixtures.ticket_fixture(%{project: project, title: title})

    ticket =
      if milestone do
        {:ok, placed} = Milestones.set_ticket_milestone(ticket, milestone.id, actor)
        placed
      else
        {:ok, placed} = Milestones.set_ticket_milestone(ticket, nil, actor)
        placed
      end

    if held do
      {:ok, held} = Engine.hold(ticket, actor)
      held
    else
      ticket
    end
  end
end
