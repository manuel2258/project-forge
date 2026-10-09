defmodule ForgeWeb.ProjectSettingsSecretsTest do
  @moduledoc """
  A project's secrets on its settings page (`docs/design/secrets.md` § Surfaces).

  The property worth pinning is that a value goes one way: typed once, sent once, and never on
  the page or in the page's process again — not after a save, not after a refusal. A page that
  could show it again would be a page that kept it.
  """

  use ForgeWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Forge.ForgeFixtures, only: [member_fixture: 2]
  import Forge.GitFixtures

  alias Forge.{Operator, Projects, Secrets}
  alias Forge.Secrets.Secret

  @value "sk_test_51Hx-typed-into-the-page"

  # A real repository, because the page also lists the project's mirrors from its git config.
  setup %{conn: conn} do
    admin = Forge.AccountsFixtures.user_fixture()

    {:ok, project} =
      Projects.register(
        %{name: "secrets-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
        admin
      )

    %{conn: log_in_user(conn, admin), project: project, admin: admin}
  end

  defp settings(conn, project), do: live(conn, ~p"/projects/#{project.name}/settings")

  defp set(view, params),
    do: view |> form("#secrets form", secret: params) |> render_submit()

  # Everything the page's process holds, as text: assigns, flash, the rendered tree.
  defp held(view),
    do: inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity)

  test "an admin sets one; it is listed by name and version and its value is nowhere", %{
    conn: conn,
    project: project
  } do
    {:ok, view, _html} = settings(conn, project)

    html = set(view, %{name: "STRIPE_TEST_KEY", value: @value})

    assert html =~ "Saved STRIPE_TEST_KEY, version 1."
    assert view |> element("#secret-rows td", "STRIPE_TEST_KEY") |> has_element?()
    refute html =~ @value
    refute held(view) =~ @value

    # Nor its ciphertext: the list is read without the value column, not filtered after it.
    [%{id: id}] = Secrets.list(project)
    sealed = Forge.Repo.one(from s in Secret, where: s.id == ^id, select: s.value)
    refute held(view) =~ sealed

    # A fresh form, so the browser lets go of what it was holding.
    assert has_element?(view, "#secret-form-1")
    refute has_element?(view, "#secret-form-0")

    assert [%Secret{name: "STRIPE_TEST_KEY", version: 1}] = Secrets.list(project)
  end

  test "setting a name again replaces it as the next version", %{conn: conn, project: project} do
    {:ok, view, _html} = settings(conn, project)
    set(view, %{name: "STRIPE_TEST_KEY", value: @value})

    html = set(view, %{name: "STRIPE_TEST_KEY", value: "sk_test_the-rotated-one"})

    assert html =~ "Saved STRIPE_TEST_KEY, version 2."
    assert [%Secret{version: 2}] = Secrets.list(project)
  end

  test "a refusal says which rule, keeps the name, and keeps no value", %{
    conn: conn,
    project: project
  } do
    {:ok, view, _html} = settings(conn, project)

    html = set(view, %{name: "API_KEY", value: "short"})

    assert html =~ "The value must be at least 8 characters"

    assert view
           |> element(~s(#secrets input[name="secret[name]"][value="API_KEY"]))
           |> has_element?()

    refute held(view) =~ ~s("short")

    html = set(view, %{name: "ANTHROPIC_BASE_URL", value: @value})

    assert html =~ "The name is reserved"
    refute html =~ @value
    refute held(view) =~ @value
    assert Secrets.list(project) == []
  end

  # A LiveView that raises is logged with its last message, unfiltered, and this page's last
  # message would be the form with the value in it. The database going away mid-save is the
  # failure nothing on the page can prevent: it is simulated by taking the page's process off the
  # test's connection, so its first query raises.
  test "a failure while saving is caught and logged by its kind, never with the value", %{
    conn: conn,
    project: project
  } do
    {:ok, view, _html} = settings(conn, project)
    Ecto.Adapters.SQL.Sandbox.mode(Forge.Repo, :manual)

    log =
      capture_log(fn ->
        send(self(), {:html, set(view, %{name: "STRIPE_TEST_KEY", value: @value})})
      end)

    assert_received {:html, html}
    assert html =~ "That did not work, and nothing was saved."
    assert log =~ "setting a project secret failed: DBConnection.OwnershipError"
    refute log =~ @value
    assert Process.alive?(view.pid)
  end

  # Any shape may arrive under the event's name; a clause that raised on one would be a crash
  # report carrying it.
  test "an event that is not the form is refused, not raised", %{conn: conn, project: project} do
    {:ok, view, _html} = settings(conn, project)

    for params <- [%{"secret" => "x"}, %{}, %{"secret" => [@value]}] do
      assert render_click(view, "set-secret", params) =~
               "That did not work, and nothing was saved."
    end

    render_click(view, "delete-secret", %{})
    assert Process.alive?(view.pid)
    assert Secrets.list(project) == []
  end

  test "an admin deletes one", %{conn: conn, project: project, admin: admin} do
    {:ok, secret} = Operator.set_secret(project, admin, "STRIPE_TEST_KEY", @value)
    {:ok, view, _html} = settings(conn, project)

    html = view |> element("#secret-rows button", "Delete") |> render_click()

    assert html =~ "Deleted STRIPE_TEST_KEY."
    refute has_element?(view, "#secret-rows")
    assert Secrets.list(project) == []
    assert Forge.Repo.get!(Secret, secret.id).deleted_at
  end

  describe "a member who is not an admin" do
    setup %{project: project, admin: admin} do
      member = member_fixture(project, :member)
      {:ok, secret} = Operator.set_secret(project, admin, "STRIPE_TEST_KEY", @value)
      %{member_conn: log_in_user(build_conn(), member), secret: secret}
    end

    test "reads the names, and is offered nothing to change", %{
      member_conn: conn,
      project: project
    } do
      {:ok, view, html} = settings(conn, project)

      assert view |> element("#secret-rows td", "STRIPE_TEST_KEY") |> has_element?()
      refute has_element?(view, "#secrets form")
      refute has_element?(view, "#secret-rows button")
      refute html =~ @value
    end

    # Hiding the form is not the guard; `Forge.Operator` is. Driven directly.
    test "is refused when driving either event by hand", %{
      member_conn: conn,
      project: project,
      secret: secret
    } do
      {:ok, view, _html} = settings(conn, project)

      html =
        render_click(view, "set-secret", %{
          "secret" => %{"name" => "STRIPE_TEST_KEY", "value" => "sk_test_the-member's-own"}
        })

      assert html =~ "Only an administrator can do that."

      refute held(view) =~ "sk_test_the-member's-own"

      html = render_click(view, "delete-secret", %{"id" => secret.id})
      assert html =~ "Only an administrator can do that."

      assert [%Secret{version: 1, deleted_at: nil}] = Secrets.list(project)
    end
  end
end
