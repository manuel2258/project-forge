defmodule Forge.Look.Setups.Templates do
  @moduledoc """
  The Templates and Credentials views (`14a`–`14f`) from `Forge.MachinesFixtures.templates_fixture/1`:
  a priced catalogue in euros, a template with room, one full and one out of service. Users:
  `owner`, and `nothing` — a credential, a project and no template, for the none-yet page
  (`14e`). Paths: `templates`, `template` (the full one, opened), `new`, `credentials`.
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures
  import Forge.MachinesFixtures

  @impl true
  def build do
    owner = user_fixture()
    %{templates: templates} = templates_fixture(owner)

    nothing = user_fixture()

    {:ok, _} =
      Forge.Provisioning.create_credential(nothing, %{
        name: "hz-main",
        provider: "fake",
        secret: %{"token" => "made-up"}
      })

    Forge.ForgeFixtures.project_fixture(%{name: "unprovided"})
    |> Forge.ForgeFixtures.join!(nothing)

    %{
      users: %{"owner" => owner, "nothing" => nothing},
      paths: %{
        "templates" => "/templates",
        "template" => "/templates?template=#{templates.cx22.id}",
        "new" => "/templates?new=1",
        "credentials" => "/templates?view=credentials",
        "machines" => "/workers"
      }
    }
  end
end
