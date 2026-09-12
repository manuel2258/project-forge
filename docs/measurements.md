# Measurements

These experiments determine whether parts of the design survive contact with reality. They gate the worker tier. Each is a script parametrised by a workload (repository, environment command, build command, build directory), first run on a sample project and later on the operator's own.

- [x] Whether the build tool accepts a cache produced by the environment system without rebuilding from scratch. The storage model depends on it.
- [x] How much a copy-on-write build directory actually diverges during a realistic branch build. Determines whether one worker can host several parallel compiles.
- [x] Peak memory of the build, and of its heaviest step where there is one. Sets slice limits, agents per worker, and machine size.
- [ ] End-to-end cold start of a worker. Decides whether destroying it is viable at all.
- [ ] Whether agents, prompted well, produce bounded, well-formed artifacts and ask few good questions. The quietest risk and the largest — everything can work mechanically and still be useless if the output sprawls.
  Skipped by decision: taken as given for the PoC. Milestone 5 dogfooding is where this gets observed instead.

## The harness

`bin/measure`, parametrised by a workload config in `measure/workloads/`. The design note is
`docs/design/measurement-harness.md`; `measure/workloads/README.md` says how to point it at a
project. The first three measurements are one harness because they share the sample project,
the warm checkout, the btrfs volume and the `systemd-run` wrapper, and feed each other.

It is not part of `bin/check`: it needs btrfs, cgroup v2 with memory accounting, root and Nix
on the operator's machine. What the gate does cover is `shellcheck` and `shfmt` over it, and
what stands in for a test run is `bin/measure selftest`, which drives all three measurements
against a fake workload with the privileged layers substituted, plus the renderer against
checked-in records in `measure/testdata/report/`.

```
bin/measure sample-init                     # the sample project, with M2's four branches
bin/measure preflight --workload sample-rust
bin/measure m1 --workload sample-rust       # then m2, then m3 --sweep
bin/measure report --workload sample-rust   # the tables below
```

## Results

First and only run, 2026-09-12, on the sample workload. The boxes above are ticked because
the measurements landed, not because every verdict passed: two of the three headline verdicts
the harness printed were not the verdicts they named. Both metrics have since been corrected
(`docs/design/measurement-harness.md` §§ M2, M3), but **every table below predates the
correction**, and the investigation closes here rather than re-running: neither conclusion
rests on a corrected metric — M2's rests on the per-branch reading and M3's on the observed
peak, both of which the corrections leave alone. The corrections ship with the harness and
take effect on the next run, which is the operator's own project in the closing step.

§ What these measurements decided, at the end, says what this bought and what it did not.

- Workload `sample-rust` at `main`, repository `.measure/sample-rust/origin`
- Host: Linux 7.1.13-200.fc44.x86_64, 12 cores, 31 GiB, systemd 259 (259.8-1.fc44)
- btrfs-progs: btrfs-progs v7.1, cgroup slices: user
- forge at `995f951`, plus the harness fixes that land with this file
- CPU governor `powersave`, swap on, `repeats=1`: every wall time is one sample

Slices were the user manager's, not the system manager's, because this host has no
passwordless sudo. That costs nothing for M1 and M3 — a user unit with delegation accounts
memory exactly as a system unit does — and it is why M1(b) below could not run.

### M1 build cache acceptance

Pass: only the project's own sources rebuild, and the build is within twice a warm local
build of the same work (`warm_own`: the warm tree with its own sources invalidated — see the
design note for why that is the denominator). A variant whose key is unset is recorded
`not_applicable` with the reason, which never counts as a pass.

If no variant passes, the consequence is the one `docs/poc-plan.md` § Risks names: the seed
becomes a maintained btrfs blob kept in the platform's store. The report says so itself.

Two runs, because `--only` takes one variant and (b) could not run at all.

| Build | Variant | Own rebuilt | Dep rebuilt | Files written | Wall | ×warm_own | Peak | Verdict |
|---|---|---|---|---|---|---|---|---|
| `env-baseline` | — | — | — | 0 | 5 ms | 0× | 8 MiB | — |
| `cold` | reference | 1 | 155 | 1355 | 27674 ms | 28.09× | 1644 MiB | — |
| `warm_noop` | reference | 0 | 0 | 1 | 98 ms | 0.09× | 33 MiB | — |
| `warm_own` | reference | 1 | 0 | 135 | 984 ms | 1× | 197 MiB | — |
| `m1a` | a | 1 | 155 | 1351 | 27563 ms | 27.98× | 1607 MiB | fail (155 dependency artefacts rebuilt) |

| Build | Variant | Own rebuilt | Dep rebuilt | Files written | Wall | ×warm_own | Peak | Verdict |
|---|---|---|---|---|---|---|---|---|
| `env-baseline` | — | — | — | 0 | 5 ms | 0× | 8 MiB | — |
| `cold` | reference | 1 | 155 | 1355 | 25632 ms | 26.6× | 1630 MiB | — |
| `warm_noop` | reference | 0 | 0 | 1 | 95 ms | 0.09× | 32 MiB | — |
| `warm_own` | reference | 1 | 0 | 135 | 963 ms | 1× | 196 MiB | — |
| `m1c` | c | 1 | 0 | 135 | 1295 ms | 1.34× | 226 MiB | pass |

**(a) fails outright.** A build directory produced by a Nix builder from the dependency
closure alone is rejected by cargo: all 155 dependency crates rebuild and the "cached" build
costs the same as cold, 27.6 s against 25.6 s. Not a near miss — no transplant occurs.

**(c) passes with room.** A warm build directory rsynced from a different checkout path
rebuilds nothing but the project's own crate, writes 135 files against `warm_own`'s 135, and
costs 1.34× `warm_own` against a limit of 2×. It does this despite 497 files in the build
directory embedding the old checkout path, so cargo's fingerprints evidently do not depend on
them.

**(b) was not run, and is not `not_applicable`.** The compilation-cache variant needs a
loopback ext4 volume for the sccache directory and `umount`/`drop_caches` to read it from a
cold disk, all of which need root, and this host has no passwordless sudo. That is a weaker
obstacle than it looked: nothing in the variant gates on `sudo -n`, so on a terminal it
prompts, and M2 on this same host mounted its loopback volume through exactly that prompt.
Passwordless sudo buys an unattended run, not the measurement. So (b) is unrun rather than
unrunnable, it is absent from both tables rather than recorded, and M1 is not finished until
it runs — it is the one remaining form, and sccache keys on content rather than paths, which
makes it the form most likely to survive a path change. It stays unrun: this investigation
closes with two of three variants measured, and (b) is the named gap the closing step's run
picks up.

So: the seed can be a warm build directory maintained and copied, but not an artifact built
reproducibly from the dependency closure. That is the heavier storage model
`docs/poc-plan.md` § Risks names, and for cargo it is the one that works.

### M2 copy-on-write divergence

Exclusive bytes per snapshot after four concurrent builds, and wall time at 1, 2 and 4.
Pass: the four fit the volume and keep enough of ideal scaling. Sets agents per worker.

| Concurrency | Makespan | Slowest build | Sum of builds |
|---|---|---|---|
| 1 | 1747 ms | 1436 ms | 1436 ms |
| 2 | 1792 ms | 1460 ms | 2912 ms |
| 4 | 4452 ms | 2877 ms | 7871 ms |

| Snapshot | Branch | Exclusive |
|---|---|---|
| `exclusive-l4-b0` | leaf | 38 MiB |
| `exclusive-l4-b1` | core | 38 MiB |
| `exclusive-l4-b2` | wide | 38 MiB |
| `exclusive-l4-b3` | deps | 43 MiB |
| `exclusive-total` | — | 159 MiB |

**Divergence is small and reproducible.** 159 MiB of exclusive bytes across four snapshots,
byte-identical across two runs. Against a 720 MiB warm build directory that is the number the
storage model wants, and four concurrent builds fit a volume trivially.

`leaf`, `core` and `wide` agree exactly because `forge-sample` is a single crate and cargo's
unit of compilation is the crate: editing one function, a shared type, and every module are
the same work. The four branches in `measure/sample/README.md` are described as spanning a
range of blast radii; for a single-crate cargo project they do not, and only `deps` differs
because it genuinely adds a crate. A multi-crate workspace would be needed to measure a range.

**The scaling verdict recorded above is not usable, and the metric has been replaced.** The
harness compared `makespan[1]` against `makespan[4]`, and both sides were wrong for the
question. Level 1 ran only `m2_branches[0]` (`leaf`), while level 4's makespan is set by
`deps`, which compiles an extra crate and is twice the work uncontended — so heterogeneous
workload was charged to contention. And `makespan[1]` is dominated by `nix develop` entry
inside the unit, which varies with the flake evaluation cache: two identical runs gave 2623 ms
and 1747 ms for it while `makespan[4]` moved 7 ms, flipping the verdict from pass to fail.

M2 now runs every branch serially as its level-1 reference and reports two ratios instead:
contention, the mean of `wall(l1-b<i>) / wall(l4-b<i>)`, and throughput, the four-way makespan
against its critical-path bound. The table below is the per-branch reading computed by hand
from the recorded runs — the same comparison, and what the harness prints for itself from the
next run on. The conclusion under it does not depend on the correction, which is why this is
recorded rather than re-run.

What the per-branch data says instead, comparing the same branch across rounds as the design
note intends:

| Branch | 1 concurrent | 2 concurrent | 4 concurrent | Cost of 4-way |
|---|---|---|---|---|
| `leaf` (run 1) | 1363 ms | 1433 ms | 1534 ms | +13 % |
| `leaf` (run 2) | 1436 ms | 1460 ms | 1713 ms | +19 % |
| `core` (run 2) | — | 1452 ms | 1709 ms | +18 % |

Four concurrent builds cost each build 13–19 % on 12 cores, stable across runs. That is the
answer to "can one worker host several parallel compiles", and it is yes.

### M3 peak build memory

Peak per profile, the heaviest step alone, and the environment-entry baseline beside them.
`--sweep` turns the peak into a `MemoryMax` per slice. Sets the slice limit, agents per
worker and machine size.

| Build | Profile | MemoryMax | Peak | Wall | OOM | Status |
|---|---|---|---|---|---|---|
| `env-baseline` | — | infinity | 7 MiB | 5 ms | false | ok |
| `debug-cold` | debug | infinity | 1612 MiB | 27569 ms | false | measured |
| `debug-warm` | debug | infinity | 197 MiB | 995 ms | false | measured |
| `debug-heaviest` | debug | infinity | 197 MiB | 998 ms | false | measured |
| `release-cold` | release | infinity | 1879 MiB | 54773 ms | false | measured |
| `release-warm` | release | infinity | 278 MiB | 6494 ms | false | measured |
| `release-heaviest` | release | infinity | 275 MiB | 6344 ms | false | measured |
| `observed-max-peak` | — | — | 2009 MiB | — | false | measured |
| `sweep-release-1.5` | release | 3160283136 | 275 MiB | 6321 ms | false | measured |
| `sweep-release-1.25` | release | 2633569280 | 274 MiB | 6334 ms | false | measured |
| `sweep-release-1.0` | release | 2106855424 | 286 MiB | 6374 ms | false | measured |
| `sweep-release-0.75` | release | 1580141568 | 276 MiB | 6381 ms | false | measured |

**The peaks are the usable result.** A cold build wants 1.6 GiB debug, 1.9 GiB release, and
2009 MiB is the highest peak seen in any run of this workload. Everything after the build
directory is warm is an order of magnitude smaller: 197–286 MiB. Environment entry alone is
7 MiB, so `nix develop` costs nothing against the slice. A slice sized for cold builds is
sized for eight times as many warm ones, which is the number that matters for agents per
worker.

**The sweep rows above are superseded, and their 1657 MiB recommendation was unsafe.** The
sweep derived its ceilings from the observed peak — 2009 MiB, a *cold* build — but re-ran
`build_cmd_release` after touching own sources, which is a *warm* build peaking at 275 MiB.
Every ceiling down to 0.75× therefore passed trivially, and the recommendation landed below
the peak that had just been measured. A cold build in a 1657 MiB slice would OOM. This was
exactly the conflation `docs/design/measurement-harness.md` § M3 opens by warning against:
the undistorted peak and the usable limit are two numbers, and the sweep was measuring the
second against a workload that never approaches the first.

The sweep now runs `clean_cmd` before each ceiling, so it binds on the build its ceilings came
from, and the recommendation is floored at the observed peak times the safety margin — no
future way of getting this wrong can produce a slice smaller than a build already seen to
need. Re-running it costs four cold builds, about four minutes for this workload.

The slice limit this measurement leaves behind is therefore the observed peak plus the
configured margin: 2009 MiB × 1.1 ≈ **2.2 GiB per slice**, which is also the floor the
corrected sweep starts from and so the lowest a corrected re-run could conclude. On a 31 GiB
host that is generous headroom for four concurrent workers. The sweep is not re-run here: it
would confirm the floor, not move it.

### What these measurements decided, at the end

**What they could decide.** `docs/decisions.md` settles the worker tier's architecture —
transient systemd units, btrfs snapshots, `nix develop` — and says settled decisions are not
reopened; the probe table in `poc-plan.md` reopens the sandbox question only if milestone 3
fails. So M1 to M3 were never able to say the architecture is wrong. They were able to choose
between two storage models, and to put numbers on three quantities. They did the first
decisively and the second only for the sample.

**M1 is the load-bearing result.** The plan's preferred seed — a build directory produced
reproducibly from the dependency closure — does not work for cargo, and the failure is not a
near miss: every dependency crate rebuilt and the restore cost what a cold build costs. The
storage model is now the heavier one `poc-plan.md` § Risks describes, and that changes what
milestone 3 builds. This is the one place a measurement moved the design. It is also
incomplete in one specific direction: variant (b) never ran, and a content-keyed cache is the
form most likely to transplant, so a later run of (b) could lighten the model again. Nothing
else in M1 is provisional.

**M2 and M3 proved mechanism, not quantity.** Their headings claim to set agents per worker
and machine size. A single-crate sample with a one-second warm build cannot set either, and
the plan already knows this: issue #12 says the operator's own project's numbers replace the
sample's in the closing step. What these two did establish, and what does transfer, is that
the mechanisms work and are measurable end to end — btrfs snapshots diverge by an amount that
can be counted and reproduces byte-identically across runs, cgroup peaks are readable from
inside a transient unit, four builds run concurrently under proportional shares and cost each
other 13–19 %, and a cold build wants roughly eight times a warm one. Those are the findings.
`2.2 GiB per slice` and `159 MiB of divergence` are the sample's numbers, carried as defaults
until the closing step replaces them.

**Most of what the first run found was the harness.** Seven bugs before a number could be
trusted, two of them silent — a rebuild parser with no verbose input made every M1 verdict a
vacuous pass, and a foreign cargo in the untimed helpers turned M3's heaviest step into a cold
build — and then two metrics that named something other than what they computed. That is a
high ratio of instrument to world, and it is the honest reason the boxes above say the
measurements landed rather than that they passed.

**The claim none of them tested.** The worker tier rests on "an out-of-memory build kills one
job, not the machine". M3 drove builds toward ceilings but always alone; M2 ran four together
but never under a binding one. Crossing them — four concurrent builds, one with a `MemoryMax`
below its own peak — is a mechanism test the harness can already perform, and it would produce
evidence on the sample that does transfer. It is currently deferred to milestone 3's demo,
which is the last place it should first be tried.

**Worth measuring next, in this order:** M1 variant (b), the only remaining question whose
answer cannot be predicted; M1 again on a multi-crate workload, where variant (c)'s 497 files
embedding the old checkout path have more chances to matter; and the isolation cross above,
before milestone 3 depends on it.

### M4 worker cold start

Separate: it needs the worker image and the platform's store from milestone 3, and lands with
it. It reuses this harness's phases, records and renderer, so its numbers arrive in the same
table.
