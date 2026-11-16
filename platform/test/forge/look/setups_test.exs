defmodule Forge.Look.SetupsTest do
  use Forge.DataCase, async: false

  alias Forge.Look.Setups

  test "every registered setup builds, so one that rots fails the gate and not the next ticket" do
    # A setup may configure the app as a look's own VM needs it (`signin_provider` installs an
    # OIDC provider); here that VM is the suite's, so what it changed is put back.
    oidc = Application.get_env(:forge, Forge.Accounts.Oidc)
    on_exit(fn -> Application.put_env(:forge, Forge.Accounts.Oidc, oidc || []) end)

    # `image_builds` gives the node a made-up worker image release, so its switch is drawn.
    image = Application.get_env(:forge, Forge.WorkerImage)
    on_exit(fn -> Application.put_env(:forge, Forge.WorkerImage, image || []) end)

    # A setup may stand the fake provider in for a priced one; no other test should inherit it.
    on_exit(&Forge.Provider.Fake.allow/0)

    # A look builds one setup into a database of its own, so two setups may name the same
    # person: each is built here and rolled back before the next.
    for {name, module} <- Setups.all() do
      Forge.Repo.transaction(fn ->
        assert %{users: users, paths: paths} = module.build()
        assert map_size(users) > 0, "#{name} has no user to log in as"

        for {path_name, path} <- paths do
          assert :ok == Forge.Look.Steps.check_path(path), "#{name}: #{path_name} is not a path"
        end

        Forge.Repo.rollback(:built)
      end)
    end
  end

  # The project page's tangled type has to draw a map, not an error: it is what a look photographs
  # for the case ticket 48 was filed about.
  test "the project setup's dev type parses, and draws its states" do
    Forge.Repo.transaction(fn ->
      Setups.Project.build()
      {:ok, %{types: types}} = Forge.Tickets.types(Forge.Projects.by_name("game"))

      assert %{workflow: {:ok, workflow}} = Enum.find(types, &(&1.name == "dev"))

      assert Enum.sort(ForgeWeb.Topology.order(workflow)) ==
               Enum.sort(~w(refining planning implementing checking reviewing presenting
                            review_ready merged rebasing))

      # What makes it the case the map was filed against, so that a tidier edit to the fixture
      # fails here and not on the next look: loops back, retries, two outcomes on one edge, and
      # the conflict edge.
      order = ForgeWeb.Topology.order(workflow)
      index = order |> Enum.with_index() |> Map.new()
      edges = ForgeCore.Workflow.edges(workflow)

      loops = for e <- edges, index[e.to] < index[e.from], do: e.when || "done"
      retries = for e <- edges, e.from == e.to, do: e.when

      assert Enum.sort(loops) ==
               Enum.sort(~w(plan_invalid checks_failed issues_found needs_review done))

      assert length(retries) == 8

      assert for(e <- edges, e.from == "reviewing", e.to == "presenting", do: e.when || "done") ==
               ["done", "budget_exhausted"]

      assert Enum.any?(edges, &(&1.from == "merged" and &1.to == "rebasing"))

      Forge.Repo.rollback(:built)
    end)
  end

  test "a setup is found by name, and an unknown one lists the others" do
    assert {:ok, Forge.Look.Setups.Ticket} = Setups.fetch("ticket")
    assert {:error, reason} = Setups.fetch("nope")
    assert reason =~ "there are: "

    for name <- Map.keys(Setups.all()), do: assert(reason =~ name)
  end
end
