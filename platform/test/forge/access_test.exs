defmodule Forge.AccessTest do
  @moduledoc """
  Membership, and what it does and does not let a person do.

  Each assertion is aimed at a rule: the capability expansion, the non-member's answer, the
  last-admin guard, and the fact that a node admin is not privileged here.
  See `docs/design/identity.md` § Projects and members.
  """

  use Forge.DataCase, async: true

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures

  alias Forge.Access
  alias Forge.Accounts.Scope
  alias Forge.Projects

  describe "capabilities" do
    test "an admin may use and manage" do
      assert Access.capabilities(:admin) == [:use, :manage]
    end

    test "a member may use but not manage" do
      # The mutation this catches: adding :manage to the member expansion. It is the whole
      # difference between the two roles.
      assert Access.capabilities(:member) == [:use]
    end
  end

  describe "can?/2" do
    setup do
      project = project_fixture()

      %{
        project: project,
        admin: member_fixture(project, :admin),
        member: member_fixture(project, :member)
      }
    end

    test "a member may use, not manage", %{project: project, member: user} do
      scope = Scope.for_project(Scope.for_user(user), project)

      assert Access.can?(scope, :use)
      refute Access.can?(scope, :manage)
    end

    test "an admin may do both", %{project: project, admin: user} do
      scope = Scope.for_project(Scope.for_user(user), project)

      assert Access.can?(scope, :use)
      assert Access.can?(scope, :manage)
    end

    test "a non-member may do neither", %{project: project} do
      scope = Scope.for_project(Scope.for_user(user_fixture()), project)

      # The mutation this catches: a nil role falling through to a permissive default. A scope
      # that did not resolve must never read as an unrestricted one.
      assert scope.role == nil
      refute Access.can?(scope, :use)
      refute Access.can?(scope, :manage)
    end

    test "a node admin is not privileged on a project it is not in", %{project: project} do
      scope = Scope.for_project(Scope.for_user(node_admin_fixture()), project)

      # The flag governs accounts, not work. If this ever passes, `node_admin` has quietly
      # become the superuser the design says it is not.
      refute Access.can?(scope, :use)
    end
  end

  describe "membership" do
    test "registering a project makes the registrant its admin" do
      user = user_fixture()

      {:ok, project} =
        Projects.register(
          %{name: "own-#{System.unique_integer([:positive])}", repo_path: "/srv/git/x.git"},
          user
        )

      assert Projects.role(project, user) == :admin
    end

    test "list/1 returns only the projects the user is in" do
      user = user_fixture()
      mine = project_fixture()
      join!(mine, user)
      theirs = project_fixture()

      names = Enum.map(Projects.list(user), & &1.name)

      assert mine.name in names
      refute theirs.name in names
    end

    test "put_member changes a role in place rather than adding a second row" do
      project = project_fixture()
      user = member_fixture(project, :member)
      admin = member_fixture(project, :admin)

      {:ok, _member} = Projects.put_member(project, user, :admin, admin)

      assert Projects.role(project, user) == :admin
      assert length(Projects.members(project)) == 2
    end

    test "removing a member takes their access away" do
      project = project_fixture()
      admin = member_fixture(project, :admin)
      user = member_fixture(project, :member)

      assert :ok = Projects.remove_member(project, user, admin)
      refute Projects.member?(project, user)
    end

    test "members/1 lists this project's people and nobody else's" do
      project = project_fixture()
      mine = member_fixture(project, :admin)

      other = project_fixture()
      theirs = member_fixture(other, :admin)

      ids = project |> Projects.members() |> Enum.map(& &1.user_id)

      # Without the project filter this returns every membership row on the node, and the
      # settings page lists strangers as members of your project.
      assert mine.id in ids
      refute theirs.id in ids
    end

    test "the last admin cannot be removed" do
      project = project_fixture()
      admin = member_fixture(project, :admin)
      _member = member_fixture(project, :member)

      # A member is not a substitute: only an admin can add an admin, so a project whose last
      # admin left is one nobody can ever administer again.
      assert {:error, :last_admin} = Projects.remove_member(project, admin, admin)
      assert Projects.role(project, admin) == :admin
    end

    test "an admin may be removed while another remains" do
      project = project_fixture()
      first = member_fixture(project, :admin)
      second = member_fixture(project, :admin)

      assert :ok = Projects.remove_member(project, second, first)
    end
  end
end
