defmodule Forge.Look.Setups.Codex do
  @moduledoc """
  Codex on the screens that take it: a member with a ChatGPT login (held by a run) and a Codex
  access token that expires in three days, on their account settings; a project whose admin may set
  its harness and Codex's model and effort; and the new-conversation form.
  Today's usage by kind on the login and on a Claude API key (with Claude Code's dollar figure);
  and a worker offering Codex, another whose Codex install failed, on the workers page.
  A ticket whose job ran on Codex, with a counted run and a converted one and the waiting sentence,
  and a conversation waiting the same way; a long-named access token that has expired.
  Users: `member`. Paths: `settings`, `project_settings`, `new_chat`, `chat`, `workers`, `ticket`,
  `job`, `waiting_chat`.

  The login's tokens are made-up marker strings: a picture is not masked.
  """

  @behaviour Forge.Look.Setups

  import Ecto.Query, only: [from: 2]
  import Forge.AccountsFixtures
  import Forge.ForgeFixtures

  @impl true
  def build do
    member = user_fixture() |> Ecto.Changeset.change(node_admin: true) |> Forge.Repo.update!()
    project = project_fixture(%{name: "look-codex"}) |> join!(member)

    claims =
      Base.url_encode64(~s({"https://api.openai.com/auth":{"chatgpt_plan_type":"pro"}}),
        padding: false
      )

    login =
      credential_fixture(member, %{
        harness: "codex",
        kind: "chatgpt_login",
        name: "my chatgpt login",
        secret:
          Jason.encode!(%{
            "tokens" => %{"id_token" => "h.#{claims}.s", "account_id" => "acct-look"}
          })
      })

    Forge.Repo.update_all(from(c in Forge.Credentials.Credential, where: c.id == ^login.id),
      set: [account_id: "acct-look", plan: "pro", renewed_at: DateTime.utc_now(:second)]
    )

    token =
      credential_fixture(member, %{
        harness: "codex",
        kind: "access_token",
        name: "workspace token"
      })

    Forge.Repo.update_all(from(c in Forge.Credentials.Credential, where: c.id == ^token.id),
      set: [expires_on: Date.add(Date.utc_today(), 3)]
    )

    chat = chat_fixture(%{project: project, harness: "codex", model: "gpt-look"})

    Forge.Repo.insert!(%Forge.Jobs.Run{
      job_id: chat.id,
      credential_id: login.id,
      started_at: DateTime.utc_now(:second),
      exclusive: true
    })

    api_key = credential_fixture(member, %{kind: "api_key", name: "work api key"})

    # A name as long as a person can type, and a token whose date has passed: the row cuts the one
    # and says the other.
    expired =
      credential_fixture(member, %{
        harness: "codex",
        kind: "access_token",
        name: String.duplicate("an access token with a very long name ", 5) |> String.trim()
      })

    Forge.Repo.update_all(from(c in Forge.Credentials.Credential, where: c.id == ^expired.id),
      set: [expires_on: Date.add(Date.utc_today(), -2)]
    )

    for credential <- [login, api_key] do
      Forge.Repo.insert!(%Forge.Jobs.Run{
        job_id: chat.id,
        credential_id: credential.id,
        started_at: DateTime.utc_now(:second),
        usage: 1_250_000,
        tokens: %{
          "input" => 120_000,
          "cache_write" => 0,
          "cache_read" => 3_000_000,
          "output" => 90_000
        },
        claude_cost_usd: if(credential.kind == "api_key", do: Decimal.new("6.25")),
        finished_at: DateTime.utc_now(:second)
      })
    end

    # A ticket whose job runs on Codex, with two runs (one counted by kind, one converted from
    # dollars) and the waiting sentence a job gets when every login in its pool is held; and a
    # conversation that waits the same way.
    Forge.Repo.update_all(from(p in Forge.Projects.Project, where: p.id == ^project.id),
      set: [codex_model: "gpt-look-5"]
    )

    ticket = ticket_fixture(%{project: project, title: "Persist the high score table"})

    spec =
      %ForgeCore.Job.Spec{
        job_id: "look-codex-1",
        ticket: %{number: ticket.number, title: ticket.title, ticket_type: nil},
        state: "planning",
        attempt: 1,
        prompt: "Write a plan.",
        prompt_path: "agents/plan.md",
        env: "default",
        commit: String.duplicate("a", 40),
        branch: "ticket/#{ticket.number}",
        budget: %{turns: 80, tokens: 800_000},
        preamble_hash: "sha256:x",
        inputs: [],
        produces: ["plan.md"],
        outcomes: ["done"]
      }
      |> ForgeCore.Job.Spec.to_json()
      |> Jason.decode!()

    job = job_fixture(%{ticket: ticket, spec: spec})

    ticket |> Ecto.Changeset.change(usage: 1_320_000) |> Forge.Repo.update!()

    job =
      job
      |> Ecto.Changeset.change(harness: "codex", usage: 1_320_000, turns: 3)
      |> Forge.Repo.update!()

    Forge.Repo.insert!(%Forge.Jobs.Run{
      job_id: job.id,
      credential_id: login.id,
      started_at: DateTime.add(DateTime.utc_now(:second), -3600),
      finished_at: DateTime.add(DateTime.utc_now(:second), -1800),
      usage: 1_250_000,
      tokens: %{
        "input" => 120_000,
        "cache_write" => 0,
        "cache_read" => 3_000_000,
        "output" => 90_000
      }
    })

    Forge.Repo.insert!(%Forge.Jobs.Run{
      job_id: job.id,
      credential_id: login.id,
      started_at: DateTime.add(DateTime.utc_now(:second), -900),
      finished_at: DateTime.add(DateTime.utc_now(:second), -600),
      usage: 70_000,
      converted: true
    })

    Forge.Jobs.record_wait(
      job,
      "held",
      "Waiting for a Codex login: all in this project's pool are in use."
    )

    waiting = chat_fixture(%{project: project, harness: "codex"})

    Forge.Jobs.record_wait(
      waiting,
      "held",
      "Waiting for a Codex login: all in this project's pool are in use."
    )

    claude = %{
      "driver" => "claude_code",
      "name" => "Claude Code",
      "credential" => "per_job",
      "version" => "2.1.270"
    }

    offering = fn offers ->
      {:ok, worker, _token} =
        Forge.Workers.create(%{provider: "fake", managed: true, user_id: member.id})

      {:ok, _} =
        Forge.Workers.ready(worker, %{
          "memory_budget" => 8_000,
          "harness" => claude,
          "harnesses" => [claude | offers]
        })
    end

    offering.([
      %{
        "driver" => "codex",
        "name" => "Codex",
        "version" => "codex-cli 0.46.0",
        "credential" => "per_job",
        "efforts" => ~w(minimal low medium high),
        "update" => %{"outcome" => "succeeded"}
      }
    ])

    offering.([
      %{
        "driver" => "codex",
        "name" => "Codex",
        "update" => %{
          "outcome" => "failed",
          "error" => "curl: (6) Could not resolve host: github.com"
        }
      }
    ])

    %{
      users: %{"member" => member},
      paths: %{
        "settings" => "/users/settings",
        "project_settings" => "/projects/#{project.name}/settings?section=agent",
        "new_chat" => "/chats/new?project=#{project.name}",
        "chat" => "/chats/#{chat.id}",
        "workers" => "/workers",
        "ticket" => "/tickets/#{project.name}/#{ticket.number}",
        "job" => "/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}",
        "waiting_chat" => "/chats/#{waiting.id}"
      }
    }
  end
end
