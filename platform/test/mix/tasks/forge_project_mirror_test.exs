defmodule Mix.Tasks.Forge.Project.MirrorTest do
  @moduledoc """
  `mix forge.project.mirror` is a second place `Forge.Projects.put_mirror/5`'s rules have to hold:
  `owner/1` here resolves the acting admin the same way `Forge.Projects.by_name/1` and
  `Accounts.owner_for/1` do for `mix forge.project.add`, and a rule duplicated in two places fails
  in whichever of them nobody is looking at. `--none` is tested for the same reason the task was
  rewritten: the previous grammar's `NAME --none` removed a project's one mirror, and now that a
  project may have several, that same command must not silently do nothing.
  """

  use Forge.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Forge.GitFixtures

  alias Forge.{AccountsFixtures, Projects}
  alias Mix.Tasks.Forge.Project.Mirror

  # `repos_dir` defaults to a single directory shared by the whole test environment, and
  # `register_named/3` addresses a project by name alone — a counter that restarts at a low
  # number on every `mix test` run. Without an override here, run N's project would leave its
  # bare repository (and whatever mirrors this file set on it) behind for run N+1's same-named
  # project to adopt — exactly what corrupted "--owner records the named admin as the actor"
  # above, whose project inherited another run's mirrors. Pointing `repos_dir` at a fresh
  # `node_repos_dir/0` per test avoids both the name reuse and the leak, the way
  # `test/forge/projects_mirror_test.exs` does.
  setup do
    Mix.shell(Mix.Shell.Process)

    admin = AccountsFixtures.node_admin_fixture()
    name = "task-mirror-#{System.unique_integer([:positive])}"
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
      Mix.shell(Mix.Shell.IO)
      Application.put_env(:forge, Forge.Jobs, jobs_config)
      File.rm_rf(credentials_dir)
    end)

    # `register_named/3`, not `register/2` with a fixture path: `put_mirror/5` refuses a project
    # whose repository is not at `<repos_dir>/<name>.git`.
    {:ok, project} = Projects.register_named(name, "main", admin)

    %{project: project, admin: admin}
  end

  test "setting a mirror creates it, with the node's only admin as the actor", %{project: project} do
    Mirror.run([project.name, "github", "https://github.com/x/y.git"])

    assert_received {:mix_shell, :info, ["https://github.com/x/y.git"]}
    assert [%{name: "github", url: "https://github.com/x/y.git"}] = Projects.list_mirrors(project)
  end

  test "--none removes the mirror it names", %{project: project} do
    Mirror.run([project.name, "github", "https://github.com/x/y.git"])
    assert [_mirror] = Projects.list_mirrors(project)

    Mirror.run([project.name, "github", "--none"])

    assert_received {:mix_shell, :info, ["mirror removed"]}
    assert Projects.list_mirrors(project) == []
  end

  test "a project name alone lists its mirrors", %{project: project} do
    Mirror.run([project.name, "alpha", "https://a.example/y.git"])
    Mirror.run([project.name, "zeta", "https://z.example/y.git"])

    Mirror.run([project.name])

    assert_received {:mix_shell, :info, ["alpha https://a.example/y.git"]}
    assert_received {:mix_shell, :info, ["zeta https://z.example/y.git"]}
  end

  test "a project with no mirrors says so", %{project: project} do
    Mirror.run([project.name])

    assert_received {:mix_shell, :info, ["no mirrors"]}
  end

  # The regression this guards: the previous grammar's `NAME --none` removed a project's one
  # mirror. With mirrors now plural, `NAME --none` names none of them — it must not be read as
  # "remove the only one" (there might not be one, or there might be several) and it must not be
  # silently ignored the way it was on the first cut of this rewrite, which just fell into the
  # "list" branch. It has to fail and say what to run instead.
  test "--none with no mirror named is refused, not ignored", %{project: project} do
    Mirror.run([project.name, "github", "https://github.com/x/y.git"])

    assert_raise Mix.Error, ~r/NAME MIRROR --none removes one mirror/, fn ->
      Mirror.run([project.name, "--none"])
    end

    # And nothing was removed by the refused command.
    assert [%{name: "github"}] = Projects.list_mirrors(project)
  end

  test "an unknown project is refused" do
    assert_raise Mix.Error, ~r/unknown project/, fn -> Mirror.run(["no-such-project"]) end
  end

  # `owner/1`'s rule ("resolve to the node's only admin, refuse when there is more than one") is
  # a second copy of what `Forge.Accounts.owner_for/1` already enforces for `Projects.put_mirror/5`
  # callers with no logged-in user. Covered here rather than assumed, because this copy is the one
  # nothing else exercises.
  test "more than one node admin refuses without --owner", %{project: project} do
    AccountsFixtures.node_admin_fixture()

    assert_raise Mix.Error, ~r/more than one node admin: pass --owner EMAIL/, fn ->
      Mirror.run([project.name, "github", "https://github.com/x/y.git"])
    end

    assert Projects.list_mirrors(project) == []
  end

  test "--owner records the named admin as the actor rather than the node's own", %{
    project: project,
    admin: node_admin
  } do
    other = AccountsFixtures.user_fixture()
    {:ok, _member} = Projects.put_member(project, other, :admin, node_admin)

    Mirror.run([project.name, "github", "https://github.com/x/y.git", "--owner", other.email])

    assert [%{name: "github"}] = Projects.list_mirrors(project)

    assert %{actor: actor} = last_event("project.mirror_set")
    assert actor == %{"kind" => "user", "id" => other.id}
  end

  defp last_event(type) do
    Forge.Repo.one!(
      from e in Forge.Events.Event, where: e.type == ^type, order_by: [desc: e.seq], limit: 1
    )
  end
end
