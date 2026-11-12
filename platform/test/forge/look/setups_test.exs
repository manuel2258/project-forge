defmodule Forge.Look.SetupsTest do
  use Forge.DataCase, async: false

  alias Forge.Look.Setups

  test "every registered setup builds, so one that rots fails the gate and not the next ticket" do
    for {name, module} <- Setups.all() do
      assert %{users: users, paths: paths} = module.build()
      assert map_size(users) > 0, "#{name} has no user to log in as"

      for {path_name, path} <- paths do
        assert :ok == Forge.Look.Steps.check_path(path), "#{name}: #{path_name} is not a path"
      end
    end
  end

  test "a setup is found by name, and an unknown one lists the others" do
    assert {:ok, Forge.Look.Setups.Ticket} = Setups.fetch("ticket")
    assert {:error, reason} = Setups.fetch("nope")
    assert reason =~ "there are: forge_release, ticket"
  end
end
