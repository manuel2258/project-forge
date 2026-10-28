# Rebase

The default branch moved since this ticket's base, and the merge this ticket was approved for
conflicted. Your checkout carries both: the ticket's branch and the default branch's current
head. The manifest's § Integrating says what conflicted and what has landed meanwhile.

**Rebasing is what this state is for; a merge is how you do it.** Bring the ticket up onto the
current default branch by merging it in, exactly as the manifest says — `git merge`, never
`git rebase` and never a reset — because the commit this ticket's merge was last tried for has to
stay an ancestor of what you leave. None of that reaches `main`'s history, which takes each ticket
as one squashed commit, so there the result is the same as a rebase.

Resolve every conflict by keeping both sides' intent, never by silently discarding one. Read what
the other side was for before deciding: the manifest names the commits that landed, and
`$FORGE_JOB/archive/` has the documents of the tickets that wrote them. Re-run whichever part of the
implementation the resolution touches, so the result still satisfies `refinement.md`'s acceptance
criteria and not just what merged cleanly.

## `done` merges with nobody looking

**`done` puts the ticket straight back into the merge queue, in its old place, and it lands on
`main` as soon as it checks clean.** Nobody reads what you did first. A person approved this
changeset once; ending on `done` is you saying the rebased one is still the change they approved.
So end on `done` only when every one of these holds, and on `needs_review` otherwise:

1. **The engine sent the ticket here.** The manifest's line on how the ticket arrived says who took
   the transition. *The engine* is the merge queue finding a conflict in a ticket a person
   approved. *A person* is someone sending a ticket here by hand, from a notice that it no longer
   merges or from a stuck rebase, and that may be a ticket nobody has approved at all — so it is
   `needs_review` whatever else is true.
2. **Every resolution is mechanical**: both sides kept, with nothing to choose between. Two imports
   kept, two entries added to one list, the new code calling a function by the name the other side
   renamed it to. Where keeping both meant deciding what the code should now do — both sides changed
   the same logic, or one side removed what the other relies on — that is a judgement a reviewer
   should see.
3. **The gate passes on the resolved commit.** Commit the merge, invoke `check`, and read its log.
   You may fix what it finds only where the fix is as mechanical as the resolutions: a call site of
   something the other side renamed, a test fixture missing a field the other side added. Exit
   status 2 is the machine saying the gate could not run, which is not a pass. Three invocations at
   most; a gate still failing after that is `needs_review`.
4. **Nothing else changed.** What you leave differs from a plain merge of the two sides only by the
   resolutions and those fixes — no cleanup, no improvement, no reformatting of lines nobody
   conflicted on.

`needs_review` takes the ticket out of the queue and back through `checking`, `reviewing` and
`presenting` to a person, who approves it again. The review reads your resolutions and not the
change the person already approved (`agents/review.md` § After a rebase, review the rebase), so it
costs little; merging a resolution you were unsure of costs more, and the person has no chance to
see it first.

## What to write

`rebase.md`, with front matter `outcome: done` or `outcome: needs_review`. Then each conflicted path
and how it was resolved — what each side was doing and why the resolution keeps both — what the
gate said, and for `needs_review`, which of the four conditions above did not hold. That last part
is what `reviewing` reads first, so make it specific. Then the changeset.

Where both sides changed the same logic and keeping either would lose behaviour, say so in
`rebase.md` rather than guessing, and end on `needs_review`.
