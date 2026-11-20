defmodule Forge.LfsFixtures do
  @moduledoc """
  Git LFS for tests, built at runtime: **never commit a `.gitattributes` naming `filter=lfs`, or a
  valid pointer at such a path, to forge's own tree** — forge is hosted on forge, and the push guard
  would hold the next push to it.

  Two kinds of helper. The first writes an object straight into a repository's `lfs/objects`
  (`store!/2`), which is what a test of the pages, the sweep or the mirror wants; the second drives
  a stock `git lfs` client, with a `HOME` of its own so that nothing of the machine's is read.
  """

  alias Forge.Git
  alias Forge.GitFixtures

  def oid(content), do: Base.encode16(:crypto.hash(:sha256, content), case: :lower)

  def pointer(content),
    do:
      "version https://git-lfs.github.com/spec/v1\noid sha256:#{oid(content)}\nsize #{byte_size(content)}\n"

  @doc "A pointer's text for an object `oid` of `size` bytes, whatever the object is."
  def pointer_text(oid, size),
    do: "version https://git-lfs.github.com/spec/v1\noid sha256:#{oid}\nsize #{size}\n"

  @doc """
  Commits pointers whose declared sizes are not the objects' own (`%{path => {content, size}}`): an
  object of a few bytes held for a file the pages draw as megabytes. The object is stored, so the
  repository's own guard admits the push.
  """
  def commit_sized_pointers_to(repo, branch, files, message \\ "lfs") do
    pointers =
      for {path, {content, size}} <- files, into: %{} do
        store!(repo, content)
        {path, pointer_text(oid(content), size)}
      end

    GitFixtures.commit_to(
      repo,
      branch,
      Map.put(pointers, ".gitattributes", attributes()),
      message
    )
  end

  def attributes(pattern \\ "*.bin"), do: "#{pattern} filter=lfs diff=lfs merge=lfs -text\n"

  @doc "Writes `content` into the repository's LFS directory as git-lfs would; the oid."
  def store!(repo, content) do
    oid = oid(content)
    {:ok, path} = Forge.Git.Lfs.path(repo, oid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    oid
  end

  @doc """
  Commits `files` (`%{path => content}`) to `branch` of `repo` as pointers, storing each object and
  adding `.gitattributes` for `*.bin`: what the pages read, with no LFS client involved.
  """
  def commit_pointers_to(repo, branch, files, message \\ "lfs") do
    pointers =
      for {path, content} <- files, into: %{} do
        store!(repo, content)
        {path, pointer(content)}
      end

    GitFixtures.commit_to(
      repo,
      branch,
      Map.put(pointers, ".gitattributes", attributes()),
      message
    )
  end

  @doc "A directory to use as a client's `HOME`, with git-lfs installed in its global config."
  def home do
    home = GitFixtures.tmp_dir("lfs-home")

    {_out, 0} =
      System.cmd("git", ["lfs", "install", "--skip-repo"],
        env: [{"HOME", home}],
        stderr_to_stdout: true
      )

    home
  end

  @doc "A stock git, under `home`, with prompting off."
  def git(dir, home, args, env \\ []) do
    System.cmd("git", args,
      cd: dir,
      stderr_to_stdout: true,
      env: [{"HOME", home}, {"GIT_TERMINAL_PROMPT", "0"}, {"GIT_CONFIG_NOSYSTEM", "1"} | env]
    )
  end

  @doc "Clones `url` (`branch`) with git-lfs on, setting an identity; the directory."
  def clone!(url, home, branch, env \\ []) do
    parent = GitFixtures.tmp_dir("lfs-clone")
    dir = Path.join(parent, "clone")
    {out, 0} = git(parent, home, ["clone", "--quiet", "--branch", branch, url, dir], env)
    _ = out
    {:ok, _} = Git.run(dir, ["config", "user.name", "test"])
    {:ok, _} = Git.run(dir, ["config", "user.email", "t@forge"])
    dir
  end

  @doc "Commits `path` with `content` as an LFS file (`*.bin` tracked); the new head and the oid."
  def commit_lfs!(dir, home, path, content) do
    attributes = Path.join(dir, ".gitattributes")
    if not File.exists?(attributes), do: File.write!(attributes, attributes())
    File.mkdir_p!(Path.dirname(Path.join(dir, path)))
    File.write!(Path.join(dir, path), content)
    {_, 0} = git(dir, home, ["add", "-A"])
    {_, 0} = git(dir, home, ["commit", "--quiet", "-m", "lfs #{path}"])
    {sha, 0} = git(dir, home, ["rev-parse", "HEAD"])
    {String.trim(sha), oid(content)}
  end
end
