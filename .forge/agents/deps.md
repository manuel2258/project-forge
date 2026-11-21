# Dependencies

A scheduled ticket with nobody to ask. Bring the pinned dependencies up to date and keep the
project working. Read `CLAUDE.md` first: **versions are pinned and a constraint is never loosened to
get something to compile**; a bump raises a pin to an exact newer version, and the commit message
says why each dependency moved. Files people attached are in `$FORGE_JOB/attachments/`.

If `report.md` is present a review sent an earlier attempt back, and its findings are this
attempt's criteria; `feedback.md`, from a person, comes above it.

## What to look at

- Hex packages in `core/`, `platform/` and `worker/`: `mix hex.outdated` in each, with `MIX_HOME`
  and `HEX_HOME` exported as `CLAUDE.md` says.
- `flake.lock`: `nix flake update` is allowed for one input at a time, `nixpkgs` last.
- What the scripts fetch: container base images, tool versions in `.forge/commands/` and `bin/`.

## First: audit. Bumps that fix a vulnerability are high priority

**Before any other bump**, run `mix hex.audit` in `core/`, `platform/` and `worker/`, and
look up each locked package in OSV
(`curl -s https://api.osv.dev/v1/query -d '{"package":{"ecosystem":"Hex","name":"…","version":"…"}}'`).
A retired package or one with an advisory is bumped **first**, in its own commit that names the
retirement or the advisory id, whatever else is held back, and takes the smallest version that
fixes it if the latest brings a major change. When the fix needs a decision (no fixed version, a
major that changes promised behaviour), propose a ticket and say in `implementation.md` that the
advisory is still open. State what the audit could not check (nixpkgs has no good feed) and re-run
`mix hex.audit` at the end: it should be clean of what you could fix.

## How to bump

- **One group at a time**, a group being packages that move together (Phoenix with LiveView and its
  JS, Ecto with its adapter, the Credo and formatter tools). One commit per group, each passing
  `mix test` of the project it touches before the next begins.
- **Read before you raise**: the package's changelog between the two versions, and `deps/<name>`
  for any API you are not certain of. A major version, a removed function, a changed default or a
  new transitive dependency is named in the commit message.
- **Leave out what needs a decision**: a major bump that changes behaviour the notes promise, a
  licence change, a package that is unmaintained. Propose a ticket under `out/proposals/` with
  what you found; do not half-do it.
- A bump that breaks code is fixed in the same commit, and a test you must change to make it pass
  is a finding to explain, not a thing to quietly edit (`CLAUDE.md` § Testing). Never lower the
  coverage floor.
- Do not add or remove a dependency. That is not a bump.

## Finishing

Follow `agents/implement.md` for running the gate and checking your claims with a subagent. Commit
as `build(<scope>): bump …`. Write `implementation.md`: each group moved (from, to, why), what
broke and how you fixed it, what you left out and why, and which advisories are now closed or still
open. If everything is current, say so, commit nothing, and write that.
