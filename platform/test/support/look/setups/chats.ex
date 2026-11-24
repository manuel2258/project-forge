defmodule Forge.Look.Setups.Chats do
  @moduledoc """
  The chats (`docs/design/ui.md` § Chats, § The Accept area): one project, `game`, holding a
  conversation responding on a machine of the member's with its plan half done and a branch to
  merge (`15a`, `15e`, `15f`, `18e`), one whose machine was released by the idle timeout, drawn as one
  holding a machine (`15d`, ticket 53), one released by an update, whose subline says so, one ended by hand with its branch deleted, one whose reply was
  lost with its machine, one idle whose branch conflicts with `main` (`15c`), and a ticket resting in a chat step whose document is at v2
  with one question open (`16e`–`16i`). The project has three secrets, so a new chat offers them
  as chips (`12d`); their values are made up.

  Ticket 71 adds three: a conversation mid-turn with two messages waiting for it, the oldest
  carrying *Interrupt to send now* (`queued`); one opened with files alone, whose first message is a
  bubble holding only its names (`files_only`); and a step whose nothing-yet dock has a two-question
  card open (`step_empty`).

  Ticket 75 adds `files_lost`, a conversation whose second turn reports two files the machine could
  not put where the agent reads them, one whose name is cut at 200 characters: the line under that turn in the
  transcript and in Activity (`files_lost_activity`).

  Users: `member`. Paths: `list`, `new`, `responding`, `changes`, `released`, `updated`, `ended`, `lost`, `conflict`,
  `conflict_changes`, `step`, `step_ticket`, `queued`, `files_only`, `step_empty`, `files_lost`, `files_lost_activity`.
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
    released = released!(game)
    updated = updated!(game)
    ended = ended!(game, member)
    lost = lost!(game)
    conflict = conflict!(game)
    responding = responding!(game, machine)
    queued = queued!(game, machine)
    files_only = files_only!(game, member)
    files_lost = files_lost!(game)
    {_step_empty_ticket, step_empty} = step_empty!(game, member)

    %{
      users: %{"member" => member},
      paths: %{
        "list" => "/chats",
        "new" => "/chats/new",
        "responding" => "/chats/#{responding.id}",
        "changes" => "/chats/#{responding.id}?tab=changes",
        "released" => "/chats/#{released.id}",
        "updated" => "/chats/#{updated.id}",
        "ended" => "/chats/#{ended.id}",
        "lost" => "/chats/#{lost.id}",
        "conflict" => "/chats/#{conflict.id}",
        "conflict_changes" => "/chats/#{conflict.id}?tab=changes",
        "step" => "/chats/#{step_chat.id}",
        "step_ticket" => "/tickets/#{game.name}/#{step.number}",
        "queued" => "/chats/#{queued.id}",
        "files_only" => "/chats/#{files_only.id}",
        "step_empty" => "/chats/#{step_empty.id}",
        "files_lost" => "/chats/#{files_lost.id}",
        "files_lost_activity" => "/chats/#{files_lost.id}?tab=activity"
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
    chat_started!(chat)

    said(chat, """
    The asset step is most of it. It keys its cache on `$GITHUB_SHA`, so every push rebuilds all 212 textures, about 6½ minutes.

    Keying each texture on a hash of its source and import settings would rebuild only what changed. Want me to try it on this branch?
    """)

    tool(chat, "r1", "Read", %{"file_path" => "mix/tasks/assets.ex"}, "ok")
    turn(chat, 1, "0.09")

    {:ok, event} = Conversations.send(chat, "Yes, try it.")
    taken!(chat, event)
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

  # 15d, as ticket 53 draws it: answered, then its machine released by the idle timeout, and its
  # branch gone — nothing on the page says it stopped, and sending carries it on.
  defp released!(project) do
    {:ok, chat} = Conversations.open(project, "Ideas for a two-player mode")
    run!(chat)
    chat_started!(chat)
    said(chat, "Split screen is the cheap one. Online needs a server we do not have yet.")
    turn(chat, 1, "0.04")
    {:ok, _chat} = Conversations.ended(Jobs.get(chat.id), nil, "idle")

    _ =
      Forge.Git.spawn_cmd("git", [
        "--git-dir=#{Projects.repo_path(project)}",
        "branch",
        "-D",
        Jobs.chat_branch(chat)
      ])

    chat
  end

  # Answered, then released because its machine stopped to update (`worker-tier.md` § Updating a
  # permanent machine): the one release whose subline says why, and that a message carries it on.
  defp updated!(project) do
    {:ok, chat} = Conversations.open(project, "How should scores be stored?")
    run!(chat)
    chat_started!(chat)

    said(
      chat,
      "A small table keyed by player is enough; an index on the score column is the only extra."
    )

    turn(chat, 1, "0.03")
    {:ok, _chat} = Conversations.ended(Jobs.get(chat.id), nil, "update")
    chat
  end

  # Ended by the member: read-only for good, its branch dealt with and said.
  defp ended!(project, member) do
    {:ok, chat} = Conversations.open(project, "Sketch the settings screen")
    run!(chat)
    chat_started!(chat)
    said(chat, "Three groups: sound, controls, accessibility. Want the wireframe as a doc?")
    turn(chat, 1, "0.02")
    :ok = Conversations.close(Jobs.get(chat.id), actor: {:user, member.id})
    chat
  end

  # The person's message was the last word, and the machine went before a reply came.
  defp lost!(project) do
    {:ok, chat} = Conversations.open(project, "Why does the menu music stutter?")
    run!(chat)
    chat_started!(chat)
    said(chat, "It decodes on the main thread. Moving it to a task should fix it.")
    turn(chat, 1, "0.02")

    {:ok, event} =
      Conversations.send(Jobs.get(chat.id), "Try it, and tell me what the profile says.")

    taken!(chat, event)
    running!(chat, nil)
    {:ok, _} = Jobs.requeue(chat.id, :worker_lost)
    chat
  end

  # 15c: idle with its turn finished, a commit to README.md, and `main` moved under it.
  defp conflict!(project) do
    {:ok, chat} = Conversations.open(project, "Tidy the README's install section")
    run!(chat)
    chat_started!(chat)
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

  # Mid-turn — a call still running — with two messages waiting for it. The worker holds them until
  # the turn is over, so neither is taken yet, and the oldest carries the button that stops the turn.
  defp queued!(project, machine) do
    {:ok, chat} = Conversations.open(project, "Add a loading bar to the title screen")
    run!(chat)
    chat_started!(chat)

    said(chat, "I'll start with the asset loader, then the bar that reads its progress.")
    tool(chat, "q1", "Read", %{"file_path" => "lib/game/loader.ex"}, "ok")
    tool(chat, "q2", "Bash", %{"command" => "mix test test/game/loader_test.exs"})
    running!(chat, machine)

    {:ok, _} = Conversations.send(chat, "Keep it under 40 lines, please.")
    {:ok, _} = Conversations.send(chat, "And no new dependencies.")
    chat
  end

  # Opened with a picture and nothing typed: called by the file, and its first bubble holds only
  # the names. The bytes are a few made-up words.
  defp files_only!(project, member) do
    path = Path.join(System.tmp_dir!(), "look-chats-#{System.unique_integer([:positive])}")
    File.write!(path, "pixels of the title screen")
    {:ok, upload} = Forge.Attachments.stage(project, member, {:file, path}, "title-screen.png")
    File.rm(path)

    batch = %Forge.Attachments.Batch{uploads: [%{id: upload.id, name: "title-screen.png"}]}

    {:ok, chat} =
      Conversations.open(project, "", actor: {:user, member.id}, attachments: batch)

    run!(chat)
    chat_started!(chat)
    said(chat, "The logo sits 12 px too low on a narrow phone. I can nudge it up; want that?")
    turn(chat, 1, "0.02")
    chat
  end

  # The second turn's message came with two files the machine could not show the agent: one
  # named in a few words, one with a very long name (the line cuts at 200 characters).
  defp files_lost!(project) do
    {:ok, chat} = Conversations.open(project, "Here is the crash screen.")
    run!(chat)
    chat_started!(chat)
    said(chat, "That is a null reference in the save loader. I can guard it; want that?")
    turn(chat, 1, "0.02")

    {:ok, _event} = Conversations.send(chat, "Yes, and here are two more screenshots.")
    said(chat, "I could not open the screenshots, so I will guard it from the trace alone.")

    {:ok, chat} =
      Conversations.record_turn(chat, %{
        "turn" => 2,
        "harness" => %{"turns" => 1, "cost_usd" => 0.03, "session_id" => "look"},
        "files_lost" => [
          %{
            "file" => "crash-1.png",
            "why" => "it could not be put in the folder on this machine"
          },
          %{
            "file" => String.duplicate("very-long-screenshot-name-", 12) <> ".png",
            "why" => "it could not be downloaded to this machine"
          }
        ]
      })

    chat
  end

  # A step with nothing produced yet and a card of two questions open: the dock on a phone is the
  # composer and the card, with no *Nothing to accept yet* sentence between them.
  defp step_empty!(project, member) do
    {:ok, ticket} =
      Tickets.admit(project, %{title: "Shape the settings screen"}, {:user, member.id})

    [chat] = Jobs.step_chats_for_ticket(ticket.id)
    run!(chat)
    chat_started!(chat)

    said(chat, """
    Before I write brief.md I need two things.

    ```question
    key: groups
    text: How should the settings be grouped?
    options:
      - {label: Three groups, detail: Sound and controls and accessibility, recommended: true}
      - {label: One long list, detail: No groups}
    ```

    ```question
    key: reset
    text: Does the screen have a reset to defaults?
    options:
      - {label: Yes, detail: One button at the bottom, recommended: true}
      - {label: No, detail: Settings stay as they are}
    ```
    """)

    {:ok, chat} =
      Conversations.record_turn(chat, %{
        "turn" => 1,
        "commit" => String.duplicate("c", 40),
        "harness" => %{"turns" => 1, "cost_usd" => 0.02, "session_id" => "look"}
      })

    {ticket, chat}
  end

  # What the worker says when it writes a message to an idle agent: taken, so no longer queued.
  defp taken!(chat, %{seq: seq}),
    do:
      :ok =
        Jobs.record_harness_event(chat.id, %{
          type: "job.harness.delivered",
          payload: %{message_id: to_string(seq)}
        })

  # 16f–16i: brief.md at v2, the second reply asking one question.
  defp step!(project, member) do
    {:ok, ticket} =
      Tickets.admit(project, %{title: "Shape the leaderboard screen"}, {:user, member.id})

    [chat] = Jobs.step_chats_for_ticket(ticket.id)
    run!(chat)
    chat_started!(chat)

    said(chat, "Wrote a first brief.md: an all-time tab and a weekly tab, each the top 25.")

    {:ok, chat} =
      Conversations.record_turn(chat, %{
        "turn" => 1,
        "commit" => String.duplicate("a", 40),
        "documents" => %{"brief.md" => "# Leaderboard\n\nTwo tabs, the top 25 each.\n"},
        "harness" => %{"turns" => 1, "cost_usd" => 0.02, "session_id" => "look"}
      })

    {:ok, event} =
      Conversations.send(chat, "Keep it to one screen. Top 10, your own rank pinned.")

    taken!(chat, event)

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
