defmodule Forge.Git do
  @moduledoc """
  The platform's git operations, as thin calls to the git CLI. Repositories are bare and
  owned by the platform; jobs work in worktrees checked out from them. Every function
  returns `{:ok, value}` or `{:error, reason}` and never raises on git failures.
  """

  @type repo :: String.t()
  @type sha :: String.t()

  @doc """
  Creates a bare repository at `path` unless one exists.

  It installs no hooks. There is exactly one `pre-receive` in this product — the generated one
  in `Forge.Git.Hooks`, which `Projects.register/2` installs on the next line and `ensure_hooks/0`
  re-asserts at boot — and a second implementation here was a weaker copy of a security control:
  it checked only the ref scope, with no default-branch guard, no internal marker and no delete
  guard. Nothing served it, because registration overwrote it immediately. A hostile review
  still called it out, and rightly: two implementations of a rule is one waiting to be picked up
  by a refactor as though it were the rule.
  """
  @spec init_bare(String.t()) :: :ok | {:error, term()}
  def init_bare(path) do
    if File.exists?(Path.join(path, "HEAD")) do
      :ok
    else
      File.mkdir_p!(path)

      with {:ok, _output} <- run(path, ["init", "--bare", "--quiet"]), do: :ok
    end
  end

  @doc """
  Points an unborn `HEAD` at `branch`. A bare repository starts with `HEAD` on whatever git's
  `init.defaultBranch` was, and a clone of a repository whose `HEAD` names a branch that does
  not exist checks out nothing — which is what a worker cloning its project would get. An
  existing `HEAD` is left alone: it is the operator's to set.
  """
  @spec ensure_head(repo(), String.t()) :: :ok
  def ensure_head(repo, branch) do
    with {:ok, current} <- run(repo, ["symbolic-ref", "--quiet", "HEAD"]),
         false <-
           branch_exists?(repo, current |> String.trim() |> String.replace("refs/heads/", "")) do
      run(repo, ["symbolic-ref", "HEAD", "refs/heads/" <> branch])
    end

    :ok
  end

  @root_message """
  Empty

  Made by forge so the default branch exists. Everything else starts from it: a ticket's base
  commit, a conversation's branch, and the merge that puts work back.
  """

  @doc """
  Makes sure `branch` exists, with an empty root commit if the repository has nothing yet.

  A bare repository `git init` made has no commits, so its default branch is unborn — and
  everything the platform does starts from it. A conversation forks its branch from it, a ticket
  takes its base commit from it, and a merge fast-forwards onto it; all three fail on a repository
  that has never been written to, with an error naming a ref rather than the situation.

  Nothing can fix that from outside either: `pre-receive` lets only the platform's own merge write
  the default branch, so there is no push an operator could make to create it. The first commit
  has to be the platform's, and this is it.

  Written with `commit-tree` and `update-ref` rather than a worktree: there is nothing to check
  out, and the empty tree is a constant.
  """
  @spec ensure_initial_commit(repo(), String.t()) :: :ok | {:error, term()}
  def ensure_initial_commit(repo, branch) do
    if branch_exists?(repo, branch) do
      :ok
    else
      create_root_commit(repo, branch)
    end
  end

  defp create_root_commit(repo, branch) do
    env = [
      {"GIT_AUTHOR_NAME", "forge"},
      {"GIT_AUTHOR_EMAIL", "forge@localhost"},
      {"GIT_COMMITTER_NAME", "forge"},
      {"GIT_COMMITTER_EMAIL", "forge@localhost"}
    ]

    # `hash-object -w -t tree /dev/null` writes the empty tree and prints its id. `mktree` would
    # want it on stdin, and `run/3` has no stdin to give — nor should it grow one for this. The
    # empty tree's id is also a well-known constant, and is deliberately not hard-coded here:
    # it is only constant for SHA-1, and a repository can be SHA-256.
    with {:ok, tree} <- run(repo, ["hash-object", "-w", "-t", "tree", "/dev/null"], env: env),
         {:ok, sha} <-
           run(repo, ["commit-tree", String.trim(tree), "-m", @root_message], env: env),
         {:ok, _out} <-
           run(repo, ["update-ref", "refs/heads/" <> branch, String.trim(sha)], env: env) do
      :ok
    end
  end

  @doc "Resolves a ref to a commit sha."
  @spec resolve(repo(), String.t()) :: {:ok, sha()} | {:error, {:unknown_ref, String.t()}}
  def resolve(repo, ref) do
    case run(repo, ["rev-parse", "--verify", "--quiet", ref <> "^{commit}"]) do
      {:ok, sha} -> {:ok, String.trim(sha)}
      # The ref travels with the error: this is called with a project's default branch and
      # with a ticket's own branch, and a caller reporting the failure cannot tell which.
      {:error, _} -> {:error, {:unknown_ref, ref}}
    end
  end

  @doc "The content of `path` at `sha`."
  @spec show(repo(), sha(), String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def show(repo, sha, path) do
    case run(repo, ["show", "#{sha}:#{path}"]) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  The size in bytes of the blob at `path` in `sha`, without reading it.

  What `show/3` would return the length of, asked first: a caller that draws a bounded slice of a
  file has to be able to refuse the file before it is in memory, and `show/3` captures all of it
  (`ForgeWeb.ReviewLive`). `:not_found` where git can read no object there — a missing path, an
  unknown sha.

  **And `:not_found` for a path that is not a blob**, because the size and the content would then
  be of different things. `cat-file -s` reports the size of whatever object the path resolves to:
  a tree for a directory, and for a gitlink — a `160000` entry, which an agent can commit on its
  own branch — the *commit* it names, whose size is a hundred-odd bytes while `show/3` prints the
  commit with its whole diff. A caller that bounded a read by the first number and then took the
  second would have no bound at all, which is the trap `CLAUDE.md` § Rules describes: the guard
  has to use the same model as the operation it guards.
  """
  @spec blob_size(repo(), sha(), String.t()) :: {:ok, non_neg_integer()} | {:error, :not_found}
  def blob_size(repo, sha, path) do
    with {:ok, "blob"} <- object_type(repo, sha, path),
         {:ok, output} <- run(repo, ["cat-file", "-s", "#{sha}:#{path}"]),
         {bytes, _rest} <- Integer.parse(String.trim(output)) do
      {:ok, bytes}
    else
      _other -> {:error, :not_found}
    end
  end

  defp object_type(repo, sha, path) do
    with {:ok, output} <- run(repo, ["cat-file", "-t", "#{sha}:#{path}"]) do
      {:ok, String.trim(output)}
    end
  end

  @spec exists?(repo(), sha(), String.t()) :: boolean()
  def exists?(repo, sha, path), do: match?({:ok, _}, show(repo, sha, path))

  @doc "Creates `branch` at `sha`. Fails if the branch exists."
  @spec create_branch(repo(), String.t(), sha()) :: :ok | {:error, term()}
  def create_branch(repo, branch, sha) do
    with {:ok, _} <- run(repo, ["branch", branch, sha]) do
      :ok
    end
  end

  @spec branch_exists?(repo(), String.t()) :: boolean()
  def branch_exists?(repo, branch), do: match?({:ok, _}, resolve(repo, "refs/heads/" <> branch))

  @doc """
  Deletes `branch`. A branch that is not there is not an error — this runs after work that may
  already have removed it, and failing then would report a problem that is not one.

  `-D` rather than `-d`: the branch may not be merged, which is the caller's decision and not
  git's. What keeps a merged commit reachable afterwards is the pin under `refs/forge/*`.
  """
  @spec delete_branch(repo(), String.t()) :: :ok | {:error, term()}
  def delete_branch(repo, branch) do
    if branch_exists?(repo, branch) do
      with {:ok, _out} <- run(repo, ["branch", "-D", branch]), do: :ok
    else
      :ok
    end
  end

  @doc "Checks `branch` out into a new worktree at `dir`, which must not exist."
  @spec worktree_add(repo(), String.t(), String.t()) :: :ok | {:error, term()}
  def worktree_add(repo, dir, branch) do
    File.mkdir_p!(Path.dirname(dir))

    with {:ok, _} <- run(repo, ["worktree", "add", "--quiet", dir, branch]) do
      :ok
    end
  end

  @doc """
  Returns the existing worktree at `dir` to `branch`'s head, discarding everything that was
  not committed. Ignored files are left alone, so a build directory survives.
  """
  @spec worktree_reset(String.t(), String.t()) :: :ok | {:error, term()}
  def worktree_reset(dir, branch) do
    with {:ok, _} <- run(dir, ["reset", "--quiet", "--hard", "refs/heads/" <> branch]),
         {:ok, _} <- run(dir, ["clean", "--quiet", "-fd"]) do
      :ok
    end
  end

  @doc "Removes the worktree at `dir`, discarding uncommitted changes."
  @spec worktree_remove(repo(), String.t()) :: :ok | {:error, term()}
  def worktree_remove(repo, dir) do
    with {:ok, _} <- run(repo, ["worktree", "remove", "--force", dir]) do
      :ok
    end
  end

  # A path is printed as it is written, not with every byte outside ASCII escaped: `résumé.md`
  # and not `"r\303\251sum\303\251.md"`. Only a path with a quote, a backslash or a control
  # character in it is still quoted, the same way in the patch and in `--numstat`, and
  # `unquote/1` reads it back.
  @paths_as_written ["-c", "core.quotePath=false"]

  @doc "The diff from `base` to `head`, as a patch. `paths` narrows it to those files."
  @spec diff(repo(), sha(), String.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def diff(repo, base, head, paths \\ []) do
    args = @paths_as_written ++ ["diff", "#{base}..#{head}"]
    run(repo, if(paths == [], do: args, else: args ++ ["--"] ++ paths), stderr: :separate)
  end

  @doc """
  A path as git prints it, unquoted: git wraps one containing a quote, a backslash or a control
  character in double quotes with C escapes (`\"`, `\\`, `\t`, octal bytes), and prints any
  other as it is.
  """
  @spec unquote_path(String.t()) :: String.t()
  def unquote_path("\"" <> quoted) do
    quoted |> String.trim_trailing("\"") |> unescape(<<>>)
  end

  def unquote_path(path), do: path

  defp unescape(<<>>, acc), do: acc

  defp unescape(<<"\\", a, b, c, rest::binary>>, acc)
       when a in ?0..?3 and b in ?0..?7 and c in ?0..?7,
       do: unescape(rest, <<acc::binary, (a - ?0) * 64 + (b - ?0) * 8 + (c - ?0)>>)

  defp unescape(<<"\\", char, rest::binary>>, acc),
    do: unescape(rest, <<acc::binary, escaped(char)>>)

  defp unescape(<<char, rest::binary>>, acc), do: unescape(rest, <<acc::binary, char>>)

  defp escaped(?t), do: ?\t
  defp escaped(?n), do: ?\n
  defp escaped(?r), do: ?\r
  defp escaped(?a), do: 7
  defp escaped(?b), do: ?\b
  defp escaped(?f), do: ?\f
  defp escaped(?v), do: ?\v
  defp escaped(char), do: char

  @doc """
  Per-file line counts from `base` to `head`: `{path, added, removed}`, binary files as `:binary`.
  """
  @spec diff_stat(repo(), sha(), String.t()) ::
          {:ok, [{String.t(), non_neg_integer() | :binary, non_neg_integer() | :binary}]}
          | {:error, term()}
  def diff_stat(repo, base, head) do
    with {:ok, out} <-
           run(repo, @paths_as_written ++ ["diff", "--numstat", "#{base}..#{head}"],
             stderr: :separate
           ) do
      {:ok, out |> String.split("\n", trim: true) |> Enum.map(&numstat_line/1)}
    end
  end

  defp numstat_line(line) do
    case String.split(line, "\t", parts: 3) do
      [added, removed, path] -> {unquote_path(path), count(added), count(removed)}
      _other -> {line, :binary, :binary}
    end
  end

  defp count("-"), do: :binary
  defp count(value), do: String.to_integer(value)

  @doc """
  What is directly in `dir` at `sha`: each entry's name, its path from the repository's root and
  its kind — `:blob`, `:link` (a symbolic link, which git stores as a blob of its own mode),
  `:tree`, or `:commit` for a submodule. None when `dir` is not there.

  NUL-separated, so a name git would quote arrives as it was written.
  """
  @spec ls_dir(repo(), sha(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def ls_dir(repo, sha, dir) do
    with {:ok, out} <- run(repo, ["ls-tree", "-z", sha, "--", dir <> "/"], stderr: :separate) do
      {:ok, out |> String.split(<<0>>, trim: true) |> Enum.map(&tree_entry/1)}
    end
  end

  defp tree_entry(line) do
    [meta, path] = String.split(line, "\t", parts: 2)
    [mode, type, _object] = String.split(meta, " ")
    %{name: Path.basename(path), path: path, kind: tree_kind(mode, type)}
  end

  defp tree_kind("120000", _type), do: :link
  defp tree_kind(_mode, "tree"), do: :tree
  defp tree_kind(_mode, "commit"), do: :commit
  defp tree_kind(_mode, _blob), do: :blob

  @doc "The paths under `pathspec` that differ from `base` to `head`, unquoted."
  @spec changed_paths(repo(), sha(), sha(), [String.t()]) ::
          {:ok, [String.t()]} | {:error, term()}
  def changed_paths(repo, base, head, pathspec) do
    args = @paths_as_written ++ ["diff", "--name-only", "#{base}..#{head}", "--" | pathspec]

    with {:ok, out} <- run(repo, args, stderr: :separate) do
      {:ok, out |> String.split("\n", trim: true) |> Enum.map(&unquote_path/1)}
    end
  end

  @doc "Whether `ancestor` is reachable from `descendant`."
  @spec ancestor?(repo(), String.t(), String.t()) :: boolean()
  def ancestor?(repo, ancestor, descendant),
    do: match?({:ok, _}, run(repo, ["merge-base", "--is-ancestor", ancestor, descendant]))

  @doc """
  Points `ref` at `sha`, creating it. Used for `refs/forge/approved/<n>`, which keeps an approved
  commit reachable after the ticket branch is rewritten.
  """
  @spec pin(repo(), String.t(), sha()) :: :ok | {:error, term()}
  def pin(repo, ref, sha) do
    with {:ok, _out} <- run(repo, ["update-ref", ref, sha]), do: :ok
  end

  @doc "Commit shas on `head` since `base`, newest first."
  @spec commits_since(repo(), sha(), String.t()) :: {:ok, [sha()]} | {:error, term()}
  def commits_since(repo, base, head) do
    with {:ok, out} <- run(repo, ["rev-list", "#{base}..#{head}"]) do
      {:ok, String.split(out, "\n", trim: true)}
    end
  end

  @doc "The best common ancestor of `a` and `b`."
  @spec merge_base(repo(), String.t(), String.t()) :: {:ok, sha()} | {:error, term()}
  def merge_base(repo, a, b) do
    with {:ok, out} <- run(repo, ["merge-base", a, b]), do: {:ok, String.trim(out)}
  end

  @doc """
  The commits on `head` since `base`, newest first: sha, subject, and when each was committed.
  The same range as `commits_since/3`, with what a list of commits shows a person.
  """
  @spec log(repo(), String.t(), String.t(), keyword()) ::
          {:ok, [%{sha: sha(), subject: String.t(), at: DateTime.t()}]} | {:error, term()}
  def log(repo, base, head, opts \\ []) do
    # `first_parent: true` is the line a branch's own merges make, and not what each brought in.
    first = if Keyword.get(opts, :first_parent, false), do: ["--first-parent"], else: []

    with {:ok, out} <-
           run(repo, ["log", "--format=%H%x1f%ct%x1f%s"] ++ first ++ ["#{base}..#{head}"],
             stderr: :separate
           ) do
      {:ok, out |> String.split("\n", trim: true) |> Enum.flat_map(&log_line/1)}
    end
  end

  # A line that is not one of ours is skipped rather than raised on: the list is for reading,
  # and a page that shows it should not be the thing a surprise from git takes down.
  defp log_line(line) do
    with [sha, time, subject] <- String.split(line, "\x1f", parts: 3),
         {seconds, ""} <- Integer.parse(time),
         {:ok, at} <- DateTime.from_unix(seconds) do
      [%{sha: sha, subject: subject, at: at}]
    else
      _other -> []
    end
  end

  @doc """
  Runs git with `args` in `dir`. Public so contexts can do the odd extra call.

  Options: `:env` adds variables to the child's environment, and `:stderr` set to `:separate`
  keeps stderr out of the returned output — a hook's messages arrive there, and a caller that
  parses stdout must not have them mixed in. Separate is not discarded: on a failure the error
  carries stdout followed by stderr. (`Forge.Merge` reads a conflict's paths out of that text by
  their tab, wherever they sit, so the order is for a person reading it, and swapping it is an
  equivalent mutant.)

  **Separate used to mean inherited.** `System.cmd/3` cannot capture stderr apart from stdout,
  so stderr went to the platform's own, and a chat page reading the commits of a branch its
  close had deleted wrote `fatal: ambiguous argument 'refs/heads/main..refs/heads/chat/…'` into
  the server log on every render — eleven times for two chats in production. It is written to a
  file of its own now and read back.
  """
  @spec run(String.t(), [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, {integer(), String.t()}}
  def run(dir, args, opts \\ []) do
    env = [{"GIT_TERMINAL_PROMPT", "0"} | Keyword.get(opts, :env, [])]

    case cmd(dir, args, env, Keyword.get(opts, :stderr)) do
      {out, 0, _err} -> {:ok, out}
      {out, code, err} -> {:error, {code, out <> err}}
    end
  end

  defp cmd(dir, args, env, :separate) do
    err = Path.join(System.tmp_dir!(), "forge-git-#{System.unique_integer([:positive])}.err")

    try do
      # `$0` is the file and `"$@"` git's arguments, so nothing in them is read by the shell.
      {out, code} =
        System.cmd("sh", ["-c", ~s(exec git "$@" 2>"$0"), err | args], cd: dir, env: env)

      stderr =
        case File.read(err) do
          {:ok, text} -> text
          {:error, _reason} -> ""
        end

      {out, code, stderr}
    after
      File.rm(err)
    end
  end

  defp cmd(dir, args, env, _merged) do
    {out, code} = System.cmd("git", args, cd: dir, stderr_to_stdout: true, env: env)
    {out, code, ""}
  end
end
