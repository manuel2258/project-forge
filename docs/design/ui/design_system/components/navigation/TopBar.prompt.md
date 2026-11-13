Top bar for every phone screen; includes the queue button and both usage lines.

```jsx
<TopBar title="Persist the high score table" context="game"
  subline={<><span style={{opacity:.6}}>#41 · </span><span style={{color:'var(--info)'}}>▸</span> implementing</>} />
<TopBar title="Queue" menu left={null} subline="4 decisions" />
<TopBar title="…" disconnected="retrying in 4s · last update 12s ago" />
```
- A DecisionRow, if any, goes directly under it.
- Hide usage (`usage={null}`) only on modal screens (sign-in, shown-once token).
