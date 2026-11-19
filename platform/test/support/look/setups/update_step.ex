defmodule Forge.Look.Setups.UpdateStep do
  @moduledoc """
  What an update step leaves on the screens (`docs/design/workflow-grammar-v1.md` § Bringing the
  branch up to date, `docs/design/ui.md` § Steps, § The details, § Activity, § The queue,
  § Workflow): a ticket whose step merged what two tickets and a conversation landed, a ticket whose step
  conflicted and went to a resolving job, a ticket whose step could not re-pin it, and, in a
  second project whose step names no conflict state, a ticket the step stuck; a third project's
  default branch has a workflow that no longer validates.

  Users: `member`. Paths: `merged` (a visit with four merges — two tickets', a conversation's and a commit nothing recorded —
  and a re-pin), `forwarded`, `current`,
  `conflict` (went to `resolving`, one path a hostile name), `skipped` (a re-pin the engine could
  not make, whose notice is in the details), `stuck` (the queue item), `workflow` (the project's
  Workflow view with the step's box, and `workflow_bare` one whose step names no conflict state).

  Built by the engine, as the suite's flow tests are: a job ends, the engine takes the edge into the
  step, the step runs against a repository that has moved. Made-up data only.
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures
  import Forge.GitFixtures, only: [update_workflow: 0, update_workflow: 1]
  import Forge.ProjectFixtures, only: [commit_files!: 3, commit_files!: 4]

  alias Forge.{Engine, Events, Jobs, Projects, Repo, Tickets}
  alias Forge.Look.Setups.Decision

  @integrate "Merge the default branch into the branch and resolve what conflicts.\n"

  @impl true
  def build do
    member = user_fixture()
    project = project!("look-update", update_workflow(), member)
    bare = project!("look-update-bare", update_workflow(conflict: false), member)
    # Its own project: the default branch's workflow is broken below, which the Workflow view of a
    # project would say instead of drawing the step.
    broken = project!("look-update-broken", update_workflow(), member)

    merged = admit!(project, member, "Practice timer")
    conflict = admit!(project, member, "Rename the high score table")
    forwarded = admit!(project, member, "Show the rank outside the top ten")
    current = admit!(project, member, "Sound toggle in settings")
    skipped = admit!(broken, member, "Pin the player's row")
    stuck = admit!(bare, member, "Settings screen")

    # Work of its own on the branches that have some.
    own!(merged, "lib/game/timer.ex", "defmodule Game.Timer do\nend\n")
    own!(conflict, "notes <b>bold</b>.md", "the branch's version\n")
    own!(conflict, "README.md", "# Game, the branch's version\n")
    own!(stuck, "README.md", "# Game, the branch's version\n")

    # Already current: the default branch has not moved since, so the step has nothing to do.
    finish!(current)

    # What lands on the default branch meanwhile: two tickets' merges and a conversation's.
    landed!(project, member, "Settings screen", "lib/game/settings.ex")
    landed!(project, member, "Home screen <i>new</i>", "lib/game/home.ex")
    chat_merge!(project, "lib/game/notes.ex")

    # Then it moves again, over the files the conflicting branches changed and a prompt.
    commit_files!(Projects.repo_path(project), "main", %{
      "README.md" => "# Game, as main has it\n",
      "notes <b>bold</b>.md" => "main's version\n",
      ".forge/agents/implement.md" => "Implement the plan, in newer words.\n"
    })

    commit_files!(Projects.repo_path(bare), "main", %{"README.md" => "# Game, as main has it\n"})

    finish!(merged)
    finish!(conflict)
    finish!(forwarded)

    # The workflow at the default branch's head no longer validates: the step brings the code up to
    # date and says it could not re-pin.
    commit_files!(Projects.repo_path(broken), "main", %{
      ".forge/workflow.yml" => "version: 1\ninitial: nowhere\nstates: {}\ntransitions: []\n"
    })

    finish!(skipped)
    finish!(stuck)

    %{
      users: %{"member" => member},
      paths: %{
        "merged" => "/tickets/#{project.name}/#{merged.number}",
        "forwarded" => "/tickets/#{project.name}/#{forwarded.number}",
        "current" => "/tickets/#{project.name}/#{current.number}",
        "conflict" => "/tickets/#{project.name}/#{conflict.number}",
        "skipped" => "/tickets/#{broken.name}/#{skipped.number}",
        "stuck" => "/?item=stuck-#{stuck.id}",
        "workflow" => "/projects/#{project.name}?view=workflow",
        "workflow_bare" => "/projects/#{bare.name}?view=workflow"
      }
    }
  end

  defp project!(name, workflow, member) do
    project = Decision.project!(name, workflow, member)

    commit_files!(Projects.repo_path(project), "main", %{
      ".forge/agents/integrate.md" => @integrate
    })

    project
  end

  defp admit!(project, member, title) do
    {:ok, ticket} = Tickets.admit(project, %{title: title, body: "."}, {:user, member.id})
    ticket
  end

  defp own!(ticket, path, content) do
    project = Projects.get!(ticket.project_id)
    commit_files!(Projects.repo_path(project), ticket.branch, %{path => content})
  end

  # A ticket's merge landing: its commit on the default branch, and the event the platform records.
  defp landed!(project, member, title, path) do
    ticket = admit!(project, member, title)

    sha =
      commit_files!(Projects.repo_path(project), "main", %{path => "made-up\n"},
        message: "Merge #{ticket.branch}: #{title}"
      )

    {:ok, _} =
      Events.append("ticket.merged", {:user, member.id}, %{
        ticket_id: ticket.id,
        payload: %{"sha" => sha, "already" => false, "changeset" => sha}
      })
  end

  defp chat_merge!(project, path) do
    sha =
      commit_files!(Projects.repo_path(project), "main", %{path => "made-up\n"},
        message: "Merge chat: notes on the timer"
      )

    {:ok, _} =
      Events.append("chat.merged", :system, %{
        project_id: project.id,
        payload: %{"chat" => "look-chat", "sha" => sha}
      })
  end

  # The implementing job ends and the engine takes the edge into the step, which runs.
  defp finish!(ticket) do
    job =
      ticket.id
      |> Jobs.for_ticket()
      |> Enum.filter(&(&1.state == "implementing"))
      |> List.last()
      |> Ecto.Changeset.change(
        status: :finished,
        outcome: :converged,
        declared_outcome: "done",
        started_at: DateTime.utc_now(:second)
      )
      |> Repo.update!()

    {:ok, moved} = Engine.after_job(Tickets.get!(ticket.id), job, "done")
    moved
  end
end
