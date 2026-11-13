defmodule Forge.Look.Setups.Usage do
  @moduledoc """
  Usage (`23a`, `23b`, `22e`): a member with two credentials whose reports average 91 % of the
  five-hour window and 63 % of the week, and spend across the last five hours and the week in two
  projects — three items running now, two finished, a handful earlier — and some in a third
  project the member is not in, which is drawn as *elsewhere*. A colleague's credential is in
  `game`'s pool, so the panel on that project has someone it must not name.

  Users: `member`. Paths: `usage`, `project` (`game`, for the panel over its pool).
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.UsageFixtures

  @impl true
  def build do
    member = user_fixture()
    game = project_fixture(%{name: "game"}) |> join!(member)
    forge = project_fixture(%{name: "forge"}) |> join!(member)
    site = project_fixture(%{name: "site"})
    now = DateTime.utc_now(:second)

    work = pool!(game, credential_fixture(member, name: "work-max"))
    pool!(forge, work)
    spare = pool!(game, credential_fixture(member, name: "spare-pro"))
    pool!(site, spare)

    five_hour = DateTime.add(now, 72 * 60)
    week = DateTime.add(now, 2 * 86_400 + 3 * 3_600)

    reported!(game, work, %{"five_hour" => {0.95, five_hour}, "seven_day" => {0.70, week}})
    reported!(game, spare, %{"five_hour" => {0.87, five_hour}, "seven_day" => {0.56, week}})

    colleague = member_fixture(game)
    theirs = pool!(game, credential_fixture(colleague, name: "colleague-max"))
    reported!(game, theirs, %{"five_hour" => {0.40, five_hour}})

    spend!(game, forge, site, work, spare, now)

    %{
      users: %{"member" => member},
      paths: %{"usage" => "/usage", "project" => "/projects/#{game.name}"}
    }
  end

  defp spend!(game, forge, site, work, spare, now) do
    ago = fn minutes -> DateTime.add(now, -60 * minutes) end

    # Running now: a job, a conversation, a review in the other project.
    job(game, 41, "Persist the high score table", "implementing", 2, :running)
    |> spent!(work, 220_000, ago.(3), open: true)

    chat = chat_fixture(%{project: game, status: :running})

    {:ok, _} =
      Forge.Events.append("chat.message", :system, %{
        job_id: chat.id,
        payload: %{"text" => "Why is the build so slow on CI?"}
      })

    spent!(chat, spare, 110_000, ago.(6), open: true)

    job(forge, 118, "Retry backoff for the worker socket", "review", 1, :running)
    |> spent!(work, 90_000, ago.(12), open: true)

    # Finished this window.
    job(game, 44, "Replace the font atlas", "implementing", 1, :finished, :did_not_converge)
    |> spent!(work, 190_000, ago.(70))

    job(game, 42, "Shape the leaderboard screen", "shaping", 1, :finished, :converged)
    |> spent!(spare, 140_000, ago.(110))

    for {minutes, cost} <- [{150, 40_000}, {170, 30_000}, {190, 50_000}, {205, 20_000}] do
      job(forge, nil, "Earlier work", "refining", 1, :finished, :converged)
      |> spent!(spare, cost, ago.(minutes))
    end

    # In a project the member is not in.
    job(site, nil, "Not the member's to read", "implementing", 1, :finished, :converged)
    |> spent!(spare, 60_000, ago.(40))

    # Earlier in the week.
    for {hours, cost, project} <- [
          {30, 800_000, game},
          {52, 1_300_000, forge},
          {75, 600_000, game},
          {98, 1_000_000, game},
          {120, 440_000, forge}
        ] do
      job(project, nil, "Earlier in the week", "implementing", 1, :finished, :converged)
      |> spent!(work, cost, DateTime.add(now, -3_600 * hours))
    end
  end

  # A ticket numbered as the handoff draws it, where it draws one, and its job.
  defp job(project, number, title, state, attempt, status, outcome \\ nil) do
    attrs = %{project: project, title: title, state: state}
    ticket = ticket_fixture(if number, do: Map.put(attrs, :number, number), else: attrs)

    %{ticket: ticket, state: state, attempt: attempt}
    |> job_fixture()
    |> Forge.Jobs.Job.progress_changeset(%{status: status, outcome: outcome})
    |> Forge.Repo.update!()
  end
end
