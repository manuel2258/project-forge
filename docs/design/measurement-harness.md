# Measurement harness

Scope: the script that produces measurements M1 to M3 (`docs/poc-plan.md` § Phase 0), how a
workload is described to it, and the contract M4 will reuse. Written before the code, per
`CLAUDE.md`; a change of mind updates this note first.

The harness answers three questions the worker tier is gated on: does a build cache made
elsewhere transplant (M1), how far do copy-on-write build directories diverge and how do
concurrent builds scale (M2), and how much memory does a build actually want (M3). They share a
sample project, a warm checkout, a btrfs volume and a `systemd-run` wrapper, and they feed each
other, so they are one harness with three subcommands and one results table.

## What is fixed

- **The harness is language-agnostic.** It never names a language, a build tool or a cache
  product. Everything toolchain-specific is a variable or a shell function in a workload config.
  `docs/decisions.md` makes this binding: the workload is a parameter.
- **It runs on the operator's machine, never in `bin/check`.** It needs btrfs, cgroup v2 with
  memory accounting, root and Nix. The quality gate can lint it and nothing more, so the
  verification it does get — shellcheck, `--dry-run`, a fixture-driven `report`, a self-test
  against a fake workload — has to carry the weight.
- **It measures the thing milestone 3 will build.** Every build runs in a transient systemd unit
  entered through `nix develop .#<env>`, because that is how the worker will run a job. A
  measurement taken any other way would not transfer.

## Layout

```
bin/measure                     entrypoint and argument parsing
measure/lib/common.sh           logging, config load and validation, phases, result records
measure/lib/exec.sh             measure_exec / measure_run: the transient-unit primitive
measure/lib/in_unit.sh          runs inside the unit: times the build, reads its own cgroup
measure/lib/census.sh           build-directory census, diff, rebuild classification
measure/lib/btrfs.sh            volume, seed_create, snapshots, exclusive bytes
measure/lib/preflight.sh        the preconditions, collected and reported once
measure/lib/m1.sh m2.sh m3.sh   one file per measurement
measure/lib/report.sh           JSONL to markdown
measure/lib/selftest.sh         the self-test and its assertions
measure/lib/sample.sh           materialises the sample project and M2's branches
measure/workloads/*.sh          one file per workload, plus a documented template
measure/sample/                 the sample project: a dependency tree and a heavy link
measure/testdata/report/        records the renderer is tested against
.measure/                       scratch: checkouts, volumes, results. Not committed
```

Subcommands: `preflight`, `m1`, `m2`, `m3`, `report`, `selftest`, `sample-init`, `clean`.

The entrypoint is in `bin/` because that is where this repository puts things you run;
the library is not, because `bin/` should stay a list of commands rather than become a tree.
Results live under `.measure/results/<workload>/<stamp>-<subcommand>/` and are never committed:
what gets committed is the rendered table in `docs/measurements.md`, and the raw run directory
is attached to the issue.

## Workload config

A sourced bash file. Not JSON: the hooks are naturally shell — a heaviest step is a command
line, a rebuild parser is a filter — and sourcing lets the harness export scratch paths before
the config runs, so a config can interpolate them. The cost is that a config is arbitrary code,
which is acceptable for a file the operator writes about their own machine. Configs end in
`.sh` so shellcheck and shfmt cover them.

Exported before sourcing: `FORGE_M_SCRATCH`, `FORGE_M_CACHE_DIR`, `FORGE_M_VOLUME`,
`FORGE_M_RUN_DIR`.

The four parameters `docs/poc-plan.md` names are `workload_repo`, `workload_env`,
`build_cmd_debug` and `build_dir`. The rest exist so the harness can stay language-agnostic:

| Key | Used by | Meaning |
|---|---|---|
| `workload_name` | all | Slug used in result paths and tables |
| `workload_repo` | all | Repository under measurement; cloned into scratch, never mutated |
| `workload_commit` | all | Pinned commit; every measurement uses it |
| `workload_env` | all | The `<env>` in `nix develop .#<env>`. Empty means no Nix |
| `build_dir` | all | Build directory, relative to the worktree, that the build warms |
| `build_cmd_debug` | all | Build command, a shell string run under `bash -o pipefail -c` |
| `build_cmd_release` | M3 | Release configuration. Unset is recorded `not_applicable` |
| `build_profiles` | M1, M3 | Which profiles to exercise. Default `(debug)` |
| `clean_cmd` | M1, M3 | How to empty the build directory |
| `build_timeout_seconds` | all | Per-build ceiling, enforced by `RuntimeMaxSec` |
| `own_sources` | M1 | Globs in the source tree; touched to build the `warm_own` reference |
| `own_paths`, `dep_paths` | M1 | Globs under `build_dir` classifying a rebuilt artefact |
| `parse_rebuilds` | M1 | Optional function; reads the build log, prints `own`/`dep` per unit |
| `dep_seed_attr`, `dep_seed_subpath` | M1(a) | Flake attribute producing a dependency-closure build directory |
| `cache_env` | M1(b) | Assignments enabling a compilation cache. Unset means the toolchain has none |
| `cache_populate_cmd`, `cache_stats_cmd`, `cache_reset_cmd` | M1(b) | Fill, read and stop the cache |
| `m2_branches` | M2 | At least four `name:sha`, pinned so re-runs compare |
| `m2_volume_size`, `m2_scaling_min_efficiency` | M2 | Volume size and the scaling pass threshold |
| `mem_probe_max`, `mem_sweep_factors` | M3 | Ceiling for the undistorted peak; sweep factors |
| `heaviest_step_prepare_<profile>`, `heaviest_step_cmd_<profile>` | M3 | The link, isolated |
| `repeats`, `build_jobs_env` | all | Repetitions; how to pin the build's own parallelism |

Build commands are shell strings rather than arrays because an array cannot cross the
`systemd-run --` boundary as one argument and real build commands want pipelines.

`workload_validate` takes the set of required keys as an argument, tolerates unknown keys, and
collects every missing or malformed key before dying once with the whole list. M4 will require
fewer keys and pass a smaller set.

## measure_run

`measure_run <label> <workdir> <command>` is the only place in the harness that calls
`systemd-run`. It emits one result record and one build log.

```
sudo systemd-run --unit=forge-measure-<run>-<label> \
  --service-type=exec --wait --pipe \
  --uid=<operator> --gid=<operator> --working-directory=<worktree> \
  --property=MemoryAccounting=yes --property=MemoryMax=<max> \
  --property=MemorySwapMax=0 --property=CPUAccounting=yes \
  --property=IOAccounting=yes --property=TasksAccounting=yes \
  --property=CPUWeight=100 --property=RuntimeMaxSec=<timeout> \
  --setenv=... \
  -- nix develop .#<env> --command bash measure/lib/in_unit.sh <command>
```

The flag shape follows the `forge-admin` wrapper in `nix/module.nix`, with `--pty` replaced by
`--pipe` because the harness is not interactive and needs systemd's own messages separable from
the build's output. The `nix develop .#<env> --command <exe> <args>` form is the one
`ForgeWorker.Job.Runner.maybe_nix/4` already builds, so the environment is entered exactly as
the worker will enter it.

Four choices worth stating, because each has a wrong-looking alternative:

- **No `--collect`.** It unloads the unit the moment it exits, which destroys the post-hoc
  `systemctl show` and, worse, the journal record of an OOM kill that the M3 sweep depends on.
  The harness queries immediately after `--wait` returns and calls `systemctl reset-failed`
  itself; preflight clears strays from an interrupted run.
- **`MemorySwapMax=0`.** `memory.peak` tracks `memory.current`, which excludes swapped-out
  anonymous pages, so a swapping build would report a peak lower than its real demand. Better to
  fail than to understate.
- **System units by default.** Running as the operator through `--uid`/`--gid` under the system
  manager is what milestone 3 will do, the controllers are always available, and M1(b) needs
  root for the cold-disk step regardless. `FORGE_M_USER_UNITS=1` selects `--user` for operators
  who will not grant sudo, but only after preflight has proved the memory controller is
  delegated: in a user unit without delegation, `MemoryMax=` is silently ignored, which is a
  wrong answer rather than an error.
- **An explicit environment**, mirroring the inherited list in `Runner`. A variable the worker
  forgets is then a variable the measurement also forgets, which is the failure mode that
  surfaces the problem rather than hiding it.

### Reading the peak

The reliable place is inside the unit, after the build finishes and before the unit exits.
`in_unit.sh` resolves its own cgroup from `/proc/self/cgroup`, reads `memory.peak`,
`memory.swap.peak`, `cpu.stat`, `pids.peak` and `io.stat`, and writes them as `key=value`. The
peak is hierarchical, so it covers the whole build tree, and the cgroup is still alive because
the wrapper is in it.

Fallbacks, in order, with `mem_peak_source` on every record so two kinds of number never sit in
one column unlabelled:

1. `memory.peak`, read in-unit. Authoritative.
2. `systemctl show -p MemoryPeak,Result,ExecMainStatus`. A cross-check, and frequently empty,
   because a transient service is unloaded once inactive. That raciness is why it is not first.
3. `journalctl -u <unit>` for the OOM-killer message, when no stats file was written.
4. `/usr/bin/time -v` maximum RSS, with a caveat recorded: it is the largest single process, and
   a parallel build's sum is what matters.

Preflight probes capability rather than asserting a version: cgroup v2 with the memory
controller, a throwaway unit that can read its own `memory.peak`, and `systemctl --version`
agreeing with `systemd-run --version` — a mismatch means a Nix systemd is shadowing the host
manager's client, which is why `pkgs.systemd` is deliberately absent from the measure devshell.

### Two wall times

`wall_ns_build` is measured inside the entered environment around the build alone and is what
comparisons use. `wall_ns_total` is measured around `systemd-run` and includes unit setup and
the whole `nix develop` entry. Both are recorded, because the difference is a cost milestone 3
also pays. The harness additionally records an environment-entry baseline — `nix develop
--command true` under a unit — so the evaluator's own wall time and memory sit beside the build
numbers. It is not subtracted: the slice has to accommodate the evaluator too.

A failed reference build aborts the measurement and prints the log path. A failed variant build
is a data point: `fail`, reason `build_failed`, on to the next variant.

## Counting what rebuilt

Three layers, all recorded, the verdict using the best available.

1. **A census of the build directory**, before and after, from `find -printf` sorted: files
   created, modified, touched by ctime alone, deleted, and bytes written. Generic, cheap, and
   outside the unit so it costs nothing against the measured time.
2. **Path classification** with `own_paths` and `dep_paths`. Anything matching neither is counted
   as unclassified and printed, so a reader can see how much of a verdict rests on globs.
3. **`parse_rebuilds`**, when the workload has one. Where a toolchain says out loud what it is
   compiling this is far better evidence, and it is the only layer that sees work served from a
   compilation cache without writing files.

For M1(b) there is a fourth signal: cache statistics before and after. A cache that transplants
shows near-total hits, which is the most direct evidence that variant can produce.

### Which warm build the 2x is measured against

`docs/poc-plan.md` says "time is within 2x warm" without saying which warm build. The harness
measures three references in the warm tree and reports all of them:

- `cold` — from an empty build directory. Context: what the cache saved.
- `warm_noop` — build again with nothing changed. The floor.
- `warm_own` — touch everything matching `own_sources`, then build.

**`warm_own` is the denominator.** A restore compared against `warm_noop` would fail every time,
since a no-op is seconds and any real restore is minutes; compared against `cold` it would pass
every time. `warm_own` is the local equivalent of what each variant is asked to do — rebuild the
project's own sources and nothing else. This is a reading of the plan rather than a quotation of
it, which is why it is written down here.

A variant passes when no dependency rebuilt, the file count is within 10% of `warm_own` (slack
for timestamps and lock files) and the build was within 2x `warm_own`. Missing classification, or
an M1(b) run that could not go cold, is `indeterminate`, never `pass`. An unset `dep_seed_attr`
or `cache_env` is `not_applicable` with the reason recorded — for a toolchain with no
compilation cache the result reads "toolchain has none", which is the outcome M1(b) asks for.

## M2

The seed is a full clone plus the warm build directory, in a btrfs subvolume, not a git
worktree: a worktree's `.git` is a file pointing back at the parent repository, so four
snapshots would share one index and one HEAD and their checkouts would collide.

Ten snapshots, because a snapshot that has been built in is warm and cannot serve a second
round: four for the serial round, two for the pair, four for the quartet. Branch assignment is
stable across rounds, so the same branch's divergence and build time compare across them.

**Level 1 runs all four branches, one at a time.** It is the uncontended reference, not a
single build, and it exists so that both sides of every ratio below do the same work. The
first run of this measurement compared one build of `m2_branches[0]` against a four-way round
whose makespan was set by a branch twice that size, and charged the difference to contention.
Levels 2 and 4 launch their builds simultaneously, each in its own unit with equal
`CPUWeight`, which is milestone 3's model — proportional shares, not quotas.

Recorded per round: each build's wall time, the maximum, and the makespan from first start to
last finish. Peaks, CPU time and `io.stat` come along, because I/O contention is the likeliest
bottleneck and a slow round is unexplainable without it. All accounting happens after the last
build of a round, so the harness never competes with what it is timing.

Two ratios, because "scale acceptably" is two questions and one number cannot answer both:

- **Contention**, the mean over branches of `wall(l1-b<i>) / wall(l4-b<i>)`: how much each
  build is slowed by the other three. Same branch, same work, both sides — which is what the
  paragraph above always intended.
- **Throughput**, `max(wall(l1-b<i>)) / makespan(level 4)`: the round against its critical-path
  bound. The bound is the longest uncontended build, not a quarter of the serial total: with
  jobs of different sizes no scheduler can beat the longest one, and dividing by four would
  fail a round that packed perfectly.

Both are fractions of an ideal, both are gated on `m2_scaling_min_efficiency`, and the verdict
names whichever fell short. Neither uses `makespan(level 1)`, which the first run showed is
dominated by `nix develop` entry inside the unit and moves by 900 ms between identical runs
while the four-way makespan moves by 7 ms.

Exclusive bytes come from `btrfs filesystem du -s --raw` per snapshot: no quota subsystem, no
rescan, no write overhead during the builds. Quota groups are enabled and rescanned afterwards
as a cross-check, and both numbers go in the table — a disagreement between them is itself a
finding.

The volume is a loopback image by default, sized by config, with `chattr +C` on the image when
the containing filesystem is itself btrfs, because nesting copy-on-write is pathological.
`FORGE_M_BTRFS_MOUNT` overrides it with somewhere on the operator's own btrfs, which is the
better measurement where they have one; the table marks loopback wall times as indicative,
since space numbers survive the loopback and throughput does not.

**Anywhere on btrfs, not a mountpoint.** This asked for a mountpoint first, which meant asking
for root to make one — and the loopback alternative needs `sudo mount` too, so an operator
without passwordless sudo could run no volume measurement at all, including the isolation cross
the whole tier rests on. What the layer actually needs is a filesystem that can make
subvolumes, and `stat -f` answers that. Unprivileged `btrfs subvolume delete` still fails
without `user_subvol_rm_allowed`; `subvol_delete` already falls back to `rm -rf`, which modern
kernels let the owner use on an empty subvolume.

## M3

Two numbers, and conflating them is the trap. The *undistorted peak* is measured with
`MemoryMax=infinity` and no swap: a binding ceiling would suppress the peak by forcing reclaim.
The *usable limit* is what `MemoryMax` should be per slice, which is not the peak, because a
build under mild pressure often still finishes. `--sweep` re-runs at fractions of the observed
peak and records success, OOM and wall time at each, and the recommendation is the smallest
factor that finished within an acceptable inflation. It is off by default because it multiplies
the cost of the measurement by five.

**The sweep builds cold.** It runs `clean_cmd` before each ceiling, so the build it binds on is
the build its ceilings were derived from. The first run of this measurement did not: it swept
around a 2009 MiB cold peak while re-running a warm build that peaks at 275 MiB, every ceiling
down to 0.75x passed trivially, and it recommended a slice smaller than the peak it had just
measured. That is the conflation this section opens by warning against, arriving through the
back door.

**The recommendation can never fall below the observed peak.** Whatever the sweep concludes,
the floor is the highest peak seen in any run of this workload, times the safety margin. A
sweep that binds correctly will not hit the floor; the floor is there so that no future way of
getting this wrong can produce a slice limit that a build already seen would not fit in.

The heaviest step is whatever `heaviest_step_cmd_<profile>` names, after
`heaviest_step_prepare_<profile>` has brought everything else up to date untimed. The harness
knows only "prepare, then measure this", which is what keeps it language-agnostic; a toolchain
that exposes no separable step records `not_applicable`.

Most of M3's data is already collected by the time `m3` runs: every M1 and M2 build carried a
peak. `m3` aggregates those and adds the runs nothing else performs.

## The isolation cross

M2 runs four builds together but never under a binding ceiling; M3 drives a build to its
ceiling but always alone. Neither tests the claim the worker tier actually rests on — *an
out-of-memory build kills one job, not the machine* — and `docs/measurements.md` says so. The
`isolation` subcommand is that crossing, and it exists as its own subcommand rather than as a
flag on M2 because the interesting case is asymmetric: one build under a ceiling below its own
peak, three beside it with none. Constraining all four kills all four and says nothing about
neighbours.

Two four-way rounds on fresh snapshots, in this order:

1. **The control round.** Four concurrent builds, no ceiling. It supplies the peak the ceiling
   is derived from and the wall times the neighbours are judged against, from the same
   contention as the round being judged. A serial reference would flatter the crossed round.
2. **The crossed round.** The same four branches, and branch 0 alone gets
   `MemoryMax = peak(branch 0, control) × isolation_victim_factor` (default 0.5).

The verdict needs three things, and names whichever is missing:

- **The victim died.** OOM-killed, or exited non-zero with the ceiling in force. A victim that
  finished means the ceiling did not bind, which is a failed measurement rather than a passing
  one — the harness says `indeterminate`, because it has learned nothing about isolation.
- **Every neighbour finished**, exit status zero.
- **The neighbours were not dragged down.** Each neighbour's wall time against its own wall time
  in the control round, gated on `isolation_min_efficiency`. This is the part that separates
  "killed one job" from "took the machine with it": a neighbour that survives but runs at a
  third of its speed is a machine that thrashed.

That the host survived is not asserted anywhere, because the harness asserting it would be the
harness reporting on its own existence. It prints the verdict from the host, which is the
evidence.

**The ceiling is derived, never configured.** A fixed number would drift out of relevance the
moment the workload or the machine changed, and the whole point is a ceiling that is below
*this* build's peak on *this* machine. `isolation_victim_factor` is a fraction of a measured
peak for that reason.

## Results

One directory per run. `env.json` holds host facts — kernel, systemd and btrfs-progs versions,
cores, memory, filesystem types and mount options, governor, the workload commit, the forge
commit. `run.jsonl` holds one object per build, appended as the run proceeds so a crash at
minute 90 still leaves everything up to minute 89.

`measurement` and `phase` are free strings, and a record with no census fields is legal. That is
what keeps the schema open for M4, whose records are timings rather than builds.

`bin/measure report` renders markdown to standard output. It does not rewrite
`docs/measurements.md`: that file is curated prose, and a script editing it would make the diff
unreviewable. The operator pastes, which is also how the numbers get read once before they are
committed. Sections are discovered from the data rather than hard-coded, so M4 appears in the
same table when it exists.

If no M1 variant passes, the report emits the consequence `docs/poc-plan.md` § Risks names: the
seed becomes a maintained btrfs blob kept in the platform's store. `not_applicable` never counts
as a pass, so a toolchain with no compilation cache and two genuine failures still triggers it.

A record marked `dry_run` makes the report print a banner and refuse the docs-ready form, so a
self-test table can never be mistaken for evidence.

## Verifying a harness that cannot run in CI

- `--dry-run` on every subcommand prints the ordered plan, every command line and every path,
  and executes nothing.
- `bin/measure selftest` runs all three subcommands against a fake workload — a git repository
  created on the fly whose build writes files and allocates a few hundred megabytes — with the
  two privileged layers substituted: commands run directly and report `VmHWM`, and the btrfs
  layer becomes plain directories with `cp -a` for snapshots and `du` for exclusive bytes. Both
  substitutions are stamped into every record.
- `report` is tested against a checked-in `run.jsonl` fixture covering pass, fail, each
  `not_applicable` reason and the all-fail case that must emit the btrfs-blob sentence.
- `preflight` run on a machine without btrfs is a real test of the loud-failure path.
- shellcheck and shfmt run in `bin/check`, over the harness and over the workload configs, since
  a sourced config's bugs are the harness's bugs.

## M4

M4 is a sequence of timed phases against a VM, not a build measurement, and the harness was
shaped so it did not have to be rewritten for it. What it reuses, as planned:

- `phase_begin` and `phase_end` are the timing primitive; `measure_run` is built on them. M4
  records `create-vm`, `machine-configured`, `worker-connects`, `seed-fetched`, `nix-store-populated`
  and `first-build` as ordinary phases and uses `measure_run` for the last.
- `measure_exec` is the single function that decides how a command runs. `FORGE_M_SSH` selects
  the variant that starts the unit inside the guest instead of on this host; M1 to M3 did not
  change for it. Nothing else may call `systemd-run` or assume the working directory is local.
- The config schema, `workload_validate` with a caller-supplied key set, the record schema and
  the renderer are all shared, which is what keeps the results table single.

Two things came out differently from the plan, and both are in the measurement rather than in
the harness:

**The seed is fetched before the Nix store is populated**, not after. The seed carries the
checkout whose flake the store is populated from, so the other order would need a second
checkout that no worker ever makes. `docs/design/worker-tier.md` § Volumes and the seed has the
rest of it: a machine cannot fetch a seed before it knows which project it is for, and what
tells it that is an assignment.

**M4 boots the machine itself rather than asking the platform to.** It builds the same overlay,
the same config disk and the same QEMU invocation the provider driver does, with credentials
from `mix forge.worker.new`. The alternative — admit a ticket and watch — would measure the
scheduler's poll interval and the agent's wall clock along with the cold start, and could not
separate them. The cost is that the driver and M4 now describe the same machine in two places,
and a change to one is a change to the other.

**No preflight.** M4 needs a hypervisor, an image and a platform; it does not need this host's
btrfs or cgroups. `m4_require` checks what it does need and names what is missing, the way
preflight does for the rest.

`seed_create` stands alone rather than being inlined into M2 for the same reason it always did:
`btrfs send` belongs next to it when it arrives.
