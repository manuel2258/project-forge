defmodule Forge.Look.Setups.Decision do
  @moduledoc """
  Every kind of decision row (`docs/design/ui.md` § The decision row), each waiting on a page of
  its own: a ticket in review with a changeset and a `commit-message` (`18b`, `18c`, `18f`), a
  ticket waiting on a document's approval (`18d`), a ticket in a chat step whose document has a
  version and whose last reply left one question open (`16f`, `16g`), and two chats with a
  branch to merge, one clean and one that conflicts with the default branch (`18e`).

  Users: `member`. Paths: `changeset`, `document`, `step`, `step_ticket`, `merge`, `conflict`.
  Built with git's plumbing and recorded versions directly — no worker, since a setup runs before
  the endpoint starts, and not `Forge.GitFixtures`, which cleans up with `ExUnit.Callbacks` that
  a look has no test to run under (`Forge.Look.Setups.RepoFile` says the same).
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.MergeFixtures
  import Forge.ProjectFixtures, only: [commit_files!: 3]

  alias Forge.{Artifacts, Conversations, Jobs, Projects, Tickets}

  @workflow Path.expand("../../../../../core/test/fixtures/workflow_example.yml", __DIR__)
  @external_resource @workflow

  @prompts %{
    ".forge/agents/refine.md" => "Refine the ticket into a crisp problem statement.\n",
    ".forge/agents/plan.md" => "Write a plan.\n",
    ".forge/agents/implement.md" => "Implement the plan.\n",
    ".forge/agents/verify.md" => "Verify the implementation.\n"
  }

  @step_workflow """
  version: 1
  initial: shaping
  states:
    shaping:
      chat: true
      prompt: agents/refine.md
      inputs: [ticket]
      produces: [brief.md]
      outcomes: [shaped, needs_more]
    planning:
      prompt: agents/plan.md
      inputs: [brief.md]
      produces: [plan.md]
      budget: { turns: 5, tokens: 200k }
    parked: {}
  transitions:
    - { from: shaping, to: planning, when: shaped, approve: [brief.md] }
    - { from: shaping, to: parked, when: needs_more }
    - { from: planning, to: parked }
  limits: { ticket_tokens: 5M }
  """

  @impl true
  def build do
    member = user_fixture()
    project = project!("look-review", File.read!(@workflow), member)
    steps = project!("look-steps", @step_workflow, member)

    changeset = changeset_ticket!(project, member)
    document = document_ticket!(project, member)
    {step, chat} = step_ticket!(steps, member)
    merge = chat_with_branch!(project, "NOTES.md", "Rebuild only the textures that changed.\n")
    conflict = chat_with_branch!(project, "README.md", "# Game, as the chat sees it\n")

    commit_files!(Projects.repo_path(project), "main", %{
      "README.md" => "# Game, as main has it\n"
    })

    %{
      users: %{"member" => member},
      paths: %{
        "changeset" => "/tickets/#{project.name}/#{changeset.number}?tab=changes",
        "document" => "/tickets/#{project.name}/#{document.number}?tab=docs",
        "step" => "/chats/#{chat.id}",
        "step_ticket" => "/tickets/#{steps.name}/#{step.number}",
        "merge" => "/chats/#{merge.id}",
        "conflict" => "/chats/#{conflict.id}"
      }
    }
  end

  # A project whose default branch holds `workflow` and the prompts it names, and whose pool can
  # pay for a job.
  #
  # A repository registered by name outlives the suite's sandbox (`Projects.repos_dir/0` is under
  # the checkout's `tmp/` in `test`), and a second build would find its ticket branches already
  # cut. Only this setup makes repositories of these names, so the one a previous build left is
  # removed first.
  @doc false
  def project!(name, workflow, member) do
    File.rm_rf!(Path.join(Projects.repos_dir(), name <> ".git"))
    {:ok, project} = Projects.register_named(name, "main", member)

    commit_files!(
      Projects.repo_path(project),
      "main",
      Map.merge(@prompts, %{".forge/workflow.yml" => workflow, "README.md" => "# Game\n"})
    )

    funded!(project)
    project
  end

  # In review: a commit on its branch recorded as `changeset` v1, the message its merge will
  # carry, and the approval of the changeset into `merged` waiting.
  @doc false
  def changeset_ticket!(project, member) do
    {:ok, ticket} =
      Tickets.admit(project, %{title: "Sound toggle in settings"}, {:user, member.id})

    sha =
      commit_files!(Projects.repo_path(project), ticket.branch, %{
        "lib/game/settings.ex" => "defmodule Game.Settings do\n  defstruct sound: true\nend\n",
        "test/game/settings_test.exs" => "defmodule Game.SettingsTest do\nend\n"
      })

    changeset!(ticket, sha)

    commit_message!(
      ticket,
      "Add a sound toggle to settings\n\nPersists in the save file, defaults to on.\n"
    )

    pend_merge(ticket)
  end

  # Planning done twice over: refinement.md at v3, and its approval into planning waiting.
  defp document_ticket!(project, member) do
    {:ok, ticket} =
      Tickets.admit(project, %{title: "Persist the high score table"}, {:user, member.id})

    for n <- 1..3 do
      {:ok, _} =
        Artifacts.record_version(ticket.id, "refinement.md", :document, :system, %{
          content: "---\noutcome: done\n---\n# Persist the high score table\n\nDraft #{n}.\n"
        })
    end

    ticket
    |> Ecto.Changeset.change(
      status: :active,
      pending_transition: %{
        "from" => "refining",
        "to" => "planning",
        "outcome" => "done",
        "approve" => ["refinement.md"]
      }
    )
    |> Forge.Repo.update!()
  end

  # A chat step whose conversation has written brief.md and whose last reply asks one question.
  defp step_ticket!(project, member) do
    {:ok, ticket} =
      Tickets.admit(project, %{title: "Shape the leaderboard screen"}, {:user, member.id})

    [chat] = Jobs.step_chats_for_ticket(ticket.id)
    run!(chat)

    :ok =
      Jobs.record_harness_event(chat.id, %{
        type: "job.harness.text",
        payload: %{
          text: """
          brief.md v1 is ready to accept. One thing it leaves open:

          ```question
          key: rank
          text: Outside the top 10, what does your row show?
          options:
            - {label: Your rank and score, detail: The row reads 14th · 2 300, recommended: true}
            - {label: Only your score, detail: The row reads 2 300}
          ```
          """
        }
      })

    {:ok, chat} =
      Conversations.record_turn(chat, %{
        "turn" => 1,
        "commit" => String.duplicate("a", 40),
        "documents" => %{"brief.md" => "# Leaderboard\n\nThe top ten, and your own row.\n"},
        "harness" => %{"turns" => 1, "cost_usd" => 0.01, "session_id" => "look"}
      })

    {ticket, chat}
  end

  # A project chat with one commit on its branch and a message to merge it under.
  defp chat_with_branch!(project, path, content) do
    {:ok, chat} = Conversations.open(project, "Why is the build so slow on CI?")
    commit_files!(Projects.repo_path(project), Jobs.chat_branch(chat), %{path => content})
    chat_commit_message!(chat, "Rebuild only the textures that changed\n")
    chat
  end
end
