defmodule ForgeWeb.ProjectSettingsSectionsTest do
  @moduledoc """
  Project settings as an index of sections (`docs/design/ui.md` § Project settings, `9a`, `9i`,
  `21h`): one row per section with a one-line state in warning when it is something to look at,
  only Secrets and Repository for a member, and one render that a phone, a portrait screen and a
  wide one each arrange their own way.
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.AccountsFixtures
  import Forge.ForgeFixtures, only: [member_fixture: 2]
  import Forge.GitFixtures
  import Forge.SettingsFixtures

  alias Forge.Git.Tokens
  alias Forge.{Operator, Projects}

  @workflow """
  version: 1
  initial: refining
  states:
    refining:
      prompt: agents/refine.md
      inputs: [ticket]
      produces: [refinement.md]
      budget: { turns: 20, tokens: 100k }
      secrets: [STRIPE_TEST_KEY]
    done: {}
  transitions:
    - { from: refining, to: done }
  limits:
    ticket_tokens: 1M
  """

  setup %{conn: conn} do
    admin = user_fixture()
    jobs_config = Application.get_env(:forge, Forge.Jobs)

    Application.put_env(
      :forge,
      Forge.Jobs,
      Keyword.put(jobs_config, :repos_dir, node_repos_dir())
    )

    credentials_dir = Forge.Git.Credentials.dir()

    on_exit(fn ->
      Application.put_env(:forge, Forge.Jobs, jobs_config)
      File.rm_rf(credentials_dir)
    end)

    {:ok, project} =
      Projects.register_named("sections#{System.unique_integer([:positive])}", "main", admin)

    %{conn: log_in_user(conn, admin), admin: admin, project: project}
  end

  defp settings(conn, project, query \\ ""),
    do: live(conn, "/projects/#{project.name}/settings" <> query)

  defp state(view, key), do: view |> element("#section-#{key} .ui-row-latest") |> render()

  describe "the index" do
    test "an admin sees five sections, each with its state", ctx do
      %{conn: conn, project: project, admin: admin} = ctx
      {:ok, _secret, _token} = Tokens.issue(project, name: "ci", days: 30)
      member_fixture(project, :member)
      {:ok, project} = Operator.set_defaults(project, admin, %{effort: "high"})

      {:ok, view, _html} = settings(conn, project)

      for key <- ~w(tokens people agent secrets repository),
          do: assert(has_element?(view, "#section-#{key}"))

      assert state(view, "tokens") =~ "1 live"
      assert state(view, "people") =~ "2 people · 1 admin"
      assert state(view, "agent") =~ "model: the machine&#39;s · effort: high"
      assert state(view, "secrets") =~ "none set"
      assert has_element?(view, "#section-repository .ui-row-latest", ~r/^\s*main\s*$/)
      refute has_element?(view, "#settings-sections .ui-row-latest--warning")
    end

    test "a secret nothing receives is in warning, on its row and in the index", ctx do
      %{conn: conn, admin: admin} = ctx

      {:ok, project} =
        Projects.register(
          %{
            name: "warned-#{System.unique_integer([:positive])}",
            repo_path: seeded_repo(%{".forge/workflow.yml" => @workflow})
          },
          admin
        )

      {:ok, received} = Operator.set_secret(project, admin, "STRIPE_TEST_KEY", "sk_test_received")
      {:ok, misspelt} = Operator.set_secret(project, admin, "STRIPE_TEST_KYE", "sk_test_misspelt")

      {:ok, view, _html} = settings(conn, project, "?section=secrets")

      assert has_element?(
               view,
               "#section-secrets .ui-row-latest--warning",
               "2 set · 1 that nothing receives"
             )

      assert has_element?(view, "#secret-#{misspelt.id} .settings-warning", "no state or command")
      refute has_element?(view, "#secret-#{received.id} .settings-warning")
    end

    # A failed push is a failure: danger, as the mirror's own row says it (UX pass, D17), and the
    # failing mirror is listed first.
    test "a failing mirror is in danger, named, and listed first", ctx do
      %{conn: conn, project: project, admin: admin} = ctx
      :ok = Projects.put_mirror(project, admin, "github", "https://github.com/x/y.git", [])
      :ok = Projects.put_mirror(project, admin, "backup", "https://example.net/y.git", [])
      mirror_pushed!(project, "github", "failed", error: "denied (403)")
      mirror_pushed!(project, "backup", "ok")

      {:ok, view, _html} = settings(conn, project)

      assert has_element?(
               view,
               "#section-repository .ui-row-latest--danger",
               "main · github mirror failing"
             )

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings?section=repository")

      assert ["mirror-github", "mirror-backup"] =
               view
               |> render()
               |> LazyHTML.from_document()
               |> LazyHTML.query("#mirrors tbody tr")
               |> LazyHTML.attribute("id")
    end

    test "carries the clone URL with a way to copy it", %{conn: conn, project: project} do
      {:ok, view, _html} = settings(conn, project)

      assert has_element?(view, "#settings-sections #clone-url", "/git/#{project.name}.git")
      assert has_element?(view, "#settings-sections #clone-url-copy")
    end
  end

  # Hiding is not the guard — every operation refuses a member — but no form is offered to anyone
  # the operation would refuse, and the sections that are nothing but such forms are not drawn.
  describe "a member who is not an admin" do
    setup %{project: project, admin: admin} do
      member = member_fixture(project, :member)
      {:ok, _} = Operator.set_secret(project, admin, "STRIPE_TEST_KEY", "sk_test_the-value")
      %{member_conn: log_in_user(build_conn(), member)}
    end

    test "sees only Secrets and Repository", %{member_conn: conn, project: project} do
      {:ok, view, _html} = settings(conn, project)

      assert has_element?(view, "#section-secrets")
      assert has_element?(view, "#section-repository", "Branch")
      refute has_element?(view, "#section-repository", "mirrors")

      for key <- ~w(tokens people agent),
          do: refute(has_element?(view, "#section-#{key}"))

      # A bare page shows the first of theirs, not the admin's first.
      assert has_element?(view, "#secrets")
      refute has_element?(view, "#tokens-section")
    end

    test "is not drawn an admin's section by asking for it", %{
      member_conn: conn,
      project: project
    } do
      for section <- ~w(tokens people agent) do
        {:ok, view, _html} = settings(conn, project, "?section=#{section}")

        refute has_element?(view, "#tokens-section")
        refute has_element?(view, "#people")
        refute has_element?(view, "#agent")
        refute has_element?(view, "#token-form")
        assert has_element?(view, "#secrets")
      end
    end

    # A member cannot set or delete a secret, so the warning says whom to tell (UX pass, D26).
    test "is told to ask an admin about a secret nothing receives", %{
      member_conn: conn,
      project: project
    } do
      {:ok, view, _html} = settings(conn, project)

      assert has_element?(
               view,
               "#section-secrets .ui-row-latest--warning",
               "1 set · 1 that nothing receives — ask an admin"
             )
    end

    test "reads the default branch and no mirrors", %{
      member_conn: conn,
      project: project,
      admin: admin
    } do
      :ok = Projects.put_mirror(project, admin, "github", "https://github.com/x/y.git", [])
      mirror_pushed!(project, "github", "failed", error: "denied (403)")

      {:ok, view, html} = settings(conn, project, "?section=repository")

      assert has_element?(view, "#repository", "main")
      refute html =~ "github"
      refute has_element?(view, "#add-mirror")
    end
  end

  # What a phone draws is decided by CSS from these marks: the index is hidden once a section is
  # open, the form is drawn instead of the section on its own screen, and People's form sits at
  # the foot of its rows.
  describe "the phone's arrangement" do
    test "the bare page is the index, with nothing beside it", %{conn: conn, project: project} do
      {:ok, view, _html} = settings(conn, project)

      refute has_element?(view, "#settings-sections[data-open]")
      refute has_element?(view, "#settings[data-aside]")
      refute has_element?(view, ".settings-back")
      # On a desktop the first section is drawn beside the index; a phone does not draw it.
      assert has_element?(view, ".settings-main.settings-desk #tokens-section")
    end

    test "a section replaces the index and leads back to it", %{conn: conn, project: project} do
      {:ok, view, _html} = settings(conn, project, "?section=tokens")

      assert has_element?(view, "#settings-sections[data-open]")
      refute has_element?(view, "#settings[data-aside]")
      refute has_element?(view, ".settings-main.settings-desk")
      assert has_element?(view, ~s(a.settings-back[href="/projects/#{project.name}/settings"]))

      assert has_element?(
               view,
               ~s(a.settings-phone[href$="section=tokens&add=1"]),
               "Issue a token"
             )
    end

    test "a form replaces its section and leads back to it", %{conn: conn, project: project} do
      for section <- ~w(tokens secrets repository) do
        {:ok, view, _html} = settings(conn, project, "?section=#{section}&add=1")

        assert has_element?(view, ~s(#settings[data-aside="form"]))

        assert has_element?(
                 view,
                 ~s(a.settings-back[href="/projects/#{project.name}/settings?section=#{section}"])
               )
      end
    end

    test "people's form is at the foot of its rows", %{conn: conn, project: project} do
      {:ok, view, _html} = settings(conn, project, "?section=people")

      assert has_element?(view, ~s(#settings[data-aside="foot"]))
      assert has_element?(view, "#add-member-form")
    end

    # Issuing lands back on the list with the token beside it; the dock's button is the only way
    # out of the shown-once screen, so it draws no back link of its own.
    test "issuing shows the token in the form's place, and copying it returns to the list", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = settings(conn, project, "?section=tokens&add=1")

      view
      |> form("#token-form", %{"token" => %{"name" => "ci", "git" => "reader", "api" => "none"}})
      |> render_submit()

      assert_patch(view, "/projects/#{project.name}/settings?section=tokens")
      assert has_element?(view, ~s(#settings[data-aside="form"]))
      assert has_element?(view, "#issued")
      refute has_element?(view, ".settings-back")

      view |> element("#issued button", "I have copied it") |> render_click()

      refute has_element?(view, "#settings[data-aside]")
      refute has_element?(view, "#issued")
      assert has_element?(view, "#token-form")
    end
  end
end
