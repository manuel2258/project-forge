defmodule ForgeWorker.Job.Workspace do
  @moduledoc """
  Where a job's work happens: a worktree made for it, and what becomes of that worktree when the
  run ends. `docs/decisions.md` says jobs are disposable and only what reaches the branch or the
  store survives, so the work is committed and pushed before anything is reported and the tree
  is then thrown away.

  A worktree is a snapshot of the project's seed where there is one, and a clone where there is
  not (`docs/design/worker-tier.md` § Volumes and the seed). Both end in the same place — the
  ticket branch at the head the platform has — and the difference is whether the build directory
  beside it is already warm.

  **The git is `ForgeWorker.Checkout`'s, all of it.** This module owns the volume, the seed and
  the order things happen in; every `git` invocation on this machine is in that one module, which
  is what keeps the credential's handling in one place too.
  """

  alias ForgeWorker.Checkout
  alias ForgeWorker.Job.Seed
  alias ForgeWorker.Volume

  require Logger

  @type assignment :: map()

  @doc """
  Prepares the worktree for an assignment and returns its path.

  A cold start gets the branch as the platform has it, with anything a dead run left
  uncommitted discarded. A resume keeps the tree as it stands: the work in progress is the
  point of resuming.
  """
  @spec prepare(assignment(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def prepare(assignment, root) do
    dir = dir(assignment, root)

    # A worktree that is already there belongs to a run that did not finish — this one is a
    # resume, or a previous attempt died before `discard/2`. Either way it has a repository in
    # it, and `Checkout.ensure/1` knows what to do with one.
    if File.dir?(dir) do
      with :ok <- Checkout.ensure(checkout_opts(assignment, dir, [])), do: {:ok, dir}
    else
      from_seed(assignment, root, dir) || clone(assignment, dir)
    end
  end

  @doc """
  Commits everything in the worktree and pushes it to the ticket branch, returning the head.
  One commit per run. A run that changed nothing pushes nothing and reports the head it
  started from.
  """
  @spec commit_and_push(assignment(), String.t(), String.t()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def commit_and_push(assignment, dir, message) do
    git = assignment["git"]

    with {:ok, committed?} <- Checkout.squash(dir, remote(git), message),
         :ok <- maybe_push(git, dir, committed?) do
      Checkout.head(dir)
    end
  end

  @doc """
  Throws the worktree away. A job's tree is disposable by construction — the run committed and
  pushed before anything was reported — and on the image it is a snapshot whose only cost is
  what the job wrote into it.
  """
  @spec discard(assignment(), String.t()) :: :ok
  def discard(assignment, root) do
    dir = dir(assignment, root)

    case Volume.impl().delete(dir) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("could not remove #{dir}: #{inspect(reason)}")
    end

    :ok
  end

  @doc "Where an assignment's worktree lives."
  @spec dir(assignment(), String.t()) :: String.t()
  def dir(assignment, root), do: Path.join([root, "worktrees", assignment["job_id"]])

  # A snapshot of the project's seed, pointed at this job's branch and deliberately not cleaned:
  # see `Checkout.ensure/1`'s `clean:` for what cleaning a fresh snapshot would take with it.
  defp from_seed(assignment, root, dir) do
    git = assignment["git"]

    with seed when is_binary(seed) <- Seed.ensure(assignment, root),
         :ok <- Volume.impl().snapshot(seed, dir),
         :ok <- Checkout.remote(dir, git["url"]),
         :ok <- Checkout.ensure(checkout_opts(assignment, dir, clean: false)) do
      {:ok, dir}
    else
      nil ->
        nil

      {:error, reason} ->
        # The seed is what makes a job fast, not what makes it correct: a snapshot that will
        # not become this branch is thrown away and the job clones.
        Logger.warning("could not use the seed for #{dir} (#{inspect(reason)}); cloning")
        Volume.impl().delete(dir)
        nil
    end
  end

  defp clone(assignment, dir) do
    with :ok <- Checkout.ensure(checkout_opts(assignment, dir, [])), do: {:ok, dir}
  end

  defp checkout_opts(assignment, dir, extra) do
    git = assignment["git"]

    [
      dir: dir,
      url: git["url"],
      branch: git["branch"],
      token: git["token"],
      resume: assignment["resume_session"] != nil
    ] ++ extra
  end

  defp maybe_push(_git, _dir, false), do: :ok

  defp maybe_push(git, dir, true),
    do: Checkout.push(dir: dir, branch: git["branch"], token: git["token"])

  defp remote(git), do: "origin/" <> git["branch"]
end
