# project-forge

A self-hosted platform that moves software tickets through a per-repository, statechart-defined lifecycle, executed by disposable agent jobs on an elastic worker tier. Verified, immutable, versioned artifacts are the handoff contract between steps, and the operator's attention is treated as the scarce resource: nothing reaches them until it has been verified, and what does reach them arrives as an ordered queue of decisions.

The concept is described in full in [docs/vision.md](docs/vision.md). Settled decisions, open questions, required measurements and prior-art findings are recorded alongside it in `docs/`. The proof-of-concept plan is [docs/poc-plan.md](docs/poc-plan.md).

**Status:** nothing is implemented yet. The stack is decided: Elixir, with Phoenix and LiveView for the platform and a standalone Elixir release for the worker. Further PoC-scoped choices are listed in [docs/decisions.md](docs/decisions.md). This repository holds an idea and a plan, not code.
