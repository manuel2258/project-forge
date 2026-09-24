defmodule Forge.GitCredentialsTest do
  @moduledoc """
  The credential a mirror pushes with. `docs/design/git-hosting.md` § The credential.

  It lives outside the repositories tree on purpose: the bare repositories are the thing that
  gets backed up and mirrored, and a token in `repos/<project>.git/config` is a token in every
  backup of it.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures

  alias Forge.Git.Credentials

  setup do
    project = project_fixture()
    on_exit(fn -> File.rm_rf(Credentials.dir()) end)
    %{project: project}
  end

  test "is written outside the repositories tree", %{project: project} do
    :ok = Credentials.put(project, "github", "forge-bot", "tok", "https://github.com/x/y.git")

    refute String.starts_with?(Credentials.path(project, "github"), Forge.Projects.repos_dir())
  end

  test "is in git's store format, keyed by the host it is for", %{project: project} do
    :ok = Credentials.put(project, "github", "forge-bot", "tok", "https://github.com/x/y.git")

    assert File.read!(Credentials.path(project, "github")) ==
             "https://forge-bot:tok@github.com\n"
  end

  # A non-default port is part of the key git matches on, so it has to be in the line.
  test "carries a non-default port", %{project: project} do
    :ok = Credentials.put(project, "local", "forge", "tok", "http://127.0.0.1:4002/git/y.git")

    assert File.read!(Credentials.path(project, "local")) == "http://forge:tok@127.0.0.1:4002\n"
  end

  # The file is the secret. A mode that let anything else read it would make the move pointless.
  test "is readable by nobody else", %{project: project} do
    :ok = Credentials.put(project, "github", "forge-bot", "tok", "https://github.com/x/y.git")

    assert {:ok, %File.Stat{mode: mode}} = File.stat(Credentials.path(project, "github"))
    assert Bitwise.band(mode, 0o077) == 0
  end

  # The directory is the container for the secrets. A mode that let anything else traverse it
  # would let them list which projects and mirrors have credentials, even if the files are unreadable.
  test "directory is traversable by nobody else", %{project: project} do
    :ok = Credentials.put(project, "github", "forge-bot", "tok", "https://github.com/x/y.git")

    assert {:ok, %File.Stat{mode: mode}} = File.stat(Credentials.dir())
    assert Bitwise.band(mode, 0o077) == 0
  end

  # A public mirror needs no credential, and an absent token must not write an empty one:
  # git would answer the prompt with nothing and the failure would be a confusing 401.
  test "no token writes no file", %{project: project} do
    :ok = Credentials.put(project, "public", nil, nil, "https://github.com/x/y.git")

    refute File.exists?(Credentials.path(project, "public"))
  end

  test "a token with no username gets one, because the format needs it", %{project: project} do
    :ok = Credentials.put(project, "github", nil, "tok", "https://github.com/x/y.git")

    assert File.read!(Credentials.path(project, "github")) == "https://forge:tok@github.com\n"
  end

  test "a token with punctuation survives the round trip", %{project: project} do
    :ok = Credentials.put(project, "github", "a b", "p@ss:w/rd", "https://github.com/x/y.git")

    assert File.read!(Credentials.path(project, "github")) ==
             "https://a%20b:p%40ss%3Aw%2Frd@github.com\n"
  end

  test "removing the token removes the file", %{project: project} do
    :ok = Credentials.put(project, "github", "forge-bot", "tok", "https://github.com/x/y.git")
    :ok = Credentials.put(project, "github", "forge-bot", nil, "https://github.com/x/y.git")

    refute File.exists?(Credentials.path(project, "github"))
  end

  # Project names and mirror names both allow hyphens, so a flat `<project>-<mirror>` filename is
  # ambiguous: project `a` with mirror `b-c` and project `a-b` with mirror `c` are the same
  # string. That is not a naming nicety — the store is keyed by host, so one project's push would
  # be handed the other's token. A per-project subdirectory is unambiguous by construction,
  # because neither a project name nor a mirror name may contain `/`.
  test "two projects whose names and mirrors run together keep separate credentials" do
    n = System.unique_integer([:positive])
    one = project_fixture(%{name: "collide-#{n}"})
    two = project_fixture(%{name: "collide-#{n}-b"})

    :ok = Credentials.put(one, "b-c", "one", "tok-one", "https://github.com/x/y.git")
    :ok = Credentials.put(two, "c", "two", "tok-two", "https://github.com/x/y.git")

    assert File.read!(Credentials.path(one, "b-c")) == "https://one:tok-one@github.com\n"
    assert File.read!(Credentials.path(two, "c")) == "https://two:tok-two@github.com\n"
  end

  # The same collision through `delete/2`: removing one project's mirror must not remove the
  # credential of a differently-named project whose name and mirror concatenate to the same
  # string.
  test "deleting one project's mirror leaves the other project's credential" do
    n = System.unique_integer([:positive])
    one = project_fixture(%{name: "collide-#{n}"})
    two = project_fixture(%{name: "collide-#{n}-b"})

    :ok = Credentials.put(one, "b-c", "one", "tok-one", "https://github.com/x/y.git")
    :ok = Credentials.put(two, "c", "two", "tok-two", "https://github.com/x/y.git")
    :ok = Credentials.delete(two, "c")

    assert File.exists?(Credentials.path(one, "b-c"))
    refute File.exists?(Credentials.path(two, "c"))
  end

  test "delete/2 is fine with a mirror that never had one", %{project: project} do
    assert :ok = Credentials.delete(project, "never")
  end
end
