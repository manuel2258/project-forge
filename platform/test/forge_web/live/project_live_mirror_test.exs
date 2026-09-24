defmodule ForgeWeb.ProjectLiveMirrorTest do
  @moduledoc """
  A mirror that has stopped working says so where somebody will see it. `docs/design/git-hosting.md`
  § What the mirrors say about themselves — a health surface nobody visits is not one.
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

  defp record(project, name, status) do
    repo = Projects.repo_path(project)

    {:ok, _} =
      Forge.Git.run(repo, ["config", "--local", "forge.mirror.#{name}.lastStatus", status])
  end

  # `html =~ "none"` alone is satisfied by the unrelated "worker seed" fact just below the
  # mirror one, which also reads "none" for every project these tests register (no seed_id).
  # This scopes to the one `<dl>` row whose label is "mirror", the way `accounts_live_test.exs`
  # scopes to its origin column rather than the whole page.
  defp mirror_fact(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("dl > div")
    |> Enum.find_value(fn row ->
      with [dt] <- Floki.find(row, "dt"),
           "mirror" <- dt |> Floki.text() |> String.trim() do
        row |> Floki.find("dd") |> Floki.text() |> String.trim()
      else
        _ -> nil
      end
    end)
  end

  test "a project with no mirror says none", %{conn: conn, project: project} do
    {:ok, _lv, html} = live(conn, ~p"/projects/#{project.name}")

    assert mirror_fact(html) == "none"
  end

  test "a working mirror is named, not alarming", %{conn: conn, project: project, owner: owner} do
    :ok = Projects.put_mirror(project, owner, "github", "https://github.com/x/y.git", [])
    record(project, "github", "ok")

    {:ok, _lv, html} = live(conn, ~p"/projects/#{project.name}")

    assert html =~ "github"
    refute html =~ "failing"
  end

  test "a failing mirror says so on the page people open", %{
    conn: conn,
    project: project,
    owner: owner
  } do
    :ok = Projects.put_mirror(project, owner, "github", "https://github.com/x/y.git", [])
    record(project, "github", "failed")

    {:ok, _lv, html} = live(conn, ~p"/projects/#{project.name}")

    assert html =~ "failing"
    assert html =~ "github"
  end

  test "one failing among several is enough to say so", %{
    conn: conn,
    project: project,
    owner: owner
  } do
    :ok = Projects.put_mirror(project, owner, "good", "https://a.example/y.git", [])
    :ok = Projects.put_mirror(project, owner, "bad", "https://b.example/y.git", [])
    record(project, "good", "ok")
    record(project, "bad", "failed")

    {:ok, _lv, html} = live(conn, ~p"/projects/#{project.name}")

    assert html =~ "failing"
    assert html =~ "bad"
  end
end
