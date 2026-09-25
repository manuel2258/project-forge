defmodule ForgeWeb.UserLive.SettingsCredentialsTest do
  @moduledoc """
  The section of `/users/settings` where a person adds, checks and revokes their inference
  credentials (`docs/design/credentials.md`).

  The assertions that matter are about the token: it is typed into this page and must never come
  back out of it — not into the rendered HTML, and not into the LiveView's state, which is what a
  crash report prints. The ownership guard itself is `Forge.CredentialsTest`'s; here it is only
  checked that the page hands the context the acting user rather than something else.
  """

  use ForgeWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Forge.AccountsFixtures

  alias Forge.{Credentials, Repo}

  @token "sk-ant-oat01-typed-into-the-page"

  setup :register_and_log_in_user

  defp stub(status) do
    Req.Test.stub(Forge.Harness.ClaudeCode, fn conn ->
      case status do
        200 -> Req.Test.json(conn, %{"data" => [%{"id" => "claude-opus-5"}]})
        status -> Plug.Conn.send_resp(conn, status, "")
      end
    end)
  end

  # The LiveView runs in its own process and asks the provider from there.
  defp open(conn) do
    {:ok, view, html} = live(conn, ~p"/users/settings")
    Req.Test.allow(Forge.Harness.ClaudeCode, self(), view.pid)
    {view, html}
  end

  defp state(view),
    do: inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity)

  test "a credential is added, and its token is in neither the page nor the state", %{conn: conn} do
    stub(200)
    {view, html} = open(conn)
    assert html =~ "Inference credentials"
    assert html =~ "None yet"

    # Every keystroke sends the whole form, the token included.
    changed =
      view
      |> form("#credential-form", credential: %{name: "work", kind: "oauth", secret: @token})
      |> render_change()

    refute changed =~ @token
    refute state(view) =~ @token

    html =
      view
      |> form("#credential-form", credential: %{name: "work", kind: "oauth", secret: @token})
      |> render_submit()

    assert html =~ "work"
    assert html =~ "Subscription token"
    assert html =~ "1 models"
    refute html =~ @token
    refute state(view) =~ @token
  end

  test "a token the provider refuses is not saved, and is not echoed back", %{
    conn: conn,
    user: user
  } do
    stub(401)
    {view, _html} = open(conn)

    html =
      view
      |> form("#credential-form", credential: %{name: "typo", secret: @token})
      |> render_submit()

    assert html =~ "was refused by the provider"
    refute html =~ @token
    refute state(view) =~ @token
    assert Credentials.list(user) == []
  end

  test "an unreachable provider is said so on the row", %{conn: conn} do
    stub(503)
    {view, _html} = open(conn)

    html =
      view
      |> form("#credential-form", credential: %{name: "offline", secret: @token})
      |> render_submit()

    assert html =~ "not checked: HTTP 503"
  end

  test "revoking one marks it and takes its buttons away", %{conn: conn, user: user} do
    stub(200)

    {:ok, credential} =
      Credentials.create(user, %{
        name: "old",
        harness: "claude_code",
        kind: "api_key",
        secret: @token
      })

    {view, _html} = open(conn)

    html = view |> element("#credential-#{credential.id} button", "Revoke") |> render_click()

    assert html =~ "revoked"
    refute has_element?(view, "#credential-#{credential.id} button", "Revoke")
    assert Credentials.get(user, credential.id).revoked_at
  end

  # The id is the client's. The page must pass the context the acting user, so an id belonging to
  # somebody else revokes nothing.
  test "somebody else's credential cannot be revoked or checked from here", %{conn: conn} do
    stub(200)
    other = user_fixture()

    {:ok, theirs} =
      Credentials.create(other, %{
        name: "theirs",
        harness: "claude_code",
        kind: "api_key",
        secret: @token
      })

    {view, _html} = open(conn)
    # A check that did reach their row would record this refusal on it.
    stub(401)

    render_click(view, "revoke-credential", %{"id" => theirs.id})
    render_click(view, "check-credential", %{"id" => theirs.id})

    assert %{revoked_at: nil, check_error: nil} = Credentials.get(other, theirs.id)
  end

  test "a credential is put in a project's pool from its row, and taken out again", %{
    conn: conn,
    user: user
  } do
    project = Forge.ForgeFixtures.project_fixture()
    Forge.ForgeFixtures.join!(project, user, :member)
    credential = Forge.ForgeFixtures.credential_fixture(user)

    {view, html} = open(conn)
    assert html =~ "no project yet"

    html =
      view
      |> element("#credential-#{credential.id} form[phx-submit=assign-credential]")
      |> render_submit(%{"credential" => credential.id, "project" => project.id})

    assert html =~ project.name
    assert [%{id: pooled}] = Credentials.pool(project.id, "claude_code")
    assert pooled == credential.id

    view
    |> element(~s(#credential-#{credential.id} button[phx-click=unassign-credential]))
    |> render_click()

    assert Credentials.pool(project.id, "claude_code") == []
  end

  # What each has spent today and whether it is rate-limited now are what an owner of several
  # needs to see which one the pool is leaning on (`docs/design/credentials.md` § Spend). The
  # limit is beside the figure and says it is not enforced, because it is not.
  test "a row says what the credential spent today and whether it is rate-limited", %{
    conn: conn,
    user: user
  } do
    project = Forge.ForgeFixtures.project_fixture()
    spending = Forge.ForgeFixtures.credential_fixture(user)
    limited = Forge.ForgeFixtures.credential_fixture(user)

    Repo.update_all(from(c in Forge.Credentials.Credential, where: c.id == ^spending.id),
      set: [daily_limit_usd: Decimal.new("5")]
    )

    ran(project, spending, "1.25")
    ran(project, spending, "0.5")
    resets_at = DateTime.add(DateTime.utc_now(:second), 3600)

    :ok =
      Forge.Jobs.record_harness_event(ran(project, limited, "0").id, %{
        type: "job.harness.rate_limit",
        payload: %{
          status: "rejected",
          rate_limit_type: "five_hour",
          resets_at: DateTime.to_unix(resets_at)
        }
      })

    {view, _html} = open(conn)

    spending_row = view |> element("#credential-#{spending.id}") |> render()
    assert spending_row =~ "$1.75 today of $5/day, not enforced"
    refute spending_row =~ "rate-limited"

    limited_row = view |> element("#credential-#{limited.id}") |> render()
    assert limited_row =~ "$0.00 today"

    assert view |> element("#credential-#{limited.id}-five_hour.text-warning") |> render() =~
             "5h · resets #{Calendar.strftime(resets_at, "%H:%M")} UTC · rate-limited"
  end

  # Each window the provider reported, five-hour then the week: its figure when it gave one, its
  # reset, and nothing in warning colour while nothing blocks. A credential that never reported
  # a window draws none.
  test "a row draws each window the provider reported", %{conn: conn, user: user} do
    project = Forge.ForgeFixtures.project_fixture()
    reported = Forge.ForgeFixtures.credential_fixture(user)
    silent = Forge.ForgeFixtures.credential_fixture(user)
    hour = DateTime.add(DateTime.utc_now(:second), 3600)
    week = DateTime.add(DateTime.utc_now(:second), 3 * 86_400)

    :ok =
      Forge.Jobs.record_harness_event(ran(project, reported, "0").id, %{
        type: "job.harness.rate_limit",
        payload: %{
          status: "allowed",
          rate_limit_type: "five_hour",
          resets_at: DateTime.to_unix(hour),
          windows: %{
            "five_hour" => %{utilization: 0.53, resets_at: DateTime.to_unix(hour)},
            "seven_day" => %{utilization: 0.15, resets_at: DateTime.to_unix(week)}
          }
        }
      })

    {view, _html} = open(conn)

    assert view |> element("#credential-#{reported.id}-five_hour") |> render() =~
             "5h 53% · resets #{Calendar.strftime(hour, "%H:%M")} UTC"

    assert view |> element("#credential-#{reported.id}-seven_day") |> render() =~
             "week 15% · resets #{Calendar.strftime(week, "%a %H:%M")} UTC"

    refute has_element?(view, "#credential-#{reported.id} .text-warning")
    refute has_element?(view, "[id^=credential-#{silent.id}-]")
  end

  # A job in `project` that started just now on `credential` and cost `cost`.
  defp ran(project, credential, cost) do
    job = Forge.ForgeFixtures.chat_fixture(%{project: project})

    Repo.update_all(from(j in Forge.Jobs.Job, where: j.id == ^job.id),
      set: [credential_id: credential.id]
    )

    Forge.ForgeFixtures.run!(job, credential: credential, cost: cost)
    job
  end

  # The ids are the client's: somebody else's credential cannot be pointed at a project from here,
  # even one the viewer is in.
  test "somebody else's credential cannot be put in a pool from here", %{conn: conn, user: user} do
    project = Forge.ForgeFixtures.project_fixture()
    Forge.ForgeFixtures.join!(project, user, :admin)
    theirs = Forge.ForgeFixtures.credential_fixture(user_fixture())

    {view, _html} = open(conn)

    html =
      render_submit(view, "assign-credential", %{
        "credential" => theirs.id,
        "project" => project.id
      })

    assert html =~ "could not assign it"
    assert Credentials.pool(project.id, "claude_code") == []
  end
end
