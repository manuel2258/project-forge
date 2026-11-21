# Advisory

A scheduled ticket with nobody to ask. **You change no code and open no branch.** You write
`advisory.md` and, for what is worth doing, propose tickets. Read `CLAUDE.md`,
`docs/decisions.md` and `docs/vision.md` first, then `$FORGE_JOB/tickets/index.md` and the
archive index so that you propose nothing that already exists, was declined, or was decided against.
Last week's report is in `$FORGE_JOB/archive/`: say what is new since, and only that.

## Part 1 — Vulnerabilities

For the Hex packages in `core/`, `platform/` and `worker/` (every `mix.lock`), the inputs of
`flake.lock`, and the images and tools the scripts fetch:

- `mix hex.audit` in each project, with `MIX_HOME` and `HEX_HOME` exported as `CLAUDE.md` says.
- Known advisories: query OSV (`https://api.osv.dev/v1/query`, ecosystem `Hex`) for each locked
  package and version, and the GitHub advisory database for Elixir and Erlang. State what you could
  not check (nixpkgs has no good feed; say so) rather than implying a clean result.
- For each finding: package, locked version, advisory id and link, severity, **whether forge
  reaches the vulnerable code** (read how it is used), and the fixed version.
- A reachable or high-severity one is a ticket of the `deps` type (see `tickets/index.md`) at
  once; the rest are listed in the report and wait for the monthly bump.

## Part 2 — Claude Code and AI developments

Search the web for what changed in the last few weeks in Claude Code (releases, hooks, skills,
subagents, plugins, settings, SDK), Codex CLI, the Anthropic and OpenAI APIs and the Model Context
Protocol, and in agent practice generally. Prefer first-party sources: changelogs, docs, release
notes, engineering posts; name the URL and date of each claim, and say plainly when you only
have a secondary source.

For each item: what it is, **what forge would gain**, what it would cost, which design note or
decision it touches the notes under `docs/design/` (`codex.md`, `capacity.md`, `credentials.md`,
`conversations.md`, …), and whether a decision in `docs/decisions.md` rules it out. Rank by value
against cost. Be sceptical: a trend that forge does not need is a finding too, one line, and
a feature forge already has is not news.

## Output

`advisory.md`: the two parts, newest and most important first, each item with its sources, then
**what you could not check**. A proposal for each item worth a ticket, at most five, under
`out/proposals/` (read the preamble's § Proposing a ticket): title, why now, the evidence, and the
smallest version that would be worth doing. If nothing is worth a ticket, say so; do not file for
the sake of it. Say in `advisory.md` which proposals you wrote.

If you have no web access, say so at the top of `advisory.md` and do Part 1 only from what is in the
checkout. Do not fill Part 2 from memory.
