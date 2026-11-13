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

  # Criterion 36: a long name is cut to its row and whole in its title, as names are elsewhere.
  test "a long credential name is truncated in its row and whole in its title", %{
    conn: conn,
    user: user
  } do
    name = String.duplicate("a-very-long-name ", 12) |> String.trim()
    credential = Forge.ForgeFixtures.credential_fixture(user, %{name: name})

    {view, _html} = open(conn)
    row = view |> element("#credential-#{credential.id} [title]") |> render()
    assert row =~ ~s(title="#{name}")
    # Cut to one line by `.you-credential-name` (an ellipsis, `areas/account.css`).
    assert row =~ ~s(class="you-credential-name")
  end

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
    assert html =~ "1 model"
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

    assert view |> element("#revoke-credential-#{credential.id}-confirm") |> render() =~
             "No job will start on it again"

    html = view |> element("#revoke-credential-#{credential.id}", "Revoke it") |> render_click()

    assert html =~ "revoked"

    refute has_element?(
             view,
             ~s(#credential-#{credential.id} button[phx-click="revoke-credential"])
           )

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

    # The × is a target like any other: the 46px floor has no phone exception.
    remove =
      view
      |> element(~s(#credential-#{credential.id} button[phx-click=unassign-credential]))
      |> render()

    assert remove =~ "min-h-[46px]"
    assert remove =~ "min-w-[46px]"

    view
    |> element(~s(#credential-#{credential.id} button[phx-click=unassign-credential]))
    |> render_click()

    assert Credentials.pool(project.id, "claude_code") == []
  end

  # The select offers the projects this credential does not fund yet, from a blank, and goes once
  # it funds them all (UX pass, D5).
  test "Assign offers only the projects the credential does not fund yet", %{
    conn: conn,
    user: user
  } do
    funded = Forge.ForgeFixtures.project_fixture()
    other = Forge.ForgeFixtures.project_fixture()
    Forge.ForgeFixtures.join!(funded, user, :member)
    Forge.ForgeFixtures.join!(other, user, :member)
    credential = Forge.ForgeFixtures.credential_fixture(user)
    {:ok, _} = Credentials.assign(user, credential.id, funded.id)

    {view, _html} = open(conn)

    select =
      view
      |> element("#credential-#{credential.id} form[phx-submit=assign-credential] select")
      |> render()

    refute select =~ ~s(value="#{funded.id}")
    assert select =~ ~s(value="#{other.id}")
    assert select =~ ~r/<option value="" disabled="" selected="">add a project…/

    {:ok, _} = Credentials.assign(user, credential.id, other.id)
    {view, _html} = open(conn)
    refute has_element?(view, "#credential-#{credential.id} form[phx-submit=assign-credential]")
  end

  # What each has used today and whether it is rate-limited now are what an owner of several
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
      set: [daily_limit: 1_000_000]
    )

    ran(project, spending, 250_000)
    ran(project, spending, 100_000)
    resets_at = DateTime.add(DateTime.utc_now(:second), 3600)

    :ok =
      Forge.Jobs.record_harness_event(ran(project, limited, 0).id, %{
        type: "job.harness.rate_limit",
        payload: %{
          status: "rejected",
          rate_limit_type: "five_hour",
          resets_at: DateTime.to_unix(resets_at)
        }
      })

    {view, _html} = open(conn)

    spending_row = view |> element("#credential-#{spending.id}") |> render()
    assert spending_row =~ "0.35 windows today (350k weighted tokens) of 1M/day, not enforced"
    refute spending_row =~ "rate-limited"

    limited_row = view |> element("#credential-#{limited.id}") |> render()
    assert limited_row =~ "0 windows today (0 weighted tokens)"

    assert view |> element("#credential-#{limited.id}-five_hour.text-warning") |> render() =~
             "5h · resets #{Calendar.strftime(resets_at, "%H:%M")} UTC · rate-limited"

    # A limited credential counts as full: its line is drawn at 100 though it reported no figure.
    assert has_element?(
             view,
             ~s(#credential-#{limited.id}-five_hour [role=meter][aria-valuenow="100"])
           )
  end

  # The tokens counted behind the figure, by kind, and — only on a Claude API key, which is billed
  # in dollars — Claude Code's own figure; a subscription token and a login show no dollars.
  test "a row shows today's tokens by kind, and a Claude API key its dollar figure", %{
    conn: conn,
    user: user
  } do
    project = Forge.ForgeFixtures.project_fixture()
    key = Forge.ForgeFixtures.credential_fixture(user, %{kind: "api_key"})
    token = Forge.ForgeFixtures.credential_fixture(user)

    for credential <- [key, token] do
      for input <- [1_000, 2_000] do
        job = Forge.ForgeFixtures.chat_fixture(%{project: project})

        Forge.ForgeFixtures.run!(job,
          credential: credential,
          usage: 10_000,
          tokens: %{"input" => input, "cache_write" => 0, "cache_read" => 500_000, "output" => 40},
          claude_cost_usd: Decimal.new("0.504")
        )
      end
    end

    {view, _html} = open(conn)

    key_tokens = view |> element("#credential-#{key.id}-tokens") |> render()
    assert key_tokens =~ "by kind: 3k fresh input · 0 cache write · 1M cache read · 80 output"

    assert view |> element("#credential-#{key.id}-dollars") |> render() =~
             "Claude Code&#39;s figure: $1.01 today"

    assert has_element?(view, "#credential-#{token.id}-tokens")
    refute has_element?(view, "#credential-#{token.id}-dollars")
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
      Forge.Jobs.record_harness_event(ran(project, reported, 0).id, %{
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

    # Each its usage line, the one the frame draws for that window.
    assert has_element?(
             view,
             ~s{#credential-#{reported.id}-five_hour .ui-usage:not(.ui-usage--week)[aria-valuenow="53"]}
           )

    assert has_element?(
             view,
             ~s(#credential-#{reported.id}-seven_day .ui-usage--week[aria-valuenow="15"])
           )
  end

  # Ticket 32: a window a newer report leaves out is still the week as last reported.
  test "a row keeps the week through a newer report that names only the five-hour window",
       %{conn: conn, user: user} do
    project = Forge.ForgeFixtures.project_fixture()
    credential = Forge.ForgeFixtures.credential_fixture(user)
    hour = DateTime.add(DateTime.utc_now(:second), 3600)
    week = DateTime.add(DateTime.utc_now(:second), 3 * 86_400)

    for windows <- [
          %{
            "five_hour" => %{utilization: 0.01, resets_at: DateTime.to_unix(hour)},
            "seven_day" => %{utilization: 0.3, resets_at: DateTime.to_unix(week)}
          },
          %{"five_hour" => %{utilization: 0.02, resets_at: DateTime.to_unix(hour)}}
        ] do
      :ok =
        Forge.Jobs.record_harness_event(ran(project, credential, 0).id, %{
          type: "job.harness.rate_limit",
          payload: %{
            status: "allowed",
            rate_limit_type: "five_hour",
            resets_at: DateTime.to_unix(hour),
            windows: windows
          }
        })
    end

    {view, _html} = open(conn)

    assert view |> element("#credential-#{credential.id}-five_hour") |> render() =~ "5h 2%"

    assert view |> element("#credential-#{credential.id}-seven_day") |> render() =~
             "week 30% · resets #{Calendar.strftime(week, "%a %H:%M")} UTC"
  end

  # A job in `project` that started just now on `credential` and used `usage`.
  defp ran(project, credential, usage) do
    job = Forge.ForgeFixtures.chat_fixture(%{project: project})

    Repo.update_all(from(j in Forge.Jobs.Job, where: j.id == ^job.id),
      set: [credential_id: credential.id]
    )

    Forge.ForgeFixtures.run!(job, credential: credential, usage: usage)
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

  # An empty list is the provider not saying, not a credential with no models (UX pass, D20);
  # and the form that adds one says what it is.
  test "a credential with no list of models says so, and the form is headed", %{
    conn: conn,
    user: user
  } do
    credential = Forge.ForgeFixtures.credential_fixture(user)
    {view, _html} = open(conn)

    assert has_element?(view, "#credential-#{credential.id}", "models not listed")
    refute has_element?(view, "#credential-#{credential.id}", "0 models")
    assert has_element?(view, "#credential-form h2", "Add a credential")
  end
end
