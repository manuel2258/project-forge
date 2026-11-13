Panel that drops from a bar: confirmation for decisions, menus, details.

```jsx
<DropPanel title="Accept step shaping" body="Ends the chat step, approves brief.md v2 and moves to planning."
  warning={{ title: '1 open question will stay unanswered', body: 'Planning starts from brief.md v2 as written.' }}
  secondary="Answer first" primary="Accept anyway" />
```
The confirming button has the same colour as the button that opened it. Never ask for answers inside it.
