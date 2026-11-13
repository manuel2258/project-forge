defmodule Forge.Look.Setups.Projects do
  @moduledoc """
  The projects page (`11a`–`11e`): four projects of `member`'s — `game`, three items waiting and
  three jobs running; `forge`, one waiting and one running on a permanent machine; `site`, idle,
  last merged three days ago; `api`, which can run nothing. And `newcomer`, in no project at all
  (`11b`). Paths: `projects`, `new`.
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.MachinesFixtures, only: [template_fixture: 3]
  import Forge.ProjectFixtures

  alias Forge.TicketFixtures

  @impl true
  def build do
    member = user_fixture(%{email: "sam@example.com"})
    newcomer = user_fixture(%{email: "newcomer@example.com"})
    credential = credential_fixture(member)

    game = project!("game", member, credential)
    template_fixture(member, %{max_workers: 2}, [game])
    template_fixture(member, %{max_workers: 2}, [game])
    running = ticket_in!(game, 41, "implementing", ago: 4 * 60)
    jobs_running!(running, 3)
    for n <- 38..40, do: ticket_in!(game, n, "review", status: :stuck, ago: 3600 * n)

    forge = project!("forge", member, credential)
    template_fixture(member, %{max_workers: 2}, [forge])

    {:ok, machine, _token} =
      Forge.Workers.create(%{provider: "fake", managed: false, user_id: member.id})

    serve!(machine, forge)
    jobs_running!(ticket_in!(forge, 117, "implementing", ago: 7200), 1)
    ticket_in!(forge, 118, "review", status: :stuck, ago: 3600)

    site = project!("site", member, credential)
    template_fixture(member, %{max_workers: 2}, [site])
    merged!(site, 3 * 86_400)

    project!("api", member, credential)

    %{
      users: %{"member" => member, "newcomer" => newcomer},
      paths: %{"projects" => "/projects", "new" => "/projects/new"}
    }
  end

  defp project!(name, member, credential) do
    project = project_fixture(%{name: name}) |> join!(member)
    pool!(project, credential)
    project
  end

  # A merge `ago` seconds back: what the row's latest line reads when nothing is open.
  defp merged!(project, ago),
    do: TicketFixtures.merged!(ticket_in!(project, 12, "done", ago: ago), ago)
end
