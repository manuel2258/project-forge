# Prior art

Findings recorded at handover.

- Parallel worktree orchestrators are a crowded category. Several solve multi-harness support and human-gated milestones already.
- Declarative agent workflows in YAML, including human-in-the-loop pauses and checkpoint/resume, exist as shipped products — though aimed at general agent orchestration rather than a per-repository ticket lifecycle.
- Remote control of coding agents from a phone, with push notifications and one-tap approval, is a saturated space. This is the least differentiated part of the design.
- Ephemeral and self-hostable execution environments for agents are a mature commercial category and may be adoptable rather than rebuilt.
- Remote build offloading for Rust specifically is close to unserved.
- The combination that appears unbuilt: a per-repository ticket lifecycle, immutable versioned artifacts with per-version approval as the handoff contract, and an elastic self-hosted execution tier under one roof.
