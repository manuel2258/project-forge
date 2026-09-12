# Open questions

These questions are open. They have not been answered and no recommendation is recorded.

- Which credential funds execution. Subscription authentication is individual-use; metered API billing is not. This decides whether team use is real. Settled for the PoC: the operator's subscription token, by decision; the comparison is not run. Open for team use.
- How structured questions are represented in a document.
- The idle period before a worker is destroyed.
- Branch granularity: one branch per job, or one per ticket with rebasing on conflict.
- Whether the build cache can be produced as a reproducible artifact rather than a maintained blob. Measured for one toolchain: M1 variant (a) built a cargo `target/` from the dependency closure alone with a Nix builder, and cargo rejected it outright — all 155 dependency crates rebuilt and the build cost what a cold one costs. Variant (c), a warm build directory copied from another checkout path, transplanted at 1.34× a warm local build. So for cargo the maintained blob is the form that works, which is the heavier storage model `poc-plan.md` § Risks names. One toolchain is not an answer, and the measurement closed with variant (b), a compilation cache read cold, unrun; no toolchain but cargo has been tried either. The question stays open, and what would move it is (b) on cargo — a content-keyed cache is the form most likely to transplant, and it would lighten the storage model again — or any second toolchain. See `measurements.md` § M1 and § What these measurements decided.
- Whether to adopt an existing self-hostable sandbox platform as the worker tier rather than building it.

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
  subscribed, so neither a blocking-question push nor the daily digest has run. The phone
  demo milestone 2 calls for is what would produce this evidence.
- **The queue could be lost whole.** A ticket whose pinned workflow no longer parsed raised
  from the queue's own read path, so one such row returned 500 for the queue page and the
  queue API — for every ticket, not just that one. A pinned definition is validated at
  admission and kept as it was, while the validator's rules move between milestones, so this
  is reachable without malformed data. Fixed by degrading that ticket's detail instead of the
  page, but worth recording as the shape of failure this probe is looking for: the operator
  does not lose a message, they lose the whole queue.
- **Unknown harness messages degrade rather than drop.** Claude Code emits message types the
  event mapping does not know, `rate_limit_event` among them; these arrive as
  `job.harness.unknown` carrying the raw line, as `claude-code-events.md` requires. Nothing
  was dropped and nothing raised.
- **Client mistakes were reported as platform faults.** Several ordinary errors answered 500
  with no detail, which tells an API client nothing it can act on. Mapped to 4xx with a
  reason and a detail.
