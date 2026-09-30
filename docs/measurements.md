# Measurements

These experiments determine whether parts of the design survive contact with reality. They gate the worker tier. Each is a script parametrised by a workload (repository, environment command, build command, build directory), first run on a sample project and later on the operator's own.

- [x] Whether the build tool accepts a cache produced by the environment system without rebuilding from scratch. The storage model depends on it.
- [x] How much a copy-on-write build directory actually diverges during a realistic branch build. Determines whether one worker can host several parallel compiles.
- [x] Peak memory of the build, and of its heaviest step where there is one. Sets slice limits, agents per worker, and machine size.
- [x] End-to-end cold start of a worker. Decides whether destroying it is viable at all.
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
but never under a binding one. Crossing them was deferred to milestone 3's demo, which is the
last place it should first be tried — and § The isolation cross below is that crossing, run
during milestone 3 and before the demo depended on it. It passes.

**Worth measuring next, in this order:** M1 variant (b), the only remaining question whose
answer cannot be predicted; and M1 again on a multi-crate workload, where variant (c)'s 497
files embedding the old checkout path have more chances to matter.

### The isolation cross

Run 2026-09-13, on the operator's machine, during milestone 3. `bin/measure isolation
--workload sample-rust`, user slices, volume on the host's own btrfs rather than a loopback
image.

Four concurrent builds of the four M2 branches, each in its own transient unit with equal
`CPUWeight`. A control round with no ceiling supplies the peak and the wall times; the crossed
round repeats it with branch `leaf` alone under `MemoryMax` at half its own control peak.

| Round | Branch | MemoryMax | Peak | Wall | Exit |
|---|---|---|---|---|---|
| control | leaf | ∞ | 350 MiB | 3048 ms | 0 |
| control | core | ∞ | 349 MiB | 3028 ms | 0 |
| control | wide | ∞ | 350 MiB | 3050 ms | 0 |
| control | deps | ∞ | 350 MiB | 3766 ms | 0 |
| crossed | leaf | **175 MiB** | 175 MiB | 4555 ms | **1** |
| crossed | core | ∞ | 348 MiB | 3684 ms | 0 |
| crossed | wide | ∞ | 348 MiB | 3646 ms | 0 |
| crossed | deps | ∞ | 350 MiB | 4727 ms | 0 |

**Verdict: pass.** The constrained build was killed at its ceiling — its peak reads 175 MiB,
which is the ceiling exactly, and it exited non-zero. All three neighbours finished. The
slowest kept 0.783 of its unconstrained speed (core 0.807, wide 0.820, deps 0.783).

**This is the claim the worker tier rests on, and until now nothing had tested it.** M3 drove
builds to their ceilings but always alone; M2 ran four together but never under a binding one.
The sentence "an out-of-memory build kills one job, not the machine" was an assumption
everywhere it appeared. It now has one measurement behind it, on a sample workload, on one
machine.

**One fraction was not enough, and that is a finding about ceilings rather than about the
harness.** The first attempt set the ceiling at half the peak and the victim *finished*: its
peak came out at exactly the ceiling, so the limit bound, and the build reclaimed its way
through anyway. That is `docs/design/measurement-harness.md` § M3's "the usable limit is not
the peak" arriving from the other direction — a slice under mild pressure often still
completes. The measurement now descends through `isolation_victim_factors` until the victim
actually dies, and reports which fraction did it. Two runs on the same workload disagreed about
whether 0.5 kills, which is a warning against reading the fraction as a property of the
toolchain; what reproduces is that *some* ceiling kills one job and leaves its neighbours
running.

**What it does not say.** One workload, one machine, one repetition, and a 350 MiB peak rather
than the 2 GiB a cold build reaches — the neighbours had room to spare, and a machine genuinely
short of memory is a harder case this does not cover. The 22 % the slowest neighbour lost is
against a four-way control round, so it is the cost of the victim thrashing before it died,
not the cost of concurrency, which M2 already measured at 13–19 %.

**And then the demo showed it again with real jobs.** Milestone 3's demo ran two tickets at
once on one worker, each in its own transient unit at the configured 2210 MiB. One ticket's
agent was asked to allocate six gigabytes; the kernel killed it with
`constraint=CONSTRAINT_MEMCG` and `oom_memcg=/system.slice/forge-job-07f2c802.service`, and
systemd recorded `Failed with result 'oom-kill'`. The ticket beside it on the same machine
converged and produced its artifact. That is the same mechanism at the size the tier actually
configures, which the cross above could not reach on a workload that peaks at 350 MiB.

### M4 worker cold start

Run 2026-09-13, during milestone 3, on the operator's machine: `bin/measure m4 --workload
sample-rust` against a machine created from `nix build .#worker-image`, dialling a platform on
the host. Four cores, 8 GiB, a 40 GiB overlay, user-mode networking.

Run twice: once with cloud-init doing the configuring, and again after it was replaced by
`forge-worker-config.service` (`docs/design/worker-tier.md` § How a machine learns what it is).

| Phase | With cloud-init | After | What it is |
|---|---|---|---|
| create-vm | 237 ms | 188 ms | Overlay, config disk, QEMU launch |
| machine-configured | 20.0 s | **12.5 s** | Firmware, boot, the machine reading its own identity |
| worker-connects | 0.1 s | 0.1 s | The release dialling the platform and joining its topic |
| seed-fetched | 3.6 s | 3.3 s | 192 MiB from the platform's store, unpacked into a subvolume |
| nix-store-populated | 13.2 s | 18.4 s | `nix develop .#build --command true`, from the binary cache |
| first-build | 50.0 s | 46.2 s | `cargo build -v` in a snapshot of the seed, peak ~1.5 GiB |

**Roughly 35 seconds from nothing to a machine that can build**, and about 80 to a first build
finished. The phases before the build are the cost of destroying an idle worker and making
another one when the next ticket arrives.

**Only one column difference is attributable.** `machine-configured` fell 7.5 s — 37 % — and that
is the change: no Python agent to start, no module pipeline to walk, one oneshot that reads a
disk. Boot to a worker that has joined the platform went 20.4 s to 12.9 s. The other phases moved
in both directions by more than any of them should care about; `repeats=1`, so every figure here
is one sample, and `nix-store-populated` in particular is bounded by a download. Reading the
18.4 s as a regression caused by this change would be reading noise.

**What this sets.** `idle_period_ms` was a labelled ten-minute guess with a note saying M4
would replace it. It is now five minutes, and the reasoning is that being wrong is cheap: a
machine destroyed a moment before the next ticket costs about 35 seconds, less than the
operator's own round trip to approve the artifact that produced the ticket. Five minutes
covers an approval gap — the case where a worker is genuinely about to be used again — without
holding a machine through a lunch break.

**What it does not say.** One machine, one run, locally. Two of the phases are flattered by
being on the operator's own host: the seed came 192 MiB over loopback in 3.6 s, and the Nix
store was populated from `cache.nixos.org` over a connection the guest shares with the host. On
a provider both are network-bound and both get larger, which moves the cold start up and the
argument for a *longer* idle period with it — so the closing step should re-run this before
trusting five minutes on a Hetzner machine. `worker-connects` at 0.1 s is the release dialling
a platform one hop away and means little beyond "the credential worked".

The phases also ran in a different order than this document first planned: the seed is fetched
before the Nix store is populated, because the seed carries the checkout whose flake the store
is populated from. `docs/design/worker-tier.md` § Volumes and the seed has the longer version —
a machine cannot fetch a seed before it knows which project it is for, which is what an
assignment tells it.

### Session resume

Measured 2026-09-29 against Claude Code 2.1.284, by hand rather than by the harness: a
development container with the CLI installed, `haiku`, a scratch `HOME` per case and
`env -i` so that nothing of the calling session reached the process. One run wrote a session
("remember PELICAN"), and each case then resumed it with `--resume <id>`, asking for the word.
`--permission-mode bypassPermissions` was left out because the CLI refuses it as root; it does
not bear on where a session is found. All six runs together cost about eleven cents.

| Case | Exit | `system/init` | Answer |
|---|---|---|---|
| Same `HOME`, same working directory | 0 | yes | PELICAN |
| Empty `HOME`, same directory | 1 | **no** — one `result`, `error_during_execution`, $0 | — |
| Empty `HOME`, the session file restored under `.claude/projects/<dir>/` | 0 | yes | PELICAN |
| The same, run from a different directory | 0 | yes | PELICAN |
| Empty `HOME`, the *stdout* transcript placed as the session file | 0 | **yes** | **NONE** |

The session file was 163 KiB for a two-message exchange, most of it attachments, and each
resume appended to it — to the restored file, whichever directory the run was in. A search for
`sk-ant`, OAuth, bearer and API-key strings in it found only prose from the system prompt; that
is a pattern search, not an audit.

**What this decided.** The session file is what is carried between machines, and it is checked
before it is used (`docs/design/claude-code-events.md` § Resume): the last row is a restore that
does not fail and does not work, and nothing downstream could tell. The second row is the
assumption `resume_failed?` rested on, now observed.

### The worker at its ceiling, on the image

Run 2026-09-30 on the operator's machine, by hand first and then as
`nix build .#checks.x86_64-linux.worker-health` (`nix/worker-health.nix`), which does the same
thing and fails when what the code relies on stops being true — every item below except the
forgery, which it only records (whether to close it is § Open in the note), and the timings, of
which it bounds only the probe's and the health process's. The worker image as `nix build .#worker-image` makes it
from this branch — **systemd 261.2** (the design notes had been reading 261.3's source), kernel
6.18.50, cgroup v2 — booted under QEMU with SeaBIOS and virtio-scsi as a Hetzner x86 server
presents it, 4 GiB and 2 cores, with the local driver's config disk and its ssh door. Every unit
was started by the release inside the image: `Slice.Systemd.enter/1`, `prepare/1` and `wrap/3`
made the user, the stop step and the command, and `ended/2`, `memory/1` and `bus_error/1` read
what came back, so the flags were the worker's own:

```
systemd-run --pipe --wait --collect --unit=forge-job-aaaaaaaa00004000 --uid=forge-job-aaaaaaaa00004000
  --property=WorkingDirectory=/var/lib/forge/worktrees/<id> --property=MemorySwapMax=0
  --property=OOMPolicy=continue --property=ExecStopPost=-+/var/lib/forge/jobs/<id>.worker/at-exit
  --property=MemoryMax=536870912 --property=CPUWeight=100 --setenv=PATH=… --setenv=HOME=/nonexistent
  -- sh /var/lib/forge/worktrees/<id>/job.sh
```

Each job's stdout went to a file and its stderr to the job's `stderr.log`, as the runner sends
them. What was seen, item by item:

**A child killed at a 512 MiB ceiling dies alone.** The job's shell ran `python3` allocating
1 GiB; the kernel killed it (`constraint=CONSTRAINT_MEMCG`, `oom_memcg=/system.slice/forge-job-….service`),
the shell saw `child exit: 137` and went on to print `main still alive`, and `systemd-run` exited 0.
The stderr, verbatim:

```
Running as unit: forge-job-aaaaaaaa00004000.service; invocation ID: bdf0eb2be35340a58a9cdaa7aa93e937
/var/lib/forge/worktrees/<id>/job.sh: line 2:   925 Killed                     python3 -c '…'
          Finished with result: success
Main processes terminated with: code=exited, status=0/SUCCESS
               Service runtime: 1.733s
             CPU time consumed: 420ms
                   Memory peak: 512M (swap: 0B)
                      IO Bytes: read 8.1M
```

`Running as unit:` carries `; invocation ID: …` on 261.2 whenever PID 1 had given the unit one —
the notes quoted it without — and the summary's labels are right-aligned, so they start with
spaces. `own_line?/1` trims and matches on the prefix, so both are taken out of the last line, and
`ended/2`'s `last_line` was the `Killed` line: the process's own. There is no *IP Traffic* line,
because IP accounting is off.

**The stop step runs as root and writes the whole reading.** `at-exit.reading` was owned by root
and said `events oom_kill 1`, `max 536870912`, `peak 536870912`, `exit_code exited`,
`exit_status 0`, `result success`; `ended/2` read the same.

**A main process killed at its ceiling ends the unit with `signal`, never `oom-kill`.** With the
job `exec`ing the allocation itself, `systemd-run` exited **255**, its summary said
`Finished with result: signal` and `Main processes terminated with: code=killed, status=9/KILL`,
the journal `The kernel OOM killer killed some processes in this unit` and `Failed with result
'signal'`, and the reading `exit_code killed`, `exit_status KILL`, `result signal`, with
`events oom_kill 1`. That is the combination the runner reads as *killed at its memory ceiling*.

**The cgroup reads as the worker parses it.** A job holding 470 MiB and streaming a 1 GiB file
through the rest of its 512 MiB, twenty seconds in (the by-hand run; the check's runs read the
same shapes, with `full avg10` between 10.79 and 11.83):

| File | Raw | `memory/1` a moment later |
|---|---|---|
| `memory.events` | `max 178565`, `oom 0`, `oom_kill 0` | `max_events: 182158`, `oom_kills: 0` |
| `memory.current` | 536870912 | `current: 536776704` |
| `memory.peak` | 536870912 | `peak: 536870912` |
| `memory.max` | 536870912 | `ceiling: 536870912` |
| `memory.pressure` | `full avg10=11.21 avg60=3.50 …` | `pressure: 11.53` |

The file had to be dropped from the page cache first: written by root, its pages were charged to
root's cgroup, and a job reading them paid nothing. `pressure` stayed under the 20 % threshold
for this workload; nothing here has shown what an agent's own thrashing reads as.

**The forgery works, and on the image it works every time.** A job truncated its stderr
through its own file descriptor 2, wrote `Failed to connect to bus: Connection timed out` in
place of `Running as unit:`, and filled `/dev/shm` until the kernel killed the writer. The stop
step **does run in the unit's own cgroup** — the kernel names it: `task=(at-exit)`,
`task_memcg=/system.slice/forge-job-….service`, killed before it had exec'd — and so left no
reading, and `ended/2` answered `unreachable: "systemd-run could not reach PID 1: Failed to
connect to bus: Connection timed out"`. With one fill that took 3 runs in 12; with the fill
squeezed sixteen pages at a time after the first kill, **10 in 10 by hand and 5 in 5 in each of three check runs**.
Each time, PID 1 answered `Slice.Systemd.probe/0` straight afterwards, the slowest in 6 ms. The
`/dev/shm` file outlived the unit, still owned by the job's user. Nothing at a job's end removes
it — `leave/2` takes back the paths it is given and removes the user, which is read from the
code, not run here — so it would be left to a uid the next `useradd` may reuse.

**A 2-byte ceiling wedges PID 1, as the incident note guessed.** With the worker's flags and
`MemoryMax=2` (the unit's `memory.max` reads `0`: two bytes round down to no pages), PID 1 sat in
`D` state in `kernel_clone` — `CLONE_VFORK`, waiting for a child that never execs — and the
child, in the unit's cgroup, was the subject of an endless `Out of memory and no killable
processes...`. Then:

- `timeout -k 5 10 systemctl show --property=Version --value` failed in **10.0 s** with exit 124
  and no output, every time; `probe/0` said `{:error, "systemctl show exited 124: "}`. Without
  `timeout`, `systemctl show` gave up after 90 s with `Failed to get properties: Transport
  endpoint is not connected`.
- A second `systemd-run` failed after **25.0 s** (sd-bus's default call timeout) with exit 1 and
  exactly `Failed to start transient service unit: Connection timed out` — `bus_error/1` found
  it, and `ended/2` believed it, since no reading and no `Running as unit:` said otherwise.
- **The run that caused the wedge said something else**, also after 25 s and with exit 1, and
  in two ways depending on how far PID 1 got: `Failed to request invocation ID for unit:
  Connection timed out` alone (by hand, and in the third check run), or `Running as unit:
  forge-job-….service` with no invocation ID and then `Failed to query unit state: Connection
  timed out` (the first two check runs).
  Neither is in `@bus_calls`, and the second follows a `Running as unit:`, so `ended/2` gives
  `unreachable: nil` for it: that run ends as the job's own failure, and it is the probe that
  finds the machine. Read in 261.2's `run.c`: the start call is answered — queueing a job does
  not need the fork — and the next call, `acquire_invocation_id()` or the unit-state query, is
  the one that waits. `acquire_invocation_id()` is only made without `--quiet`, which is also why
  the incident's first chat, under a worker that still passed `--quiet`, had an empty stderr.
- A new ssh login hung (60 s and counting); one already open, multiplexed, went on working.
- The kernel's OOM report for that child repeats without end: journald ran flat out, and (by
  hand, after six minutes wedged) the journal of the wedged boot kept **8 seconds** of it — 711,949 lines, everything earlier rotated
  away, the worker's own `PID 1 did not answer` lines with it. A follower started before the wedge
  kept them.
- **The worker's own health process noticed**: `PID 1 did not answer the probe: systemctl show
  exited 124: ; asking again`, then `PID 1 did not answer twice in a row …`, **94–97 s** after
  the wedge in three check runs, and about 2 min 5 s by hand.

**`systemctl --force --force reboot` reboots it.** With PID 1 still wedged it printed
`Rebooting.` (by hand; `ForgeWorker.Health.reboot/0` keeps what the command prints to itself), the
kernel said `reboot: Restarting system`, Limine booted it again inside the same QEMU, and the
console showed a login prompt **7–8 s** after the command — by hand, and through `reboot/0` in the
check. `/proc/sysrq-trigger` was not needed. **Both
`--force`s are needed**: with one (a mutation of `reboot/0`, below) the wedged machine had not
rebooted three minutes later; by `systemctl(1)`, a single `--force` still has the service manager
do it.

**The same machine comes back with the same identity.** On the new boot `forge-worker-config.service`
ran again (`identity: forge-config`), and `/etc/forge-worker.env` was byte for byte what the first
boot had written (same sha256), with the ssh key line taken out again. That is the local driver's
config disk; the metadata service on a Hetzner machine is still unobserved.

**The check fails when what it checks stops being true.** Each of these was made to the worker
in a copy of the tree, the image rebuilt from it, and the check run against it:

| Mutation | Where the check failed |
|---|---|
| `OOMPolicy=stop` instead of `continue` | `oom-child`: `systemd-run exited 1; the main process should have lived` |
| the stop step `-` instead of `-+`, so as the job's user | `oom-child`: `the stop step did not run as root` |
| `Connection timed out` taken out of `@bus_errors` | `wedge`: `bus_error/1 does not know the line systemd-run printed` |
| `memory/1` reading `max_events` from `high` | `readings`: `memory/1 read no reclaim at the ceiling` |
| `Health` never marking, its count of failures held at one | `health`: `the worker did not mark itself unhealthy within four minutes` |
| `Health.reboot/0` with one `--force` | the reboot: `no login prompt number 2 within three minutes` |
| `parse_pressure/1` answering `0.0` (after review tightened the item) | `readings`: `memory/1 read no pressure, for a job stalled at its ceiling` |

**What it does not say.** One machine, 4 GiB and 2 cores, under KVM on the operator's host; a
local config disk, not Hetzner's metadata service; and the release not joined to any platform —
what the platform does with the worker's `unhealthy` is § The unhealthy machine, end to end.

### The unhealthy machine, end to end

Run 2026-09-30 by hand on the operator's machine, as a checklist rather than a test: the platform
from this branch (`elixir --sname forge -S mix phx.server`, driven from a remote shell), a
`health` project whose one workflow state has its agent run a ten-minute wait, a template on the
`local` provider booting the same image under QEMU (OVMF, as `LocalVm` boots it — no
`-no-reboot`, so a guest's reboot stays in the same QEMU), the ssh door open
(`FORGE_WORKER_SSH_KEY`, `FORGE_WORKER_SSH_PORT`), and `FORGE_WORKER_TIMEOUT_MS=15000` so that
only the grace could keep a rebooting machine's row. `reboot_interval_ms` and `reboot_grace_ms`
were the defaults, an hour and ten minutes, except where said. The worker's probe was its
default minute. Each item, with what showed it:

- [x] **`machine.unhealthy` in the machine's log.** A chat (idle between turns) and a workflow job
  (in its wait) running on machine `9639a928`; PID 1 wedged over ssh with `systemd-run -p
  MemoryMax=2` at 11:33:32; at 11:35:34 the machine's log had `machine.unhealthy: PID 1 did not
  answer twice in a row: systemctl show exited 124: . It has stopped its jobs and takes no more; the
  platform requeues them`,
  then `job.abandoned` for each job.
- [x] **The platform receives `unhealthy`.** Its own line, the same second: `unhealthy: PID 1 did
  not answer twice in a row: …; requeued 2 job(s); told to reboot`; the row's `unhealthy_at` and
  `rebooted_at` both 11:35:34.
- [x] **The chat goes dormant and the workflow job back to `pending`, each with `job.interrupted`
  `worker_unhealthy`.** The chat `hibernated`, the job `pending` and then running again on the
  same machine once it had rejoined; both with `%{"reason" => "worker_unhealthy"}`.
- [x] **The workers page shows the unhealthy line.** Fetched as the logged-in operator during the
  second wedge below: *unhealthy since 11:39 UTC: PID 1 did not answer twice in a row: systemctl
  show exited 124: — rebooted within the hour, so not again: destroy it, or wait for it to rejoin
  healthy*; for the unmanaged machine, *… — not the platform's to reboot: restart it, and it takes
  work again when it rejoins healthy*.
- [x] **The platform answers reboot, and the guest reboots.** `machine.rebooting: the platform said
  to reboot, and this is a machine it made: rebooting now` at 11:35:34; the console shows
  `reboot: Restarting system` and a second login prompt, and the QEMU process is the one `create`
  started.
- [x] **The machine rejoins as the same worker row, and the mark clears.** `joined` and `healthy:
  joined without saying it is unhealthy; takes work` at 11:36:42 on row `9639a928`, `idle` and
  unmarked. Not sooner: the platform held the dead socket until `disconnected: shut down:
  :read_timeout` at 11:36:34, and refused the rebooted machine's joins as `already_connected`
  until then — ten of them in the node's log.
- [x] **`sweep_unreachable/0` leaves the row alone during the grace.** Staged so that nothing
  but the grace could keep the row: with `reboot_interval_ms` set to a second on the running node,
  machine `41c055f6` was wedged at 12:15:47, told to reboot at 12:17:16, and its QEMU stopped
  (`SIGSTOP`) 0.9 seconds later so that it could not come back. The platform dropped the socket at
  12:18:17; at 12:21:43, four minutes past its last heartbeat against a 15-second timeout, the row
  was still there and `sweep_unreachable/0` run by hand took nothing (`0`). With `reboot_grace_ms`
  then set to a second, the same call took it at once (`1`: `unreachable: not heard from since
  12:17:19 UTC; requeued 0 job(s) and destroying it`). A reboot that came back inside the grace is
  the first wedge above.
- [x] **A second wedge within the interval is not rebooted, and waits for a person.** Wedged again
  at 11:37:39: `unhealthy … requeued 1 job(s); not rebooted: it was told to at 2026-09-30 11:35:34
  UTC, within the hour, so it waits for a person`; the row stayed connected and marked, with no
  reboot, for the nine minutes until it was rebooted by hand at 11:48.
- [x] **An unmanaged machine never reboots.** A second VM from the same image, its config disk
  from `mix forge.worker.new` with no `FORGE_MANAGED=1`, joined as row `ebb8a9f9` (`managed=false`)
  and was wedged at 11:41:52: `not rebooted: it is not the platform's machine, and its owner
  restarts it`, `rebooted_at` never set, and three minutes later it was still up (uptime 343 s,
  one login prompt, no `Restarting`) and still wedged.

**What it found that the checklist did not ask.**

- The worker's line after the platform said no arrived as type **`unknown`**: it was
  `machine.not_rebooting`, and the platform keeps a type only if it is lower-case words and dots
  (`docs/design/worker-log.md`). Renamed `machine.unrebooted`, and a worker test now holds the
  type of every `Log.line/4` call in the worker to that rule, and every call to naming its type
  as a literal so the scan sees it.
- **A person's reboot of a machine not told to reboot loses its row under a short timeout.** With
  the timeout at 15 seconds, rebooting the second-wedged machine by hand got it destroyed: the
  platform noticed the dead socket at its read timeout, 70 seconds after the last heartbeat, and
  the sweep took the row that second, since only a machine told to reboot has a grace. At the
  default three minutes the machine would have rejoined first.
- **With the host's disk saturated, the database stalled and the channels crashed.** While six
  image builds ran for the mutation tests, I/O pressure reached `full avg10=85%`, a heartbeat's
  `UPDATE workers` waited more than 15 seconds and was cancelled (`57014 query_canceled`), the
  channel crashed with it, and machine `5ec19979` was destroyed by the sweep in the same second it
  rejoined. That is this host, not the design — but the sweep and a join are not ordered, and
  under a stalled database a machine that has just joined can be swept as unreachable.
