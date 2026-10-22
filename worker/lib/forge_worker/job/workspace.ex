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

  alias ForgeWorker.{Checkout, Log, Slice, Volume}

  # How long a run that ended while the platform was away waits to push before it gives up: long
  # enough for a deploy, short of the job credential's own lifetime.
  @push_patience_ms :timer.minutes(10)
  alias ForgeWorker.Job.Seed

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

  **A state that produces no `changeset` is always the second case.** Its run's tree is never
  committed and `promote/3` is skipped for it (`ForgeWorker.Link`), and the worktree is discarded
  at the end of every run, so a resume finds nothing of its own here and falls through to the
  ticket's older template or the seed. That is what such a state promised — its documents are its
  output and its tree is scratch — and its continuation prompt says so rather than telling it the
  files are the ones it left (`ForgeCore.Prompt.branch_state/2`).

  **The tree is `user`'s before any git runs in it, and git runs as `user`**
  (`docs/design/worker-tier.md` § The job slice). A snapshot of a ticket's template carries the
  last job's `.git`, hooks and all; a tree left by an earlier attempt carries this job's. Only a
  clone — into an empty volume this module just made, which nothing of a job has touched — is the
  worker's own, and it is handed over after.
  """
  @spec prepare(assignment(), String.t(), Slice.user()) :: {:ok, String.t()} | {:error, term()}
  def prepare(assignment, root, user) do
    dir = dir(assignment, root)

    # A worktree that is already there belongs to a run that did not finish — this one is a
    # resume, or a previous attempt died before `discard/2`. Either way it has a repository in
    # it, and `Checkout.ensure/1` knows what to do with one.
    if File.dir?(dir) do
      with :ok <- Slice.own(user, [dir]),
           :ok <- Checkout.ensure(checkout_opts(assignment, dir, user, [])),
           do: {:ok, dir}
    else
      from_template(assignment, root, dir, user) || from_seed(assignment, root, dir, user) ||
        clone(assignment, dir, user)
    end
  end

  @doc """
  Keeps the finished worktree as this ticket's template, so the ticket's next job starts where
  this one left off rather than where the project's seed was published.

  **Only after the run committed and pushed**, which is what makes the template safe to snapshot
  from without cleaning: `Checkout.squash/5` stages everything with `add -A`, so what is left
  beside the checkout is the ignored build output and nothing a later run could mistake for its
  own work. A run that ended before that keeps the template the ticket already had.

  Best effort throughout. This is a cache: a promotion that fails costs the next job a colder
  start and nothing else, so it warns and returns `:ok`.
  """
  @spec promote(assignment(), String.t(), String.t()) :: :ok
  def promote(assignment, root, dir) do
    case template(assignment, root) do
      nil -> :ok
      path -> replace(path, dir, assignment["job_id"])
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
  started from. As `user`, whose tree it is and whose hooks it would run.
  """
  @spec commit_and_push(assignment(), String.t(), String.t(), Slice.user()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def commit_and_push(assignment, dir, message, user) do
    git = assignment["git"]
    as = Slice.as_user(user)

    with {:ok, committed?} <- Checkout.squash(dir, remote(git), message, as, keep: merged(git)),
         :ok <- maybe_push(git, dir, committed?, as) do
      Checkout.head(dir, as)
    end
  end

  @doc """
  The ticket branch head this run started from: the `origin/<branch>` its checkout fetched, read
  as `user`.

  Not the worktree's own `HEAD`, which an agent that used git itself has already moved past —
  onto commits that were never pushed and, for a state that produces no changeset, never will
  be. This is what such a run reports instead of a push (`ForgeWorker.Link`).
  """
  @spec base(assignment(), String.t(), Slice.user()) :: {:ok, String.t()} | {:error, term()}
  def base(assignment, dir, user),
    do: Checkout.rev(dir, remote(assignment["git"]), Slice.as_user(user))

  @doc "The commit the worktree is on, read as `user`."
  @spec head(String.t(), Slice.user()) :: {:ok, String.t()} | {:error, term()}
  def head(dir, user), do: Checkout.head(dir, Slice.as_user(user))

  @doc """
  Throws the worktree away. A job's tree is disposable by construction — the run committed and
  pushed before anything was reported — and on the image it is a snapshot whose only cost is
  what the job wrote into it.
  """
  @spec discard(assignment(), String.t()) :: :ok
  def discard(assignment, root) do
    dir = dir(assignment, root)

    case Volume.impl().delete(dir) do
      :ok ->
        :ok

      {:error, reason} ->
        Log.line("worktree.undeleted", :warning, "could not remove #{dir}: #{inspect(reason)}",
          job_id: assignment["job_id"]
        )
    end

    :ok
  end

  @doc "Where an assignment's worktree lives."
  @spec dir(assignment(), String.t()) :: String.t()
  def dir(assignment, root), do: Path.join([root, "worktrees", assignment["job_id"]])

  defp from_template(assignment, root, dir, user) do
    path = template(assignment, root)

    if is_binary(path) and File.dir?(path),
      do: from_volume(assignment, path, dir, "ticket volume", user)
  end

  defp from_seed(assignment, root, dir, user) do
    case Seed.ensure(assignment, root) do
      seed when is_binary(seed) -> from_volume(assignment, seed, dir, "seed", user)
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
  #
  # **Handed to the job's user before git touches it.** A template's `.git` is the last job's,
  # written by a user who could put a `post-checkout` hook in it; run as root, the checkout below
  # would run that hook as root.
  defp from_volume(assignment, source, dir, what, user) do
    git = assignment["git"]
    opts = checkout_opts(assignment, dir, user, clean: false, resume: false)

    with :ok <- Volume.impl().snapshot(source, dir),
         :ok <- Slice.own(user, [dir]),
         :ok <- Checkout.remote(dir, git["url"], opts[:as]),
         :ok <- Checkout.ensure(opts) do
      {:ok, dir}
    else
      {:error, reason} ->
        # A warm start is what makes a job fast, not what makes it correct: a snapshot that will
        # not become this branch is thrown away and the caller falls back to a colder start.
        Log.line(
          "volume.unused",
          :warning,
          "could not use the #{what} for #{dir}, so it starts colder: #{inspect(reason)}",
          job_id: assignment["job_id"]
        )

        Volume.impl().delete(dir)
        nil
    end
  end

  # Into a sibling first, so a promotion that fails leaves the template the ticket already had
  # rather than none at all. The touch is what `sweep/2` reads: a snapshot carries the mtime of
  # the tree it came from, which says when the worktree's root last changed rather than when this
  # ticket last ran.
  defp replace(path, dir, job_id) do
    volume = Volume.impl()
    staging = path <> ".promoting." <> Base.url_encode64(:crypto.strong_rand_bytes(6))

    with :ok <- volume.snapshot(dir, staging),
         :ok <- volume.delete(path),
         :ok <- File.rename(staging, path) do
      File.touch!(path)
      :ok
    else
      {:error, reason} ->
        Log.line(
          "volume.unkept",
          :warning,
          "could not keep #{dir} as #{path}, so the next job starts colder: #{inspect(reason)}",
          job_id: job_id
        )

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

  # The worker's own clone, into an empty volume of its own making, and the job's user's the
  # moment the checkout is in it.
  #
  # **The volume comes first, and that is the point.** `git clone` is happy with a directory that
  # already exists as long as it is empty, and a worktree the clone created itself is a plain
  # directory — which `promote/3` cannot snapshot, so a ticket whose first job here was a cold
  # clone never got a template and every job on it cloned cold again, for the whole life of the
  # ticket. The warm paths never had this: `from_volume/5` snapshots *into* `dir`, so there the
  # worktree is a volume before git sees it.
  #
  # **And a failure takes the volume with it**, as `from_volume/5`'s does. `git clone` removes the
  # directory only when git made it, so a clone that fails would otherwise leave one behind — and
  # `prepare/3` reads a worktree that is already there as an unfinished run's own and refreshes
  # it, so that leftover would send this job's next attempt past the ticket's template and into a
  # cold clone again. Nothing of anyone's is in it to lose: `clone/3` is reached only when `dir`
  # did not exist. Nothing sweeps `worktrees/*` to clear it either — `Dir.sweep/2` is given
  # `jobs/` and `sweep/2` here reads `volumes/ticket/*`.
  defp clone(assignment, dir, user) do
    volume(dir, assignment["job_id"])

    with :ok <- Checkout.ensure(checkout_opts(assignment, dir, user, [])),
         :ok <- Slice.own(user, [dir]) do
      {:ok, dir}
    else
      {:error, reason} ->
        Volume.impl().delete(dir)
        {:error, reason}
    end
  end

  # Best effort, like every other volume operation here and for the same reason: a volume is
  # warmth, and warmth is not correctness. A machine that will not make one — a root that is not
  # btrfs, a full disk — costs this ticket's next job a cold start, and failing this job instead
  # would cost it the run. `git clone` makes the directory itself when this leaves none.
  defp volume(dir, job_id) do
    case Volume.impl().create(dir) do
      :ok ->
        :ok

      {:error, reason} ->
        Log.line(
          "volume.uncreated",
          :warning,
          "could not make #{dir} a volume, so the next job starts colder: #{inspect(reason)}",
          job_id: job_id
        )
    end
  end

  defp checkout_opts(assignment, dir, user, extra) do
    git = assignment["git"]

    Keyword.merge(
      [
        dir: dir,
        url: git["url"],
        branch: git["branch"],
        token: git["token"],
        resume: assignment["resume_session"] != nil,
        default: git["default_branch"],
        as: Slice.as_user(user)
      ],
      extra
    )
  end

  defp maybe_push(_git, _dir, false, _as), do: :ok

  defp maybe_push(git, dir, true, as) do
    push = fn -> Checkout.push(dir: dir, branch: git["branch"], token: git["token"], as: as) end
    patiently(push, Application.get_env(:forge_worker, :push_patience_ms, @push_patience_ms))
  end

  @doc false
  # **A platform that is not there is waited for** (`docs/design/worker-channel.md` § A platform
  # restart). The branch is the platform's, so a run that ended while the platform restarted
  # could not push, and failed with its work unpushed — a job lost to a deploy. A push that did
  # not reach the platform (`unreachable?/1`) is tried again, backing off from a second to thirty,
  # until `patience` milliseconds have been waited; anything else — a credential refused, a ref
  # rejected — fails at once, because waiting does not change it. Public, with the push and the
  # sleep handed in, for its test.
  @spec patiently((-> :ok | {:error, term()}), non_neg_integer(), (pos_integer() -> any())) ::
          :ok | {:error, term()}
  def patiently(push, patience, sleep \\ &Process.sleep/1),
    do: patiently(push, patience, sleep, 0, 1_000)

  defp patiently(push, patience, sleep, waited, delay) do
    case push.() do
      {:error, {_code, out}} = error when is_binary(out) ->
        if waited < patience and unreachable?(out) do
          sleep.(delay)
          patiently(push, patience, sleep, waited + delay, min(delay * 2, 30_000))
        else
          error
        end

      other ->
        other
    end
  end

  # What git — through curl — says when the platform is not there to answer: no connection, a
  # name that does not resolve, a proxy's 502/503/504, a timeout. A refused credential is a 401 or
  # a 403 and is not among them.
  @unreachable [
    "failed to connect",
    "couldn't connect",
    "could not resolve host",
    "connection refused",
    "connection reset",
    "empty reply from server",
    "timed out",
    "returned error: 502",
    "returned error: 503",
    "returned error: 504"
  ]

  @doc false
  @spec unreachable?(String.t()) :: boolean()
  def unreachable?(out), do: String.contains?(String.downcase(out), @unreachable)

  defp remote(git), do: "origin/" <> git["branch"]

  # The default branch an integrating job or a conversation was given, as its checkout fetched it:
  # what the squash keeps as a second parent when the run merged it (`Checkout.squash/5`). Kind is
  # not asked here and is not knowable from an assignment's `git`; the platform decides which runs
  # are told a default branch (`Forge.Jobs.assignment/4`).
  defp merged(%{"default_branch" => default}) when is_binary(default),
    do: "refs/remotes/origin/" <> default

  defp merged(_git), do: nil
end
