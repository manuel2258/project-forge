defmodule Forge.GitLfsSweepTest do
  @moduledoc """
  The daily deletion of LFS objects nothing uses (`docs/design/git-hosting.md` § Git LFS, *Deleting
  an object nothing uses*). The clock is injected, and an object's own clock is set with
  `File.touch/2`, so no test waits.
  """

  use Forge.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Forge.ForgeFixtures
  import Forge.GitFixtures, only: [commit_to: 4, seeded_repo: 0]
  import Forge.LfsFixtures

  alias Forge.Events.Event
  alias Forge.Git
  alias Forge.Git.Lfs
  alias Forge.Git.Lfs.Sweeper
  alias Forge.Projects

  @day 86_400
  @t0 ~U[2027-01-01 00:00:00Z]

  setup do
    bare = seeded_repo()
    name = "sweep#{System.unique_integer([:positive])}"
    {:ok, project} = register_owned!(%{name: name, repo_path: bare, default_branch: "main"})
    %{project: project, bare: bare}
  end

  defp at(days), do: DateTime.add(@t0, days * @day, :second)
  defp posix(days), do: DateTime.to_unix(at(days))

  defp path(bare, oid), do: elem(Lfs.path(bare, oid), 1)

  # Sets the object's own clock, and checks that it took: a `touch` that silently did nothing
  # would leave every test below passing on today's date.
  defp stamp!(bare, oid, days) do
    File.touch!(path(bare, oid), posix(days))
    assert File.stat!(path(bare, oid), time: :posix).mtime == posix(days)
  end

  defp deleted_events, do: Repo.all(from e in Event, where: e.type == "git.lfs.deleted")

  # One object each, and what names it: the tip of a branch; an earlier commit of a live branch's
  # history (`ticket/5` dropped the file again); a tag; a ref of forge's own (`refs/forge/merged/9`,
  # after `main` was put back off it); and nothing. Every object is a hundred days old by its own
  # clock.
  defp populate(c) do
    {:ok, base} = Git.resolve(c.bare, "refs/heads/main")
    tip = commit_pointers_to(c.bare, "main", %{"tip.bin" => "in the tip"})
    {:ok, _} = Git.run(c.bare, ["update-ref", "refs/forge/approved/1", tip])

    :ok = Git.create_branch(c.bare, "ticket/5", base)
    commit_pointers_to(c.bare, "ticket/5", %{"old.bin" => "in a branch's history only"})
    commit_to(c.bare, "ticket/5", %{"old.bin" => nil}, "drop it again")

    tagged = commit_pointers_to(c.bare, "main", %{"tag.bin" => "in a tag"})
    {:ok, _} = Git.run(c.bare, ["tag", "v2", tagged])

    held = commit_pointers_to(c.bare, "main", %{"held.bin" => "a forge ref only"})
    {:ok, _} = Git.run(c.bare, ["update-ref", "refs/forge/merged/9", held])
    {:ok, _} = Git.run(c.bare, ["update-ref", "refs/heads/main", tip])

    used =
      for content <- ["in the tip", "in a branch's history only", "in a tag", "a forge ref only"],
          do: oid(content)

    unused = store!(c.bare, "nothing names this")
    for oid <- used ++ [unused], do: stamp!(c.bare, oid, -100)
    {used, unused}
  end

  test "an object any ref names, anywhere in its history, is never deleted; one nothing names is, after 30 days",
       c do
    {used, unused} = populate(c)
    {:ok, before} = Git.run(c.bare, ["count-objects", "-v"])

    # The first run has no record: it records what is unused as unused from now, and deletes nothing
    # however old the objects are.
    assert {:ok, %{deleted: 0}} = Lfs.sweep(c.project, at(0))
    assert File.exists?(path(c.bare, unused))
    assert File.exists?(Path.join([c.bare, "lfs", "forge", "sweep"]))
    assert deleted_events() == []

    assert {:ok, %{deleted: 0}} = Lfs.sweep(c.project, at(29))
    assert File.exists?(path(c.bare, unused))

    assert {:ok, %{deleted: 1, bytes: 18}} = Lfs.sweep(c.project, at(30))
    refute File.exists?(path(c.bare, unused))
    assert Enum.all?(used, &Lfs.held?(c.bare, &1))

    # A run that deletes nothing records nothing; the one that deleted records one event.
    assert {:ok, %{deleted: 0}} = Lfs.sweep(c.project, at(60))

    assert [%{payload: %{"objects" => 1, "bytes" => 18, "project" => name}} = event] =
             deleted_events()

    assert name == c.project.name
    assert Forge.Events.summary(event) == "deleted 1 LFS object(s) nothing used, 18 bytes"

    # Only LFS objects: the repository's own git objects are not touched.
    assert {:ok, ^before} = Git.run(c.bare, ["count-objects", "-v"])
  end

  test "an object nothing named since upload is counted from its own clock, never from the record",
       c do
    filler = store!(c.bare, "already there, so the first run writes a record")
    stamp!(c.bare, filler, 25)
    assert {:ok, _} = Lfs.sweep(c.project, at(0))
    new = store!(c.bare, "uploaded on day one")
    stamp!(c.bare, new, 1)

    assert {:ok, %{deleted: 0}} = Lfs.sweep(c.project, at(30))
    assert Lfs.held?(c.bare, new)
    assert {:ok, %{deleted: 1}} = Lfs.sweep(c.project, at(31))
    refute Lfs.held?(c.bare, new)
  end

  test "a batch naming the object, or a push checking it, restarts its clock", c do
    unused = store!(c.bare, "nothing names this")
    stamp!(c.bare, unused, -100)
    assert {:ok, %{deleted: 0}} = Lfs.sweep(c.project, at(0))

    # Both touch the object's file, which is the whole of clock A.
    stamp!(c.bare, unused, 29)
    assert {:ok, %{deleted: 0}} = Lfs.sweep(c.project, at(30))
    assert {:ok, %{deleted: 0}} = Lfs.sweep(c.project, at(58))
    assert {:ok, %{deleted: 1}} = Lfs.sweep(c.project, at(59))
  end

  test "an object in use again loses its record, and its 30 days start afresh", c do
    sha = commit_pointers_to(c.bare, "main", %{"x.bin" => "comes and goes"})
    oid = oid("comes and goes")
    stamp!(c.bare, oid, -100)
    {:ok, _} = Git.run(c.bare, ["update-ref", "refs/heads/ticket/9", sha])
    {:ok, _} = Git.run(c.bare, ["update-ref", "-d", "refs/heads/main"])

    # Unused as of day 0 ...
    {:ok, _} = Git.run(c.bare, ["update-ref", "-d", "refs/heads/ticket/9"])
    assert {:ok, %{deleted: 0}} = Lfs.sweep(c.project, at(0))
    # ... in use again on day 10 ...
    {:ok, _} = Git.run(c.bare, ["update-ref", "refs/heads/ticket/9", sha])
    assert {:ok, %{deleted: 0}} = Lfs.sweep(c.project, at(10))
    # ... and unused from day 20, so day 30 is not its day.
    {:ok, _} = Git.run(c.bare, ["update-ref", "-d", "refs/heads/ticket/9"])
    assert {:ok, %{deleted: 0}} = Lfs.sweep(c.project, at(20))
    assert {:ok, %{deleted: 0}} = Lfs.sweep(c.project, at(30))
    assert {:ok, %{deleted: 0}} = Lfs.sweep(c.project, at(49))
    assert {:ok, %{deleted: 1}} = Lfs.sweep(c.project, at(50))
  end

  test "when git cannot say what is in use, nothing is deleted", c do
    unused = store!(c.bare, "nothing names this")
    stamp!(c.bare, unused, -100)
    assert {:ok, %{deleted: 0}} = Lfs.sweep(c.project, at(0))

    # A ref at an object that is not there.
    File.write!(
      Path.join([c.bare, "refs", "heads", "dangling"]),
      String.duplicate("1", 40) <> "\n"
    )

    assert {:error, _reason} = Lfs.in_use(c.bare)
    assert {:error, _reason} = Lfs.sweep(c.project, at(100))
    assert Lfs.held?(c.bare, unused)
  end

  test "a lost record is the safe reading: nothing is deleted until it has been rebuilt and aged",
       c do
    unused = store!(c.bare, "nothing names this")
    stamp!(c.bare, unused, -100)
    assert {:ok, %{deleted: 0}} = Lfs.sweep(c.project, at(0))
    File.rm!(Path.join([c.bare, "lfs", "forge", "sweep"]))

    assert {:ok, %{deleted: 0}} = Lfs.sweep(c.project, at(40))
    assert {:ok, %{deleted: 1}} = Lfs.sweep(c.project, at(70))
  end

  test "a repository with no LFS directory gets no files", c do
    assert {:ok, %{deleted: 0, bytes: 0}} = Lfs.sweep(c.project, at(0))
    refute File.exists?(Path.join(c.bare, "lfs"))
    refute Lfs.due?(c.bare, at(0))
  end

  test "a deletion waits for a push check in progress, and an object that check touched survives",
       c do
    unused = store!(c.bare, "nothing names this")
    stamp!(c.bare, unused, -100)
    assert {:ok, %{deleted: 0}} = Lfs.sweep(c.project, at(0))
    parent = self()

    check =
      Task.async(fn ->
        Lfs.with_lock(c.bare, :shared, fn ->
          send(parent, :checking)
          receive do: (:go -> File.touch!(path(c.bare, unused), posix(31)))
        end)
      end)

    assert_receive :checking, 5_000
    sweep = Task.async(fn -> Lfs.sweep(c.project, at(31)) end)
    assert Task.yield(sweep, 500) == nil
    assert Lfs.held?(c.bare, unused)

    send(check.pid, :go)
    assert {:ok, %{deleted: 0}} = Task.await(sweep)
    assert Lfs.held?(c.bare, unused)
  end

  test "abandoned uploads in the incoming directory are removed after a day", c do
    store!(c.bare, "anything")
    dir = Lfs.incoming_dir(c.bare)
    File.mkdir_p!(dir)
    old = Path.join(dir, "old")
    fresh = Path.join(dir, "fresh")
    File.write!(old, "x")
    File.write!(fresh, "x")
    File.touch!(old, posix(-2))
    File.touch!(fresh, posix(0))

    assert {:ok, _} = Lfs.sweep(c.project, at(0))
    refute File.exists?(old)
    assert File.exists?(fresh)
  end

  test "the sweeper runs a repository once a day, and only one that holds objects", c do
    store!(c.bare, "anything")
    other = seeded_repo()

    {:ok, _bare_less} =
      register_owned!(%{
        name: "bare#{System.unique_integer([:positive])}",
        repo_path: other,
        default_branch: "main"
      })

    assert Sweeper.run(at(0)) == 1
    assert Sweeper.run(at(0)) == 0
    assert Sweeper.run(DateTime.add(at(0), 23 * 3600, :second)) == 0
    assert Sweeper.run(DateTime.add(at(0), 24 * 3600, :second)) == 1
    assert Projects.repo_path(c.project) == Path.expand(c.bare)
  end
end
