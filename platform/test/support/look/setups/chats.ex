defmodule Forge.Look.Setups.Chats do
  @moduledoc """
  The chats (`docs/design/ui.md` § Chats, § The Accept area): one project, `game`, holding a
  conversation responding on a machine of the member's with its plan half done and a branch to
  merge (`15a`, `15e`, `15f`, `18e`), one stopped whose branch is gone (`15d`), one idle whose
  branch conflicts with `main` (`15c`), and a ticket resting in a chat step whose document is at v2
  with one question open (`16e`–`16i`). The project has three secrets, so a new chat offers them
  as chips (`12d`); their values are made up.

  Users: `member`. Paths: `list`, `new`, `responding`, `changes`, `stopped`, `conflict`,
  `conflict_changes`, `step`, `step_ticket`.
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.MachinesFixtures, only: [machine_fixture: 2]
  import Forge.MergeFixtures
  import Forge.ProjectFixtures, only: [commit_files!: 3]

  alias Forge.{Conversations, Jobs, Operator, Projects, Repo, Tickets}
  alias Forge.Look.Setups.Decision

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
    game = Decision.project!("look-chats", @step_workflow, member)

    for {name, value} <- [
          {"SENTRY_DSN", "made-up-sentry-dsn"},
          {"STEAM_UPLOAD_KEY", "made-up-steam-key"},
          {"ASSET_CDN_TOKEN", "made-up-cdn-token"}
        ] do
      {:ok, _} = Operator.set_secret(game, member, name, value)
    end

    machine =
      machine_fixture(member, %{
        provider_id: "hz-fsn1-2",
        memory_budget: 8 * 1024 * 1024 * 1024,
        cores: 4
      })

    {step, step_chat} = step!(game, member)
    stopped = stopped!(game)
    conflict = conflict!(game)
    responding = responding!(game, machine)

    %{
      users: %{"member" => member},
      paths: %{
        "list" => "/chats",
        "new" => "/chats/new",
        "responding" => "/chats/#{responding.id}",
        "changes" => "/chats/#{responding.id}?tab=changes",
        "stopped" => "/chats/#{stopped.id}",
        "conflict" => "/chats/#{conflict.id}",
        "conflict_changes" => "/chats/#{conflict.id}?tab=changes",
        "step" => "/chats/#{step_chat.id}",
        "step_ticket" => "/tickets/#{game.name}/#{step.number}"
      }
    }
  end

  # 15a: two turns, the second still open — its plan three of five done, a build running — on a
  # machine of the member's, with two commits on its branch and the message a merge would carry.
  defp responding!(project, machine) do
    {:ok, chat} =
      Conversations.open(
        project,
        "Why is the build so slow on CI? It went from 4 to 11 minutes this month."
      )

    run!(chat)

    said(chat, """
    The asset step is most of it. It keys its cache on `$GITHUB_SHA`, so every push rebuilds all 212 textures, about 6½ minutes.

    Keying each texture on a hash of its source and import settings would rebuild only what changed. Want me to try it on this branch?
    """)

    tool(chat, "r1", "Read", %{"file_path" => "mix/tasks/assets.ex"}, "ok")
    turn(chat, 1, "0.09")

    {:ok, _} = Conversations.send(chat, "Yes, try it.")
    running!(chat, machine)

    tool(chat, "p1", "TodoWrite", %{"todos" => plan()}, "ok")
    tool(chat, "e1", "Edit", %{"file_path" => "mix/tasks/assets.ex"}, "ok")
    tool(chat, "b1", "Bash", %{"command" => "mix assets.build --since HEAD~1"})

    repo = Projects.repo_path(project)
    branch = Jobs.chat_branch(chat)

    commit_files!(repo, branch, %{
      "mix/tasks/assets.ex" => "defmodule Mix.Tasks.Assets do\n  # keyed per texture\nend\n"
    })

    commit_files!(repo, branch, %{
      ".github/workflows/ci.yml" => "name: ci\non: push\n",
      "test/mix/assets_test.exs" => "defmodule Mix.AssetsTest do\nend\n"
    })

    chat_commit_message!(
      chat,
      "Rebuild only the textures that changed\n\nEach texture is now keyed on its source and import settings.\n"
    )

    chat
  end

  defp plan do
    [
      %{"content" => "Read the asset task", "status" => "completed"},
      %{"content" => "Key each texture on its source", "status" => "completed"},
      %{"content" => "Run the build twice", "status" => "completed"},
      %{
        "content" => "Measure a push that touches no texture",
        "activeForm" => "Measuring a push that touches no texture",
        "status" => "in_progress"
      },
      %{"content" => "Say what changed", "status" => "pending"}
    ]
  end

  # 15d: answered, then stopped going idle; ending deleted its branch, so reopening starts one.
  defp stopped!(project) do
    {:ok, chat} = Conversations.open(project, "Ideas for a two-player mode")
    run!(chat)
    said(chat, "Split screen is the cheap one. Online needs a server we do not have yet.")
    turn(chat, 1, "0.04")
    {:ok, _chat} = Conversations.ended(Jobs.get(chat.id), nil, "idle")

    _ =
      System.cmd("git", [
        "--git-dir=#{Projects.repo_path(project)}",
        "branch",
        "-D",
        Jobs.chat_branch(chat)
      ])

    chat
  end

  # 15c: idle with its turn finished, a commit to README.md, and `main` moved under it.
  defp conflict!(project) do
    {:ok, chat} = Conversations.open(project, "Tidy the README's install section")
    run!(chat)
    said(chat, "Done: the install section is three steps now. Merge when you are ready.")
    turn(chat, 1, "0.03")
    running!(chat, nil)

    repo = Projects.repo_path(project)

    commit_files!(repo, Jobs.chat_branch(chat), %{
      "README.md" => "# Game, as the chat sees it\n"
    })

    commit_files!(repo, "main", %{"README.md" => "# Game, as main has it\n"})
    chat_commit_message!(chat, "Shorten the install section\n")
    chat
  end

  # 16f–16i: brief.md at v2, the second reply asking one question.
  defp step!(project, member) do
    {:ok, ticket} =
      Tickets.admit(project, %{title: "Shape the leaderboard screen"}, {:user, member.id})

    [chat] = Jobs.step_chats_for_ticket(ticket.id)
    run!(chat)

    said(chat, "Wrote a first brief.md: an all-time tab and a weekly tab, each the top 25.")

    {:ok, chat} =
      Conversations.record_turn(chat, %{
        "turn" => 1,
        "commit" => String.duplicate("a", 40),
        "documents" => %{"brief.md" => "# Leaderboard\n\nTwo tabs, the top 25 each.\n"},
        "harness" => %{"turns" => 1, "cost_usd" => 0.02, "session_id" => "look"}
      })

    {:ok, _} = Conversations.send(chat, "Keep it to one screen. Top 10, your own rank pinned.")

    said(chat, """
    Updated brief.md to v2: one screen, top 10, your row pinned under a divider. One thing it leaves open:

    ```question
    key: rank
    text: Outside the top 10, what does your row show?
    options:
      - {label: Your rank and score, detail: The row reads 14th · 2 300, recommended: true}
      - {label: Only your score, detail: The row reads 2 300}
    ```
    """)

    {:ok, chat} =
      Conversations.record_turn(chat, %{
        "turn" => 2,
        "commit" => String.duplicate("b", 40),
        "documents" => %{
          "brief.md" => """
          # Leaderboard screen

          One screen reached from the title menu and the end-of-game screen. It shows the top 10
          scores from `Game.Scores.top/1` with name, score and date.

          ## Your row

          When you are outside the top 10, your best score is pinned under a divider at the
          bottom. What the row shows is open.

          ## Done when

          - the screen opens from both places
          - an empty table shows one line saying so
          """
        },
        "harness" => %{"turns" => 1, "cost_usd" => 0.03, "session_id" => "look"}
      })

    {ticket, chat}
  end

  defp said(chat, text),
    do:
      :ok =
        Jobs.record_harness_event(chat.id, %{type: "job.harness.text", payload: %{text: text}})

  defp tool(chat, id, name, input, result \\ nil) do
    :ok =
      Jobs.record_harness_event(chat.id, %{
        type: "job.harness.tool_use",
        payload: %{id: id, name: name, input: input}
      })

    if result do
      :ok =
        Jobs.record_harness_event(chat.id, %{
          type: "job.harness.tool_result",
          payload: %{tool_use_id: id, is_error: false, bytes: byte_size(result), excerpt: result}
        })
    end
  end

  defp turn(chat, index, cost) do
    {:ok, _chat} =
      Conversations.record_turn(chat, %{
        "turn" => index,
        "harness" => %{"turns" => 1, "cost_usd" => String.to_float(cost), "session_id" => "look"}
      })
  end

  defp running!(chat, machine) do
    chat
    |> Jobs.Job.progress_changeset(%{status: :running, worker_id: machine && machine.id})
    |> Repo.update!()
  end
end
