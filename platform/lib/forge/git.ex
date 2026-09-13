defmodule Forge.Git do
  @moduledoc """
  The platform's git operations, as thin calls to the git CLI. Repositories are bare and
  owned by the platform; jobs work in worktrees checked out from them. Every function
  returns `{:ok, value}` or `{:error, reason}` and never raises on git failures.
  """

  @type repo :: String.t()
  @type sha :: String.t()

  @doc "Creates a bare repository at `path` unless one exists."
  @spec init_bare(String.t()) :: :ok | {:error, term()}
  def init_bare(path) do
    if File.exists?(Path.join(path, "HEAD")) do
      install_hooks(path)
    else
      File.mkdir_p!(path)

      with {:ok, _} <- run(path, ["init", "--bare", "--quiet"]) do
        install_hooks(path)
      end
    end
  end

  # A job's push may touch exactly one ref: the branch its token names, which the platform
  # puts in the environment when it runs `git http-backend`. The check is a hook because only
  # git knows what a push contains; a plug would have to parse the pack to find out.
  #
  # An empty variable allows the push. Nothing but the platform's git endpoint sets it, so an
  # empty one means this is not a job pushing — it is the operator, on this machine, with the
  # repository's path, and `docs/decisions.md` leaves them SSH and the command line.
  @pre_receive """
  #!/bin/sh
  # Installed by forge. See Forge.Git.install_hooks/1.
  allowed="${FORGE_ALLOWED_REF:-}"
  [ -z "$allowed" ] && exit 0
  status=0
  while read -r _old _new ref; do
    if [ "$ref" != "$allowed" ]; then
      echo "forge: this credential may only update $allowed, not $ref" >&2
      status=1
    fi
  done
  exit $status
  """

  @doc "Installs the hooks the platform relies on. Idempotent, and safe on an existing repo."
  @spec install_hooks(repo()) :: :ok
  def install_hooks(repo) do
    path = Path.join([repo, "hooks", "pre-receive"])
    File.mkdir_p!(Path.dirname(path))

    unless File.read(path) == {:ok, @pre_receive} do
      File.write!(path, @pre_receive)
      File.chmod!(path, 0o755)
    end

    :ok
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

  @doc "The diff from `base` to `head`, as a patch. `paths` narrows it to those files."
  @spec diff(repo(), sha(), String.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def diff(repo, base, head, paths \\ []) do
    args = ["diff", "#{base}..#{head}"]
    run(repo, if(paths == [], do: args, else: args ++ ["--"] ++ paths))
  end

  @doc """
  Per-file line counts from `base` to `head`: `{path, added, removed}`, binary files as `:binary`.
  """
  @spec diff_stat(repo(), sha(), String.t()) ::
          {:ok, [{String.t(), non_neg_integer() | :binary, non_neg_integer() | :binary}]}
          | {:error, term()}
  def diff_stat(repo, base, head) do
    with {:ok, out} <- run(repo, ["diff", "--numstat", "#{base}..#{head}"]) do
      {:ok, out |> String.split("\n", trim: true) |> Enum.map(&numstat_line/1)}
    end
  end

  defp numstat_line(line) do
    case String.split(line, "\t", parts: 3) do
      [added, removed, path] -> {path, count(added), count(removed)}
      _other -> {line, :binary, :binary}
    end
  end

  defp count("-"), do: :binary
  defp count(value), do: String.to_integer(value)

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

  @doc """
  Runs git with `args` in `dir`. Public so contexts can do the odd extra call.

  Options: `:env` adds variables to the child's environment, and `:stderr` set to `:separate`
  keeps stderr out of the returned output — a hook's messages arrive there, and a caller that
  parses stdout must not have them mixed in.
  """
  @spec run(String.t(), [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, {integer(), String.t()}}
  def run(dir, args, opts \\ []) do
    env = [{"GIT_TERMINAL_PROMPT", "0"} | Keyword.get(opts, :env, [])]
    separate? = Keyword.get(opts, :stderr) == :separate

    case System.cmd("git", args, cd: dir, stderr_to_stdout: not separate?, env: env) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {code, out}}
    end
  end
end
