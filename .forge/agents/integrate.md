# Integrate

The default branch moved since this ticket's base, and the merge this ticket was approved for
conflicted. Your checkout carries both: the ticket's branch and the default branch's current
head.

Merge the default branch into the ticket branch — never rebase, which would detach the merge this
ticket already had approved — and resolve every conflict by keeping both sides' intent, never by
discarding one silently. Where both sides changed the same logic and keeping either would lose
behaviour, say so in `integration.md` rather than guessing.

Re-run whichever part of `plan.md` the resolution touches, so the result is still what the plan
describes and not just what merged cleanly. Produce `integration.md` — what conflicted and how it
was resolved — and the changeset.
