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
    %{conn: log_in_user(conn, node_admin_fixture())}
  end

  defp origins(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("span.font-mono")
    |> Enum.map(&(&1 |> Floki.text() |> String.trim()))
  end

  test "an account made on the host is shown as local", %{conn: conn} do
    user_fixture(%{email: "host@example.org"})

    {:ok, _lv, html} = live(conn, ~p"/accounts")

    assert "local" in origins(html)
  end

  test "an account an issuer let through is shown by its issuer", %{conn: conn} do
    {:ok, _user} =
      Accounts.log_in_with_identity(%{
        issuer: "https://id.acme.example",
        subject: "sub-1",
        email: "person@example.org"
      })

    {:ok, _lv, html} = live(conn, ~p"/accounts")

    assert "https://id.acme.example" in origins(html)
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

    assert "local" in shown
    assert "https://id.acme.example" in shown
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

      assert render(lv) =~ "approved account cannot be deleted"
      assert Accounts.get_user(approved.id)
    end
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

    assert Enum.any?(origins(html), &(&1 =~ "id.acme.example" and &1 =~ "other.example.test"))
  end
end
