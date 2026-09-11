# project-forge

A self-hosted platform that moves software tickets through a per-repository, statechart-defined lifecycle, executed by disposable agent jobs on an elastic worker tier. Verified, immutable, versioned artifacts are the handoff contract between steps, and the operator's attention is treated as the scarce resource: nothing reaches them until it has been verified, and what does reach them arrives as an ordered queue of decisions.

The concept is described in full in [docs/vision.md](docs/vision.md). Settled decisions, open questions, required measurements and prior-art findings are recorded alongside it in `docs/`. The proof-of-concept plan is [docs/poc-plan.md](docs/poc-plan.md).

**Status:** skeleton only. The stack is decided: Elixir, with Phoenix and LiveView for the platform and a standalone Elixir release for the worker. Further PoC-scoped choices are listed in [docs/decisions.md](docs/decisions.md). No feature has been built yet.

## Layout

| Directory | Mix app | Purpose |
|---|---|---|
| `core/` | `forge_core` | Workflow parser, event schema, artifact types. Shared by path dependency. |
| `platform/` | `forge` | Phoenix + LiveView platform: orchestrator, artifact store, queue UI. |
| `worker/` | `forge_worker` | Standalone release for the worker-side agent manager. |

## Getting started

Requires Nix with flakes. Postgres is included in the devshell; point `platform/config/dev.exs` at whichever instance you run.

```
nix develop            # or `direnv allow`
bin/check              # quality gate: compile, format, credo, tests, in every project
cd platform && mix setup && mix phx.server
```

Releases build with `nix build .#forge` and `nix build .#forge-worker`.

