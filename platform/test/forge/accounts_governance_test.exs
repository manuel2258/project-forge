defmodule Forge.AccountsGovernanceTest do
  @moduledoc """
  The approval perimeter: who may act, who may let them, and what the log says about it.

  Every assertion here is aimed at a rule rather than a happy path, because the rules are the
  whole point of the module — see `docs/design/identity.md` § Approval.
  """

  use Forge.DataCase, async: true

  import Forge.AccountsFixtures

  alias Forge.Accounts
  alias Forge.Accounts.User

  describe "active?/1" do
    test "a pending account is not active" do
      refute User.active?(pending_user_fixture())
    end

    test "an approved account is active" do
      assert User.active?(user_fixture())
    end

    test "suspension outranks approval" do
      admin = node_admin_fixture()
      {:ok, user} = Accounts.suspend_user(user_fixture(), admin)

      # The mutation this catches: dropping `is_nil(suspended_at)` from active?/1. The row is
      # still approved, deliberately, so approval alone must not be enough to answer yes.
      assert user.approved_at
      refute User.active?(user)
    end
  end

  describe "approve_user/2" do
    test "approves and writes an attributed event" do
      admin = node_admin_fixture()
      user = pending_user_fixture()

      {:ok, approved} = Accounts.approve_user(user, admin)

      assert approved.approved_at
      assert User.active?(approved)

      event = last_event("user.approved")
      assert event.actor == %{"kind" => "user", "id" => admin.id}
      assert event.payload["user_id"] == user.id
    end
  end

  describe "suspend_user/2 and reinstate_user/2" do
    test "suspending stops the account acting, reinstating lets it act again" do
      admin = node_admin_fixture()
      user = user_fixture()

      {:ok, suspended} = Accounts.suspend_user(user, admin)
      refute User.active?(suspended)
      assert last_event("user.suspended").payload["user_id"] == user.id

      {:ok, reinstated} = Accounts.reinstate_user(suspended, admin)
      assert User.active?(reinstated)
      assert last_event("user.reinstated").payload["user_id"] == user.id
    end
  end

  describe "set_node_admin/3" do
    test "grants the flag" do
      admin = node_admin_fixture()
      user = user_fixture()

      {:ok, promoted} = Accounts.set_node_admin(user, admin, true)

      assert promoted.node_admin
      assert last_event("user.node_admin_granted").payload["user_id"] == user.id
    end

    test "revokes the flag while another admin remains" do
      admin = node_admin_fixture()
      other = node_admin_fixture()

      {:ok, demoted} = Accounts.set_node_admin(other, admin, false)

      refute demoted.node_admin
    end

    test "refuses to revoke the last node admin" do
      only = node_admin_fixture()

      # The mutation this catches: dropping the last_node_admin? clause. A node with no admin
      # is a node nobody can ever be approved into again, and no page could undo it.
      assert {:error, :last_node_admin} = Accounts.set_node_admin(only, only, false)
      assert Accounts.get_user!(only.id).node_admin
    end

    test "a suspended node admin still counts as one for the last-admin rule" do
      only = node_admin_fixture()
      {:ok, only} = Accounts.suspend_user(only, only)

      # Deliberate: the rule counts rows carrying the flag, not rows that may currently act.
      # Reinstating is one field, so a suspended admin is recoverable; a demoted last admin is
      # not. If this is ever changed, it must be changed knowing that.
      assert {:error, :last_node_admin} = Accounts.set_node_admin(only, only, false)
    end
  end

  describe "list_pending_users/0" do
    test "lists only accounts waiting on a decision" do
      admin = node_admin_fixture()
      pending = pending_user_fixture()
      approved = user_fixture()
      {:ok, suspended} = Accounts.suspend_user(user_fixture(), admin)

      ids = Enum.map(Accounts.list_pending_users(), & &1.id)

      assert pending.id in ids
      refute approved.id in ids
      # A refused account is decided, not waiting: it must not come back to the top of the page
      # every time it is looked at.
      refute suspended.id in ids
    end
  end

  describe "create_operator/3" do
    test "creates an approved account, not a pending one" do
      {:ok, user} = Accounts.create_operator(unique_user_email(), valid_user_password())

      assert User.active?(user)
      refute user.node_admin
    end

    test "seeds a node admin when asked" do
      {:ok, user} =
        Accounts.create_operator(unique_user_email(), valid_user_password(), node_admin: true)

      assert user.node_admin
      assert User.active?(user)
    end
  end

  describe "delete_unapproved_user/2" do
    test "frees the address a pending account was holding" do
      admin = node_admin_fixture()
      squatter = pending_user_fixture(%{email: "colleague@corp.com"})

      assert {:ok, _deleted} = Accounts.delete_unapproved_user(squatter, admin)
      refute Accounts.get_user_by_email("colleague@corp.com")

      # The whole point: the address can now be used by the person whose it is.
      assert {:ok, _user} = Accounts.create_operator("colleague@corp.com", "a long enough one")
    end

    test "takes the identities with it, so the issuer can provision again" do
      admin = node_admin_fixture()

      {:ok, squatter} =
        Accounts.log_in_with_identity(%{
          issuer: "https://id.oecis.io",
          subject: "sub-1",
          email: "colleague@corp.com"
        })

      assert {:ok, _deleted} = Accounts.delete_unapproved_user(squatter, admin)
      refute Accounts.get_user_by_identity("https://id.oecis.io", "sub-1")
    end

    # The perimeter, stated as a refusal: this is irreversible, so the page hiding the button is
    # not what may be relied on. Same shape as every other `govern/4` guard.
    test "a user who is not a node admin may not delete anyone" do
      assert {:error, :forbidden} =
               Accounts.delete_unapproved_user(pending_user_fixture(), user_fixture())
    end

    # Approval is the line. An approved account has reached projects, answers and decisions, and
    # the record of what it decided is what `on_delete: :restrict` exists to keep.
    test "an approved account is not deletable, however quiet its history" do
      admin = node_admin_fixture()

      assert {:error, :approved} = Accounts.delete_unapproved_user(user_fixture(), admin)
    end

    test "a suspended but never approved account is still deletable" do
      admin = node_admin_fixture()
      {:ok, squatter} = Accounts.suspend_user(pending_user_fixture(), admin)

      assert {:ok, _deleted} = Accounts.delete_unapproved_user(squatter, admin)
    end

    # The database is the authority on "has this account acted", not a question asked in Elixir.
    # A pending account cannot normally reach any of the restricting tables, so this reaches
    # around the perimeter to put a row there and proves the delete is refused rather than
    # raising an `Ecto.ConstraintError` through whatever called it.
    test "an account something still points at is refused, not raised through" do
      admin = node_admin_fixture()
      squatter = pending_user_fixture()

      project = Forge.ForgeFixtures.project_fixture()
      now = DateTime.utc_now(:second)

      Forge.Repo.insert_all("project_members", [
        %{
          id: Ecto.UUID.bingenerate(),
          project_id: Ecto.UUID.dump!(project.id),
          user_id: Ecto.UUID.dump!(squatter.id),
          role: "member",
          inserted_at: now,
          updated_at: now
        }
      ])

      assert {:error, :has_history} = Accounts.delete_unapproved_user(squatter, admin)
      assert Accounts.get_user_by_email(squatter.email)
    end

    test "the record of the deletion outlives the row" do
      admin = node_admin_fixture()
      squatter = pending_user_fixture(%{email: "colleague@corp.com"})

      {:ok, _deleted} = Accounts.delete_unapproved_user(squatter, admin)

      event = last_event("user.deleted")

      assert event.payload["email"] == "colleague@corp.com"
      assert event.payload["user_id"] == squatter.id
      assert event.actor == %{"kind" => "user", "id" => admin.id}
    end
  end

  defp last_event(type) do
    Forge.Repo.one!(
      from e in Forge.Events.Event, where: e.type == ^type, order_by: [desc: e.seq], limit: 1
    )
  end
end
