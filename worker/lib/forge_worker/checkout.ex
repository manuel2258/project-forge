defmodule ForgeWorker.Checkout do
  @moduledoc """
  The working copy a job runs in: cloned from the platform over smart HTTP with the job's own
  short-lived token, and pushed back when the job ends.

  This is the worker's git, not the platform's. It lives here rather than in the platform because
  the worker tier runs on a different machine, where a local worktree of the platform's bare
  repository is not available and this module is the whole of what changes: nothing.

  The credential never reaches argv. git is run with a `credential.helper` that prints
  `$FORGE_GIT_TOKEN`, and the variable is passed through the process environment only — the same
  rule `ForgeWorker.Job.Runner` applies to every `{:secret, _}` value.

  See `docs/design/git-hosting.md`.
  """

  require Logger

  @helper ~S|!f() { printf 'username=forge\npassword=%s\n' "$FORGE_GIT_TOKEN"; }; f|

  @type opts :: [
          dir: String.t(),
          url: String.t(),
          branch: String.t(),
          token: (-> String.t()),
          resume: boolean(),
          clean: boolean(),
          identity: {String.t(), String.t()}
        ]

  @doc """
  Makes `dir` a checkout of `branch`.

  A first run clones. A later one fetches; unless it is resuming an interrupted run, it also
  resets the working tree to the branch head and removes what is not tracked, so a cold start
  never inherits a dead run's uncommitted work. Ignored files are left alone, so a build
  directory survives.

  `clean: false` keeps the untracked files as well, which is what a worktree freshly snapshotted
  from a seed needs: it has nothing a dead run left in it, and what it does have beside the
  checkout is the warm build directory the seed exists to carry
  (`docs/design/worker-tier.md` § Volumes and the seed). A build directory that is *not* in
  `.gitignore` would otherwise be deleted by the one command meant to protect the run from a
  predecessor it never had.
  """
  @spec ensure(opts()) :: :ok | {:error, term()}
  def ensure(opts) do
    dir = Keyword.fetch!(opts, :dir)

    if File.dir?(Path.join(dir, ".git")) do
      refresh(dir, opts)
    else
      clone(dir, opts)
    end
  end

  @doc """
  Points the checkout's `origin` at `url`, whatever it was pointing at before.

  A seed was cloned from wherever it was built, which is not necessarily where this job fetches
  from — a different host, a different platform address — so the remote is set rather than
  trusted. A checkout with no origin at all still ends up with one.
  """
  @spec remote(String.t(), String.t()) :: :ok | {:error, term()}
  def remote(dir, url) do
    case git(dir, ["remote", "set-url", "origin", url], []) do
      {:ok, _out} ->
        :ok

      {:error, _reason} ->
        with {:ok, _out} <- git(dir, ["remote", "add", "origin", url], []), do: :ok
    end
  end

  @doc """
  Stages everything the run did as one change on top of `base` and commits it, saying whether
  there was anything to commit.

  The reset is what makes this a squash rather than an append, and it is not optional: an agent
  that used git itself — which Claude Code does — leaves its work in commits, so `git add -A`
  finds nothing staged, nothing is committed, and a converged job's changes never leave the
  machine. `decisions.md` asks for one commit per run rather than an agent's keystrokes, and
  this is where that happens.
  """
  @spec squash(String.t(), String.t(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def squash(dir, base, message) do
    with {:ok, _out} <- git(dir, ["reset", "--soft", base], []),
         {:ok, _out} <- git(dir, ["add", "-A"], []) do
      commit(dir, message)
    end
  end

  # A non-zero status from `diff --cached --quiet` means something is staged, which is the only
  # reason to make a commit at all.
  defp commit(dir, message) do
    case git(dir, ["diff", "--cached", "--quiet"], []) do
      {:ok, _out} ->
        {:ok, false}

      {:error, _reason} ->
        with {:ok, _out} <- git(dir, ["commit", "--quiet", "-m", message], []), do: {:ok, true}
    end
  end

  @doc "Pushes the checkout's current commit onto its branch. Force, because a job may squash."
  @spec push(opts()) :: :ok | {:error, term()}
  def push(opts) do
    dir = Keyword.fetch!(opts, :dir)
    branch = Keyword.fetch!(opts, :branch)

    with {:ok, _out} <-
           git(dir, ["push", "--force", "origin", "HEAD:refs/heads/" <> branch], opts) do
      :ok
    end
  end

  @doc "The commit the checkout is on."
  @spec head(String.t()) :: {:ok, String.t()} | {:error, term()}
  def head(dir) do
    with {:ok, out} <- git(dir, ["rev-parse", "HEAD"], []), do: {:ok, String.trim(out)}
  end

  defp clone(dir, opts) do
    url = Keyword.fetch!(opts, :url)
    branch = Keyword.fetch!(opts, :branch)
    File.mkdir_p!(Path.dirname(dir))

    args = ["clone", "--quiet", "--branch", branch, "--single-branch", url, dir]

    with {:ok, _out} <- git(Path.dirname(dir), args, opts) do
      identity(dir, opts)
    end
  end

  defp refresh(dir, opts) do
    branch = Keyword.fetch!(opts, :branch)

    with {:ok, _out} <- git(dir, ["fetch", "--quiet", "origin", branch], opts),
         :ok <- identity(dir, opts) do
      if Keyword.get(opts, :resume, false),
        do: :ok,
        else: reset(dir, branch, Keyword.get(opts, :clean, true))
    end
  end

  # `-B` rather than a bare reset: a snapshot of a seed is on whatever commit the seed was
  # built at, and often not on this branch at all.
  defp reset(dir, branch, clean?) do
    with {:ok, _out} <- git(dir, ["checkout", "--quiet", "-B", branch, "FETCH_HEAD"], []),
         {:ok, _out} <- git(dir, ["reset", "--quiet", "--hard", "FETCH_HEAD"], []),
         {:ok, _out} <- maybe_clean(dir, clean?) do
      :ok
    end
  end

  defp maybe_clean(_dir, false), do: {:ok, ""}
  defp maybe_clean(dir, true), do: git(dir, ["clean", "--quiet", "-fd"], [])

  # The harness runs with a private HOME, so a fresh clone has no global identity and the agent's
  # first commit would fail with git's "please tell me who you are".
  defp identity(dir, opts) do
    {name, email} = Keyword.get(opts, :identity, {"forge", "forge@localhost"})

    with {:ok, _out} <- git(dir, ["config", "--local", "user.name", name], []),
         {:ok, _out} <- git(dir, ["config", "--local", "user.email", email], []) do
      :ok
    end
  end

  defp git(dir, args, opts) do
    args = ["-c", "credential.helper=", "-c", "credential.helper=" <> @helper] ++ args

    env =
      [{"GIT_TERMINAL_PROMPT", "0"}] ++
        case Keyword.get(opts, :token) do
          nil -> []
          token when is_function(token, 0) -> [{"FORGE_GIT_TOKEN", token.()}]
          token when is_binary(token) -> [{"FORGE_GIT_TOKEN", token}]
        end

    case System.cmd("git", args, cd: dir, stderr_to_stdout: true, env: env) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {code, redact(out)}}
    end
  end

  # git echoes the remote URL in its errors, and a caller may have put the token in one.
  defp redact(out), do: String.replace(out, ~r{//[^/@\s]+@}, "//")
end
