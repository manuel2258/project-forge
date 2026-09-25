defmodule ForgeWorker.Job.Workspace do
  @moduledoc """
  Where a job's work happens: a worktree made for it, and what becomes of that worktree when the
  run ends. `docs/decisions.md` says jobs are disposable and only what reaches the branch or the
  store survives, so the work is committed and pushed before anything is reported and the tree
  is then thrown away.

  A worktree is a snapshot of the ticket's own volume where this machine has one, of the project's
  seed where it does not, and a clone where there is neither (`docs/design/worker-tier.md`
  § Volumes and the seed, § The ticket volume). All three end in the same place — the ticket
  branch at the head the platform has — and the difference is only how warm the build directory
  beside it is.

  **The git is `ForgeWorker.Checkout`'s, all of it.** This module owns the volume, the seed and
  the order things happen in; every `git` invocation on this machine is in that one module, which
  is what keeps the credential's handling in one place too.
  """

  alias ForgeWorker.Checkout
  alias ForgeWorker.Job.Seed
  alias ForgeWorker.Volume

  require Logger

  @type assignment :: map()

  # The branch becomes a path, so it is matched rather than trusted: the platform built it and the
  # repository's `pre-receive` enforces the same shape, but a guard that takes the platform's word
  # for it is not a guard. Conversations are deliberately absent — `chat/<uuid>` keeps one
  # worktree for the whole of its life, so it already holds its own warmth.
  @ticket_branch ~r{^ticket/\d+$}

  @doc """
  Prepares the worktree for an assignment and returns its path.

  A cold start gets the branch as the platform has it, with anything a dead run left
  uncommitted discarded. A resume keeps a tree that is already here as it stands: the work in
  progress is the point of resuming. A tree made for the resume — a snapshot, a clone — has no
  work in progress, and is the branch as the platform has it like any other.
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
      from_template(assignment, root, dir) || from_seed(assignment, root, dir) ||
        clone(assignment, dir)
    end
  end

  @doc """
  Keeps the finished worktree as this ticket's template, so the ticket's next job starts where
  this one left off rather than where the project's seed was published.

  **Only after the run committed and pushed**, which is what makes the template safe to snapshot
  from without cleaning: `Checkout.squash/3` stages everything with `add -A`, so what is left
  beside the checkout is the ignored build output and nothing a later run could mistake for its
  own work. A run that ended before that keeps the template the ticket already had.

  Best effort throughout. This is a cache: a promotion that fails costs the next job a colder
  start and nothing else, so it warns and returns `:ok`.
  """
  @spec promote(assignment(), String.t(), String.t()) :: :ok
  def promote(assignment, root, dir) do
    case template(assignment, root) do
      nil -> :ok
      path -> replace(path, dir)
    end
  end

  @doc """
  Removes ticket volumes older than `older_than_ms`, returning how many went.

  Nothing tells this machine that a ticket was merged or abandoned — the platform sends `assign`
  and `cancel`, and a conversation's `message`, `interrupt` and `close` — so age is what there
  is. Called where the job directories are swept, for the same reason: the end of a job is
  already a moment spent on the filesystem.
  """
  @spec sweep(String.t(), non_neg_integer()) :: non_neg_integer()
  def sweep(root, older_than_ms) do
    cutoff = System.os_time(:second) - div(older_than_ms, 1000)

    [root, "volumes", "ticket", "*"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.count(&remove_if_stale(&1, cutoff))
  end

  @doc """
  Where this ticket's warm template lives on this machine, or `nil` for a branch that does not get
  one.
  """
  @spec template(assignment(), String.t()) :: String.t() | nil
  def template(assignment, root) do
    branch = get_in(assignment, ["git", "branch"])

    if is_binary(branch) and Regex.match?(@ticket_branch, branch),
      do: Path.join([root, "volumes", branch]),
      else: nil
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

  defp from_template(assignment, root, dir) do
    path = template(assignment, root)

    if is_binary(path) and File.dir?(path),
      do: from_volume(assignment, path, dir, "ticket volume")
  end

  defp from_seed(assignment, root, dir) do
    case Seed.ensure(assignment, root) do
      seed when is_binary(seed) -> from_volume(assignment, seed, dir, "seed")
      nil -> nil
    end
  end

  # A snapshot of `source` — the ticket's template or the project's seed — pointed at this job's
  # branch and deliberately not cleaned: see `Checkout.ensure/1`'s `clean:` for what cleaning a
  # fresh snapshot would take with it.
  #
  # **Never a resume, whatever the assignment says.** A resume keeps the tree it finds because an
  # unfinished tree is the point of resuming, and a snapshot is not one: it is on whatever commit
  # the volume was, often not this branch at all. Kept as it was, a resume on a machine without
  # the job's own worktree ran on the wrong tree, and the squash at its end pushed the difference
  # as a commit undoing the ticket's work.
  defp from_volume(assignment, source, dir, what) do
    git = assignment["git"]

    with :ok <- Volume.impl().snapshot(source, dir),
         :ok <- Checkout.remote(dir, git["url"]),
         :ok <- Checkout.ensure(checkout_opts(assignment, dir, clean: false, resume: false)) do
      {:ok, dir}
    else
      {:error, reason} ->
        # A warm start is what makes a job fast, not what makes it correct: a snapshot that will
        # not become this branch is thrown away and the caller falls back to a colder start.
        Logger.warning("could not use the #{what} for #{dir} (#{inspect(reason)})")
        Volume.impl().delete(dir)
        nil
    end
  end

  # Into a sibling first, so a promotion that fails leaves the template the ticket already had
  # rather than none at all. The touch is what `sweep/2` reads: a snapshot carries the mtime of
  # the tree it came from, which says when the worktree's root last changed rather than when this
  # ticket last ran.
  defp replace(path, dir) do
    volume = Volume.impl()
    staging = path <> ".promoting." <> Base.url_encode64(:crypto.strong_rand_bytes(6))

    with :ok <- volume.snapshot(dir, staging),
         :ok <- volume.delete(path),
         :ok <- File.rename(staging, path) do
      File.touch!(path)
      :ok
    else
      {:error, reason} ->
        Logger.warning("could not keep #{dir} as #{path} (#{inspect(reason)})")
        volume.delete(staging)
        :ok
    end
  end

  # A promotion in flight is a sibling of the volume it is replacing, and sweeping one would
  # delete a finishing job's copy out from under it.
  defp remove_if_stale(path, cutoff) do
    with false <- String.contains?(Path.basename(path), ".promoting."),
         true <- File.dir?(path),
         {:ok, %File.Stat{mtime: mtime}} <- File.stat(path, time: :posix),
         true <- mtime < cutoff do
      case Volume.impl().delete(path) do
        :ok ->
          Logger.info("swept ticket volume #{Path.basename(path)}")
          true

        {:error, reason} ->
          Logger.warning("could not sweep #{path}: #{inspect(reason)}")
          false
      end
    else
      _other -> false
    end
  end

  defp clone(assignment, dir) do
    with :ok <- Checkout.ensure(checkout_opts(assignment, dir, [])), do: {:ok, dir}
  end

  defp checkout_opts(assignment, dir, extra) do
    git = assignment["git"]

    Keyword.merge(
      [
        dir: dir,
        url: git["url"],
        branch: git["branch"],
        token: git["token"],
        resume: assignment["resume_session"] != nil
      ],
      extra
    )
  end

  defp maybe_push(_git, _dir, false), do: :ok

  defp maybe_push(git, dir, true),
    do: Checkout.push(dir: dir, branch: git["branch"], token: git["token"])

  defp remote(git), do: "origin/" <> git["branch"]
end
