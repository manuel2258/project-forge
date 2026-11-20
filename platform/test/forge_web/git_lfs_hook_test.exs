defmodule ForgeWeb.GitLfsHookTest do
  @moduledoc """
  `pre-receive`'s Git LFS rule: a branch a push leaves behind must not point at an LFS object
  forge does not hold (`docs/design/git-hosting.md` § Git LFS, *Verification at a push*).

  The client pushes with `GIT_LFS_SKIP_PUSH=1`, so its `pre-push` hook uploads nothing and the
  objects are missing on purpose.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures, only: [seeded_repo: 0, commit_to: 3]
  import Forge.LfsFixtures

  alias Forge.Git
  alias Forge.Git.{Lfs, Tokens, Url}

  @skip [{"GIT_LFS_SKIP_PUSH", "1"}]

  setup do
    bare = seeded_repo()
    name = "hook#{System.unique_integer([:positive])}"
    {:ok, project} = register_owned!(%{name: name, repo_path: bare, default_branch: "main"})
    {:ok, main} = Git.resolve(bare, "refs/heads/main")
    :ok = Git.create_branch(bare, "ticket/1", main)
    {:ok, secret, _row} = Tokens.issue(project, name: "t", ref: "refs/heads/ticket/1")
    home = home()
    dir = clone!(Url.with_token(project, secret), home, "ticket/1")
    %{project: project, bare: bare, secret: secret, home: home, dir: dir}
  end

  defp push(c, env \\ @skip, flags \\ []) do
    git(
      c.dir,
      c.home,
      flags ++
        ["push", "--quiet", Url.with_token(c.project, c.secret), "HEAD:refs/heads/ticket/1"],
      env
    )
  end

  defp head(c), do: Git.resolve(c.bare, "refs/heads/ticket/1")

  test "a push naming an object forge does not hold is refused, and writes nothing", c do
    {_sha, oid} = commit_lfs!(c.dir, c.home, "audio/sound.bin", "BYTES")
    {:ok, before} = head(c)

    assert {out, code} = push(c)
    assert code != 0
    assert out =~ "audio/sound.bin"
    assert out =~ String.slice(oid, 0, 10)
    assert out =~ "git lfs push --all"
    refute out =~ oid
    assert {:ok, ^before} = head(c)
  end

  test "once the object is uploaded the same push is accepted", c do
    {sha, _oid} = commit_lfs!(c.dir, c.home, "sound.bin", "BYTES")

    assert {_out, 0} = push(c, [])
    assert {:ok, ^sha} = head(c)
  end

  test "a clean tip over a history that names a missing object is accepted", c do
    commit_lfs!(c.dir, c.home, "sound.bin", "BYTES")
    {_, 0} = git(c.dir, c.home, ["rm", "-q", "sound.bin"])
    {_, 0} = git(c.dir, c.home, ["commit", "-q", "-m", "drop it"])
    {:ok, tip} = Git.run(c.dir, ["rev-parse", "HEAD"])

    assert {_out, 0} = push(c)
    assert {:ok, String.trim(tip)} == head(c)
  end

  test "a valid pointer at a path that is not an LFS path is never refused", c do
    # A test fixture, say: the pointer text of an object nobody holds, in a file the repository's
    # attributes do not send through the filter.
    File.write!(Path.join(c.dir, ".gitattributes"), attributes())
    File.write!(Path.join(c.dir, "fixture.txt"), pointer("nobody holds this"))
    {_, 0} = git(c.dir, c.home, ["add", "-A"])
    {_, 0} = git(c.dir, c.home, ["commit", "-q", "-m", "a fixture"])

    assert {_out, 0} = push(c)
  end

  test "paths are printed as plain text, cut, and the list stops at thirty", c do
    long = String.duplicate("d", 150) <> ".bin"
    names = ["a\tb\a\nc.bin", "esc\e[31mred.bin", long | for(n <- 1..33, do: "f#{n}.bin")]
    for name <- names, do: commit_lfs!(c.dir, c.home, name, "content of " <> name)

    assert {out, code} = push(c, @skip, ["-c", "sideband.allowControlCharacters=true"])
    assert code != 0

    lines = for line <- String.split(out, "\n"), line =~ ~r/\(([0-9a-f]{10})\)/, do: line
    assert length(lines) == 30
    assert out =~ "and 6 more"
    # No control character reaches the terminal from a path: the tab, the bell, the newline and
    # the escape are gone, and the rest of the name is what is printed.
    assert out =~ "abc.bin"
    assert out =~ "esc[31mred.bin"
    refute out =~ "\e[31m"
    refute out =~ "\a"
    refute out =~ String.duplicate("d", 121)
    assert out =~ String.duplicate("d", 120) <> " ("
  end

  test "an object two files share is named once", c do
    commit_lfs!(c.dir, c.home, "one.bin", "the same bytes")
    commit_lfs!(c.dir, c.home, "two.bin", "the same bytes")

    assert {out, code} = push(c)
    assert code != 0
    assert out =~ "names 1 LFS object(s)"
    assert length(Regex.scan(~r/\([0-9a-f]{10}\)/, out)) == 1
  end

  # Added with the filter off, so that the bytes committed are the bytes written.
  defp commit_raw!(c, files, mode \\ nil) do
    for {path, content} <- files do
      File.write!(Path.join(c.dir, path), content)
      if mode, do: File.chmod!(Path.join(c.dir, path), mode)
    end

    off = [
      "-c",
      "filter.lfs.clean=",
      "-c",
      "filter.lfs.process=",
      "-c",
      "filter.lfs.required=false"
    ]

    {_, 0} = git(c.dir, c.home, off ++ ["add", "-A"])
    {_, 0} = git(c.dir, c.home, ["commit", "-q", "-m", "raw"])
  end

  for locale <- ["C", "C.utf8"], {kind, content} <- [nul: :nul, accent: :accent] do
    # **A plain file at an LFS path, ahead of a pointer in tree order, must not hide it.** A small
    # image committed before `git lfs track` is exactly this. Read by character count, or with its NULs
    # dropped, it threw the reader off and the pointer after it was never looked up.
    test "a plain file with #{kind} bytes at an LFS path does not hide the pointer after it (#{locale})",
         c do
      previous = System.get_env("LC_ALL")
      System.put_env("LC_ALL", unquote(locale))

      on_exit(fn ->
        if previous, do: System.put_env("LC_ALL", previous), else: System.delete_env("LC_ALL")
      end)

      plain =
        case unquote(content) do
          :nul -> <<0, 1, 2>> <> String.duplicate("x", 197)
          :accent -> String.duplicate("é", 100)
        end

      File.write!(Path.join(c.dir, ".gitattributes"), attributes())
      commit_raw!(c, %{"a.bin" => plain, "b.bin" => pointer("never uploaded")})

      assert {out, code} = push(c)
      assert code != 0
      assert out =~ "b.bin"
    end
  end

  test "every shape of pointer git-lfs knows is held to the rule", c do
    oid = fn name -> oid(name) end
    line = fn v, name -> "version #{v}\noid sha256:#{oid.(name)}\nsize 9\n" end

    File.write!(Path.join(c.dir, ".gitattributes"), attributes())

    commit_raw!(c, %{
      "hawser.bin" => line.("https://hawser.github.com/spec/v1", "hawser"),
      "media.bin" => line.("http://git-media.io/v/2", "media"),
      "crlf.bin" =>
        String.replace(line.("https://git-lfs.github.com/spec/v1", "crlf"), "\n", "\r\n")
    })

    # A file the executable bit is set on is a regular file all the same.
    commit_raw!(c, %{"exec.bin" => line.("https://git-lfs.github.com/spec/v1", "exec")}, 0o755)

    assert {out, code} = push(c)
    assert code != 0

    for path <- ["hawser.bin", "media.bin", "crlf.bin", "exec.bin"],
        do: assert(out =~ path, "#{path} was not refused: #{out}")
  end

  test "the platform's own pushes are held to it too", c do
    {:ok, before} = head(c)

    assert_raise MatchError, fn ->
      commit_to(c.bare, "ticket/1", %{
        ".gitattributes" => attributes(),
        "x.bin" => pointer("gone")
      })
    end

    assert {:ok, ^before} = head(c)
  end

  test "an object the push checks is touched, so a deletion run does not take it", c do
    oid = store!(c.bare, "BYTES")
    {:ok, path} = Lfs.path(c.bare, oid)
    File.touch!(path, 1_000_000)
    commit_lfs!(c.dir, c.home, "sound.bin", "BYTES")

    assert {_out, 0} = push(c)
    assert File.stat!(path, time: :posix).mtime > 1_000_000
  end

  test "a push waits for a deletion run's exclusive lock", c do
    store!(c.bare, "BYTES")
    commit_lfs!(c.dir, c.home, "sound.bin", "BYTES")
    parent = self()

    run =
      Task.async(fn ->
        Lfs.with_lock(c.bare, :exclusive, fn ->
          send(parent, :holding)
          receive do: (:release -> :released)
        end)
      end)

    assert_receive :holding, 5_000
    waiting = Task.async(fn -> push(c) end)
    assert Task.yield(waiting, 1_500) == nil

    send(run.pid, :release)
    assert Task.await(run) == :released
    assert {_out, 0} = Task.await(waiting, 30_000)
  end

  test "a repository that uses no LFS pushes with git-lfs absent, and gets no lfs directory", c do
    path = System.get_env("PATH")
    without = path |> String.split(":") |> Enum.reject(&File.exists?(Path.join(&1, "git-lfs")))
    refute without == String.split(path, ":")
    System.put_env("PATH", Enum.join(without, ":"))
    on_exit(fn -> System.put_env("PATH", path) end)

    File.write!(Path.join(c.dir, "plain.txt"), "plain\n")
    {_, 0} = git(c.dir, c.home, ["add", "-A"])
    {_, 0} = git(c.dir, c.home, ["commit", "-q", "-m", "plain"])

    assert {_out, 0} = push(c, [])
    refute File.exists?(Path.join(c.bare, "lfs"))
  end
end
