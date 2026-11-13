defmodule Forge.Look.Setups.Machines do
  @moduledoc """
  The machines pages (`12f`, `12g`, `12o`): one owner's fleet from `Forge.MachinesFixtures` —
  busy on a job and on a chat, idle until its template destroys it, permanent, turned away at its
  join, and destroyed with a log. **None is connected**: connection is a registry the platform
  holds for a live channel, and a look has none (`docs/design/look.md`). Users: `owner`. Paths:
  `machines`, `gone` (the destroyed machine's log), `studio` (a permanent machine's).
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures
  import Forge.MachinesFixtures

  @impl true
  def build do
    owner = user_fixture()
    %{machines: machines} = fleet_fixture(owner)

    %{
      users: %{"owner" => owner},
      paths: %{
        "machines" => "/workers",
        "gone" => "/workers/#{machines.gone.id}",
        "studio" => "/workers/#{machines.studio.id}"
      }
    }
  end
end
