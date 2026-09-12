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
      :ok
    else
      File.mkdir_p!(path)

      with {:ok, _} <- run(path, ["init", "--bare", "--quiet"]) do
        :ok
      end
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

  @doc "The diff from `base` to `head`, as a patch."
  @spec diff(repo(), sha(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def diff(repo, base, head), do: run(repo, ["diff", "#{base}..#{head}"])

  @doc "Commit shas on `head` since `base`, newest first."
  @spec commits_since(repo(), sha(), String.t()) :: {:ok, [sha()]} | {:error, term()}
  def commits_since(repo, base, head) do
    with {:ok, out} <- run(repo, ["rev-list", "#{base}..#{head}"]) do
      {:ok, String.split(out, "\n", trim: true)}
    end
  end

  @doc "Runs git with `args` in `dir`. Public so contexts can do the odd extra call."
  @spec run(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, {integer(), String.t()}}
  def run(dir, args) do
    case System.cmd("git", args,
           cd: dir,
           stderr_to_stdout: true,
           env: [{"GIT_TERMINAL_PROMPT", "0"}]
         ) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {code, out}}
    end
  end
end
