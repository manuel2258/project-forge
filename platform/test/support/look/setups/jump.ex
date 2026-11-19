defmodule Forge.Look.Setups.Jump do
  @moduledoc """
  The fold of other states on Steps (`docs/design/ui.md` § Steps, ticket 56): a ticket stuck in
  `refining` with its one arrow, and a second one that has a changeset and a commit message, so
  the jump into `merged` is drawn as the approval it records; a done ticket, which is reopened by
  a jump; and one already moved by a jump, so that Steps and Activity read it.

  Users: `member`. Paths: `stuck`, `ready`, `done`, `jumped`. The workflow is
  `Forge.MergeFixtures.jump_workflow/1`; no secret, no worker.
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.MergeFixtures
  import Forge.ProjectFixtures, only: [commit_files!: 3]

  alias Forge.{Artifacts, Jobs, Operator, Projects, Repo, Tickets}

  @impl true
  def build do
    member = user_fixture()
    name = "look-jump"
    File.rm_rf!(Path.join(Projects.repos_dir(), name <> ".git"))
    {:ok, project} = Projects.register_named(name, "main", member)

    commit_files!(
      Projects.repo_path(project),
      "main",
      Map.put(jump_files(), "README.md", "# Game\n")
    )

    funded!(project)

    stuck = rest!(project, member, "Persist the high score table")
    ready = ready!(project, member)
    done = rest!(project, member, "Sound toggle in settings", "merged", :done)
    jumped = jumped!(project, member)

    %{
      users: %{"member" => member},
      paths:
        Map.new(~w(stuck ready done jumped)a, fn key ->
          ticket = Map.fetch!(%{stuck: stuck, ready: ready, done: done, jumped: jumped}, key)
          {Atom.to_string(key), "/tickets/#{project.name}/#{ticket.number}"}
        end)
    }
  end

  # A ticket whose job is over, with the document its one edge approves, resting in `state`.
  defp rest!(project, member, title, state \\ "refining", status \\ :stuck) do
    {:ok, ticket} = Tickets.admit(project, %{title: title}, {:user, member.id})

    for job <- Jobs.for_ticket(ticket.id) do
      job |> Ecto.Changeset.change(status: :finished, outcome: :converged) |> Repo.update!()
    end

    {:ok, _} =
      Artifacts.record_version(ticket.id, "refinement.md", :document, :system, %{
        content: "---\noutcome: done\n---\n# Refinement\n\nScores should survive a restart.\n"
      })

    ticket |> Ecto.Changeset.change(state: state, status: status) |> Repo.update!()
  end

  defp ready!(project, member) do
    ticket = rest!(project, member, "Add a sound toggle to settings")

    sha =
      commit_files!(Projects.repo_path(project), ticket.branch, %{
        "lib/game/settings.ex" => "defmodule Game.Settings do\n  defstruct sound: true\nend\n"
      })

    changeset!(ticket, sha)
    commit_message!(ticket, "Add a sound toggle to settings\n\nPersists in the save file.\n")
    ticket
  end

  defp jumped!(project, member) do
    ticket = rest!(project, member, "Plan went wrong")
    {:ok, moved} = Operator.transition(ticket, member, "review_ready", comment: "plan skipped")
    moved
  end
end
