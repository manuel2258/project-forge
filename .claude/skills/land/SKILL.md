---
name: land
description: Land the current branch on main as one squashed commit, fast-forward only, resolving conflicts on the way. No pull request.
---

# land

Work lands on `main` directly. One branch of work becomes one commit on `main`; the branch
is then reset onto the new `main` and stays the working branch. There are no pull requests
and no merge commits.

## Preconditions

- The working tree is clean (`git status --porcelain` prints nothing). Commit or stash first.
- The gate passes: `bin/check` from the repository root. A branch that does not pass is not
  landed.

## Steps

1. **Update main.**

   ```
   git fetch origin main
   ```

2. **Nothing to land?** If `git log origin/main..HEAD --oneline` is empty, stop and say so.

3. **Rebase onto main.**

   ```
   git rebase origin/main
   ```

   On a conflict: resolve it in the files, `git add` them, `git rebase --continue`; repeat
   until the rebase ends. Resolve by keeping both intents, never by discarding one side
   silently. Regenerate lockfiles and generated files with the project's tooling, not by
   hand. If both sides changed the same logic and keeping either loses behaviour, stop and
   ask. After any conflict, run `bin/check` again before going on.

4. **Squash into one commit.**

   ```
   git reset --soft origin/main
   git commit
   ```

   Write the message for the landed change as a whole, not a list of the squashed commits:
   a subject under 72 characters and a body saying what changed and why, including why any
   dependency was added. Keep the attribution trailers the session requires. Read the
   squashed messages first (`git log origin/main..HEAD@{1}`) so nothing they explained is
   lost.

5. **Fast-forward main.**

   ```
   git push origin HEAD:main
   ```

   Never `--force` here. If the push is rejected because `main` moved, go back to step 1;
   the squash commit rebases like any other.

6. **Reset the working branch onto main** so it continues from what just landed:

   ```
   git fetch origin main
   git reset --hard origin/main
   git push --force-with-lease origin HEAD
   ```

   The force is fine: the branch's only history is what `main` now carries.

7. **Report** the landed commit's hash and subject.
