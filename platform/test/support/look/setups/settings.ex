defmodule Forge.Look.Setups.Settings do
  @moduledoc """
  A project with something in every section of its settings (`docs/design/ui.md` § Project
  settings): tokens — one about to lapse, one held by a job, one revoked; secrets — one that
  nothing receives, one held by a live conversation; four people, two of them administrators; an
  effort, a worker offering three levels and a harness that reported its model; and two mirrors,
  one failing. Users: `admin` (a project admin), `member` (a member who is not one). Paths:
  `index`, `tokens`, `issue`, `secrets`, `people`, `agent`, `repository`.

  The values are made up and none is a real credential (`docs/design/look.md` § Only made-up
  data).
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures, only: [join!: 3]
  import Forge.ProjectFixtures, only: [commit_files!: 3]
  import Forge.SettingsFixtures

  alias Forge.{Conversations, Jobs, Operator, Projects, Repo, Tickets, Workers}
  alias Forge.Git.Tokens

  @workflow """
  version: 1
  initial: implementing
  commands:
    release:
      run: .forge/commands/release.sh
      timeout: 10m
      secrets: [STEAM_UPLOAD_KEY]
  states:
    implementing:
      prompt: agents/implement.md
      inputs: [ticket]
      produces: [implementation.md]
      budget: { turns: 20, tokens: 100k }
      secrets: [SENTRY_DSN]
    review:
      prompt: agents/review.md
      inputs: [ticket]
      produces: [review.md]
      budget: { turns: 20, tokens: 100k }
      secrets: [SENTRY_DSN, ASSET_CDN_TOKEN]
    done: {}
  transitions:
    - { from: implementing, to: review }
    - { from: review, to: done }
  limits:
    ticket_tokens: 1M
  """

  @impl true
  def build do
    admin = user_fixture(%{email: "you@example.com"})
    ana = user_fixture(%{email: "ana@example.com"})
    member = user_fixture(%{email: "jo@example.com"})
    bot = user_fixture(%{email: "ci-bot@example.com"})

    # A name of its own per build: the suite builds every setup into one shared repository
    # directory, and a ticket's branch left there by the last build would refuse this one's.
    {:ok, project} =
      Projects.register_named("game-#{System.unique_integer([:positive])}", "main", admin)

    join!(project, ana, :admin)
    join!(project, member, :member)
    join!(project, bot, :member)

    commit_files!(Projects.repo_path(project), "main", %{
      ".forge/workflow.yml" => @workflow,
      ".forge/commands/release.sh" => "#!/bin/sh\n",
      ".forge/agents/implement.md" => "Implement the ticket.\n",
      ".forge/agents/review.md" => "Review the change.\n"
    })

    {:ok, ticket} = Tickets.admit(project, %{title: "Persist the high score table"}, :system)
    [job] = Jobs.for_ticket(ticket.id)

    tokens!(project, admin, ticket, job)
    secrets!(project, admin, ana)
    agent!(project, admin, job)
    mirrors!(project, admin)

    base = "/projects/#{project.name}/settings"

    %{
      users: %{"admin" => admin, "member" => member},
      paths: %{
        "index" => base,
        "tokens" => base <> "?section=tokens",
        "issue" => base <> "?section=tokens&add=1",
        "secrets" => base <> "?section=secrets",
        "people" => base <> "?section=people",
        "agent" => base <> "?section=agent",
        "repository" => base <> "?section=repository"
      }
    }
  end

  defp tokens!(project, admin, ticket, job) do
    now = DateTime.utc_now(:second)

    {:ok, _secret, dashboard} =
      Tokens.issue(project,
        name: "ci-dashboard",
        git: :reader,
        api: :read,
        days: 2,
        issued_by_id: admin.id
      )

    used!(dashboard, DateTime.add(now, -3 * 60), :api)

    {:ok, _secret, laptop} =
      Tokens.issue(project,
        name: "laptop",
        git: :developer,
        api: :write,
        days: 21,
        issued_by_id: admin.id
      )

    used!(laptop, DateTime.add(now, -3600), :git)

    {:ok, _secret, held} = Tokens.issue_for_job(job, ticket, project)
    used!(held, now, :git)

    {:ok, _secret, old} =
      Tokens.issue(project, name: "old-script", git: :reader, api: :none, days: 7)

    {:ok, _} = Tokens.revoke(old.id)
  end

  defp used!(token, at, via),
    do: Repo.update!(Ecto.Changeset.change(token, last_used_at: at, last_used_via: via))

  defp secrets!(project, admin, ana) do
    {:ok, _} = Operator.set_secret(project, admin, "STEAM_UPLOAD_KEY", "made-up-steam-key-v1")
    {:ok, _} = Operator.set_secret(project, admin, "STEAM_UPLOAD_KEY", "made-up-steam-key-v2")
    {:ok, _} = Operator.set_secret(project, ana, "SENTRY_DSN", "made-up-sentry-dsn")
    {:ok, _} = Operator.set_secret(project, admin, "STRIPE_TEST_KEY", "made-up-stripe-key")
    {:ok, _} = Operator.set_secret(project, admin, "ASSET_CDN_TOKEN", "made-up-cdn-token")
    {:ok, _chat} = Conversations.open(project, "Why is the build slow?", secrets: ["SENTRY_DSN"])
  end

  # The effort the project names, the levels a worker offers, and the model a harness reported
  # starting on for a job that named none: what `9g` draws beside *the machine's*.
  defp agent!(project, admin, job) do
    {:ok, _project} = Operator.set_defaults(project, admin, %{effort: "high"})
    {:ok, worker, _token} = Workers.create(%{provider: "fake"})

    {:ok, _worker} =
      Workers.ready(worker, %{
        "memory_budget" => 8_000,
        "harness" => %{"aliases" => ["opus", "sonnet"], "efforts" => ~w(low medium high)}
      })

    harness_started!(job, "claude-sonnet-4-5")
  end

  defp mirrors!(project, admin) do
    :ok = Projects.put_mirror(project, admin, "github", "https://github.com/manu/game.git", [])
    :ok = Projects.put_mirror(project, admin, "backup", "https://git.example.net/game.git", [])
    now = DateTime.utc_now(:second)

    mirror_pushed!(project, "github", "failed",
      at: DateTime.to_iso8601(DateTime.add(now, -3 * 3600)),
      error: "remote: Permission to manu/game.git denied (403)",
      ok_at: DateTime.to_iso8601(DateTime.add(now, -4 * 86_400))
    )

    mirror_pushed!(project, "backup", "ok", at: DateTime.to_iso8601(DateTime.add(now, -3 * 3600)))
  end
end
