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
options:
  - label: "Local file"
    detail: "Simple, but another thing to back up."
  - label: "SQLite database"
    detail: "The scores already live there."
    recommended: true
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
