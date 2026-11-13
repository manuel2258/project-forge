defmodule Forge.Look.Setups.Project do
  @moduledoc """
  The project page (`7a`–`7h`, `21c`, `21d`) and the ticket form (`12e`): `game`, with ticket
  types `feature` and `bug` and a release workflow, and open tickets in every way the Tickets view
  draws one — two waiting on an approval, one stuck, two running with their agent's last line, one
  waiting for a machine, two in the merge queue — then two in its history, three conversations
  (one with two proposals) and a failing mirror.

  Users: `admin` (a project admin, who sees the release block) and `member`. Paths: `project`,
  `merge`, `chats`, `workflow`, `proposals`, `new`, `ticket_new`.
  """

  @behaviour Forge.Look.Setups

  import Ecto.Query, only: [from: 2]
  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.ProjectFixtures, only: [commit_files!: 3]
  import Forge.SettingsFixtures, only: [mirror_pushed!: 3]

  alias Forge.{Conversations, Projects, Repo, Tickets}
  alias Forge.Jobs.Job

  @prompts %{
    ".forge/agents/triage.md" => "Triage the ticket.\n",
    ".forge/agents/shape.md" => "Shape it with the person.\n",
    ".forge/agents/plan.md" => "Write a plan.\n",
    ".forge/agents/implement.md" => "Implement the plan.\n",
    ".forge/agents/fix.md" => "Fix the bug.\n",
    ".forge/agents/release.md" => "Write the changelog.\n"
  }

  @feature """
  version: 1
  description: Something new.
  initial: triage
  states:
    triage:
      prompt: agents/triage.md
      inputs: [ticket]
      produces: [triage.md]
      outcomes: [ready, needs_shaping]
      budget: { turns: 10, tokens: 40k }
    shaping:
      chat: true
      prompt: agents/shape.md
      inputs: [ticket, triage.md]
      produces: [brief.md]
      outcomes: [shaped]
    planning:
      prompt: agents/plan.md
      inputs: [ticket]
      produces: [plan.md]
      budget: { turns: 30, tokens: 200k }
    implementing:
      prompt: agents/implement.md
      inputs: [plan.md]
      produces: [implementation.md, changeset, commit-message]
      outcomes: [done, plan_invalid]
      budget: { turns: 30, tokens: 200k }
    review: {}
    merged:
      on_enter: [merge]
  transitions:
    - { from: triage, to: planning, when: ready }
    - { from: triage, to: shaping, when: needs_shaping }
    - { from: shaping, to: planning, when: shaped, approve: [brief.md] }
    - { from: planning, to: implementing, approve: [plan.md] }
    - { from: implementing, to: review }
    - { from: implementing, to: planning, when: plan_invalid }
    - { from: review, to: merged, approve: [changeset], queue: true }
  limits: { ticket_tokens: 5M }
  """

  @bug """
  version: 1
  description: Something that worked and does not.
  initial: triage
  states:
    triage:
      prompt: agents/triage.md
      inputs: [ticket]
      produces: [triage.md]
      budget: { turns: 10, tokens: 40k }
    fixing:
      prompt: agents/fix.md
      inputs: [ticket, triage.md]
      produces: [changeset, commit-message]
      budget: { turns: 30, tokens: 200k }
    review: {}
    merged:
      on_enter: [merge]
  transitions:
    - { from: triage, to: fixing }
    - { from: fixing, to: review }
    - { from: review, to: merged, approve: [changeset], queue: true }
  limits: { ticket_tokens: 2M }
  """

  @release """
  version: 1
  description: Cut a release.
  release: true
  initial: changelog
  states:
    changelog:
      prompt: agents/release.md
      produces: [release-notes.md]
      budget: { turns: 10, tokens: 200k }
    published: {}
  transitions:
    - { from: changelog, to: published }
  limits: { ticket_tokens: 1M }
  """

  @impl true
  def build do
    admin = user_fixture(%{email: "you@example.com"})
    member = user_fixture(%{email: "kim@example.com"})
    project = project!(admin, member)

    # In ascending number: admission numbers a ticket one past the highest, so renumbering
    # upwards never meets a branch an earlier admission cut.
    closed!(project, admin, 34, "Online leaderboard", :cancelled, 5)
    double_jump = queued!(project, admin, 36, "Fix the double jump on slopes", 40, type: "bug")
    end_screen = queued!(project, admin, 37, "Show the score on the end screen", 20, [])
    closed!(project, admin, 38, "Show the high score on the title screen", :done, 2)
    approval!(project, admin, 39, "Sound toggle in settings", "review", "changeset", 60)

    running!(project, admin, 41, "Persist the high score table", "implementing", 4,
      said: "Changing top/1 to order by score, then time set."
    )

    approval!(project, admin, 42, "Shape the leaderboard screen", "shaping", "brief.md", 12)
    stuck!(project, admin, 44, "Replace the font atlas with a single SDF texture")

    running!(project, admin, 45, "Score flickers when the window resizes", "triage", 1,
      type: "bug",
      said: "Reading the resize handler in hud.ex."
    )

    pending!(project, admin, 46, "Pause menu keyboard navigation")

    # In the merge queue's order, which is insertion order: #37 integrating ahead of #36.
    entry!(project, end_screen, :integrating)
    entry!(project, double_jump, :waiting)

    chats!(project)

    name = project.name

    %{
      users: %{"admin" => admin, "member" => member},
      paths: %{
        "project" => "/projects/#{name}",
        "merge" => "/projects/#{name}?view=merge",
        "chats" => "/projects/#{name}?view=chats",
        "workflow" => "/projects/#{name}?view=workflow",
        "proposals" => "/projects/#{name}?view=proposals",
        "new" => "/projects/#{name}?new",
        "ticket_new" => "/tickets/new?project=#{name}"
      }
    }
  end

  # A project whose default branch holds both types, the release and their prompts, funded, with a
  # failing mirror. A repository of this name a previous build left is removed first: it outlives
  # the suite's sandbox (`Forge.Look.Setups.Decision` says the same).
  defp project!(admin, member) do
    File.rm_rf!(Path.join(Projects.repos_dir(), "game.git"))
    {:ok, project} = Projects.register_named("game", "main", admin)
    join!(project, member, :member)

    commit_files!(
      Projects.repo_path(project),
      "main",
      Map.merge(@prompts, %{
        ".forge/workflows/feature.yml" => @feature,
        ".forge/workflows/bug.yml" => @bug,
        ".forge/workflows/release.yml" => @release,
        "README.md" => "# Game\n"
      })
    )

    funded!(project)

    :ok = Projects.put_mirror(project, admin, "github", "https://github.example/game.git", [])
    mirror_pushed!(project, "github", "failed")
    project
  end

  # Admitted as `type`, numbered `number`, moved to `state` and last changed `ago` minutes back,
  # with the job admission queued taken off the machine queue: each caller says what it runs.
  defp ticket!(project, admin, number, title, state, ago, opts) do
    {:ok, ticket} =
      Tickets.admit(
        project,
        %{
          title: title,
          body: "Made up for a look.",
          ticket_type: Keyword.get(opts, :type, "feature")
        },
        {:user, admin.id}
      )

    Repo.update_all(from(j in Job, where: j.ticket_id == ^ticket.id), set: [status: :finished])

    ticket
    |> Ecto.Changeset.change(
      number: number,
      state: state,
      status: Keyword.get(opts, :status, :active),
      pending_transition: Keyword.get(opts, :pending),
      usage: Keyword.get(opts, :usage, 240_000),
      updated_at: DateTime.add(DateTime.utc_now(:second), -ago * 60)
    )
    |> Repo.update!()
  end

  defp approval!(project, admin, number, title, state, document, ago) do
    to = if document == "changeset", do: "merged", else: "planning"

    ticket!(project, admin, number, title, state, ago,
      pending: %{"from" => state, "to" => to, "outcome" => "done", "approve" => [document]}
    )
  end

  defp running!(project, admin, number, title, state, minutes, opts) do
    ticket = ticket!(project, admin, number, title, state, 0, opts)

    job =
      %{ticket: ticket, attempt: 2, status: :running}
      |> job_fixture()
      |> Ecto.Changeset.change(started_at: DateTime.add(DateTime.utc_now(:second), -minutes * 60))
      |> Repo.update!()

    said!(job, ticket, opts[:said])
  end

  defp queued!(project, admin, number, title, ago, opts),
    do: ticket!(project, admin, number, title, "review", ago, opts)

  defp entry!(project, ticket, status) do
    Repo.insert!(%Forge.MergeQueue.Entry{
      project_id: project.id,
      ticket_id: ticket.id,
      from_state: "review",
      to_state: "merged",
      edge_outcome: "done",
      status: status
    })
  end

  defp stuck!(project, admin, number, title) do
    ticket = ticket!(project, admin, number, title, "implementing", 25, status: :stuck)

    Repo.insert!(%Forge.Events.Event{
      type: "ticket.stuck",
      actor: %{"kind" => "system", "id" => nil},
      ticket_id: ticket.id,
      project_id: project.id,
      payload: %{"reason" => "did_not_converge: out of turns with 3 shader tests failing"}
    })
  end

  defp pending!(project, admin, number, title) do
    ticket = ticket!(project, admin, number, title, "triage", 20, usage: 0)
    job_fixture(%{ticket: ticket, attempt: 2, status: :pending})
  end

  defp closed!(project, admin, number, title, status, days) do
    state = if status == :done, do: "merged", else: "shaping"
    ticket = ticket!(project, admin, number, title, state, days * 1440, status: status)

    if status == :done do
      Repo.insert!(%Forge.Events.Event{
        type: "ticket.merged",
        actor: %{"kind" => "system", "id" => nil},
        ticket_id: ticket.id,
        project_id: project.id,
        payload: %{"sha" => "a41c09e" <> String.duplicate("0", 33)},
        inserted_at: DateTime.add(DateTime.utc_now(:second), -days * 86_400)
      })
    end
  end

  defp said!(_job, _ticket, nil), do: :ok

  defp said!(job, ticket, text) do
    Repo.insert!(%Forge.Events.Event{
      type: "job.harness.text",
      actor: %{"kind" => "job", "id" => job.id},
      job_id: job.id,
      ticket_id: ticket.id,
      project_id: ticket.project_id,
      payload: %{"text" => text}
    })
  end

  # Three conversations: one the agent answered last, one ended, one that proposed two tickets.
  defp chats!(project) do
    {:ok, ci} = Conversations.open(project, "Why is the build so slow on CI?")
    said!(ci, "The asset step rebuilds every texture because the cache key includes the commit.")

    {:ok, coop} = Conversations.open(project, "Ideas for a two-player mode")
    {:ok, _ended} = Conversations.ended(coop, nil, "closed")

    {:ok, saves} = Conversations.open(project, "Audit the save format")
    said!(saves, "Proposed two tickets: version the save file, and migrate saves from 0.3.")

    proposal_fixture(%{job: saves, file: "save-version.md", title: "Version the save file"})
    proposal_fixture(%{job: saves, file: "migrate-saves.md", title: "Migrate saves from 0.3"})
  end

  defp said!(chat, text) do
    Repo.insert!(%Forge.Events.Event{
      type: "job.harness.text",
      actor: %{"kind" => "job", "id" => chat.id},
      job_id: chat.id,
      project_id: chat.project_id,
      payload: %{"text" => text}
    })
  end
end
