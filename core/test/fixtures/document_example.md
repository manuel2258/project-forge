---
outcome: done
summary: Persist the high score table.
---
# Plan

Persist the high score table between runs.

```question
key: storage-backend
anchor: "Persist the high score table"
text: Local file or the existing SQLite database?
options: [local-file, sqlite]
default: sqlite
blocking: false
assumption: sqlite
```

Some code the plan refers to:

````markdown
```question
key: not-a-question
text: this is inside a code block and must be ignored
```
````

```rust
fn main() {}
```

```question
key: score-format
text: Which score fields matter for the table?
blocking: true
```
