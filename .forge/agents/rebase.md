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

## Merge it: `done` is the default

**`done` puts the ticket straight back into the merge queue, in its old place, and it lands on
`main` as soon as it checks clean.** A person approved this changeset once, and the review loop a
`needs_review` starts costs hours of waiting and a review's worth of tokens, to read a resolution
that is almost always smaller than the change they already approved. So **lean toward `done`**:
end on it whenever you have kept both sides' intent and the gate passes on what you leave. Ask
whether the person would be surprised by the result, not whether you made a choice. Resolving a
conflict is making choices; that alone is not a reason to send it back.

End on `needs_review` only when one of these holds:

1. **The engine did not send the ticket here.** The manifest's line on how the ticket arrived says
   who took the transition. *The engine* is the merge queue finding a conflict in a ticket a person
   approved. *A person* is someone sending a ticket here by hand, and that may be a ticket nobody
   has approved at all — so it is `needs_review` whatever else is true.
2. **The gate does not pass on the resolved commit.** Commit the merge, invoke `check` once, and
   read its log. You may fix what it finds where the fix follows from the other side's change: a
   call site of something it renamed, a fixture missing a field it added, a test that asserted what
   the other side deliberately changed. Exit status 2 is the machine saying the gate could not run,
   which is not a pass. Three invocations at most; a gate still failing after that is
   `needs_review`.
3. **Keeping both sides would lose behaviour that a person approved**, or you could not tell which
   side's behaviour the result should have — the two sides changed the same logic to do different
   things, or one side removed what the other relies on and nothing in `refinement.md` says which
   wins. If you can say in a sentence why your resolution satisfies both, it is not this case.
4. **You changed something that is not a resolution or a fix the gate demanded** — cleanup,
   improvement, reformatting of lines nobody conflicted on. Take it back out rather than sending the
   ticket to review for it.

`needs_review` takes the ticket out of the queue and back through `checking`, `reviewing` and
`presenting` to a person, who approves it again. Use it for a real doubt, and say what the doubt is;
do not use it as insurance.

## What to write

`rebase.md`, with front matter `outcome: done` or `outcome: needs_review`. Then each conflicted path
and how it was resolved — what each side was doing and why the resolution keeps both — what the
gate said, and for `needs_review`, which of the conditions above applied. That last part
is what `reviewing` reads first, so make it specific. Then the changeset.

Where both sides changed the same logic and keeping either would lose behaviour, say so in
`rebase.md` rather than guessing, and end on `needs_review`.
