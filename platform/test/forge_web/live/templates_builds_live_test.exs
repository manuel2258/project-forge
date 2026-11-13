defmodule ForgeWeb.TemplatesBuildsLiveTest do
  @moduledoc """
  A credential's row on `/templates`: the switch, *Build now* and the account's recent image builds
  (`docs/design/ui.md` § Templates, `docs/design/provisioning.md` § Putting the release's image into
  an account). Only the credential's owner sees any of it.
  """

  use ForgeWeb.ConnCase, async: false

  import Forge.AccountsFixtures
  import Forge.ImageBuildsFixtures
  import Phoenix.LiveViewTest

  alias Forge.ImageBuilds.Build
  import Ecto.Query, only: [from: 2]

  alias Forge.{Provider, Repo}

  setup :register_and_log_in_user

  setup %{user: user} do
    Provider.Fake.watch()
    on_exit(&Provider.Fake.allow/0)
    put_release()
    %{credential: credential_fixture(user)}
  end

  defp mount_page(conn) do
    {:ok, lv, _html} = live(conn, ~p"/templates")
    html = render_async(lv)
    {lv, html}
  end

  defp insert_build(credential, attrs) do
    Repo.insert!(
      struct!(
        Build,
        Enum.into(attrs, %{
          provider_credential_id: credential.id,
          build: "abcdef123456",
          status: :built,
          started_at: DateTime.utc_now()
        })
      )
    )
  end

  test "with no builds the row says what would fill it", %{conn: conn} do
    {_lv, html} = mount_page(conn)
    assert html =~ "No builds yet"
    assert html =~ "the first time a template naming latest needs a machine"
    assert html =~ "Build worker images automatically"
  end

  test "a provider that cannot build draws no build controls", %{
    conn: conn,
    credential: credential
  } do
    Repo.update_all(from(c in Forge.Provisioning.Credential, where: c.id == ^credential.id),
      set: [provider: "local"]
    )

    {_lv, html} = mount_page(conn)
    refute html =~ "Build worker images automatically"
    refute html =~ "No builds yet"
  end

  test "on a node with no release there is neither switch nor button", %{conn: conn} do
    put_release(nil)
    {_lv, html} = mount_page(conn)
    assert html =~ "This node has no release build to put there."
    refute html =~ "Build worker images automatically"
    refute html =~ "Build now"
  end

  test "the switch is on for a credential and saved when flipped", %{
    conn: conn,
    credential: credential
  } do
    {lv, html} = mount_page(conn)
    assert html =~ ~r/<input[^>]*type="checkbox"[^>]*checked/

    lv |> element("#credential-#{credential.id} input[type=checkbox]") |> render_click()
    refute Repo.get!(Forge.Provisioning.Credential, credential.id).build_images

    # A reconnect loses nothing: the page is drawn from what is stored.
    {_lv, html} = mount_page(conn)
    refute html =~ ~r/<input[^>]*type="checkbox"[^>]*checked/
  end

  test "someone else's credential cannot be flipped or built by sending its id", %{conn: conn} do
    other = credential_fixture(user_fixture())
    {lv, _html} = mount_page(conn)

    render_hook(lv, "set-auto", %{"id" => other.id, "on" => "false"})
    render_hook(lv, "build-now", %{"id" => other.id})

    assert Repo.get!(Forge.Provisioning.Credential, other.id).build_images
    assert Repo.all(Build) == []
  end

  test "Build now is offered, costs a few minutes, and starts one build", %{
    conn: conn,
    credential: credential
  } do
    listing([])
    {lv, html} = mount_page(conn)
    assert html =~ "Build now"
    assert html =~ "a few minutes of a small machine"

    html = lv |> element("#credential-#{credential.id} button", "Build now") |> render_click()
    assert [%{status: :running}] = Repo.all(Build)
    refute html =~ ~r/<button[^>]*>\s*Build now/
    assert html =~ "A build is running."
    assert html =~ "running, started"
  end

  test "Build now is not offered when the current build is already in the account", %{conn: conn} do
    listing([snapshot("have", %{build: release_build(), current: true})])
    {_lv, html} = mount_page(conn)
    refute html =~ ~r/<button[^>]*>\s*Build now/
    assert html =~ "The current build is already in this account."
  end

  test "an account whose snapshots cannot be read offers nothing and says so", %{conn: conn} do
    Provider.Fake.refuse_images("revoked")
    {_lv, html} = mount_page(conn)
    refute html =~ ~r/<button[^>]*>\s*Build now/
    assert html =~ "could not be read"
  end

  test "shows the last five builds, newest first, with who started each", %{
    conn: conn,
    credential: credential
  } do
    now = DateTime.utc_now()

    for n <- 1..7 do
      insert_build(credential, %{
        build: "build#{String.pad_leading(to_string(n), 7, "0")}",
        started_at: DateTime.add(now, -n * 3600),
        template_name: if(n == 1, do: "my-template")
      })
    end

    {_lv, html} = mount_page(conn)
    positions = for n <- 1..5, do: html |> :binary.match("build000000#{n}") |> elem(0)
    assert positions == Enum.sort(positions)
    refute html =~ "build0000006"
    refute html =~ "build0000007"
    assert html =~ "by template my-template"
    assert html =~ "by Build now"
  end

  test "the words of a provider are text, never markup, and a long one is cut short", %{
    conn: conn,
    credential: credential
  } do
    insert_build(credential, %{
      status: :failed,
      message: "<b>bold</b> " <> String.duplicate("x", 500)
    })

    {_lv, html} = mount_page(conn)

    refute html =~ "<b>bold</b>"
    assert html =~ "&lt;b&gt;bold&lt;/b&gt;"
    assert html =~ "truncate"
  end

  test "an abandoned build says why", %{conn: conn, credential: credential} do
    insert_build(credential, %{
      status: :abandoned,
      message: "abandoned at the time limit: the builder never powered off"
    })

    {_lv, html} = mount_page(conn)
    assert html =~ "abandoned at the time limit"
  end

  test "another user's builds are never shown", %{conn: conn} do
    other = credential_fixture(user_fixture())
    insert_build(other, %{build: "theirs0000000", template_name: "their-template"})

    {_lv, html} = mount_page(conn)
    refute html =~ "theirs0000000"
    refute html =~ "their-template"
  end
end
