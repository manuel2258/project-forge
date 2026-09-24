defmodule Forge.ProjectsMirrorTest do
  @moduledoc """
  Who may point a project's code at another host, and what is refused. A mirror is egress: it
  sends the project somewhere the node does not control, so the guard is in the context and not
  on the page — `docs/design/identity.md` § Where the guard lives, and `put_member/4`, which was
  once open because only the page refused.
  """

  # async: false, not true: `register_named/3` resolves its repository under
  # `Forge.Projects.repos_dir/0`, and isolating that means mutating the global `Forge.Jobs`
  # application config for the duration of each test (see the setup below). Two tests racing
  # that mutation concurrently — which is what `async: true` invites — would each run against
  # whichever directory the other last wrote, not its own. Serializing the file is the same
  # choice `test/forge_web/git_http_test.exs`, `test/forge/merge_test.exs` and
  # `test/forge/demo_test.exs` already made for the same reason.
  use Forge.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Forge.AccountsFixtures
  import Forge.GitFixtures

  alias Forge.Projects

  # `repos_dir` defaults to a single directory shared by the whole test environment
  # (`platform/tmp/repos`), and `register_named/3` addresses a project by name alone
  # (`mirrored#{System.unique_integer([:positive])}`) — a counter that restarts at a low
  # number on every `mix test` run. Without an override here, run N's project `mirrored3`
  # leaves its bare repository behind (with whatever mirrors this file set on it), and run
  # N+1's `mirrored3` adopts that same directory and inherits them. Pointing `repos_dir` at a
  # fresh `node_repos_dir/0` per test avoids both the name reuse and the leak: it is unique
  # per call and removes itself in its own `on_exit`.
  setup do
    owner = user_fixture()
    jobs_config = Application.get_env(:forge, Forge.Jobs)

    Application.put_env(
      :forge,
      Forge.Jobs,
      Keyword.put(jobs_config, :repos_dir, node_repos_dir())
    )

    # Captured now, while the override above is live: `Credentials.dir/0` reads
    # `Projects.repos_dir/0` when called, and an `on_exit` that restored the config first and
    # read it after would compute the *original* `repos_dir` — deleting an empty directory
    # nobody used while leaving this test's own credential files behind in the shared
    # `mirror-credentials` directory forever.
    credentials_dir = Forge.Git.Credentials.dir()

    on_exit(fn ->
      Application.put_env(:forge, Forge.Jobs, jobs_config)
      File.rm_rf(credentials_dir)
    end)

    # `register_named/3`, not `register/2` with a fixture path: `put_mirror/5` refuses a project
    # whose repository is not at `<repos_dir>/<name>.git` (see its moduledoc), and this is the
    # call that guarantees that address.
    {:ok, project} =
      Projects.register_named("mirrored#{System.unique_integer([:positive])}", "main", owner)

    %{project: project, owner: owner}
  end

  test "an admin may not point a mirror from a project whose repository is not where a normal registration would put it",
       %{owner: owner} do
    bare = Forge.GitFixtures.seeded_repo()

    {:ok, imported} =
      Projects.register(
        %{
          name: "imported#{System.unique_integer([:positive])}",
          repo_path: bare,
          default_branch: "main"
        },
        owner
      )

    assert {:error, :repo_path_not_standard} =
             Projects.put_mirror(imported, owner, "github", "https://github.com/x/y.git", [])

    assert Projects.list_mirrors(imported) == []
    refute File.exists?(Forge.Git.Credentials.path(imported, "github"))
  end

  test "a project admin sets one", %{project: project, owner: owner} do
    assert :ok = Projects.put_mirror(project, owner, "github", "https://github.com/x/y.git", [])
    assert [%{name: "github"}] = Projects.list_mirrors(project)
  end

  test "a member who is not an admin may not", %{project: project, owner: owner} do
    member = user_fixture()
    {:ok, _} = Projects.put_member(project, member, :member, owner)

    assert {:error, :forbidden} =
             Projects.put_mirror(project, member, "github", "https://github.com/x/y.git", [])

    assert Projects.list_mirrors(project) == []
  end

  test "somebody in no project at all may not", %{project: project} do
    assert {:error, :forbidden} =
             Projects.put_mirror(project, user_fixture(), "x", "https://h/y.git", [])
  end

  test "an admin may not store a URL the rules refuse", %{project: project, owner: owner} do
    assert {:error, :transport_helper} =
             Projects.put_mirror(project, owner, "evil", "ext::sh -c id", [])

    assert {:error, :scheme} =
             Projects.put_mirror(project, owner, "local", "/var/lib/forge/repos/other.git", [])

    assert {:error, :credentials_in_url} =
             Projects.put_mirror(project, owner, "x", "https://u:t@h/y.git", [])

    assert Projects.list_mirrors(project) == []
  end

  test "an admin may not store a name that breaks the key", %{project: project, owner: owner} do
    assert {:error, :invalid_name} =
             Projects.put_mirror(project, owner, "git.hub", "https://h/y.git", [])
  end

  # The token is the reason this function exists rather than a Hooks call from the LiveView.
  test "the token goes to the credential file and not into the config", %{
    project: project,
    owner: owner
  } do
    :ok =
      Projects.put_mirror(project, owner, "github", "https://github.com/x/y.git",
        user: "bot",
        token: "s3cret"
      )

    assert File.read!(Forge.Git.Credentials.path(project, "github")) =~ "s3cret"
    refute File.read!(Path.join(Projects.repo_path(project), "config")) =~ "s3cret"
    assert [%{user: "bot", url: "https://github.com/x/y.git"}] = Projects.list_mirrors(project)
  end

  test "removing a mirror removes its credential too", %{project: project, owner: owner} do
    :ok = Projects.put_mirror(project, owner, "github", "https://h/y.git", token: "s3cret")

    assert :ok = Projects.delete_mirror(project, owner, "github")
    refute File.exists?(Forge.Git.Credentials.path(project, "github"))
    assert Projects.list_mirrors(project) == []
  end

  test "a member who is not an admin may not remove one", %{project: project, owner: owner} do
    member = user_fixture()
    {:ok, _} = Projects.put_member(project, member, :member, owner)
    :ok = Projects.put_mirror(project, owner, "github", "https://h/y.git", [])

    assert {:error, :forbidden} = Projects.delete_mirror(project, member, "github")
    assert [%{name: "github"}] = Projects.list_mirrors(project)
  end

  test "setting one is recorded with who did it", %{project: project, owner: owner} do
    :ok = Projects.put_mirror(project, owner, "github", "https://h/y.git", [])

    assert %{payload: payload, actor: actor} = last_event("project.mirror_set")
    assert payload["project"] == project.name
    assert payload["mirror"] == "github"
    assert actor == %{"kind" => "user", "id" => owner.id}
  end

  test "removing one is recorded with who did it", %{project: project, owner: owner} do
    :ok = Projects.put_mirror(project, owner, "github", "https://h/y.git", [])

    assert :ok = Projects.delete_mirror(project, owner, "github")

    assert %{payload: payload, actor: actor} = last_event("project.mirror_removed")
    assert payload["project"] == project.name
    assert payload["mirror"] == "github"
    assert actor == %{"kind" => "user", "id" => owner.id}
  end

  defp last_event(type) do
    Forge.Repo.one!(
      from e in Forge.Events.Event, where: e.type == ^type, order_by: [desc: e.seq], limit: 1
    )
  end
end
