defmodule ForgeWeb.ProjectSettingsLiveTest do
  @moduledoc """
  Issuing, seeing and revoking a project's git credentials.

  The property worth pinning is that the secret appears exactly once and is never recoverable:
  only its hash is stored, so a page that could show it again would be a page that stored it.
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.GitFixtures

  alias Forge.Git.Tokens
  alias Forge.{Projects, Repo, Tickets}

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, project} =
      Projects.register(
        %{
          name: "settings-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo()
        },
        user
      )

    %{project: project}
  end

  @defaults %{"name" => "ci", "git" => "reader", "api" => "none", "days" => "7"}

  # The ticket select only exists once git is `branch`, and `form/3` checks its params against the
  # rendered DOM — so git changes on its own first, which is also the order an operator does it in.
  defp issue(view, %{"git" => "branch"} = params) do
    view |> form("#token-form", %{"token" => %{"git" => "branch"}}) |> render_change()
    view |> form("#token-form", %{"token" => Map.merge(@defaults, params)}) |> render_submit()
  end

  defp issue(view, params) do
    view |> form("#token-form", %{"token" => Map.merge(@defaults, params)}) |> render_submit()
  end

  # Settings belong to the project, so they carry its strip (`ui.md` § The bottom strip).
  test "the strip is the project's views", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")

    for key <- ~w(tickets merge chats workflow proposals) do
      assert has_element?(view, ~s|#tab-#{key}[href="/projects/#{project.name}?view=#{key}"]|)
    end
  end

  test "issues a read token and shows it once, with the line that uses it", ctx do
    %{conn: conn, project: project} = ctx
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings?section=tokens")

    html = issue(view, %{"name" => "dashboard", "api" => "read"})

    assert has_element?(view, "#issued h2", "dashboard")
    # What the token may do, said beside it: the row below can only describe it from now on.
    assert has_element?(view, "#issued", "Git: read every branch · API: read, until")
    assert has_element?(view, "#issued .ui-notice", "Copy it now. It is not shown again.")
    assert html =~ ~s(id="issued-secret")
    assert html =~ ~s(id="issued-curl")
    assert html =~ "Authorization: Bearer"
    assert html =~ "/api/v1/tickets"

    assert html =~ ~s(id="issued-url")
    assert html =~ ~s(data-target="issued-url")
    assert html =~ "phx-hook"
    assert [token] = Tokens.list(project)
    assert token.name == "dashboard"
    assert token.git_access == :reader
    assert token.api_access == :read

    # The secret is on screen and in nothing that is stored, and opens both doors.
    # Read as text: the URL may break after its `/` and `:` (`breakable/1`).
    text = html |> LazyHTML.from_document() |> LazyHTML.text()
    assert [_, secret] = Regex.run(~r|forge:([A-Za-z0-9_-]+)@|, text)
    assert {:ok, %{id: id}} = Tokens.authorise(secret, project, :read)
    assert {:ok, %{id: ^id}} = Tokens.authenticate_api(secret)
    assert id == token.id

    # Dismissing it is the last time it exists anywhere.
    refute view |> element("#issued button", "I have copied it") |> render_click() =~ secret
    refute render(view) =~ secret
  end

  test "an API-only token is shown without a clone URL, and the issuer is recorded", ctx do
    %{conn: conn, project: project, user: user} = ctx
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings?section=tokens")

    html = issue(view, %{"git" => "none", "api" => "write"})

    refute html =~ ~s(id="issued-url")
    assert html =~ ~s(id="issued-curl")
    assert [token] = Tokens.list(project)
    assert token.issued_by_id == user.id
    assert html =~ "issued by #{user.email}"
  end

  # Each choice is visible, because each decides what the token can touch: git as five rows, the
  # API as a switch, the days as a stepper (`9c`).
  test "nothing that writes is preselected", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings?section=tokens")

    assert has_element?(view, ~s(#token-form input[type=radio][name="token[git]"]:checked))
    assert has_element?(view, ~s(#token-form input[name="token[git]"][value=reader][checked]))

    for value <- ~w(none branch developer admin),
        do:
          refute(
            has_element?(view, ~s(#token-form input[name="token[git]"][value=#{value}][checked]))
          )

    assert has_element?(view, ~s(#token-form input[name="token[api]"][value=none][checked]))
    refute has_element?(view, ~s(#token-form input[name="token[api]"][value=write][checked]))
    assert has_element?(view, ~s(#token-form input#token-days[type=number][value="7"]))
  end

  # The admin scope's warning is inline on its row, and only while it is the one picked.
  test "the default branch's scope says what it reaches when picked", ctx do
    %{conn: conn, project: project} = ctx
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings?section=tokens")

    assert has_element?(
             view,
             ~s(label[for=token-git-admin]),
             "push any open ticket's branch and main"
           )

    refute has_element?(view, ~s(label[for=token-git-admin]), "every job builds on")

    view |> form("#token-form", %{"token" => %{"git" => "admin"}}) |> render_change()

    assert has_element?(view, ~s(label[for=token-git-admin]), "every job builds on")
  end

  test "a branch token is scoped to one ticket's branch", ctx do
    %{conn: conn, project: project, user: user} = ctx
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings?section=tokens")

    html = issue(view, %{"git" => "branch", "ticket" => to_string(ticket.number)})

    assert [token] = Tokens.list(project)
    assert token.git_access == :branch
    assert token.ref == "refs/heads/" <> ticket.branch
    assert token.ticket_id == ticket.id
    # Said as the form offered it, not as a ref (UX pass, D13).
    assert html =~ "Git: write ##{ticket.number}&#39;s branch"
    refute html =~ "refs/heads/#{ticket.branch}"
  end

  test "developer and admin tokens name no ref, and admin says what it reaches", ctx do
    %{conn: conn, project: project} = ctx
    {:ok, view, html} = live(conn, ~p"/projects/#{project.name}/settings?section=tokens")

    assert html =~ "push any open ticket&#39;s branch"
    assert html =~ "push any open ticket&#39;s branch and main"

    issue(view, %{"name" => "dev", "git" => "developer"})
    view |> element("#issued button", "I have copied it") |> render_click()
    issue(view, %{"name" => "adm", "git" => "admin"})

    # The band that shows it once says it in the form's words, never `admin` (UX pass, D13).
    assert has_element?(view, "#issued", "Git: push any open ticket's branch and main")
    refute has_element?(view, "#issued", "Git: admin")

    tokens = Map.new(Tokens.list(project), &{&1.name, &1})
    assert %{git_access: :developer, ref: nil} = tokens["dev"]
    assert %{git_access: :admin, ref: nil} = tokens["adm"]
  end

  test "a job's token cannot be asked for from the page", ctx do
    %{conn: conn, project: project} = ctx
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings?section=tokens")
    issue(view, %{"name" => "plain"})

    assert [token] = Tokens.list(project)
    assert is_nil(token.job_id)
    assert is_nil(token.ref)
  end

  test "a branch token with no ticket chosen is refused, not issued", ctx do
    %{conn: conn, project: project} = ctx
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings?section=tokens")

    html = issue(view, %{"git" => "branch", "ticket" => ""})

    assert html =~ "Choose the ticket"
    assert Tokens.list(project) == []
  end

  test "a refusal keeps what was typed and says what to change", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings?section=tokens")

    html = issue(view, %{"name" => "keep me", "days" => "366"})
    assert html =~ "from 1 to 365"
    assert html =~ ~s(value="keep me")

    assert issue(view, %{"name" => "x", "days" => "0"}) =~ "from 1 to 365"
    assert issue(view, %{"name" => "x", "days" => "soon"}) =~ "from 1 to 365"
    assert issue(view, %{"name" => "  "}) =~ "Give the token a name"
    assert issue(view, %{"name" => "x", "git" => "none", "api" => "none"}) =~ "allows nothing"
    assert Tokens.list(project) == []
  end

  test "a name over sixty characters is refused, and one with markup is drawn as text", ctx do
    %{conn: conn, project: project} = ctx
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings?section=tokens")

    # The input's own `maxlength` is the browser's; the server says it too.
    long = String.duplicate("n", 61)

    html =
      render_submit(view, "issue", %{
        "token" => Map.put(@defaults, "name", long) |> Map.put("nonce", nonce(view))
      })

    assert html =~ "A name is at most 60 characters."
    assert Tokens.list(project) == []

    html = issue(view, %{"name" => "<script>alert(1)</script>"})
    refute html =~ "<script>alert(1)"
    assert html =~ "&lt;script&gt;"
  end

  defp nonce(view) do
    [_, nonce] = Regex.run(~r/name="token\[nonce\]" value="([^"]+)"/, render(view))
    nonce
  end

  test "a second submit of the same form makes no second token", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings?section=tokens")
    params = Map.put(@defaults, "nonce", nonce(view))

    render_submit(view, "issue", %{"token" => params})
    render_submit(view, "issue", %{"token" => params})

    assert [_one] = Tokens.list(project)
  end

  test "with no tokens the section says what one is for", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings?section=tokens")

    assert has_element?(view, "#tokens-section", "lets an outside program")
    refute has_element?(view, "#tokens")
  end

  test "a row says what the token may do, who issued it and when it was used", ctx do
    %{conn: conn, project: project, user: user} = ctx
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings?section=tokens")
    issue(view, %{"name" => "nightly", "api" => "read"})
    [token] = Tokens.list(project)

    Repo.update!(
      Ecto.Changeset.change(token, last_used_at: DateTime.utc_now(:second), last_used_via: :api)
    )

    {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}/settings?section=tokens")
    assert html =~ "nightly"
    assert html =~ "Git: read every branch · API: read"
    assert html =~ "issued by #{user.email}"
    assert html =~ "via api"
  end

  test "a token whose issuer has gone says so, and keeps working", ctx do
    %{conn: conn, project: project, user: user} = ctx

    {:ok, secret, token} =
      Tokens.issue(project, name: "orphan", git: :reader, api: :read, issued_by_id: user.id)

    Repo.update!(Ecto.Changeset.change(token, issued_by_id: nil))
    {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}/settings?section=tokens")

    refute html =~ "removed account"
    refute html =~ "issued by"
    assert {:ok, _} = Tokens.authenticate_api(secret)
  end

  test "a hand-sent value outside the choices is refused, not a crash", ctx do
    %{conn: conn, project: project} = ctx
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings?section=tokens")
    nonce = nonce(view)

    for {field, value} <- [{"git", "root"}, {"api", "admin"}, {"days", "7abc"}] do
      params = @defaults |> Map.put(field, value) |> Map.put("nonce", nonce)

      assert render_submit(view, "issue", %{"token" => params}) =~ "Choose the" or
               render(view) =~ "Days must be"
    end

    assert Tokens.list(project) == []
  end

  test "a branch token for a ticket that is not this project's is refused", ctx do
    %{conn: conn, project: project, user: user} = ctx
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings?section=tokens")

    params = @defaults |> Map.merge(%{"git" => "branch", "ticket" => "#{ticket.number + 1}"})
    html = render_submit(view, "issue", %{"token" => Map.put(params, "nonce", nonce(view))})

    assert html =~ "Choose the ticket"
    assert Tokens.list(project) == []
  end

  # Whole, wrapping rather than cut: a `title` is a hover, and a phone has none.
  test "a long name is drawn whole", ctx do
    %{conn: conn, project: project} = ctx
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings?section=tokens")
    long = String.duplicate("long-name-", 5)
    issue(view, %{"name" => long})
    [token] = Tokens.list(project)

    assert has_element?(view, "#token-#{token.id} .settings-name", long)
  end

  test "the heading counts the live tokens, not the revoked ones", %{
    conn: conn,
    project: project
  } do
    {:ok, _secret, _kept} = Tokens.issue(project, name: "kept", git: :reader, api: :read)
    {:ok, _secret, gone} = Tokens.issue(project, name: "gone", git: :reader, api: :read)
    {:ok, _} = Tokens.revoke(gone.id)

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings?section=tokens")

    assert has_element?(view, "#tokens-section .settings-count", "1 live")
    assert has_element?(view, "#section-tokens", "1 live")
  end

  test "four hundred tokens leave the page readable", %{conn: conn, project: project} do
    for i <- 1..400,
        do: {:ok, _, _} = Tokens.issue(project, name: "token #{i}", git: :reader, api: :read)

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings?section=tokens")
    assert has_element?(view, "#tokens-section .settings-count", "400 live")
  end

  test "a live token can be revoked, and then is not live", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings?section=tokens")
    issue(view, %{})
    [token] = Tokens.list(project)

    html = view |> element(~s(button[phx-value-id="#{token.id}"])) |> render_click()

    assert [revoked] = Tokens.list(project)
    refute is_nil(revoked.revoked_at)
    refute Tokens.live?(revoked, DateTime.utc_now())

    # The row stays — it is the audit trail — but only behind the disclosure.
    refute html =~ ~s(phx-click="revoke")
    refute has_element?(view, "#token-#{token.id}")

    view |> element("button", "Show expired and revoked · 1") |> render_click()
    assert has_element?(view, "#token-#{token.id}.settings-spent", "revoked just now")
  end

  test "a token a job holds is listed and not revocable by hand", %{
    conn: conn,
    project: project,
    user: user
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    [job] = Forge.Jobs.for_ticket(ticket.id)
    {:ok, _secret, token} = Tokens.issue_for_job(job, ticket, project)

    {:ok, view, html} = live(conn, ~p"/projects/#{project.name}/settings?section=tokens")

    assert html =~ "held by a job · revoked when it ends"
    refute has_element?(view, ~s(button[phx-value-id="#{token.id}"]))

    # And the context refuses it even if the button is bypassed: revoking mid-run fails the job
    # for a reason nothing records.
    assert {:error, :held_by_job} = Tokens.revoke(token.id)
  end

  test "it requires a logged-in operator", %{project: project} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(build_conn(), ~p"/projects/#{project.name}/settings")
  end

  # One block per row on a phone and a table from 768px, from the same markup: the expiry is on
  # the name's line on a phone and in its own column on a desktop, and the control is in both.
  test "a token row draws its expiry for both widths and keeps its control", ctx do
    %{conn: conn, project: project} = ctx
    {:ok, _secret, token} = Tokens.issue(project, name: "t", days: 7)

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings?section=tokens")

    assert has_element?(
             view,
             "#token-#{token.id} .settings-name-line .settings-phone",
             ~r/in [67]d/
           )

    assert has_element?(view, "#token-#{token.id} td.settings-desk", ~r/in [67]d/)
    assert has_element?(view, ~s(#token-#{token.id} button[phx-click="revoke"]))
  end

  # About to lapse is something to look at; a job's token, which lasts hours by design, is not.
  test "a token about to lapse is in warning, a job's is not", ctx do
    %{conn: conn, project: project, user: user} = ctx
    {:ok, _secret, soon} = Tokens.issue(project, name: "soon", days: 2)
    {:ok, _secret, later} = Tokens.issue(project, name: "later", days: 4)

    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    [job] = Forge.Jobs.for_ticket(ticket.id)
    {:ok, _secret, held} = Tokens.issue_for_job(job, ticket, project)

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings?section=tokens")

    assert has_element?(view, "#token-#{soon.id} td.settings-warning")
    refute has_element?(view, "#token-#{later.id} td.settings-warning")
    refute has_element?(view, "#token-#{held.id} td.settings-warning")

    assert has_element?(
             view,
             "#section-tokens .ui-row-latest--warning",
             "1 expires within 3 days"
           )
  end

  # `docs/design/codex.md`: the project's default harness, and Codex's own model and effort, in the
  # one Save with Claude Code's (`docs/design/ui.md` § Model and effort).
  describe "the harness" do
    test "an admin sets the project's harness and Codex's dials, and clears them", ctx do
      %{conn: conn, project: project} = ctx
      {:ok, view, html} = live(conn, ~p"/projects/#{project.name}/settings?section=agent")
      assert html =~ "Harness"
      assert has_element?(view, ~s(#project_harness input[value="claude_code"][checked]))

      view
      |> form("#defaults-form", %{
        "project" => %{"harness" => "codex", "codex_model" => "gpt-x", "codex_effort" => "high"}
      })
      |> render_submit()

      assert %{harness: "codex", codex_model: "gpt-x", codex_effort: "high", model: nil} =
               Projects.get!(project.id)

      assert has_element?(view, ~s(#project_harness input[value="codex"][checked]))
      assert has_element?(view, "#section-agent", "Codex · model: gpt-x · effort: high")

      view
      |> form("#defaults-form", %{"project" => %{"codex_model" => "", "codex_effort" => ""}})
      |> render_submit()

      assert %{harness: "codex", codex_model: nil, codex_effort: nil} = Projects.get!(project.id)
    end

    test "a plain member is not shown the form, and the context refuses it", ctx do
      %{conn: conn, project: project} = ctx
      member = Forge.AccountsFixtures.user_fixture()
      Forge.ForgeFixtures.join!(project, member, :member)
      conn = log_in_user(build_conn(), member)

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings?section=agent")
      refute has_element?(view, "#defaults-form")

      assert {:error, :forbidden} = Forge.Operator.set_harness(project, member, "codex")

      assert {:error, :forbidden} =
               Forge.Operator.set_defaults(project, member, %{codex_model: "gpt-x"})

      assert %{harness: "claude_code", codex_model: nil} = Projects.get!(project.id)
    end
  end
end
