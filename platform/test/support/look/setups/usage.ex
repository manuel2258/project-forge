defmodule Forge.Look.Setups.Usage do
  @moduledoc """
  Usage in weighted tokens, where cost was drawn: a ticket with a job that used 3,150 weighted
  tokens, one whose figure was converted from dollars by the migration, and a credential with a
  day's usage and a daily limit on the member's account settings.
  Users: `member`. Paths: `job`, `converted`, `ticket`, `settings`.
  """

  @behaviour Forge.Look.Setups

  import Ecto.Query, only: [from: 2]
  import Forge.AccountsFixtures
  import Forge.ForgeFixtures

  @impl true
  def build do
    member = user_fixture()
    project = project_fixture(%{name: "look-usage"}) |> join!(member)
    ticket = ticket_fixture(%{project: project, title: "Persist the high score table"})

    # A spec by hand, since a real one needs a git repository behind the project: the job page
    # draws its budget and its inputs.
    spec =
      %ForgeCore.Job.Spec{
        job_id: "look-1",
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

    counted = job_fixture(%{ticket: ticket, spec: spec})
    converted = job_fixture(%{ticket: ticket, attempt: 2, spec: spec})

    for {job, usage, flag} <- [{counted, 3_150, false}, {converted, 420_000, true}] do
      job
      |> Ecto.Changeset.change(
        status: :finished,
        outcome: :converged,
        usage: usage,
        usage_converted: flag,
        turns: 7
      )
      |> Forge.Repo.update!()
    end

    ticket
    |> Ecto.Changeset.change(usage: 423_150, usage_converted: true)
    |> Forge.Repo.update!()

    credential = credential_fixture(member)

    Forge.Repo.update_all(
      from(c in Forge.Credentials.Credential, where: c.id == ^credential.id),
      set: [daily_limit: 4_000_000]
    )

    run!(chat_fixture(%{project: project}), credential: credential, usage: 350_000)

    %{
      users: %{"member" => member},
      paths: %{
        "job" => "/tickets/#{project.name}/#{ticket.number}/jobs/#{counted.id}",
        "converted" => "/tickets/#{project.name}/#{ticket.number}/jobs/#{converted.id}",
        "ticket" => "/tickets/#{project.name}/#{ticket.number}",
        "settings" => "/users/settings"
      }
    }
  end
end
