defmodule ForgeWorker.Checkout do
  @moduledoc """
  The working copy a job runs in: cloned from the platform over smart HTTP with the job's own
  short-lived token, and pushed back when the job ends.

  This is the worker's git, not the platform's. It lives here rather than in the platform because
  the worker tier runs on a different machine, where a local worktree of the platform's bare
  repository is not available and this module is the whole of what changes: nothing.

  The credential never reaches argv. git is run with a `credential.helper` that prints
  `$FORGE_GIT_TOKEN`, and the variable is passed through git's own process environment only, which
  no other user can read — never an argument.

  **Git runs as whoever `as` says, and in a job's worktree that is the job's user.** A
  repository's hooks and configuration are programs — a `pre-commit`, a `core.fsmonitor` — and
  git runs them as whoever runs git; the job's user can write every one of them. So every
  function that runs git in a checkout takes `as` (`ForgeWorker.Slice.as_user/1`), and the one
  command that runs as the worker itself is the clone into a directory that does not exist yet,
  which nothing of a job has touched (`docs/design/worker-tier.md` § The job slice).

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
          identity: {String.t(), String.t()},
          default: String.t() | nil,
          as: ForgeWorker.Slice.as()
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

  `as` runs git in a checkout that is already there, and the checkout must already be the job's
  user's. A clone is the worker's own — into a directory nothing has touched — and the caller
  gives it to the user afterwards.

  `default` names the project's default branch, for an integrating job or a conversation: it is
  fetched as well, on every run, into `origin/<default>`, so the run can merge it
  (`docs/design/job-prompt.md` § Integrating the default branch,
  `docs/design/conversations.md` § Commits). Fetching is all: the job's token still writes nothing
  but its own branch.
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
  @spec remote(String.t(), String.t(), ForgeWorker.Slice.as()) :: :ok | {:error, term()}
  def remote(dir, url, as) do
    case git(dir, ["remote", "set-url", "origin", url], as: as) do
      {:ok, _out} ->
        :ok

      {:error, _reason} ->
        with {:ok, _out} <- git(dir, ["remote", "add", "origin", url], as: as), do: :ok
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

  **`keep` names a branch the run may have merged** — an integrating job's or a conversation's
  `origin/<default>`. When
  the run's head contains history of it that `base` does not — their merge base is no ancestor of
  `base` — that merge base is the squashed commit's second parent, so the squash keeps the merge:
  one parent would put the merged tree on the branch while losing that the default branch was
  merged, and the next `merge-tree` would start from the old merge base and find the same conflict
  (`docs/design/git-hosting.md` § Non-fast-forward on a ticket branch). The merge base and not
  `keep` itself, because a run resumed after the default branch moved has fetched a newer head
  than the one it merged. `base` stays the first parent whatever the
  run did, so a run that rebased instead of merging still leaves the commit before it an ancestor.

  **A conflict the run left in the tree is dealt with before the reset**, which git refuses
  outright while one is open — the squash used to die on it with the run's work neither committed
  nor explained (ticket 11). See `settle/4`: resolved — staged, as git asks, and carrying no
  conflict marker anywhere a run that merged would commit one — a merge is committed, so
  `merged/4` sees the default branch in the run's history as it would have. Unresolved,
  `{:error, {:merge_unresolved, paths}}`, and nothing is staged, committed or reset.
  """
  @spec squash(String.t(), String.t(), String.t(), ForgeWorker.Slice.as(), keyword()) ::
          {:ok, boolean()} | {:error, term()}
  def squash(dir, base, message, as, opts \\ []) do
    keep = Keyword.get(opts, :keep)

    with :ok <- settle(dir, base, keep, as),
         {:ok, merged} <- merged(dir, base, keep, as),
         {:ok, _out} <- git(dir, ["reset", "--soft", base], as: as),
         {:ok, _out} <- git(dir, ["add", "-A"], as: as) do
      commit(dir, base, merged, message, as)
    end
  end

  # **Leaves the tree in a state `reset --soft` will accept, or refuses to touch it.**
  #
  # git refuses the reset on `is_merge() || unmerged_cache()` (`builtin/reset.c`), so both halves
  # are asked, and the sequencer's own state with them: a conflicted cherry-pick, rebase or revert
  # has no `MERGE_HEAD` and dies on the reset just the same, with the bare git error ticket 11 is
  # about.
  #
  # **An unresolved conflict is one the index still holds both sides of.** That is git's own
  # record, the thing the reset refuses on, and the only question that has an answer for every
  # path: resolving means editing *and* `git add`, which is what `git status` tells the agent to
  # do. **An edit left unstaged is not a resolution here**, deliberately — judging the content
  # instead needs a model the operation does not have for every path git will not show as text (a
  # binary conflict, a `-diff` or `binary` attribute), and reaches into files no conflict touched.
  # The cost is a run refused for a `git add` it did not do; the tree is untouched, so a
  # conversation's next turn can stage it, and the paths are named either way.
  #
  # **A tree carrying conflict markers is refused as well**, because `git add` on a conflicted
  # path clears the index's record without resolving anything: staging the markers and stopping is
  # the commonest reflex there is, and committing that put `<<<<<<< HEAD` on the branch *as the
  # merge's resolution*, second parent and all, which is the loss ticket 11 exists to stop made
  # permanent. **Asked whenever the run has a conflict open or a merge this squash will keep** —
  # the second half because `git commit` is what closes an operation, so an agent that committed
  # its markers leaves nothing open, and the worst case would be the one case never looked at.
  # Outside both it is not asked, so a repository whose own files show a conflict — a design note
  # about one — is asked about while it resolves or merges, and not on every run.
  defp settle(dir, base, keep, as) do
    with {:ok, false} <- unmerged?(dir, as) do
      settle(dir, base, keep, as, operation(dir, as))
    else
      {:ok, true} -> unresolved(dir, as)
      {:error, reason} -> {:error, reason}
    end
  end

  defp settle(dir, base, keep, as, operation) do
    with {:ok, keeping?} <- keeping?(dir, base, keep, as, operation),
         :ok <- unmarked(dir, as, operation != :none or keeping?) do
      commit_merge(dir, as, operation)
    end
  end

  # Whether this squash would keep a merge as a second parent, which is the other reason to ask
  # for markers. Asked only when nothing is open, because an open operation opens that gate by
  # itself; `merged/4` is asked again after `settle/4` because committing the merge is what makes
  # it findable at all.
  defp keeping?(_dir, _base, _keep, _as, operation) when operation != :none, do: {:ok, true}

  defp keeping?(dir, base, keep, as, _none) do
    with {:ok, merged} <- merged(dir, base, keep, as), do: {:ok, merged != nil}
  end

  defp unmarked(_dir, _as, false), do: :ok

  defp unmarked(dir, as, true) do
    with {:ok, false} <- marked?(dir, as) do
      :ok
    else
      {:ok, true} -> marked(dir, as)
      {:error, reason} -> {:error, reason}
    end
  end

  defp unresolved(dir, as) do
    with {:ok, paths} <- unmerged_paths(dir, as), do: {:error, {:merge_unresolved, paths}}
  end

  defp marked(dir, as) do
    with {:ok, paths} <- marked_paths(dir, as), do: {:error, {:merge_unresolved, paths}}
  end

  # The merge is committed because that commit is what `merged/4` reads the merged history from,
  # and what `reset --soft` needs gone. Nothing is staged first: `settle/5` is only reached with an
  # index that has nothing unmerged in it, so the resolution is already in there.
  defp commit_merge(dir, as, :merge) do
    with {:ok, _out} <- git(dir, ["commit", "--no-edit", "--quiet"], as: as), do: :ok
  end

  # A cherry-pick, a rebase or a revert has no second parent to keep, so an index with nothing
  # unmerged in it is the whole of what the reset needs from it; their own state is the agent's
  # business. Committing for these as well would be an **equivalent mutant** — the squash throws
  # that commit's tree away with its own `reset --soft` and keeps no second parent for it — so no
  # test can tell, and none should be written for it.
  defp commit_merge(_dir, _as, _sequencer), do: :ok

  # Which operation the tree is in the middle of. A merge is apart from the other three because it
  # is the only one with a second parent to keep.
  #
  # **A rebase is asked for by its directory, not by `REBASE_HEAD`.** That ref outlives the rebase:
  # `git rebase --continue` finishes, `git status` says the branch is clean, and the ref is still
  # there — `reset --soft` clears `CHERRY_PICK_HEAD` and `REVERT_HEAD` but not that one. Asking it
  # said an operation was open for the rest of a worktree's life, which for a conversation is
  # every remaining turn: one file carrying all three markers — a `mergetool` `.orig`, a note about
  # a conflict — and nothing would ever be committed again. `.git/rebase-merge` and
  # `.git/rebase-apply` are git's own in-progress test (`wt_status_get_state`), and they go when
  # the rebase does.
  @sequencer ["CHERRY_PICK_HEAD", "REVERT_HEAD"]

  defp operation(dir, as) do
    cond do
      head?(dir, as, "MERGE_HEAD") -> :merge
      Enum.any?(@sequencer, &head?(dir, as, &1)) -> :sequencer
      rebasing?(dir, as) -> :sequencer
      true -> :none
    end
  end

  defp head?(dir, as, ref),
    do: match?({:ok, _sha}, git(dir, ["rev-parse", "-q", "--verify", ref], as: as))

  # The paths are git's own, from `--git-path`; the stat is the worker's, and it is the one thing
  # here that runs no program the job's user could have written, which is what `as` is for
  # everywhere else.
  defp rebasing?(dir, as) do
    case git(dir, ["rev-parse", "--git-path", "rebase-merge", "--git-path", "rebase-apply"],
           as: as
         ) do
      {:ok, out} ->
        out |> String.split("\n", trim: true) |> Enum.any?(&File.dir?(Path.expand(&1, dir)))

      {:error, _reason} ->
        false
    end
  end

  # **A verdict is an exit status; a name is for the message.** `git/3` folds stderr into stdout,
  # so whatever git chatters — a `core.fsmonitor` that writes there, a file in the tree it cannot
  # stat — arrives mixed into the answer. An exit status cannot be polluted that way, so every
  # decision below is one, and the names are read out of the same output only for the reason a
  # person reads: a line git wrote to stderr costs a name there and can change nothing else.
  defp unmerged?(dir, as) do
    case git(dir, ["diff", "--quiet", "--diff-filter=U"], as: as) do
      {:ok, _none} -> {:ok, false}
      {:error, {1, _some}} -> {:ok, true}
      {:error, reason} -> {:error, reason}
    end
  end

  # **All three of git's markers, in one file**: a single line of seven `=` is a Markdown heading
  # underline, and refusing a run for one would lose a turn's work over a file nothing conflicted
  # in. Asked of the worktree *and* its untracked files, which is what `add -A` will stage and so
  # the bytes the commit would carry — `git mergetool` leaves its `.orig` untracked, and a path
  # staged as deleted is still on disk.
  #
  # **`-G` because the dialect would otherwise be the repository's to choose.** `grep.patternType`
  # is read from a config the job's user writes, and `fixed` turns every pattern here into a
  # literal — `^` included — so nothing matched and a conflicted tree was called resolved. A value
  # git itself refuses still fails the run, which is a refusal that says why rather than a pass.
  # Nothing else is passed: `-a` *looked* load-bearing and is not, because `-l` lists a binary file
  # it matched either way — what would hide a path is `-I`, and that is not passed.
  @markers ["-e", "^<<<<<<< ", "-e", "^=======", "-e", "^>>>>>>> "]
  @grep ["grep", "-G", "--untracked", "--all-match"]

  defp marked?(dir, as) do
    case git(dir, @grep ++ ["--quiet"] ++ @markers, as: as) do
      {:ok, _found} -> {:ok, true}
      {:error, {1, _none}} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  # Sorted, which **no test can tell** from its absence: `git grep` has printed these in byte
  # order in every arrangement tried — tracked beside untracked, upper case beside lower — so it
  # is an equivalent mutant. It stays because the order a person reads should not rest on that,
  # and because the list beside it is sorted for a reason that is written down.
  defp marked_paths(dir, as) do
    with {:ok, out} <- git(dir, @grep ++ ["-l", "-z"] ++ @markers, as: as) do
      {:ok, out |> records() |> Enum.filter(&path?/1) |> Enum.sort()}
    end
  end

  # One path per conflict, out of the three stages the index holds it at. `-z`, because `ls-files`
  # quotes a path with a newline in it otherwise and this one is printed for a person to read. The
  # sort here *is* an equivalent mutant — the index is ordered by path, byte for byte as
  # `Enum.sort/1` is — and it stays so that both lists read the same way.
  @stage ~r/\A\d+ [0-9a-f]+ [123]\t(?<path>.+)\z/s

  defp unmerged_paths(dir, as) do
    with {:ok, out} <- git(dir, ["ls-files", "-z", "--unmerged"], as: as) do
      {:ok, out |> records() |> Enum.flat_map(&stage_path/1) |> Enum.uniq() |> Enum.sort()}
    end
  end

  defp records(out), do: String.split(out, <<0>>, trim: true)

  defp stage_path(record), do: Regex.run(@stage, record, capture: ["path"]) || []

  # A path git printed, as against a line it chattered into the same stream: `-z` ends a path with
  # a NUL and nothing else, so a record carrying a newline is not one.
  defp path?(record), do: record != "" and not String.contains?(record, "\n")

  # The commit to keep as a second parent, or nil: the newest of `keep`'s history the run's head
  # contains, when `base` does not contain it. Asked before the reset, while `HEAD` is the run's.
  defp merged(_dir, _base, nil, _as), do: {:ok, nil}

  defp merged(dir, base, keep, as) do
    case git(dir, ["merge-base", "HEAD", keep], as: as) do
      {:ok, out} ->
        sha = String.trim(out)
        if ancestor?(dir, sha, base, as), do: {:ok, nil}, else: {:ok, sha}

      # `keep` not fetched, or nothing in common with the run: nothing of it to keep. No test reaches
      # it, and failing here instead is an equivalent mutant: `keep` is set only for a checkout
      # whose `ensure/1` fetched it, and a ticket branch is cut from the branch it names.
      {:error, _none} ->
        {:ok, nil}
    end
  end

  defp ancestor?(dir, ancestor, of, as),
    do: match?({:ok, _out}, git(dir, ["merge-base", "--is-ancestor", ancestor, of], as: as))

  # With a merged commit, always a commit, and written with both parents: the merge is the point
  # even when the tree it leaves is the one `base` had.
  defp commit(dir, _base, nil, message, as), do: commit(dir, message, as)

  defp commit(dir, base, merged, message, as) do
    with {:ok, tree} <- git(dir, ["write-tree"], as: as),
         {:ok, sha} <-
           git(
             dir,
             ["commit-tree", String.trim(tree), "-p", base, "-p", merged, "-m", message],
             as: as
           ),
         {:ok, _out} <- git(dir, ["reset", "--soft", String.trim(sha)], as: as) do
      {:ok, true}
    end
  end

  # A non-zero status from `diff --cached --quiet` means something is staged, which is the only
  # reason to make a commit at all.
  defp commit(dir, message, as) do
    case git(dir, ["diff", "--cached", "--quiet"], as: as) do
      {:ok, _out} ->
        {:ok, false}

      {:error, _reason} ->
        with {:ok, _out} <- git(dir, ["commit", "--quiet", "-m", message], as: as),
             do: {:ok, true}
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

  @doc """
  Puts the checkout on `sha`, detached, with the working tree reset to it and the untracked files
  kept — what a command runs against (`docs/design/commands.md` § The ensured commit). The commit
  is on the branch `ensure/1` fetched, because the job that invoked it pushed it there before it
  parked; a sha the fetch did not bring is refused rather than looked for elsewhere.
  """
  @spec detach(String.t(), String.t(), ForgeWorker.Slice.as()) :: :ok | {:error, term()}
  def detach(dir, sha, as) do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/, sha) do
      with {:ok, _out} <- git(dir, ["checkout", "--quiet", "--detach", sha], as: as),
           {:ok, _out} <- git(dir, ["reset", "--quiet", "--hard", sha], as: as) do
        :ok
      end
    else
      {:error, {:not_a_commit, sha}}
    end
  end

  @doc "The commit the checkout is on."
  @spec head(String.t(), ForgeWorker.Slice.as()) :: {:ok, String.t()} | {:error, term()}
  def head(dir, as), do: rev(dir, "HEAD", as)

  @doc "The commit `ref` names in this checkout."
  @spec rev(String.t(), String.t(), ForgeWorker.Slice.as()) ::
          {:ok, String.t()} | {:error, term()}
  def rev(dir, ref, as) do
    with {:ok, out} <- git(dir, ["rev-parse", ref], as: as), do: {:ok, String.trim(out)}
  end

  # The worker's own, and the only git that is: `dir` does not exist yet, so there is no hook or
  # configuration in it that anybody but git wrote. `as` is dropped rather than used — the job's
  # user cannot write the directory the clone is made in.
  defp clone(dir, opts) do
    url = Keyword.fetch!(opts, :url)
    branch = Keyword.fetch!(opts, :branch)
    File.mkdir_p!(Path.dirname(dir))
    opts = Keyword.put(opts, :as, &worker/2)

    args = ["clone", "--quiet", "--branch", branch, "--single-branch", url, dir]

    with {:ok, _out} <- git(Path.dirname(dir), args, opts),
         :ok <- identity(dir, opts) do
      fetch_default(dir, opts)
    end
  end

  defp refresh(dir, opts) do
    branch = Keyword.fetch!(opts, :branch)

    with {:ok, _out} <- git(dir, ["fetch", "--quiet", "origin", branch], opts),
         :ok <- identity(dir, opts),
         :ok <- reset_unless_resuming(dir, branch, opts) do
      # Last, because it writes FETCH_HEAD too, and the reset is to the branch's.
      fetch_default(dir, opts)
    end
  end

  defp reset_unless_resuming(dir, branch, opts) do
    if Keyword.get(opts, :resume, false),
      do: :ok,
      else: reset(dir, branch, Keyword.get(opts, :clean, true), opts[:as])
  end

  # `-B` rather than a bare reset: a snapshot of a seed is on whatever commit the seed was
  # built at, and often not on this branch at all.
  defp reset(dir, branch, clean?, as) do
    with {:ok, _out} <- git(dir, ["checkout", "--quiet", "-B", branch, "FETCH_HEAD"], as: as),
         {:ok, _out} <- git(dir, ["reset", "--quiet", "--hard", "FETCH_HEAD"], as: as),
         {:ok, _out} <- maybe_clean(dir, clean?, as) do
      :ok
    end
  end

  # Into `origin/<default>` and nowhere else, by an explicit refspec: the clone is single-branch,
  # so nothing configured would fetch it. The name becomes part of a refspec, so it is matched
  # rather than trusted — a `:` in it would name a second ref to write.
  defp fetch_default(dir, opts) do
    case Keyword.get(opts, :default) do
      nil -> :ok
      branch -> fetch_default(dir, branch, branch_name?(branch), opts)
    end
  end

  defp fetch_default(dir, branch, true = _name?, opts) do
    refspec = "+refs/heads/#{branch}:refs/remotes/origin/#{branch}"
    with {:ok, _out} <- git(dir, ["fetch", "--quiet", "origin", refspec], opts), do: :ok
  end

  defp fetch_default(_dir, branch, false = _name?, _opts), do: {:error, {:not_a_branch, branch}}

  # `..` is refused here and by git, which will not fetch into a ref named with one, so dropping
  # this half is an equivalent mutant no test can tell; it stays so the refusal is ours and says so.
  defp branch_name?(name),
    do: Regex.match?(~r{^[A-Za-z0-9][A-Za-z0-9._/-]*$}, name) and not String.contains?(name, "..")

  defp maybe_clean(_dir, false, _as), do: {:ok, ""}
  defp maybe_clean(dir, true, as), do: git(dir, ["clean", "--quiet", "-fd"], as: as)

  # The harness runs with a private HOME, so a fresh clone has no global identity and the agent's
  # first commit would fail with git's "please tell me who you are".
  defp identity(dir, opts) do
    {name, email} = Keyword.get(opts, :identity, {"forge", "forge@localhost"})

    with {:ok, _out} <- git(dir, ["config", "--local", "user.name", name], opts),
         {:ok, _out} <- git(dir, ["config", "--local", "user.email", email], opts) do
      :ok
    end
  end

  # `as` is required rather than defaulted: a call that forgot it would be git run as root in a
  # job's tree, which is the one thing this module is careful never to do.
  defp git(dir, args, opts) do
    as = Keyword.fetch!(opts, :as)

    {executable, args} =
      as.("git", ["-c", "credential.helper=", "-c", "credential.helper=" <> @helper] ++ args)

    env =
      [{"GIT_TERMINAL_PROMPT", "0"}] ++
        case Keyword.get(opts, :token) do
          nil -> []
          token when is_function(token, 0) -> [{"FORGE_GIT_TOKEN", token.()}]
          token when is_binary(token) -> [{"FORGE_GIT_TOKEN", token}]
        end

    case System.cmd(executable, args, cd: dir, stderr_to_stdout: true, env: env) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {code, redact(out)}}
    end
  end

  # git echoes the remote URL in its errors, and a caller may have put the token in one. The
  # error becomes the job's failure reason, crosses the channel and is written to the platform's
  # event log, so a credential that reaches here is recorded permanently.
  #
  # Defence in depth, and deliberately untested: git 2.55 already strips the userinfo from the
  # URL it prints, and no failure that could be produced — refused connection, unresolvable host,
  # rejected port, unknown protocol, over http and ssh — puts the credential in the output at
  # all. A mutation sweep flagged this line as unprotected; it is an equivalent mutant against
  # this git, not a missing test, and writing one would mean asserting a string git never emits.
  # Kept because older git did echo credentials and the cost of being wrong here is a token in a
  # log for ever.
  defp worker(executable, args), do: {executable, args}

  defp redact(out), do: String.replace(out, ~r{//[^/@\s]+@}, "//")
end
