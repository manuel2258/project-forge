defmodule ForgeWeb.GitLfsMirrorTest do
  @moduledoc """
  A mirror receives the LFS objects with the refs, to the mirror's own LFS endpoint and no other
  (`docs/design/git-hosting.md` § `post-receive` — the mirrors, § What a mirror URL may be). The
  destination is a second forge project on the same endpoint, as in `GitHttpTest`.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures
  import Forge.LfsFixtures

  alias Forge.Git.Tokens
  alias Forge.Projects

  setup do
    owner = Forge.AccountsFixtures.user_fixture()
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

    # The hook finds its credential file from its own directory, so the repository has to sit at
    # `<repos_dir>/<name>.git` as a registered one does (`GitHttpTest` explains it at length).
    name = "src#{System.unique_integer([:positive])}"
    bare = Path.join(Projects.repos_dir(), name <> ".git")
    File.mkdir_p!(Path.dirname(bare))
    File.rename!(seeded_repo(), bare)
    {:ok, project} = register_owned!(%{name: name, repo_path: bare, default_branch: "main"})
    join!(project, owner, :admin)

    destination_bare = mirror_target(bare)

    {:ok, destination} =
      register_owned!(%{
        name: "dest#{System.unique_integer([:positive])}",
        repo_path: destination_bare,
        default_branch: "main"
      })

    {:ok, token, _row} = Tokens.issue(destination, name: "t", ref: "refs/heads/main")
    url = platform_git_url(destination.name)
    :ok = Projects.put_mirror(project, owner, "backup", url, user: "forge", token: token)

    %{
      owner: owner,
      token: token,
      url: url,
      project: project,
      bare: bare,
      destination: destination,
      destination_bare: destination_bare
    }
  end

  defp mirror(c), do: Projects.list_mirrors(c.project) |> Enum.find(&(&1.name == "backup"))

  test "the destination receives the objects with the refs, and the mirror reads as working", c do
    sha = push_pointers_to(c.bare, "main", %{"sound.bin" => "THE REAL SOUND"})

    assert Forge.Git.Lfs.held?(c.destination_bare, oid("THE REAL SOUND"))

    assert File.read!(elem(Forge.Git.Lfs.path(c.destination_bare, oid("THE REAL SOUND")), 1)) ==
             "THE REAL SOUND"

    assert {:ok, ^sha} = Forge.Git.resolve(c.destination_bare, "refs/heads/main")
    assert %{last_status: "ok", last_error: nil} = mirror(c)
  end

  test "a mirror that refuses the objects still gets the refs, and says the objects failed", c do
    # The destination's own guard is wrapped permissive, so that its refs can land without objects,
    # and its limit is small, so that the object is refused.
    File.write!(Path.join([c.destination_bare, "hooks", "pre-receive"]), "#!/bin/sh\nexit 0\n")
    config = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(config, :lfs_max_object_bytes, 10))
    on_exit(fn -> Application.put_env(:forge, Forge.Jobs, config) end)

    sha = push_pointers_to(c.bare, "main", %{"sound.bin" => "THE REAL SOUND, TOO BIG"})

    assert {:ok, ^sha} = Forge.Git.resolve(c.destination_bare, "refs/heads/main")
    refute Forge.Git.Lfs.held?(c.destination_bare, oid("THE REAL SOUND, TOO BIG"))
    assert %{last_status: "failed", last_error: "LFS objects failed:" <> _} = mirror(c)
    assert mirror(c).last_error =~ "at most 10 bytes"
  end

  test "a .lfsconfig in the repository cannot send the objects anywhere else", c do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    parent = self()

    Task.start(fn ->
      case :gen_tcp.accept(listener, 20_000) do
        {:ok, socket} ->
          send(parent, :dialled)
          :gen_tcp.close(socket)

        {:error, _reason} ->
          :ok
      end
    end)

    elsewhere = "http://127.0.0.1:#{port}/stolen/info/lfs"

    push_commit_to(c.bare, "main", %{
      ".lfsconfig" => "[lfs]\n\turl = #{elsewhere}\n\tpushurl = #{elsewhere}\n"
    })

    push_pointers_to(c.bare, "main", %{"sound.bin" => "THE REAL SOUND"})

    refute_receive :dialled, 500
    assert Forge.Git.Lfs.held?(c.destination_bare, oid("THE REAL SOUND"))
    assert %{last_status: "ok"} = mirror(c)
    :gen_tcp.close(listener)
  end

  test "a mirror URL without .git still reaches its LFS endpoint, derived as git-lfs derives it",
       c do
    # Where a GitHub mirror is usually written. The refs go to `/git/<name>`, which this platform does
    # not serve, so they fail; the objects go to `/git/<name>.git/info/lfs`, which it does.
    :ok = Forge.Git.Hooks.delete_mirror(Projects.repo_path(c.project), "backup")
    bare_url = String.replace_suffix(c.url, ".git", "")

    :ok =
      Projects.put_mirror(c.project, c.owner, "nogit", bare_url, user: "forge", token: c.token)

    push_pointers_to(c.bare, "main", %{"sound.bin" => "THE REAL SOUND"})

    assert Forge.Git.Lfs.held?(c.destination_bare, oid("THE REAL SOUND"))
  end

  test "a migrated URL with credentials in it is never echoed into the stored error", c do
    # `Projects.put_mirror/5` refuses userinfo, but a mirror migrated from the old scalar can carry it
    # (`Forge.Git.Hooks.list_mirrors/1`), and a failing push may echo the URL it was given. git-lfs
    # 3.7.1 prints nothing of it with the flags the hook gives it, so this holds the line and cannot
    # tell the hook's `redact` from that (the hook says so).
    repo = Projects.repo_path(c.project)
    :ok = Forge.Git.Hooks.delete_mirror(repo, "backup")
    :ok = Forge.Git.Hooks.put_mirror(repo, "old", "http://user:SECRETTOKEN@127.0.0.1:1/x.git", [])

    push_pointers_to(c.bare, "main", %{"sound.bin" => "THE REAL SOUND"})

    assert %{last_status: "failed", last_error: error} =
             Enum.find(Forge.Git.Hooks.list_mirrors(repo), &(&1.name == "old"))

    assert error =~ "LFS objects failed:"
    refute error =~ "SECRETTOKEN"
  end

  test "a repository with no LFS objects is pushed as before, with no LFS push", c do
    push_commit_to(c.bare, "main", %{"README.md" => "plain\n"})

    assert %{last_status: "ok"} = mirror(c)
    refute File.exists?(Path.join(c.destination_bare, "lfs"))
  end
end
