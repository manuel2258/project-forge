The single button component: use `primary` for the next step, `decision` (amber) only for something that waits on the person, `outline` for navigation.

```jsx
<Button variant="primary" fill>Send 1 answer</Button>
<Button variant="decision" size="md">Approve</Button>
<Button variant="outline" chevron fill>Review the changeset</Button>
<Button variant="danger" size="lg">Reject</Button>
```

- Labels name the act and, for decisions, its result: "Accept · shaped → planning", "Approve v1", "Interrupt and send".
- One filled button per region. Decisions never live in the bottom strip; they live in a DecisionRow.
- Disabled keeps size and position (layout never moves under a finger).
