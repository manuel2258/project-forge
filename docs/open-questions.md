# Open questions

These questions are open. They have not been answered and no recommendation is recorded.

- ~~Which credential funds execution.~~ **Answered structurally.** A credential is owned by a user
  and is either a subscription token or an API key; its owner assigns it to projects they are a
  member of, and a job picks one from its project's pool when it starts. Team use is real because
  each person brings their own, so subscription authentication's individual-use constraint is
  respected rather than worked around. The node's own token from the environment is not read.
  See `design/credentials.md`, `design/identity.md`
  § Credentials and `decisions.md` § Security and users. **Residual, narrower than the
  original:** a subscription credential assigned to a project other people work in runs their jobs
  on its owner's subscription. That is now an assignment its owner made rather than a side effect
  of sharing a machine, it does not arise until a second person exists on a node, and it is
  undecided.
- How structured questions are represented in a document.
- The idle period before a worker is destroyed. **Has an evidence-based default, not an answer.**
  M4 measured about 35 seconds from nothing to a machine that can build, and the node's
  `idle_period_ms` is five minutes on that basis (`measurements.md` § M4,
  `platform/config/config.exs`); a worker template may set its own. That cold start was local,
  with the seed and the Nix store arriving over loopback, and the closing step is to re-measure it
  on a provider. The idle time across real tickets, which `poc-plan.md` § How each open question is
  probed also asks for, is unrecorded.
- Branch granularity: one branch per job, or one per ticket with rebasing on conflict.
- Whether the build cache can be produced as a reproducible artifact rather than a maintained blob. Measured for one toolchain: M1 variant (a) built a cargo `target/` from the dependency closure alone with a Nix builder, and cargo rejected it outright — all 155 dependency crates rebuilt and the build cost what a cold one costs. Variant (c), a warm build directory copied from another checkout path, transplanted at 1.34× a warm local build. So for cargo the maintained blob is the form that works, which is the heavier storage model `poc-plan.md` § Risks names. One toolchain is not an answer, and the measurement closed with variant (b), a compilation cache read cold, unrun; no toolchain but cargo has been tried either. The question stays open, and what would move it is (b) on cargo — a content-keyed cache is the form most likely to transplant, and it would lighten the storage model again — or any second toolchain. See `measurements.md` § M1 and § What these measurements decided.
- Whether to adopt an existing self-hostable sandbox platform as the worker tier rather than building it. **Not reopened:** `poc-plan.md` reopens it only if milestone 3's thin version — systemd slices plus btrfs — failed, and it held. The isolation cross and milestone 3's demo each saw the one under a binding ceiling killed by its own cgroup while its neighbours finished (`measurements.md` § The isolation cross). No alternative has been evaluated.

## Probe notes

Evidence gathered against a running node, for the probes `poc-plan.md` attaches to a
milestone. Observations only: nothing here answers a question above or recommends anything.

### Question representation under real use

2026-09-12, first run of the loop outside the test suite: platform and embedded worker on one
Linux host, a small Python repository in a local bare repo, a two-job workflow, Claude Code
on a subscription credential.

- **Parse failures: none.** Every document produced by a job parsed, across 18 jobs (2 on
  Sonnet, 16 on Haiku). The only `invalid_document` and `error` outcomes seen were provoked
  deliberately by test workflows written to provoke them. No agent produced front matter or a
  `question` block that the parser rejected.
- **Taps per question.** One question arose from a real ticket rather than a contrived one:
  key `path-param`, on whether the persistence path should be an optional constructor
  argument or hard-coded. It carried two options and a default, so the queue offered two taps
  plus free text. Answered in one tap.
- **The blocking path works as designed.** A job that emitted `blocking: true` went to
  `waiting`, its OS process ended, the question entered the queue, and answering it resumed
  the same job and attempt with `--resume` on the recorded session. An agent that kept the
  same question block in the resumed document was not asked again, which is the behaviour
  `job-prompt.md` specifies.
- **Non-blocking answers reach the next job.** The answer was written as an `answers.md`
  version and appeared in the next job's runtime manifest with the answered key, and that
  job's output referred to it.
- **Cases the format could not express: no evidence either way.** One real question is not a
  sample. The format was sufficient for it, which says little; the probe needs tickets whose
  questions are not a two-way choice with an obvious default. This is the gap to close before
  the question above can be answered.

### Spend caps, and one runaway job stopped

2026-09-13, milestone 4. The definition of usable asks for a cap to have stopped at least one
runaway job in testing. It has, though so far in the test suite rather than on a real ticket.

- **The mechanism is the harness's, not a meter of ours.** The provider streams no per-turn cost,
  so the platform has nothing to watch a running job against. What it does instead is hand the
  harness a smaller budget: the effective cost budget of a job is the least of what its state
  declared, what the ticket allowance has left and what the daily cap has left. A job on a ticket
  with $0.10 left is started with `--max-budget-usd 0.10` against a state that declared $0.50, the
  harness stops itself at that figure, and the ticket sticks. The wall clock is the platform's own
  coarse stop beside it.
- **Two caps, two treatments**, per `capacity.md`: a ticket allowance sticks the ticket into the
  queue, a daily cap pauses the node and puts nothing in the queue. Both are asked in
  `Forge.Jobs.assign/2`, the one place every billed invocation passes.
- **What is still unobserved:** whether the harness honours `--max-budget-usd` as precisely as the
  test's stand-in does, and what a real overshoot costs. That is dogfooding's to record.

### Branch granularity, mechanically enforced

2026-09-13, milestone 4. The question is still open — it needs conflicts and rebases from real
tickets — but the discipline is no longer a convention. A job reaches its repository over the
platform's own git endpoint with a credential scoped to exactly one ref, and the repository's
`pre-receive` hook refuses anything else: another ticket's branch, a branch that is not
`ticket/<n>`, a deletion, or the default branch, which only the platform's own merge may write.
A rewrite of a ticket's own branch is allowed and noted, because a job squashes; what an approval
attaches to is the changeset's sha, and each merge attempt pins the commit it merges under
`refs/forge/approved/<n>` so a rewrite cannot lose it (`docs/design/git-hosting.md`
§ Non-fast-forward on a ticket branch).

### Provider-reported capacity

2026-09-12, read from the job transcripts the same node produced: 87 `rate_limit_event` messages
on the stream-json channel, all on a subscription credential.

- **The five-hour window is provider-reported.** Every event carried `rateLimitType: "five_hour"`
  and a `resetsAt` unix epoch. The window boundary and reset time do not have to be inferred from
  forge's own invocation record, which is what the operator UI's capacity readout assumed it would
  have to do.
- **Utilization is only reported once it matters.** `utilization` appeared on 21 of 87 — exactly
  the events with `status: "allowed_warning"`, which also carry `surpassedThreshold: 0.9`. The
  other 66 were `status: "allowed"` and carried no figure. Observed range where present: 0.92 to
  0.99.
- **No weekly event was seen.** `rateLimitType` was `five_hour` on all 87, so whether a weekly
  ceiling is reported at all is unobserved.
- **No rejecting status was seen.** Only `allowed` and `allowed_warning` occurred, so what the
  harness emits when a window is actually exhausted is unobserved — including whether the job
  fails, hibernates, or is refused before starting.
- The events were reaching the platform as `job.harness.unknown` with the raw line, per the note
  below; nothing was lost, and the payloads above were read back out of the stored transcripts.

### Message reliability

- **Web push: not exercised.** VAPID keys were never configured on this node and no browser
  subscribed, so neither a blocking-question push nor the daily digest has run. Milestone 2's
  demo — one blocking question arriving as a push, verified on the desktop browser — is what
  would produce this evidence; the phone is the closing step's.
- **The queue could be lost whole.** A ticket whose pinned workflow no longer parsed raised
  from the queue's own read path, so one such row returned 500 for the queue page and the
  queue API — for every ticket, not just that one. A pinned definition is validated at
  admission and kept as it was; it was then validated again on every read, so a rule added
  between milestones made it unreadable without any malformed data (0.16.0's `commit-message`
  rule did, and `Parser.from_pinned/1` now reads a pin without the validator). Fixed by degrading that ticket's detail instead of the
  page, but worth recording as the shape of failure this probe is looking for: the operator
  does not lose a message, they lose the whole queue.
- **Unknown harness messages degrade rather than drop.** Claude Code emits message types the
  event mapping does not know — `rate_limit_event` was among them until
  `design/credentials.md` mapped it — and these arrive as `job.harness.unknown` carrying the raw
  line, as `claude-code-events.md` requires. Nothing was dropped and nothing raised.
- **Client mistakes were reported as platform faults.** Several ordinary errors answered 500
  with no detail, which tells an API client nothing it can act on. Mapped to 4xx with a
  reason and a detail.
