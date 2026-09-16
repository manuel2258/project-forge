# The worker tier

Scope: milestone 3. The machine that hosts agents, how it is created and destroyed, how a job is
isolated on it, where its worktree and build directory come from, and how a job survives being
interrupted. `docs/decisions.md` settles the architecture — transient systemd units, btrfs
copy-on-write, `nix develop`, a provider driver, a worker that dials out — and M1 to M3 supply the
numbers this note carries. Nothing here reopens those.

What changes in this milestone: the platform stops running jobs in its own BEAM. Today
`platform/mix.exs` depends on `forge_worker` by path and `Forge.Jobs.start/1` spawns a runner
in-process. After this milestone the platform knows workers only through the provider driver and
the channel, and `forge_worker` is a release that runs on a different machine.

## Worker lifecycle

The `workers` row already carries the states (`platform/lib/forge/workers/worker.ex`). What moves
them:

| State | Set by | Meaning |
|---|---|---|
| `creating` | the platform, before calling the driver | The row and its token exist; the machine may not. |
| `ready` | the worker's `ready` message | Booted, Nix store populated, seed present. Assignable. |
| `busy` | the platform when a job is assigned | At least one job running. Still assignable if budget remains. |
| `idle` | the platform when the last job ends | The idle timer is running. |
| `destroyed` | the platform after the driver returns | Terminal. The row stays; the token stops working. |

The row is written before the machine is created and kept after it is destroyed, so there is never
a machine the platform has no record of. The opposite — a row with no machine — is recoverable and
is what a failed `create` leaves.

**`creating` is not assignable, and neither is a worker that has joined but not reported `ready`.**
A worker joins the channel when the release boots, which is minutes before its Nix store and seed
are usable. `docs/design/worker-channel.md` § Messages says why `ready` is a separate message.

### Managed and unmanaged

A `managed` worker is one the platform created through the driver and may therefore destroy. An
**unmanaged** worker is a machine the operator provisioned and told the platform about with
`mix forge.worker.new` — long-lived, and not the platform's to power off. The column exists
because the two differ in exactly one way, and it is the only way that matters: *who may end
this machine's life.*

Everything else is the same. An unmanaged worker joins the same channel with the same kind of
token, is scheduled by the same memory gate, runs the same slices, and counts against
`max_workers` like any other — that setting is how many machines exist, not how many the
platform made. Setting `max_workers` to 0 and provisioning by hand is the pure permanent model;
leaving room above the permanent ones is a permanent worker with burst capacity.

**"Everything else is the same" includes the harness credential**, and that is the part it is
easy to get wrong. `mix forge.worker.new` prints the whole environment a machine needs, the
credential included, because it stands in for the driver and the driver injects it — see below.
A machine minted without it joins, reports `ready`, is scheduled, and then fails every job it is
given with *Not logged in*: a worker that looks healthy on every surface the operator has and
cannot do the one thing it exists for. Anything that mints a machine's environment mints all of
it.

**Why not infer it from `provider_id`.** A machine the platform did not create has no
`provider_id`, and `destroy/1` already reads that to skip the driver — so it looks like the
signal is there for free. It is not: a `create` that fails leaves a row with no `provider_id`
either, and treating that as permanent would leave it holding a `max_workers` slot for ever.
That is precisely the deadlock § What the operator's machine settled records finding the hard
way. A failed create and a machine somebody else owns are not the same thing and must not be
spelled the same.

**An unreachable unmanaged worker loses its jobs but keeps its row.** The jobs are re-queued —
they are re-runnable by construction and nothing is observing them — but the row stays, because
the machine may well come back and a `destroyed` row can never rejoin. A managed one is
destroyed as before: it is cattle, and the platform can make another.

## The provider driver

`Forge.Provider`, one implementation in the PoC:

```
@callback create(opts) :: {:ok, %{provider_id: String.t(), address: String.t()}} | {:error, term}
@callback destroy(provider_id) :: :ok | {:error, term}
@callback status(provider_id) :: {:ok, :pending | :running | :gone} | {:error, term}
```

`opts` carries the worker id, the token, the platform's address and the machine size. That is the
whole surface, and it matches what `docs/vision.md` says a provider is: create a machine, destroy
it, and somewhere to put bytes. The bytes are `Forge.Storage`'s (`docs/design/storage.md`), not
the driver's, which is why `create` and `destroy` are all that is left here.

**Nothing above the driver knows the provider.** Not the scheduler, not the channel, not the
worker. A module that pattern-matches on `"local"` outside `Forge.Provider.*` is the bug this
callback set exists to prevent, and the Hetzner implementation in the closing step is the test of
whether it worked.

`Forge.Provider.LocalVm` boots the NixOS worker image under QEMU: a copy-on-write overlay on the
image so the base is never written, user-mode networking with no inbound ports, and a config disk
carrying the worker id, the token and the platform's address. `destroy` kills the process and
removes the overlay and the disk. `status` reads the process.

**One door, and it is shut by default.** A worker has no inbound port; that is the property the
direction of the channel exists to give. `ssh_key` and `ssh_port` open one anyway — a forward
from the platform host's loopback to the guest's sshd, with a key the config disk carries — and
two things need it. M4 measures cold-start phases from outside the guest
(`docs/design/measurement-harness.md` § What M4 reuses), and a job that failed on a machine
about to be destroyed has left its stderr on that machine and nowhere else. Both are the
operator's own machine looking at its own VM. Neither is configured unless the operator does it,
and the Hetzner implementation in the closing step is free to have no equivalent.

`Forge.Provider.Fake` records calls and returns synthetic ids. It is what the platform's tests run
against, and it is also the honest way to develop the platform on a machine that cannot boot a VM.

## The worker image

A NixOS image, built by the flake, that boots unchanged both locally and — after the closing step
— on the provider.

- btrfs root, so the volume layer below has subvolumes to snapshot.
- The Nix daemon, with the binary cache configured, so `nix develop` on the project's flake is a
  download rather than a build.
- Claude Code, which is unfree and needs the same `allowUnfreePredicate` the platform module
  already carries (`docs/deploy.md`).
- The `forge_worker` release, started by a systemd unit that reads the worker id, token and
  platform address `forge-worker-config.service` found.
- No project toolchain. The workload is a parameter: the environment comes from the project's own
  flake through `nix develop .#<env>`, exactly as `ForgeWorker.Job.Runner` already does it.

## How a machine learns what it is

The image is **identical for every worker**, and that is load-bearing rather than tidy: it is what
makes `create` a `qemu-img` overlay on a shared read-only base — 237 ms, M4 — instead of a Nix
build, and it is why the image can be cached and copied. The moment one per-machine fact is in it,
a worker needs an image of its own. So something has to inject at boot, and the only question is
what.

`forge-worker-config.service`, a oneshot ordered before the release, writes `/etc/forge-worker.env`
(0600, root) from the first source that answers:

1. **A filesystem labelled `forge-config`**, mounted read-only, holding one file of `KEY=VALUE`
   lines. Locally the driver builds it with `genisoimage` and attaches it as a virtio disk. The
   block device is root's, so a job cannot read it.
2. **The provider's metadata service**, `FORGE_CONFIG_URL`, defaulting to Hetzner Cloud's
   `http://169.254.169.254/hetzner/v1/userdata` — which returns whatever was passed as the
   server's user data, so the provider driver passes exactly the bytes the disk would have held.

Same content both ways, so the unit has one parser and the image has one contract: *give me an
environment file, by whichever route you have.*

**This replaced cloud-init, which used to do it.** Cloud-init was chosen because a provider speaks
it, and it was doing exactly one job nothing else could — the injection above. Everything else it
did on a worker, NixOS already did or could do in a line: hostname, DHCP, growing the root
partition (which it did *twice*, once as NixOS's `boot.growPartition` and once as its own
`growpart`), the random seed, ssh host keys.

**The reason is not size, and the first draft of this paragraph said it was.** Cloud-init's own
closure is 422 MiB, which is what made removing it look obviously worthwhile; its *marginal* cost
to the image was 27 MiB (1507 → 1480 MiB), because nearly all of that 422 is shared. In
particular the Python runtime stays — `git` depends on it, and a worker cannot do without git. A
change argued on a number should be checked against the number, and this one was not until after
it was written.

What it is actually worth: **7.5 seconds off every cold start** — M4's `machine-configured` phase
went from 20.0 s to 12.5 s, a 37 % fall, and that one is attributable because nothing else in the
phase changed. Beyond the clock, the boot path is now twenty lines of shell that can be read in
one sitting instead of a module pipeline whose default list nobody on this project had audited;
the double `growpart` is gone; and the contract between a driver and the image is one sentence
rather than a dialect of YAML. In an appliance whose whole purpose is confining code an agent
wrote, that is worth 27 MiB of nothing.

**The metadata service is closed after it is read.** On a provider, `169.254.169.254` answers any
process on the machine, including the agent — so the user data holding the worker token and the
harness credential would be one `curl` away from a job. The config unit drops the route to it once
it has what it needs. Locally there is nothing there to drop, and the rule is harmless.

**What this gives up, and why it is worth it.** Cloud-init's other modules were free in the sense
that nobody had to write them; a provider whose networking needs more than DHCP, or whose disks
need `disk_setup`, would have been handled without a change here. That bill comes due at the
closing step if Hetzner turns out to need any of it. Against that: the injection path is now
twenty lines that can be read in one sitting, and the boot no longer depends on an agent whose
default module list nobody had audited. **The Hetzner half of this is written but unrun** — the
local half is exercised on every boot, and § What the operator's machine settled says what that
distinction has been worth so far.

The image pins nothing about any particular project, and it is the one artefact of this milestone
that cannot be built or booted anywhere but the operator's machine.

**It is an appliance, not a host.** `nix/worker-image.nix` builds it with `systemd-repart`: an
ESP holding systemd-boot and one unified kernel image, and a btrfs root partition holding the
closure. There is no system profile and nothing to `nixos-rebuild`, because a worker is replaced
rather than updated. `make-disk-image.nix`, the usual route, was not taken: it can only make an
ext4 root, and the volume layer needs btrfs.

Two consequences the driver carries, and they are why `Forge.Provider.LocalVm` is not the
three-argument QEMU invocation it looks like it should be:

- **The machine boots UEFI**, so the driver passes QEMU an OVMF code image and gives each
  machine its own writable copy of the variable store. The devshell exports both paths; nothing
  in the platform can guess them, so a driver without them refuses to create rather than
  starting a machine that hangs at the firmware.
- **The image is small and the machine's disk is not.** repart minimises the root partition, so
  the overlay is created larger than the image it backs and the guest grows its partition and
  filesystem into it on the first boot. What has to fit is the Nix store, the seed and several
  build directories — none of which are in the image.

A repart image carries the closure's files but not the Nix store's database, so the image
registers it once at first boot, as the installer images do. Without that a fresh machine's
`nix` considers every path invalid and sets about fetching what it already has.

**The harness's environment is the machine's, not the job's.** Claude Code needs an
`ANTHROPIC_API_KEY` or a `CLAUDE_CODE_OAUTH_TOKEN`, and neither is scoped to one job nor short
lived, so neither belongs in an assignment: `docs/design/worker-channel.md` reserves per-
assignment tokens for credentials that are both. It is injected at creation by the same route that
carries the worker token — § How a machine learns what it is — and the release reads it from its
environment exactly as the platform did while it ran jobs itself. That is one route and not two:
the driver writes it into the config the machine reads at boot, and `mix forge.worker.new` prints
it beside the worker token for a machine the operator is provisioning by hand. The blast radius is
one machine, which is already the blast radius of the worker token sitting beside it. The model
rides along for the same reason — it is an operator setting, not a per-job one, until the workflow
grammar has something to say about it. The executable does not: the platform's is a path on the
platform's host, and the image has its own.

## Scheduling

`Forge.Jobs.Scheduler` stops counting jobs and starts measuring memory.

A job's slice is `slice_memory` — configuration, defaulting to **2.2 GiB**, which is M3's observed
peak (2009 MiB) plus its margin (`docs/measurements.md` § M3). A worker's `memory_budget` is its
RAM less a reserve for the system and the Nix daemon. A job is assigned only when its slice fits
what the worker has left. That is the rule `docs/vision.md` states, and the reason it is a rule is
the claim the whole tier rests on: an out-of-memory build kills one job, not the machine.

Two gates now compose, and they answer different questions:

1. **The window gate** (`docs/design/capacity.md` § Gate the scheduler): may we spend an
   invocation at all? A blocking rate-limit window pauses everything.
2. **The memory gate**: does this job's slice fit on a worker we have, and if not, is it worth
   creating one?

The window gate runs first. Nothing is gained by creating a machine for a job that cannot start.

When no ready worker has room, the platform creates one — up to `max_workers`, which is 1 for the
PoC because everything runs on the operator's laptop. A job that fits no worker and cannot have one
created stays `pending`; it is not an error, and the ticket stays `active`.

**2.2 GiB is the sample's number, not the operator's.** `docs/measurements.md` is explicit that M2
and M3 proved mechanism rather than quantity, and that issue #12 replaces both with the operator's
project's numbers. It is a configured default precisely so replacing it is a config change.

## The job slice

One transient systemd unit per job, started by the worker:

```
systemd-run --pipe --wait --collect --unit=forge-job-<job_id>
            --uid=<per-job user> --property=WorkingDirectory=<worktree>
            --property=MemoryMax=<slice> --property=MemorySwapMax=0
            --property=CPUWeight=100
            -- <nix develop .#env --command> <harness>
```

- **`MemorySwapMax=0`.** A slice allowed to swap does not die at its ceiling, it drags the machine
  down to disk speed and takes its neighbours with it. The ceiling should kill.
- **Equal `CPUWeight`.** Proportional shares, not quotas: an agent waiting on inference donates its
  share to whoever is compiling, which is the behaviour `docs/decisions.md` asks for and quotas
  would prevent. `measure/`'s M2 already runs its builds this way.
- **A fresh Unix user per job**, created at assignment and removed after, owning the snapshot and
  the job directory. It is what stops one job reading another's worktree, credentials or outputs on
  a machine where several run at once. The ownership is handed back when the slice is cleaned up,
  before the worker commits and pushes: git refuses to work in a repository owned by somebody
  else, which is how a repository's own configuration gets executed by a user who did not write
  it, and files owned by a deleted uid otherwise outlive every job the machine ever runs.
- **`--pipe --wait`** so the runner's existing Port sees the harness's stdout and its exit, which is
  what `ForgeWorker.Job.Runner` is already built around. The unit is the wrapper, not a new
  execution model.
- **The environment is named, not inherited.** systemd starts the unit with its own default
  environment rather than `systemd-run`'s, so everything the runner composed — `PATH`, `HOME`, the
  job directory, the harness's own variables — is passed as `--setenv`. A secret is named without
  its value, which `systemd-run` then reads from its own environment: the value reaches systemd
  over the bus instead of sitting in an argument vector for the length of the job. This is why the
  slice is told the environment in `prepare/1` rather than only the command in `wrap/3`.

This is behind `ForgeWorker.Slice`, with two implementations: `Slice.Systemd` as above, and
`Slice.Direct`, which is what the runner does today — spawn the process with no unit and no limit.
`Direct` is not a mock. It is how the worker runs during development on a machine without systemd,
and it is the only implementation that can be exercised in a container. The same substitution is
what `measure/`'s selftest already makes for the same reason
(`docs/design/measurement-harness.md`), and stamping which one ran is part of the record there and
here.

## Volumes and the seed

Each job gets its own worktree and build directory, snapshotted from a warm seed.

**The seed is a full clone plus its warm build directory in a btrfs subvolume — not a git
worktree.** `docs/design/measurement-harness.md` § M2 gives the reason: a worktree's `.git` is a
file pointing at the parent repository, so four snapshots would share one index and one HEAD and
collide. This is a change from milestone 1, where the platform ran `git worktree add` on its own
disk; that call goes away with the path dependency.

**The seed is maintained, not derived.** M1 settled this and it is the one place a measurement
moved the design: a build directory produced reproducibly from the dependency closure is rejected
by the toolchain (every dependency rebuilt, no better than cold), while a warm build directory
copied from another checkout path rebuilds only the project's own sources at 1.34× a warm local
build. So the seed is a blob somebody keeps up to date, held in the store under
`seed/<project>/<seed_id>`, and refreshing it is an operator action with a Mix task behind it.
`docs/measurements.md` says M1 variant (b) is unrun and could lighten this later; nothing here may
assume the heavy form is permanent, which is why the seed reaches the worker through
`Forge.Storage` like any other blob.

Transport is a compressed tar of the subvolume's contents, unpacked into a fresh subvolume on the
worker. Not a `btrfs send` stream: that would require the producer — the platform host, or whoever
refreshes the seed — to be btrfs too, and the PoC may not assume it. `btrfs send` belongs next to
`seed_create` in the harness when both ends are btrfs.

**The seed is fetched per project, on the first job for it, not before `ready`.** This note said
the opposite first — boot, join, populate the Nix store, fetch the seed, *then* report `ready` —
and that ordering cannot be built, because a machine does not know what project it is for until it
is assigned something. Pinning a worker to a project at creation would fix that and cost more than
it is worth: `max_workers` is 1 in the PoC, so a pinned machine is a queue that stops the moment
two projects both have tickets. So the assignment carries the seed's key and a token for it, the
worker fetches once and keeps it, and every later job for that project snapshots what is already
there. The machine reports the seeds it holds in its join payload and in `ready`.

What that costs is that the first job for a project pays for the download inside its own wall
clock, along with populating the Nix store, which happens on the first `nix develop` for the same
reason. What it buys is a machine that is assignable as soon as its release is up, and one machine
that can serve every project. M4 measures both as phases of the first job, which is where they
now are.

**A worker with no seed still works.** It clones the repository and builds cold. The seed is what
makes the demo fast, not what makes it correct: a project nobody has published a seed for, and a
fetch that fails, both end in a clone rather than an error.

Per job: `btrfs subvolume snapshot <seed> <job worktree>`, then check out the ticket branch in it.
On job end the snapshot is deleted — after the push and the transcript upload, because everything
that must survive has left the machine by then. Behind `ForgeWorker.Volume`, with `Volume.Btrfs`
and `Volume.Copy` (`cp -a`, delete by `rm -rf`) — again the substitution `measure/` already makes,
and again not a mock: `Copy` is correct, just without the sharing.

**A snapshot is not cleaned, and a reused worktree is.** `git clean -fd` is what stops a run
inheriting what a dead one left behind, and it is exactly the command that deletes the warm build
directory the seed exists to carry. A fresh snapshot has nothing to inherit, so it only checks out
the branch; a worktree that survived a previous run is cleaned. Relying on the build directory
being in `.gitignore` would work for most projects and fail silently for the rest.

### The ticket volume: warmth between a ticket's own jobs

The seed makes a job's *first* build fast. It did nothing for the second, and a ticket is several
jobs: implement compiles the ticket's changes into a snapshot, the snapshot is deleted when the
job ends, and verify snapshots the same cold seed and compiles them again. The worktree is keyed
by job id, so nothing carried between them.

**So a ticket gets a volume of its own, and it is a seed one level down.** `volumes/ticket/<n>` on
the machine, made by snapshotting the project's seed on the ticket's first job here, and replaced
by a snapshot of the finished worktree when a run ends. The next job for that ticket snapshots the
ticket volume instead of the project seed, and starts warm for the code this ticket has been
writing rather than the code the seed was published at.

Every rule above survives, because the ticket volume is a *template* and never a worktree a job
runs in:

- **A job's worktree is still per job and still disposable.** It is snapshotted from the template,
  and deleted when the run ends, exactly as before.
- **A fresh snapshot is still not cleaned, and a reused worktree still is.** The template is only
  ever a snapshot source, so `clean: false` keeps meaning "this tree has nothing a dead run left".
- **The template's HEAD does not matter.** `Checkout.reset/3` does `checkout -B <branch>
  FETCH_HEAD` before `reset --hard`, for the seed's sake — a seed is on whatever commit it was
  built at — and that repoints a ticket volume sitting on the last job's commit just as well.

**Promotion happens only after the run committed and pushed**, and that is what makes the template
safe to snapshot without cleaning. `Checkout.squash/3` does `reset --soft origin/<branch>` then
`add -A`, so after a successful run every untracked file that was not ignored has been committed,
and what is left beside the checkout is the ignored build output the whole mechanism is for. A run
that failed before it pushed keeps its worktree's untracked debris, and promoting that would hand
the next job exactly the inheritance the clean rule exists to prevent. So a failed run promotes
nothing and the ticket keeps the template it had.

**Only ticket branches.** A conversation holds one worktree for the whole of its life
(`ForgeWorker.Job.Conversation` prepares once and discards at close), so it already keeps its own
warmth and a template would be a second copy of it. The branch name becomes a path here, so it is
matched against `ticket/<number>` before it is used as one rather than trusted because the
platform sent it — the same reason `Forge.Storage.Key` validates a key the platform built.

**It is machine-local, and nothing announces it.** No upload, no new channel message, and nothing
tells a machine that a ticket merged or was abandoned — the platform's messages are `assign`,
`cancel` and `drain`. So a ticket volume is swept by age like the job directories beside it,
defaulting to two days: long enough to cover a ticket blocked on a question overnight, short
enough that a machine which never dies is not holding a volume per ticket it ever touched. The
exclusive bytes are what that ticket's builds wrote, which M2 measured and which is the number
that matters on a real host.

**On `Volume.Copy` promotion is a full `cp -a`.** On the image it is a btrfs snapshot and costs
nothing; on a machine without btrfs — a development machine, a container — each promotion copies
the tree. Correct either way, and slow in the place that is already slow.

What this deliberately does not do is move warmth *between* tickets. When a ticket merges, its
volume is the best possible starting point for the next ticket on that machine, and promoting it
to be the project's local base is the obvious next step — and a separate one, because it needs a
merge signal the channel does not carry today. Publishing a new project seed from it is the step
after that, and it is not free: the store is content-addressed per whole archive, so it costs a
full seed upload per merge and a full download on every machine that later wants it. Both wait for
the idle period's own question to be answered, because how often a machine is destroyed is what
decides whether local warmth is worth keeping at all.

**Which seed is current is the database's.** `projects.seed_id` holds it, set by `mix
forge.seed.publish PROJECT DIRECTORY`, which archives the directory, names it by the archive's own
hash and uploads it. The store has no listing and is not getting one (`docs/design/storage.md` §
The behaviour), so nothing can discover the current seed by looking.

## Git

The worker no longer shares a disk with the platform, so it clones and pushes over HTTP.

**The endpoint and the token are milestone 4's**, and `docs/design/git-hosting.md` is the note
that owns them: `git http-backend` behind a plug at `/git/<project>.git/*`, a `git_tokens` row
scoped to one project, one capability and — for a write — one `refs/heads/ticket/<n>`, and a
`pre-receive` hook that enforces the ref from the environment the CGI wrapper set. This note
proposed a thinner version of both while milestone 4 was being written in parallel; milestone 4's
is the one that exists, and it is better in every respect the two overlap on.

What is this milestone's is *where the token is issued and who spends it*. The issuing point
moves from `Forge.Jobs.start/1`, which no longer exists, to `Forge.Jobs.assign/2` — still the one
choke point every billed invocation passes — and the credential travels in the assignment rather
than into a runner in the platform's own BEAM. It is revoked when the job ends, as before.

**The clone, the push and the squash are the worker's.** `ForgeWorker.Checkout` is the whole of
what changes when the worker moves to another machine, which is what its own note predicted; this
milestone is the move. The agent gets `FORGE_GIT_URL` and `FORGE_GIT_TOKEN` in its environment as
it always did, so it can fetch and push on its own, and the worker pushes what the run left before
it reports anything.

**One commit per run, taken from the remote rather than from HEAD.** The worker resets the
worktree to the branch as the platform has it, stages everything and makes one commit. The
obvious version — `git add -A`, commit if anything is staged, push if we committed — is wrong
against a real agent, and the first end-to-end run on a real machine is how that was found: Claude
Code committed its own work, so nothing was staged, so nothing was committed, so nothing was
pushed, and a converged job left its changes on a machine that was about to be destroyed. The
squash is what makes the agent's commits part of this run's change instead of history the worker
walks past.

**Boundary with milestone 4, as it turned out.** `docs/poc-plan.md` files smart HTTP under
milestone 4, and this note originally recorded a scope call to take the minimum of it early,
because a remote worker cannot work without one. The two milestones were then built in parallel
against the same base, so both arrived. Milestone 4's git hosting stands and this milestone's
thinner version was dropped whole on landing — a `Phoenix.Token` with a `%{job_id, repo, branch}`
claim, and a plug that authorised from it. Nothing was lost: every property that version was for
is a property `docs/design/git-hosting.md` states more carefully.

The lesson is worth more than the code was. Two milestones built from one base will both build
whatever sits between them, and the one that is *only* enough to unblock the other is the one to
throw away — not the one that was designed.

## Updating a worker

The image is an appliance and a worker is replaced rather than updated — that is the rule, and
it stays the rule for the base: NixOS, Claude Code, the Nix settings, the unit that fetches the
identity. Those change rarely and no-drift is worth having.

**It is the wrong mechanism for the release, and the numbers say so.** The image is 1.8 GiB; the
worker release's own store path, which is all that changes on a code edit, is 24 MiB. On a
provider it is worse than a ratio: Hetzner Cloud has no image upload, so a new image means
booting a rescue server, writing the disk, snapshotting it and throwing the server away — minutes
of pipeline to deliver a few megabytes of BEAM code, for the component that changes most often
while the tier is being built.

So the release is separable from the image. `ExecStart` runs `/var/lib/forge/release`, a symlink
rather than a store path, and an *indirect* GC root points at it so a release put there by hand
is not collected by the `min-free` sweep. A machine with nothing overriding it points the symlink
at the release the image was built with, so the default is exactly what it was.

**`bin/worker-update` is the dev-phase tool and only that.** It builds the release, `nix copy`s
it over the ssh door, repoints the symlink and restarts the unit — seconds, and the machine keeps
its warm Nix store and its seeds, which a replaced machine does not. It needs the ssh door
(§ The provider driver), which is shut by default and forwards from loopback, so it works where
the operator can already reach the machine and nowhere else. **It does not work on a provider**,
by construction: a worker there has no inbound port, which is the property the whole channel
direction exists to give.

What that needs instead is the same operation pulled rather than pushed, and every piece is
already here: `drain` stops the worker taking work, the store serves it blobs under scoped
short-lived tokens, and the channel carries platform-to-worker messages. An `update` message
carrying a store key and a token, a fetch, a symlink swap and a restart uses no new transport and
no new kind of credential. It is not built, because nothing yet runs a worker the operator cannot
ssh to.

**A machine says which build it is running when it joins.** Once the release is separable from
the image, "what is this worker running" stops being answerable from the image, and the
application version does not answer it either — every release in the PoC is `0.1.0`. What
changes on a code edit is the store path, so the join line names it:

```
joined worker:8eaaacc1-… running 0.1.0 (8rh57whmgk6m); ready with 6176456704 bytes
```

which is the first twelve characters of what `nix build .#forge-worker` prints, so the operator
can compare the two without logging in. It is a log line and not a channel field on purpose —
see the second point below for why it will have to become one.

Two things it will need that do not exist, and both get harder the longer they wait:

- **Rollback.** A release that will not start leaves a machine that will not work, and the
  symlink's previous target is the whole of the fix.
- **A version on the wire.** Nothing in `docs/design/worker-channel.md` carries one, which is
  harmless only because platform and worker are built from one flake and move together. A worker
  that can be updated on its own — or simply kept for months — breaks that, and an unknown
  message is currently a log line rather than a refusal. The build identifier above is in the
  worker's log, where the platform cannot see it; the platform is the side that has to decide
  whether to send a machine work.

## What a machine that never dies accumulates

Four things grow without bound, because until a worker could be permanent the machine's own
destruction collected them. Each has a rule, and the rules are retention rather than lifecycle on
purpose: a worker cannot always tell whether a job will be resumed, and a sweep that only has to
know an age is a sweep that cannot get that wrong.

- **Job directories.** `<root>/jobs/<job_id>` holds the prompt, stderr, the transcripts and the
  agent's private `HOME` — which is where Claude Code keeps the session a resume needs, so it
  cannot simply go when the job ends. Directories untouched for `job_retention_ms` are removed
  when a job finishes, which is a moment the worker is already doing filesystem work. A crash
  leaves nothing behind that the next job's sweep will not collect.
- **Ticket volumes.** `<root>/volumes/ticket/<n>`, one per ticket this machine has run a job for
  (§ The ticket volume). Swept at the same moment as the job directories, at
  `ticket_volume_retention_ms` — two days by default, shorter than a job directory's week because
  a volume is a warm build directory rather than a few files. The exclusive bytes are what that
  ticket's builds wrote, which is the figure M2 measured and the one that matters on a real host.
  Nothing tells this machine that a ticket merged, so there is no lifecycle here to use instead.
- **Seeds.** A worker keeps one seed per project and fetches a new one when the project's
  `seed_id` moves; the old one used to stay for ever at a few hundred megabytes a time. Fetching
  a seed now removes the others under `seed/<project>/`. A running job holding a snapshot of the
  old one is unaffected — a btrfs snapshot is not a child of its source, and the extents live as
  long as anything references them.
- **The Nix store.** Every project's `nix develop` closure stays for ever. The image sets
  `min-free`/`max-free`, so the daemon collects during a build when the disk gets tight, rather
  than on a timer that fires when nothing is wrong. The cost is that a seldom-used project's
  closure may have to be fetched again; the alternative is a full disk, which costs every
  project at once.

**None of this is per-job hygiene, and it should not become it.** A job's *worktree* is deleted
the moment the job ends, because that is a snapshot whose whole cost is what the job wrote into
it. These three are shared or resumable, and deleting them eagerly would either break a resume
or throw away the warm start the seed exists to provide.

## Hibernation and resume

A job that is interrupted — cancelled, drained, out of budget, a worker being destroyed — commits
before it stops. `docs/decisions.md`: jobs are disposable, anything that must survive is committed
to the branch or written to the store, history is squashed.

The sequence: SIGTERM the harness, wait the grace period, `git add -A` and commit in the worktree,
push to the ticket branch with the job's token, upload the transcript to the store, send
`hibernated` with the commit sha. The platform records the sha and sets the job `hibernated` — a
status that has existed since milestone 1 and has never been reachable.

Resume reconstructs from the branch and the manifest, never from the conversation. The spec is
immutable and already in the row; inputs are re-pinned at run time as they are today; the worktree
is a fresh snapshot with the branch checked out at the commit the hibernation left. Conversation
resume is attempted only when the same worker still has the same worktree path, because Claude
Code's session lookup is per project directory and will not find it anywhere else
(`docs/design/claude-code-events.md`). When it is not found, the job runs from the prompt and the
artifacts, which is the contract.

## Idle destroy

A worker with no running jobs goes `idle` and starts a timer. On expiry the platform sends `drain`,
waits for the last job to end, destroys the machine through the driver, and marks the row
`destroyed`. The next ticket creates a new one.

The period is configuration, and its default is now M4's rather than a guess: **five minutes**.
M4 measured a machine going from nothing to able to build in about 35 seconds
(`docs/measurements.md` § M4), which is what being wrong costs — less than the operator's own
round trip to approve the artifact that produces the next ticket. Five minutes covers an
approval gap without holding a machine through a lunch break.

The number is local, and the two phases that dominate it are the two the closing step makes
worse: the seed arrived over loopback and the Nix store came from the binary cache over the
host's own connection. On a provider both are network-bound, the cold start gets longer, and
the argument for a longer idle period goes with it. Re-measuring there is the closing step's.

## What the operator's machine settled

Most of this milestone was written in a container with no KVM, no systemd as PID 1, no btrfs and
no Nix, so five things were argv and assertion rather than evidence. All five have since run on a
machine that has them, and what that found is worth keeping, because in every case the tests
against the fakes passed and the real thing did not.

- **`Provider.LocalVm` never booted anything.** Its invocation passed both `-nographic` and
  `-daemonize`, which QEMU refuses to combine, so `create` could only ever have failed. The image
  also needs UEFI firmware and an overlay larger than itself, neither of which a command-shape
  test can notice.
- **`Slice.Systemd` dropped the whole environment.** systemd starts a transient unit with its own
  default environment, not `systemd-run`'s, so the process the runner had carefully composed an
  environment for got none of it — and could not change into a worktree owned by the user the
  slice had just given it to. § The job slice has both.
- **`Volume.Btrfs` works, and the seed it snapshots did not.** `tar` as root restores the owners
  the archive recorded, so every seeded worktree was a repository git refused as dubiously owned.
  It fell back to cloning, which is why this was a slow first run rather than a failed one.
- **The image builds and boots**, and M4 measured the cold start it makes: about 35 seconds
  from nothing to a machine that can build (`docs/measurements.md` § M4). The idle period is that
  measurement's now rather than a guess.
- **The claim the tier rests on is measured.** Four concurrent builds with one under a ceiling
  below its own peak: the constrained build was killed by its own cgroup, the other three
  finished (`docs/measurements.md` § The isolation cross). Milestone 3's demo then showed the
  same thing with real jobs — one ticket's agent asked for six gigabytes inside a 2210 MiB slice
  and was OOM-killed with `constraint=CONSTRAINT_MEMCG`, while the ticket beside it on the same
  machine converged.

Two things the demo showed that no test could: an assignment carries a `MemoryMax` that binds in
practice, and a worker really is destroyed after its idle period and recreated by the next
ticket.

## Open

- **`slice_memory` is one number for every job.** A refine job and a build job get the same
  ceiling. Per-state slices belong in the workflow grammar, and there is no evidence yet that the
  difference matters.
- **`max_workers` is 1 for the PoC.** Nothing in the scheduler assumes it; nothing has tested it
  above 1 either.
- **Seed refresh has no schedule.** Someone runs the Mix task. How stale a seed may be before it
  costs more than it saves is a dogfooding question.
- **A partitioned worker is destroyed, not waited for.** Correct while jobs are re-runnable and
  machines are cattle; revisit if a job ever becomes expensive enough to want recovery.
- **The model a job asks for is not part of what makes a worker assignable.** It cannot bite
  while `max_workers` is 1, which is the item above that gates it: this matters only once the
  fleet is large enough to be heterogeneous. Stated once, in
  `docs/design/worker-channel.md` § Open, beside the `ready` message that carries the data it
  would be matched against.
