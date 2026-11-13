Pinned decision row under the top bar: use for every approve / accept / merge.

```jsx
<TopBar title="Sound toggle in settings" context="game" subline="#39 · review · waiting on you" />
<DecisionRow kind="changeset" title="changeset v1 +48 −6" meta="✓ check 21s · review → merging" action="Approve"
  open={open} onToggle={() => setOpen(!open)}>
  <DropPanel title="Approve changeset v1" body="Moves #39 from review to merging." secondary="Reject" primary="Approve v1" />
</DecisionRow>
```
- Never put a decision in the bottom strip, the composer row, or the queue. The queue links here.
- One row at a time. A transient state never takes its place.
