defmodule ForgeWeb.UserLive.SettingsCodexTest do
  @moduledoc """
  Adding and reading a Codex credential on `/users/settings`
  (`docs/design/credentials.md`, `docs/design/ui.md` § Account settings): a ChatGPT login pasted into
  a box of several lines, an access token with an expiry, rows that say what each kind reports, and
  nothing of what was pasted coming back out.
  """

  use ForgeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Forge.{Credentials, Repo}

  @marker "MARKER-pasted-and-never-shown"

  setup :register_and_log_in_user

  defp login(account \\ "acct-ui") do
    claims =
      Base.url_encode64(~s({"https://api.openai.com/auth":{"chatgpt_plan_type":"plus"}}),
        padding: false
      )

    Jason.encode!(%{
      "tokens" => %{
        "id_token" => "h.#{claims}.s",
        "access_token" => "at-#{@marker}",
        "refresh_token" => "rt-#{@marker}",
        "account_id" => account
      }
    })
  end

  # The harness is changed first, on its own, as a person's choosing it is: the kinds a form offers
  # are the chosen harness's, and a test form is checked against what the page last drew.
  defp codex(view, kind, extra) do
    view |> form("#credential-form", credential: %{harness: "codex"}) |> render_change()
    view |> form("#credential-form", credential: %{kind: kind}) |> render_change()

    view
    |> form("#credential-form", credential: Map.merge(%{harness: "codex", kind: kind}, extra))
  end

  defp open(conn) do
    {:ok, view, _html} = live(conn, ~p"/users/settings")
    view
  end

  test "choosing Codex offers the two kinds by plan, and a login gets a box of several lines",
       %{conn: conn} do
    view = open(conn)
    html = view |> codex("chatgpt_login", %{}) |> render_change() |> String.replace(~r/\s+/, " ")

    assert html =~ "ChatGPT login (Plus or Pro)"
    assert html =~ "Codex access token (Business or Enterprise)"
    assert html =~ "codex login --device-auth"
    assert html =~ "forge alone"
    assert html =~ "sign that login out at OpenAI"
    assert html =~ "<textarea"
    refute html =~ "Expires on"

    token = view |> codex("access_token", %{}) |> render_change()
    assert token =~ "Expires on"
    refute token =~ "<textarea"
    refute token =~ "codex login --device-auth"
  end

  test "a login is saved on its shape, says it was not checked, and shows what it names",
       %{conn: conn} do
    view = open(conn)

    html = view |> codex("chatgpt_login", %{name: "mine", secret: login()}) |> render_submit()

    assert html =~ "not checked with OpenAI: the first job is the check"
    assert html =~ "account acct-ui"
    assert html =~ "plus plan"
    assert html =~ "free"
    # Nothing to check again: no call to OpenAI is made.
    refute html =~ "Check again"
    # Pasted in a box that is never valued, and emptied after a successful add.
    refute html =~ @marker

    refute inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity) =~
             @marker
  end

  test "a login that is wrong is refused without being echoed", %{conn: conn} do
    view = open(conn)

    html =
      view
      |> codex("chatgpt_login", %{name: "bad", secret: ~s({"tokens": #{@marker})})
      |> render_submit()

    assert html =~ "is not JSON"
    refute html =~ @marker
    assert Repo.aggregate(Forge.Credentials.Credential, :count) == 0
  end

  test "a login a live run holds says it is in use, and one whose run ended is free",
       %{conn: conn, user: user} do
    make = fn name ->
      {:ok, credential} =
        Credentials.create(user, %{
          name: name,
          harness: "codex",
          kind: "chatgpt_login",
          secret: login(name)
        })

      credential
    end

    held = make.("held")
    ended = make.("ended")
    project = Forge.ForgeFixtures.project_fixture()

    for {credential, finished_at} <- [{held, nil}, {ended, DateTime.utc_now(:second)}] do
      Repo.insert!(%Forge.Jobs.Run{
        job_id: Forge.ForgeFixtures.chat_fixture(%{project: project}).id,
        credential_id: credential.id,
        started_at: DateTime.utc_now(:second),
        finished_at: finished_at,
        exclusive: true
      })
    end

    {:ok, view, _html} = live(conn, ~p"/users/settings")
    assert view |> element("#credential-#{held.id}") |> render() =~ "in use"
    assert view |> element("#credential-#{ended.id}") |> render() =~ "free"
    refute view |> element("#credential-#{ended.id}") |> render() =~ "in use"
  end

  describe "an access token's expiry" do
    defp token(view, name, on),
      do:
        view
        |> codex("access_token", %{name: name, secret: "tok-#{name}", expires_on: on})
        |> render_submit()

    test "is asked, optionally, and its days left are drawn", %{conn: conn} do
      view = open(conn)
      in_a_month = Date.utc_today() |> Date.add(30) |> Date.to_iso8601()
      html = token(view, "later", in_a_month)

      assert html =~ "30 days left"
      refute html =~ "text-warning"

      assert view
             |> codex("access_token", %{name: "never", secret: "tok-never"})
             |> render_submit() =~ "never"
    end

    test "the warning starts at seven days left and not at eight", %{conn: conn} do
      view = open(conn)
      seven = Date.utc_today() |> Date.add(7) |> Date.to_iso8601()
      eight = Date.utc_today() |> Date.add(8) |> Date.to_iso8601()

      refute token(view, "eight", eight) =~ "text-warning"
      assert token(view, "seven", seven) =~ "text-warning"
    end

    test "in its last seven days is in warning colour, and after is expired", %{conn: conn} do
      view = open(conn)
      soon = Date.utc_today() |> Date.add(3) |> Date.to_iso8601()
      past = Date.utc_today() |> Date.add(-2) |> Date.to_iso8601()

      html = token(view, "soon", soon)
      assert html =~ "3 days left"
      assert html =~ "text-warning"

      html = token(view, "past", past)
      assert html =~ "expired"
    end
  end
end
