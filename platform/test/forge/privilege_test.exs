defmodule Forge.PrivilegeTest do
  @moduledoc """
  Every human write, refused for someone who may not make it.

  These are aimed at the class a review found: the guards were at `Forge.Operator`'s entrance
  and at LiveView mounts, and every write that went through neither — a `handle_event` holding a
  client-supplied id, the settings handlers — was open. See `docs/design/identity.md`
  § Where the guard lives.
  """

  use Forge.DataCase, async: true

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures

  alias Forge.{Accounts, Conversations, Operator, Projects}

  setup do
    project = project_fixture()

    %{
      project: project,
      admin: member_fixture(project, :admin),
      member: member_fixture(project, :member),
      # A member of somewhere *else*, not a member of nothing. An account with no membership at
      # all is refused by paths that a membership row alone would satisfy, so it cannot tell a
      # project filter from its absence.
      outsider: member_fixture(project_fixture(), :admin)
    }
  end

  describe "conversations" do
    test "an outsider cannot send into a conversation", %{project: project, outsider: outsider} do
      chat = chat_fixture(%{project: project, status: :running})

      assert {:error, :forbidden} = Operator.send_chat(chat, outsider, "rm -rf the repo please")
      assert Conversations.messages(chat.id) == []
    end

    test "a member can", %{project: project, member: member} do
      chat = chat_fixture(%{project: project, status: :running})

      assert {:ok, _event} = Operator.send_chat(chat, member, "which backend?")
      assert Enum.map(Conversations.messages(chat.id), & &1.text) == ["which backend?"]
    end

    test "an outsider cannot stop, close or reopen one", %{project: project, outsider: outsider} do
      chat = chat_fixture(%{project: project, status: :running})

      assert {:error, :forbidden} = Operator.stop_chat(chat, outsider)
      assert {:error, :forbidden} = Operator.close_chat(chat, outsider)
      assert {:error, :forbidden} = Operator.reopen_chat(chat, outsider)
    end

    test "an outsider cannot open one on someone else's project", %{
      project: project,
      outsider: outsider
    } do
      assert {:error, :forbidden} = Operator.open_chat(project, outsider, "let me in")
    end
  end

  describe "project settings are the admin's" do
    test "a member cannot change the model", %{project: project, member: member} do
      assert {:error, :forbidden} = Operator.set_model(project, member, "evil-model")
      assert Projects.get!(project.id).model == nil
    end

    test "an admin can", %{project: project, admin: admin} do
      assert {:ok, _project} = Operator.set_model(project, admin, "claude-opus-5")
      assert Projects.get!(project.id).model == "claude-opus-5"
    end

    # The second dial needs its own guard, not the first one's: a setter reached without one is
    # a member turning the whole project's spend up.
    test "a member cannot change the effort", %{project: project, member: member} do
      assert {:error, :forbidden} = Operator.set_effort(project, member, "max")
      assert Projects.get!(project.id).effort == nil
    end

    test "an admin can change the effort", %{project: project, admin: admin} do
      assert {:ok, _project} = Operator.set_effort(project, admin, "high")
      assert Projects.get!(project.id).effort == "high"
    end

    test "a member cannot mint a git token", %{project: project, member: member} do
      assert {:error, :forbidden} = Operator.issue_token(project, member, [])
      assert Forge.Git.Tokens.list(project) == []
    end

    test "a member cannot revoke one", %{project: project, admin: admin, member: member} do
      {:ok, _secret, token} = Operator.issue_token(project, admin, [])

      assert {:error, :forbidden} = Operator.revoke_token(project, member, token.id)
      assert [%{revoked_at: nil}] = Forge.Git.Tokens.list(project)
    end

    test "an admin cannot revoke another project's token", %{admin: admin, project: project} do
      other = project_fixture()
      other_admin = member_fixture(other, :admin)
      {:ok, _secret, theirs} = Operator.issue_token(other, other_admin, [])

      # The id is the only thing the page sends. Without resolving it to this project, any
      # admin anywhere can revoke any token on the node given its UUID.
      assert {:error, :not_found} = Operator.revoke_token(project, admin, theirs.id)
      assert [%{revoked_at: nil}] = Forge.Git.Tokens.list(other)
    end
  end

  describe "admitting a ticket" do
    test "an outsider cannot admit into someone else's project", %{
      project: project,
      outsider: outsider
    } do
      assert {:error, :forbidden} = Operator.admit(project, outsider, %{title: "mine now"})
      assert Forge.Tickets.list(project) == []
    end
  end

  describe "membership" do
    test "the last admin cannot demote itself" do
      # Its own project: the setup's already has two admins, and the rule is about the last one.
      project = project_fixture()
      only = member_fixture(project, :admin)

      # `remove_member/3` refuses this; `put_member/4` did not, and a project with no admin has
      # nobody who can add one. The repair is SQL.
      assert {:error, :last_admin} = Projects.put_member(project, only, :member, only)
      assert Projects.role(project, only) == :admin
    end

    test "an admin may be demoted while another remains", %{project: project, admin: admin} do
      second = member_fixture(project, :admin)

      assert {:ok, _member} = Projects.put_member(project, second, :member, admin)
      assert Projects.role(project, second) == :member
    end

    # Approval is the perimeter, and a membership is inside it. The page said "No approved
    # account" for an unknown address and then added a pending one.
    test "an account nobody has approved is not added", %{project: project, admin: admin} do
      pending = pending_user_fixture()

      assert {:error, :not_approved} = Projects.put_member(project, pending, :member, admin)
      assert Projects.role(project, pending) == nil
    end

    # Suspended outranks approved, as it does for a login: the row keeps `approved_at` so that
    # reinstating is one field, and that must not read as "may be added".
    test "a suspended account is not added either", %{project: project, admin: admin} do
      {:ok, suspended} = Accounts.suspend_user(user_fixture(), node_admin_fixture())

      assert {:error, :suspended} = Projects.put_member(project, suspended, :member, admin)
      assert Projects.role(project, suspended) == nil
    end

    # Not only for someone new: a member already in the project who is then suspended is not
    # promoted either. A check that looked only at accounts with no row yet would let a
    # suspended member be made an admin of the project they can no longer sign in to.
    test "a member who is suspended is not given a new role", %{project: project, admin: admin} do
      member = member_fixture(project, :member)
      {:ok, suspended} = Accounts.suspend_user(member, node_admin_fixture())

      assert {:error, :suspended} = Projects.put_member(project, suspended, :admin, admin)
      assert Projects.role(project, suspended) == :member
    end

    # The caller's check comes first, so the answer says nothing about somebody's account to
    # somebody who could not have added them anyway.
    test "a non-admin is refused before anything is said about the account", %{
      project: project,
      member: member
    } do
      assert {:error, :forbidden} =
               Projects.put_member(project, pending_user_fixture(), :member, member)
    end
  end

  describe "account governance checks its actor" do
    test "a plain user cannot approve an account" do
      pending = pending_user_fixture()
      nobody = user_fixture()

      assert {:error, :forbidden} = Accounts.approve_user(pending, nobody)
      refute Accounts.get_user!(pending.id).approved_at
    end

    test "a plain user cannot promote themselves" do
      nobody = user_fixture()

      assert {:error, :forbidden} = Accounts.set_node_admin(nobody, nobody, true)
      refute Accounts.get_user!(nobody.id).node_admin
    end

    test "a plain user cannot suspend anyone" do
      victim = user_fixture()
      nobody = user_fixture()

      assert {:error, :forbidden} = Accounts.suspend_user(victim, nobody)
      assert Forge.Accounts.User.active?(Accounts.get_user!(victim.id))
    end

    test "a node admin can do all three" do
      admin = node_admin_fixture()
      pending = pending_user_fixture()

      assert {:ok, _} = Accounts.approve_user(pending, admin)
      assert {:ok, _} = Accounts.set_node_admin(pending, admin, true)
      assert {:ok, _} = Accounts.suspend_user(pending, admin)
    end
  end
end
