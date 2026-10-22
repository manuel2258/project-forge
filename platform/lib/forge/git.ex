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
      run(repo, ["symbolic-ref", "HEAD", {:data, "refs/heads/" <> branch}])
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

    with {:ok, tree} <- empty_tree(repo, write: true),
         {:ok, sha} <- run(repo, ["commit-tree", {:data, tree}, "-m", @root_message], env: env),
         {:ok, _out} <-
           run(repo, ["update-ref", {:data, "refs/heads/" <> branch}, {:data, String.trim(sha)}],
             env: env
           ) do
      :ok
    end
  end

  @doc """
  The empty tree, written into `repo` and named.

  `hash-object -w -t tree /dev/null` writes it and prints its id. `mktree` would want it on
  stdin, and `run/3` has no stdin to give — nor should it grow one for this. The empty tree's id
  is also a well-known constant, and is deliberately not hard-coded here: it is only constant for
  SHA-1, and a repository can be SHA-256.

  **`write: true` only when a commit will reference it.** Git carries the empty tree as a cached
  object, so `cat-file`, `commit-tree` and `diff` all accept its id in a repository holding no
  objects at all — which is why a page reading a root commit's diff against it needs nothing
  written, and why browsing a repository writes nothing whatsoever.

  A commit that *references* it is the other case, and the difference is observable:
  `commit-tree` accepts the unwritten id happily and `git clone` of the result checks out fine,
  but `git fsck` on that repository then reports `missing tree 4b825dc…` for ever. So
  `create_root_commit/2` writes it and nothing else does.
  """
  @spec empty_tree(repo(), keyword()) :: {:ok, sha()} | {:error, term()}
  def empty_tree(repo, opts \\ []) do
    write = if Keyword.get(opts, :write, false), do: ["-w"], else: []

    with {:ok, out} <- run(repo, ["hash-object"] ++ write ++ ["-t", "tree", "/dev/null"]) do
      {:ok, String.trim(out)}
    end
  end

  @doc "Resolves a ref to a commit sha."
  @spec resolve(repo(), String.t()) :: {:ok, sha()} | {:error, {:unknown_ref, String.t()}}
  def resolve(repo, ref) do
    case run(repo, ["rev-parse", "--verify", "--quiet", {:data, ref <> "^{commit}"}]) do
      {:ok, sha} -> {:ok, String.trim(sha)}
      # The ref travels with the error: this is called with a project's default branch and
      # with a ticket's own branch, and a caller reporting the failure cannot tell which.
      {:error, _} -> {:error, {:unknown_ref, ref}}
    end
  end

  @doc "The content of `path` at `sha`."
  @spec show(repo(), sha(), String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def show(repo, sha, path) do
    case run(repo, ["show", {:data, "#{sha}:#{path}"}]) do
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
         {:ok, output} <- cat_file(repo, "-s", sha, path),
         {bytes, _rest} <- Integer.parse(String.trim(output)) do
      {:ok, bytes}
    else
      _other -> {:error, :not_found}
    end
  end

  defp object_type(repo, sha, path) do
    with {:ok, output} <- cat_file(repo, "-t", sha, path) do
      {:ok, String.trim(output)}
    end
  end

  # `{:data, …}` because the revision is composed of two values a caller was handed, and
  # `stderr: :separate` because "not a valid object name" on the terminal is noise for a question
  # whose answer is already `{:error, :not_found}`.
  defp cat_file(repo, flag, sha, path) do
    run(repo, ["cat-file", flag, {:data, "#{sha}:#{path}"}], stderr: :separate)
  end

  @spec exists?(repo(), sha(), String.t()) :: boolean()
  def exists?(repo, sha, path), do: match?({:ok, _}, show(repo, sha, path))

  @doc "Creates `branch` at `sha`. Fails if the branch exists."
  @spec create_branch(repo(), String.t(), sha()) :: :ok | {:error, term()}
  def create_branch(repo, branch, sha) do
    with {:ok, _} <- run(repo, ["branch", {:data, branch}, {:data, sha}]) do
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
      with {:ok, _out} <- run(repo, ["branch", "-D", {:data, branch}]), do: :ok
    else
      :ok
    end
  end

  @doc "Checks `branch` out into a new worktree at `dir`, which must not exist."
  @spec worktree_add(repo(), String.t(), String.t()) :: :ok | {:error, term()}
  def worktree_add(repo, dir, branch) do
    File.mkdir_p!(Path.dirname(dir))

    with {:ok, _} <- run(repo, ["worktree", "add", "--quiet", {:data, dir}, {:data, branch}]) do
      :ok
    end
  end

  @doc """
  Returns the existing worktree at `dir` to `branch`'s head, discarding everything that was
  not committed. Ignored files are left alone, so a build directory survives.
  """
  @spec worktree_reset(String.t(), String.t()) :: :ok | {:error, term()}
  def worktree_reset(dir, branch) do
    with {:ok, _} <- run(dir, ["reset", "--quiet", "--hard", {:data, "refs/heads/" <> branch}]),
         {:ok, _} <- run(dir, ["clean", "--quiet", "-fd"]) do
      :ok
    end
  end

  @doc "Removes the worktree at `dir`, discarding uncommitted changes."
  @spec worktree_remove(repo(), String.t()) :: :ok | {:error, term()}
  def worktree_remove(repo, dir) do
    with {:ok, _} <- run(repo, ["worktree", "remove", "--force", {:data, dir}]) do
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
    args = @paths_as_written ++ ["diff", {:data, "#{base}..#{head}"}]
    paths = Enum.map(paths, &{:data, &1})
    run(repo, if(paths == [], do: args, else: args ++ ["--"] ++ paths), stderr: :separate)
  end

  @doc """
  A path as git prints it, unquoted: git wraps one containing a quote, a backslash or a control
  character in double quotes with C escapes (`\"`, `\\`, `\t`, octal bytes), and prints any
  other as it is.
  """
  @spec unquote_path(String.t()) :: String.t()
  def unquote_path("\"" <> quoted) do
    # One closing quote, not every trailing one: `String.trim_trailing/2` took them all, so a
    # path that is itself quoted — `"quoted"`, which git prints as `"\"quoted\""` — came back
    # with its last escape eaten and did not round-trip through `printable_path/1`.
    quoted |> String.replace_suffix("\"", "") |> unescape(<<>>)
  end

  def unquote_path(path), do: path

  defp unescape(<<>>, acc), do: acc

  defp unescape(<<"\\", a, b, c, rest::binary>>, acc)
       when a in ?0..?3 and b in ?0..?7 and c in ?0..?7,
       do: unescape(rest, <<acc::binary, (a - ?0) * 64 + (b - ?0) * 8 + (c - ?0)>>)

  defp unescape(<<"\\", char, rest::binary>>, acc),
    do: unescape(rest, <<acc::binary, escaped(char)>>)

  defp unescape(<<char, rest::binary>>, acc), do: unescape(rest, <<acc::binary, char>>)

  @doc """
  A path as a page may draw it and as JSON may carry it: as git printed it when that is text, and
  C-escaped in double quotes — git's own form for a path it cannot print — when it is not.

  **Every path this module returns has been through it.** A repository may hold a file whose name
  is not valid UTF-8 (`caf\xE9.txt`), and `@paths_as_written` plus `ls-tree -z` are exactly what
  make git hand those bytes over raw rather than quoted. Drawn into a page they make the rendered
  HTML invalid UTF-8, and `Phoenix.Socket.V2.JSONSerializer.encode!/1` then raises on it in the
  socket's own transport process — taking every LiveView on that connection down, not just the
  page that drew the name. The same byte in a JSON response is a 500 from `Jason`.

  It is applied here rather than at each place a path is drawn so that the rule cannot be
  forgotten by the next caller: nothing downstream has to remember anything, because there is
  nothing left to remember it about.

  `unquote_path/1` is its exact inverse, which is what lets a path make the round trip out to a
  browser and back into a git argument. A path that is already quoted-looking — one that begins
  with a `"` — is escaped too, so that the inverse has only one reading.
  """
  @spec printable_path(String.t()) :: String.t()
  def printable_path(path) do
    if String.valid?(path) and not String.starts_with?(path, "\"") and not control?(path),
      do: path,
      else: escape(path)
  end

  defp control?(path), do: String.to_charlist(path) |> Enum.any?(&(&1 < 0x20))

  # The form `unquote_path/1` reads: double quotes around it, `\\` and `\"` escaped, the escapes
  # git itself prints for a tab or a newline, and every other byte outside printable ASCII as
  # three octal digits.
  defp escape(path), do: "\"" <> escape(path, <<>>) <> "\""

  defp escape(<<>>, acc), do: acc

  defp escape(<<byte, rest::binary>>, acc) when byte in [?\\, ?"],
    do: escape(rest, <<acc::binary, ?\\, byte>>)

  defp escape(<<byte, rest::binary>>, acc) when byte in 0x20..0x7E,
    do: escape(rest, <<acc::binary, byte>>)

  defp escape(<<byte, rest::binary>>, acc) do
    case escape_char(byte) do
      nil -> escape(rest, <<acc::binary, octal(byte)::binary>>)
      char -> escape(rest, <<acc::binary, ?\\, char>>)
    end
  end

  defp escape_char(?\t), do: ?t
  defp escape_char(?\n), do: ?n
  defp escape_char(?\r), do: ?r
  defp escape_char(7), do: ?a
  defp escape_char(?\b), do: ?b
  defp escape_char(?\f), do: ?f
  defp escape_char(?\v), do: ?v
  defp escape_char(_byte), do: nil

  defp octal(byte),
    do: "\\" <> (byte |> Integer.to_string(8) |> String.pad_leading(3, "0"))

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
           run(repo, @paths_as_written ++ ["diff", "--numstat", {:data, "#{base}..#{head}"}],
             stderr: :separate
           ) do
      {:ok, out |> String.split("\n", trim: true) |> Enum.map(&numstat_line/1)}
    end
  end

  defp numstat_line(line) do
    case String.split(line, "\t", parts: 3) do
      [added, removed, path] ->
        {path |> unquote_path() |> printable_path(), count(added), count(removed)}

      _other ->
        {line, :binary, :binary}
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
    # The repository's root is no pathspec at all: `ls-tree -z <sha> -- "/"` is a path that
    # matches nothing, not "everything at the top", so a root asked for with one came back empty.
    pathspec = if dir == "", do: [], else: ["--", {:data, dir <> "/"}]

    with {:ok, out} <- run(repo, ["ls-tree", "-z", {:data, sha}] ++ pathspec, stderr: :separate) do
      {:ok, out |> String.split(<<0>>, trim: true) |> Enum.map(&tree_entry/1)}
    end
  end

  defp tree_entry(line) do
    [meta, path] = String.split(line, "\t", parts: 2)
    [mode, type, _object] = String.split(meta, " ")

    %{
      name: path |> Path.basename() |> printable_path(),
      path: printable_path(path),
      kind: tree_kind(mode, type)
    }
  end

  defp tree_kind("120000", _type), do: :link
  defp tree_kind(_mode, "tree"), do: :tree
  defp tree_kind(_mode, "commit"), do: :commit
  defp tree_kind(_mode, _blob), do: :blob

  @doc """
  The repository's branches, by their short names, sorted.

  `refs/heads/` only: this is what a person is offered to look at, and the platform's own
  bookkeeping refs — `refs/forge/approved/*` and anything else outside `refs/heads/` — are not
  branches anybody chooses.
  """
  @spec branches(repo()) :: {:ok, [String.t()]} | {:error, term()}
  def branches(repo) do
    args = ["for-each-ref", "--format=%(refname:short)", "refs/heads/"]

    with {:ok, out} <- run(repo, args, stderr: :separate) do
      {:ok, out |> String.split("\n", trim: true) |> Enum.sort()}
    end
  end

  @doc "The paths under `pathspec` that differ from `base` to `head`, unquoted."
  @spec changed_paths(repo(), sha(), sha(), [String.t()]) ::
          {:ok, [String.t()]} | {:error, term()}
  def changed_paths(repo, base, head, pathspec) do
    pathspec = Enum.map(pathspec, &{:data, &1})

    args =
      @paths_as_written ++ ["diff", "--name-only", {:data, "#{base}..#{head}"}, "--" | pathspec]

    with {:ok, out} <- run(repo, args, stderr: :separate) do
      {:ok,
       out
       |> String.split("\n", trim: true)
       |> Enum.map(&(&1 |> unquote_path() |> printable_path()))}
    end
  end

  @doc """
  The tree `sha` holds, or an error. What `Forge.Merge` compares a merged tree against to tell
  "merging this changes nothing" from "this makes a commit", now that a merge leaves one parent
  and reachability no longer answers it.
  """
  @spec tree(repo(), sha()) :: {:ok, sha()} | {:error, term()}
  def tree(repo, sha) do
    case run(repo, ["rev-parse", "--verify", "--quiet", {:data, sha <> "^{tree}"}]) do
      {:ok, tree} -> {:ok, String.trim(tree)}
      {:error, _reason} -> {:error, {:unknown_ref, sha}}
    end
  end

  @doc "Whether `ancestor` is reachable from `descendant`."
  @spec ancestor?(repo(), String.t(), String.t()) :: boolean()
  def ancestor?(repo, ancestor, descendant),
    do:
      match?(
        {:ok, _},
        run(repo, ["merge-base", "--is-ancestor", {:data, ancestor}, {:data, descendant}])
      )

  @doc """
  Points `ref` at `sha`, creating it. Used for `refs/forge/approved/<n>`, which keeps an approved
  commit reachable after the ticket branch is rewritten.
  """
  @spec pin(repo(), String.t(), sha()) :: :ok | {:error, term()}
  def pin(repo, ref, sha) do
    with {:ok, _out} <- run(repo, ["update-ref", {:data, ref}, {:data, sha}]), do: :ok
  end

  @doc "Commit shas on `head` since `base`, newest first."
  @spec commits_since(repo(), sha(), String.t()) :: {:ok, [sha()]} | {:error, term()}
  def commits_since(repo, base, head) do
    with {:ok, out} <- run(repo, ["rev-list", {:data, "#{base}..#{head}"}]) do
      {:ok, String.split(out, "\n", trim: true)}
    end
  end

  @doc "The best common ancestor of `a` and `b`."
  @spec merge_base(repo(), String.t(), String.t()) :: {:ok, sha()} | {:error, term()}
  def merge_base(repo, a, b) do
    with {:ok, out} <- run(repo, ["merge-base", {:data, a}, {:data, b}]),
         do: {:ok, String.trim(out)}
  end

  # Sha, committer time and subject, unit-separated: a subject may hold anything but a newline,
  # so the separator cannot be one of the characters it may hold.
  @log_format "--format=%H%x1f%ct%x1f%s"

  @doc """
  The commits on `head` since `base`, newest first: sha, subject, and when each was committed.
  The same range as `commits_since/3`, with what a list of commits shows a person.
  """
  @spec log(repo(), String.t(), String.t(), keyword()) ::
          {:ok, [commit()]} | {:error, term()}
  def log(repo, base, head, opts \\ []) do
    # `first_parent: true` is the line a branch's own merges make, and not what each brought in.
    first = if Keyword.get(opts, :first_parent, false), do: ["--first-parent"], else: []

    with {:ok, out} <-
           run(repo, ["log", @log_format] ++ first ++ [{:data, "#{base}..#{head}"}],
             stderr: :separate
           ) do
      {:ok, commits(out)}
    end
  end

  @typedoc "A commit as a list of them shows it."
  @type commit :: %{sha: sha(), subject: String.t(), at: DateTime.t()}

  @doc """
  One page of `ref`'s own history, newest first: `limit` commits from `skip`, and whether there
  are more behind them.

  A single ref rather than a range — this is the whole branch, not what one branch added — and
  one row more than `limit` is asked of git so that `more` is known without a second counting
  pass over every commit in the repository. The extra row is trimmed before it is returned.
  """
  @spec history(repo(), String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, %{commits: [commit()], more: boolean()}} | {:error, term()}
  def history(repo, ref, skip, limit)
      when is_integer(skip) and skip >= 0 and is_integer(limit) and limit > 0 do
    # `skip` and `limit` are the caller's too, and they are interpolated into flags rather than
    # marked `{:data, …}` — a flag's own value is not a position git reads an option in. The
    # guard is what makes that safe rather than lucky: a binary here would put whatever it held
    # inside `--skip=`, and the mark cannot be used on something that is not a whole argument.
    args = ["log", @log_format, "--skip=#{skip}", "--max-count=#{limit + 1}", {:data, ref}]

    with {:ok, out} <- run(repo, args, stderr: :separate) do
      commits = commits(out)
      {:ok, %{commits: Enum.take(commits, limit), more: length(commits) > limit}}
    end
  end

  @doc """
  The first parent of `sha`, or `{:error, :no_parent}` for a root commit.

  First parent only, which is what a merge commit's own diff is read against — the same reading
  `log/4`'s `first_parent: true` takes of a branch.
  """
  @spec parent(repo(), sha()) :: {:ok, sha()} | {:error, :no_parent}
  def parent(repo, sha) do
    case run(repo, ["rev-parse", "--verify", "--quiet", {:data, sha <> "^"}]) do
      {:ok, out} -> {:ok, String.trim(out)}
      {:error, _reason} -> {:error, :no_parent}
    end
  end

  defp commits(out), do: out |> String.split("\n", trim: true) |> Enum.flat_map(&log_line/1)

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

  @typedoc """
  One argument to git: a literal written at the call site, or `{:data, value}` for a ref, a rev,
  a range or a path the caller was handed.
  """
  @type arg :: String.t() | {:data, String.t()}

  @doc """
  Runs git with `args` in `dir`. Public so contexts can do the odd extra call.

  **An argument the caller was handed is marked `{:data, value}`, and is refused when it begins
  with a dash.** git reads an argument beginning with `-` as an option wherever it sits in the
  command line — `log --output=<file>` writes a file, relative to the working directory — so a
  rev that arrives from outside and starts with a dash is an arbitrary create-or-truncate as the
  platform's own user, not a lookup that misses. A page served
  `/projects/:name/repo/commits/--output=config` emptied the project's `HEAD` with one GET, and
  `--output=../../x` wrote outside the repositories directory entirely.

  The mark is on the value rather than a check inside each function because the rule has to hold
  for the *next* caller too, and because it is greppable: every value in this module that is not
  a literal carries it, so a new one that does not is visible in review. The refusal is the whole
  rule — `--end-of-options` would close the same hole, but only on the subcommands that parse it,
  and there is no position in any git command line where a leading dash is a legitimate rev, ref
  or path.

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
  @spec run(String.t(), [arg()], keyword()) ::
          {:ok, String.t()} | {:error, {integer(), String.t()} | {:not_a_rev, String.t()}}
  def run(dir, args, opts \\ []) do
    env = [{"GIT_TERMINAL_PROMPT", "0"} | Keyword.get(opts, :env, [])]

    with {:ok, argv} <- argv(args) do
      case cmd(dir, argv, env, Keyword.get(opts, :stderr)) do
        {out, 0, _err} -> {:ok, out}
        {out, code, err} -> {:error, {code, out <> err}}
      end
    end
  end

  defp argv(args) do
    Enum.reduce_while(args, {:ok, []}, fn arg, {:ok, acc} ->
      case arg do
        {:data, "-" <> _rest = value} -> {:halt, {:error, {:not_a_rev, value}}}
        {:data, value} when is_binary(value) -> {:cont, {:ok, [value | acc]}}
        # A `{:data, …}` that is not a binary is the same mistake one line later: git is given
        # a term it cannot be given, and `System.cmd/3` raises rather than refusing.
        {:data, value} -> {:halt, {:error, {:not_a_rev, inspect(value)}}}
        literal when is_binary(literal) -> {:cont, {:ok, [literal | acc]}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, reason} -> {:error, reason}
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
