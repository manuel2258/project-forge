defmodule ForgeWeb.ProjectSettingsMirrorTest do
  @moduledoc """
  Setting a mirror without a shell, which is the whole reason this exists: the page used to show
  the mirror read-only and tell the operator to run a Mix task that a release does not have.
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.AccountsFixtures
  import Forge.GitFixtures

  alias Forge.Projects

  # `repos_dir` defaults to a single directory shared by the whole test environment, and
  # `register_named/3` addresses a project by name alone — a counter that restarts at a low
  # number on every `mix test` run. Without an override here, run N's project would leave its
  # bare repository (and whatever mirrors this file set on it) behind for run N+1's same-named
  # project to adopt. Pointing `repos_dir` at a fresh `node_repos_dir/0` per test avoids both the name
  # reuse and the leak, the way `test/forge/projects_mirror_test.exs` does.
  setup %{conn: conn} do
    owner = user_fixture()
    jobs_config = Application.get_env(:forge, Forge.Jobs)

    Application.put_env(
      :forge,
      Forge.Jobs,
      Keyword.put(jobs_config, :repos_dir, node_repos_dir())
    )

    # Captured now, while the override above is live: an `on_exit` that restored the config
    # first and read the credentials dir after would compute the *original* `repos_dir`.
    credentials_dir = Forge.Git.Credentials.dir()

    on_exit(fn ->
      Application.put_env(:forge, Forge.Jobs, jobs_config)
      File.rm_rf(credentials_dir)
    end)

    # `register_named/3`, not `register/2` with an arbitrary path: `put_mirror/5` refuses a
    # project whose repository is not at `<repos_dir>/<name>.git` (`:repo_path_not_standard`,
    # see `Forge.ProjectsMirrorTest`), and this is the call that guarantees that address.
    {:ok, project} =
      Projects.register_named("mirrored#{System.unique_integer([:positive])}", "main", owner)

    %{conn: log_in_user(conn, owner), project: project, owner: owner}
  end

  test "an admin adds one and sees it listed", %{conn: conn, project: project} do
    {:ok, lv, _html} = live(conn, ~p"/projects/#{project.name}/settings")

    html =
      lv
      |> form("#add-mirror", mirror: %{name: "github", url: "https://github.com/x/y.git"})
      |> render_submit()

    assert html =~ "github"
    assert html =~ "https://github.com/x/y.git"
    assert [%{name: "github"}] = Projects.list_mirrors(project)
  end

  test "a refused URL says so and stores nothing", %{conn: conn, project: project} do
    {:ok, lv, _html} = live(conn, ~p"/projects/#{project.name}/settings")

    html =
      lv
      |> form("#add-mirror", mirror: %{name: "evil", url: "ext::sh -c id"})
      |> render_submit()

    assert html =~ "https:// or http://"
    assert Projects.list_mirrors(project) == []
  end

  test "http says what it costs", %{conn: conn, project: project} do
    {:ok, _lv, html} = live(conn, ~p"/projects/#{project.name}/settings")

    assert html =~ "in clear"
  end

  # Write-only: the point of moving the token out of the URL was that no surface renders it.
  test "the token is never rendered back", %{conn: conn, project: project} do
    {:ok, lv, _html} = live(conn, ~p"/projects/#{project.name}/settings")

    lv
    |> form("#add-mirror",
      mirror: %{name: "github", url: "https://github.com/x/y.git", token: "s3cret"}
    )
    |> render_submit()

    refute render(lv) =~ "s3cret"
  end

  test "a mirror's status is shown", %{conn: conn, project: project, owner: owner} do
    :ok = Projects.put_mirror(project, owner, "github", "https://github.com/x/y.git", [])
    repo = Projects.repo_path(project)

    {:ok, _} =
      Forge.Git.run(repo, ["config", "--local", "forge.mirror.github.lastStatus", "failed"])

    {:ok, _} = Forge.Git.run(repo, ["config", "--local", "forge.mirror.github.lastError", "boom"])

    {:ok, _lv, html} = live(conn, ~p"/projects/#{project.name}/settings")

    assert html =~ "failed"
    assert html =~ "boom"
  end

  test "an admin removes one", %{conn: conn, project: project, owner: owner} do
    :ok = Projects.put_mirror(project, owner, "github", "https://github.com/x/y.git", [])

    {:ok, lv, _html} = live(conn, ~p"/projects/#{project.name}/settings")

    lv
    |> element(~s|button[phx-click="remove-mirror"][phx-value-name="github"]|)
    |> render_click()

    assert Projects.list_mirrors(project) == []
  end

  # Hiding the form is not the guard; the context is. Driven directly, as an ordinary member.
  #
  # The brief's version of this test minted a fresh, unrelated `owner` for `put_member/4`'s `by`
  # — a user who is an admin of nothing, so the call returns `{:error, :forbidden}` — and matched
  # its result against bare `:ok`, which `put_member/4` never returns (`{:ok, member}` on
  # success). Either defect alone crashes the test before it reaches the assertion it is for.
  # Fixed here: the project's actual admin from `setup` as `by`, matched against `{:ok, _}`.
  test "a member who is not an admin is refused even driving the event", %{
    project: project,
    owner: owner
  } do
    member = user_fixture()
    {:ok, _} = Projects.put_member(project, member, :member, owner)

    {:ok, lv, _html} =
      build_conn() |> log_in_user(member) |> live(~p"/projects/#{project.name}/settings")

    render_click(lv, "add-mirror", %{"mirror" => %{"name" => "x", "url" => "https://h/y.git"}})

    assert Projects.list_mirrors(project) == []
  end
end
