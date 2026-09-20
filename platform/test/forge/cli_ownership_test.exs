defmodule Forge.CliOwnershipTest do
  @moduledoc """
  A project registered from the command line has to be reachable afterwards.

  Membership made `Projects.register/2` take an owner, and the two host-side callers were left
  passing none — which produced a project with no members: invisible to every user including a
  node admin, and repairable only with SQL. Both are documented commands
  (`README.md`, `docs/design/../deploy.md`), so this is the deploy path.
  """

  use Forge.DataCase, async: true

  import Forge.ForgeFixtures

  import Forge.AccountsFixtures

  import Forge.GitFixtures

  alias Forge.{Accounts, Projects}

  # `Projects.register/2` creates the bare repository, so the path has to be one this process
  # may write. It used to be `/srv/git/x.git`, which made these tests pass only on a machine
  # where that directory happened to exist and be writable — everywhere else they failed in
  # `File.mkdir_p!` before reaching the ownership rule they are about.
  defp attrs(label),
    do: %{
      name: "#{label}-#{System.unique_integer([:positive])}",
      repo_path: Path.join(tmp_dir("cli-owner"), "x.git")
    }

  describe "Projects.register/2 with no owner" do
    test "is refused rather than making an unreachable project" do
      assert {:error, :no_owner} = Projects.register(attrs("orphan"))
    end
  end

  describe "resolving the owner the command line names" do
    test "an address names its user" do
      user = user_fixture()
      assert {:ok, resolved} = Accounts.owner_for(user.email)
      assert resolved.id == user.id
    end

    test "an unknown address is refused, not silently ignored" do
      assert {:error, :unknown_user} = Accounts.owner_for("ghost@example.com")
    end

    test "with one node admin and no address, that admin is the owner" do
      # The single-operator case, which is every PoC node: naming yourself on every command is
      # friction for no decision.
      admin = node_admin_fixture()
      assert {:ok, resolved} = Accounts.owner_for(nil)
      assert resolved.id == admin.id
    end

    test "with two node admins and no address, it refuses rather than guessing" do
      _first = node_admin_fixture()
      _second = node_admin_fixture()
      assert {:error, :ambiguous_owner} = Accounts.owner_for(nil)
    end

    test "with no node admin at all and no address, it refuses" do
      assert {:error, :no_owner} = Accounts.owner_for(nil)
    end

    test "the resolved owner administers what it registers" do
      user = user_fixture()
      %{name: name} = a = attrs("released")
      {:ok, owner} = Accounts.owner_for(user.email)

      {:ok, project} = Projects.register(a, owner)

      assert Projects.role(project, user) == :admin
      assert name in Enum.map(Projects.list(user), & &1.name)
    end
  end

  describe "adding a member from the host" do
    test "grant_member/3 repairs a project the product cannot" do
      owner = user_fixture()
      {:ok, project} = Projects.register(attrs("repair"), owner)
      newcomer = user_fixture()

      assert {:ok, _member} = Projects.grant_member(project, newcomer, :member)
      assert Projects.role(project, newcomer) == :member
    end

    test "it does not need an existing admin to act through" do
      # The point of the host path: a project whose admins are all gone is fixable here and
      # nowhere else, so this must not route through `put_member/4`'s `:manage` check.
      owner = user_fixture()
      {:ok, project} = Projects.register(attrs("stranded"), owner)

      Forge.Repo.delete_all(from(m in Forge.Projects.Member, where: m.project_id == ^project.id))
      assert Projects.members(project) == []

      rescuer = user_fixture()
      assert {:ok, _member} = Projects.grant_member(project, rescuer, :admin)
      assert Projects.role(project, rescuer) == :admin
    end
  end

  describe "the host can approve without a node admin existing" do
    test "which is the bootstrap, since the first admin cannot be approved by anyone" do
      pending = pending_user_fixture()

      assert {:ok, user} = Accounts.approve_user(pending, :host)
      assert Accounts.User.active?(user)
    end
  end
end
