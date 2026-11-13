defmodule ForgeWeb.AccountsLiveTest do
  @moduledoc """
  What the accounts page tells a node admin about each account.

  `ForgeWeb.ApprovalGateTest` covers who may reach this page at all. This covers what the page
  says once they are on it — specifically the origin column, which is the question a node admin
  is actually answering when a pending account appears: did somebody make this on the host, or
  did an issuer let it through?

  A column that answered that backwards would be worse than no column, because it would be
  believed.
  """

  use ForgeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Forge.AccountsFixtures

  alias Forge.Accounts

  setup %{conn: conn} do
    admin = node_admin_fixture()
    %{conn: log_in_user(conn, admin), admin: admin}
  end

  defp origins(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find(".account-identity")
    |> Enum.map(&(&1 |> Floki.text() |> String.trim()))
  end

  # Approve is an outline, not a primary: two waiting rows were two primaries side by side, and the
  # decision is reached from the queue's item (UX pass, A23).
  test "a waiting account's Approve is an outline", %{conn: conn} do
    waiting = pending_user_fixture()

    {:ok, lv, _html} = live(conn, ~p"/accounts")

    approve = ~s|button[phx-click="approve"][phx-value-id="#{waiting.id}"]|
    assert has_element?(lv, approve <> ".ui-btn--outline", "Approve")
    refute has_element?(lv, approve <> ".ui-btn--primary")
  end

  # In You's words for the same account (UX pass, D20): the way it can sign in, never `local`.
  test "an account made on the host says how it signs in, as You does", %{conn: conn} do
    user_fixture(%{email: "host@example.org"})

    {:ok, _lv, html} = live(conn, ~p"/accounts")

    assert "email link" in origins(html)
    refute "local" in origins(html)
  end

  # What Refuse and Delete each do is said before either is pressed (UX pass, D22).
  test "the waiting list says how Refuse and Delete differ", %{conn: conn} do
    pending_user_fixture()
    {:ok, view, _html} = live(conn, ~p"/accounts")

    assert has_element?(
             view,
             "#accounts-waiting-hint",
             "Refuse keeps the address blocked; Delete frees it to sign up again."
           )
  end

  # The pair is the identity (`docs/design/identity.md`), so the row draws both: the issuer, by
  # its host while no provider names it, and the subject it sent.
  test "an account an issuer let through is shown by its issuer and subject", %{conn: conn} do
    {:ok, _user} =
      Accounts.log_in_with_identity(%{
        issuer: "https://id.acme.example",
        subject: "sub-1",
        email: "person@example.org"
      })

    {:ok, _lv, html} = live(conn, ~p"/accounts")

    assert "id.acme.example · sub-1" in origins(html)
  end

  # The two together, because each alone passes against a column that prints one constant.
  test "the two are told apart on one page", %{conn: conn} do
    user_fixture(%{email: "host@example.org"})

    {:ok, _user} =
      Accounts.log_in_with_identity(%{
        issuer: "https://id.acme.example",
        subject: "sub-1",
        email: "person@example.org"
      })

    {:ok, _lv, html} = live(conn, ~p"/accounts")

    shown = origins(html)

    assert "email link" in shown
    assert "id.acme.example · sub-1" in shown
  end

  describe "deleting a squatted address" do
    test "a waiting account can be deleted, and its address comes free", %{conn: conn} do
      squatter = pending_user_fixture(%{email: "colleague@corp.com"})

      {:ok, lv, _html} = live(conn, ~p"/accounts")

      html =
        lv
        |> element(~s|button[phx-click="delete"][phx-value-id="#{squatter.id}"]|)
        |> render_click()

      refute html =~ "colleague@corp.com"
      refute Accounts.get_user_by_email("colleague@corp.com")
    end

    # It cannot be undone, so the page asks. Asserted because a confirm that quietly stops being
    # rendered is not something anyone notices until it matters.
    test "the button asks first", %{conn: conn} do
      _squatter = pending_user_fixture()

      {:ok, _lv, html} = live(conn, ~p"/accounts")

      assert html =~ "cannot be undone"
    end

    # An approved account has no Delete button, and would be refused if it had one. Both halves,
    # because hiding a button is cosmetics — `ForgeWeb.ApprovalGateTest` says the same of the page.
    test "an approved account is offered no delete, and refuses one anyway", %{conn: conn} do
      approved = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/accounts")

      refute has_element?(lv, ~s|button[phx-click="delete"][phx-value-id="#{approved.id}"]|)

      render_click(lv, "delete", %{"id" => approved.id})

      assert has_element?(
               lv,
               "#account-#{approved.id} #refused-#{approved.id}[role=alert]",
               "approved account cannot be deleted"
             )

      # In that row and no other.
      assert lv
             |> element("#accounts-decided")
             |> render()
             |> then(&Regex.scan(~r/id="refused-/, &1))
             |> length() == 1

      assert Accounts.get_user(approved.id)
    end
  end

  # Suspending signs the account out on its next request: a node admin is not offered it on their
  # own row, and the press is refused in that row if it is sent anyway (`Accounts.suspend_user/2`).
  test "your own row offers no Suspend, and a suspend of yourself is refused", %{
    conn: conn,
    admin: me
  } do
    other = user_fixture()
    {:ok, lv, _html} = live(conn, ~p"/accounts")

    refute has_element?(lv, ~s|#account-#{me.id} button[phx-click="suspend"]|)
    assert has_element?(lv, ~s|#account-#{other.id} button[phx-click="suspend"]|)

    render_click(lv, "suspend", %{"id" => me.id})

    assert has_element?(lv, "#refused-#{me.id}", "You cannot suspend your own account.")
    assert Forge.Accounts.User.active?(Accounts.get_user!(me.id))
  end

  # Suspend and Make admin each change who governs the node: asked in place, in words naming the
  # account, and done by the button the question offers.
  test "Suspend and Make admin ask first, naming the account", %{conn: conn} do
    other = user_fixture(%{email: "ana@example.org"})
    {:ok, lv, _html} = live(conn, ~p"/accounts")

    assert lv |> element("#suspend-#{other.id}-confirm") |> render() =~
             "Suspend ana@example.org? They are signed out everywhere"

    assert lv |> element("#promote-#{other.id}-confirm") |> render() =~
             "Make ana@example.org a node admin?"

    lv |> element("#promote-#{other.id}", "Make them admin") |> render_click()
    assert Accounts.get_user!(other.id).node_admin
  end

  # A page holds the user it mounted with. An admin suspended while `/accounts` was open went on
  # approving and reinstated themselves from it (review fixes 7, H1): every act reads the actor
  # again, and says so in the row.
  test "a suspended admin's open page can no longer approve or reinstate", %{admin: admin} do
    other = node_admin_fixture()
    pending = pending_user_fixture()
    {:ok, lv, _html} = live(log_in_user(build_conn(), other), ~p"/accounts")

    {:ok, _suspended} = Accounts.suspend_user(other, admin)

    render_click(lv, "approve", %{"id" => pending.id})
    refute Forge.Accounts.User.active?(Accounts.get_user!(pending.id))
    assert has_element?(lv, "#refused-#{pending.id}", "You can no longer govern accounts.")

    render_click(lv, "reinstate", %{"id" => other.id})
    refute Forge.Accounts.User.active?(Accounts.get_user!(other.id))
  end

  # Remove admin on your own row takes away the page you are on: asked first. On anyone else's it
  # is one tap, and only offered while an admin who can act is left (review fixes 7, M1).
  test "Remove admin asks first on your own row, and counts only admins who can act", %{
    conn: conn,
    admin: admin
  } do
    other = node_admin_fixture()
    {:ok, lv, _html} = live(conn, ~p"/accounts")

    assert lv |> element("#demote-#{admin.id}-confirm") |> render() =~
             "Remove your own admin?"

    assert has_element?(lv, ~s|#account-#{other.id} button[phx-click="demote"]|)
    refute has_element?(lv, "#demote-#{other.id}-confirm")

    # With the other admin suspended, you are the last who can act: no Remove admin on your row.
    {:ok, _suspended} = Accounts.suspend_user(other, admin)
    {:ok, lv, _html} = live(conn, ~p"/accounts")
    refute has_element?(lv, "#demote-#{admin.id}-confirm")
    refute has_element?(lv, ~s|#account-#{admin.id} button[phx-click="demote"]|)
  end

  # A press on a row another admin has just removed: no row is left to draw the refusal in, so it
  # is drawn above the lists rather than nowhere.
  test "a refusal for an account that has gone is drawn above the lists", %{conn: conn} do
    squatter = pending_user_fixture()
    {:ok, lv, _html} = live(conn, ~p"/accounts")

    {:ok, _} = Accounts.delete_unapproved_user(squatter, node_admin_fixture())
    render_click(lv, "suspend", %{"id" => squatter.id})

    refute has_element?(lv, "#account-#{squatter.id}")
    assert has_element?(lv, "#accounts-refused", "No such account.")
  end

  test "an account with two issuers shows both", %{conn: conn} do
    {:ok, user} =
      Accounts.log_in_with_identity(%{
        issuer: "https://id.acme.example",
        subject: "sub-1",
        email: "person@example.org"
      })

    {:ok, _identity} = Accounts.link_identity(user, "https://other.example.test", "sub-2")

    {:ok, _lv, html} = live(conn, ~p"/accounts")

    assert "id.acme.example · sub-1" in origins(html)
    assert "other.example.test · sub-2" in origins(html)
  end

  test "the title counts the waiting and the accounts", %{conn: conn} do
    pending_user_fixture()
    user_fixture()

    {:ok, lv, _html} = live(conn, ~p"/accounts")

    # The admin who is looking, one approved, one waiting.
    assert has_element?(lv, "#top-bar .ui-top-sub", "1 waiting · 3 accounts")
    assert has_element?(lv, "#accounts-waiting .ui-eyebrow", "Waiting")
  end

  # Beside each address: how long a waiting one has waited; admin and you; and how long ago a
  # suspended one was suspended.
  test "each row says where the account stands", %{conn: conn, admin: me} do
    waiting = pending_user_fixture()
    waiting |> Ecto.Changeset.change(inserted_at: ago(2 * 86_400)) |> Forge.Repo.update!()
    suspended = user_fixture()
    {:ok, _} = Accounts.suspend_user(suspended, me)
    suspended = Accounts.get_user(suspended.id)
    suspended |> Ecto.Changeset.change(suspended_at: ago(3 * 86_400)) |> Forge.Repo.update!()
    other = user_fixture()
    just = user_fixture()
    {:ok, _} = Accounts.suspend_user(just, me)

    {:ok, lv, _html} = live(conn, ~p"/accounts")

    # Under a minute in the sentence's words: never "suspended now" (r3 L3).
    assert has_element?(lv, "#account-#{just.id} .account-meta", "suspended <1m")

    assert has_element?(lv, "#account-#{waiting.id} .account-meta", "2d")
    assert has_element?(lv, "#account-#{me.id} .account-meta", "admin · you")
    assert has_element?(lv, "#account-#{suspended.id} .account-meta", "suspended 3d")
    refute has_element?(lv, "#account-#{other.id} .account-meta", "you")
    refute has_element?(lv, "#account-#{other.id} .account-meta", "admin")
  end

  defp ago(seconds),
    do: DateTime.utc_now() |> DateTime.add(-seconds) |> DateTime.truncate(:second)
end
