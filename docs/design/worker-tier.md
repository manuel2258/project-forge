# The worker tier

Scope: milestone 3. The machine that hosts agents, how it is created and destroyed, how a job is
isolated on it, where its worktree and build directory come from, and how a job survives being
interrupted. `docs/decisions.md` settles the architecture — transient systemd units, btrfs
copy-on-write, `nix develop`, a provider driver, a worker that dials out — and M1 to M3 supply the
numbers this note carries. Nothing here reopens those.

What changed in this milestone: the platform stopped running jobs in its own BEAM. Before it,
`platform/mix.exs` depended on `forge_worker` by path and `Forge.Jobs.start/1` spawned a runner
in-process. Now `forge_core` is the only project the platform depends on by path, it knows
workers only through the provider driver and the channel, and `forge_worker` is a release that
runs on a different machine.

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
token, is scheduled by the same gate and runs the same slices.

**It counts against no ceiling**, which is the one thing here that changed. While `max_workers`
was one number for the node it counted every machine, the operator's included, and setting it to
0 was how a node ran on permanent machines alone. The ceiling is a worker template's now, and
`Provisioning.live_count/1` counts the rows carrying that template's id — which a permanent
worker never does. The pure permanent model is a project with no template assigned: when a
permanent machine could hold the job once it is free, the answer is a queue rather than a stuck
ticket (`Workers.create_machine/1`). Permanent workers with a template assigned as well is that
model with burst capacity.

**`docs/design/provisioning.md` keeps the rest exactly as it is, and that is the point.** A
worker template is a recipe for creating a machine, so a machine nobody created from one simply
has a null `template_id` and its resources set by the operator rather than copied. No second
concept appears for a machine the platform did not make — which is the choice `managed` already
represents.

**"Everything else is the same" includes what the machine is given at creation**, and that is
the part it is easy to get wrong. `mix forge.worker.new` prints the whole environment a machine
needs, because it stands in for the driver and the driver injects it — see below. Anything that
mints a machine's environment mints all of it. **That no longer includes an inference
credential**: a machine holds none, and each job brings its own (`docs/design/credentials.md`),
so a permanent machine and a made one run a job on the same account — the one the job picked.

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

`Forge.Provider`, and the second implementation now exists — `Forge.Provider.Hetzner`, behind
the same callbacks, resolved through the registry `docs/design/provisioning.md` § Where a
machine comes from describes rather than through one configured module. **It has created and
destroyed real Hetzner machines, and none has yet run a job**: they booted, could not reach a
platform on `localhost`, and were destroyed at the timeout (`provisioning.md` § A template that
cannot make a working machine is taken out of service). Every request is shaped against the
published API and exercised through a seam, which is precisely the position § What the
operator's machine settled warns about: in every case the tests against the fakes passed and the
real thing did not. What it does settle is the
boundary — nothing above `Forge.Provider.*` learned a Hetzner name for it to exist, and the
identity route needed no change at all, because § How a machine learns what it is had already
chosen Hetzner's metadata endpoint and the bytes are the same ones the local driver writes to a
disk.

The callbacks:

```
@callback create(opts) ::
            {:ok, %{provider_id: String.t(), address: String.t() | nil}} | {:error, term}
@callback destroy(provider_id, credential) :: :ok | {:error, term}
@callback status(provider_id, credential) :: {:ok, :pending | :running | :gone} | {:error, term}
@callback shapes(credential) :: {:ok, [shape]} | {:error, term}
@callback images(credential) :: {:ok, [image]} | {:error, term}
@callback list(credential) :: {:ok, [instance]} | {:error, term}
@callback credential_fields() :: [%{key: String.t(), label: String.t()}]
@callback required_template_fields() :: [:size | :image]
```

`opts` carries the worker id, the token, the platform's address, the provider name the registry
resolves the driver from, the template's `size` and `image`, the provider credential's secret as
`credential`, and `harness_env`. The first three callbacks are a machine's whole life, and they
match what `docs/vision.md` says a provider is: create a machine, destroy it, and somewhere to put
bytes. The bytes are `Forge.Storage`'s (`docs/design/storage.md`), not the driver's. `destroy`
and `status` take the credential the machine was made with, because ending a machine is an
account operation too (`docs/design/provisioning.md` § Whose account records what it cost when
they did not). `status` has no caller above the driver yet.

**`opts.size` used to be declared and read by nobody** — a `String.t()` on the type and a
`machine_size` config key that reached `Provider.create/1` and stopped there, because one
machine shape needs no name. `docs/design/provisioning.md` gave it a consumer: a worker
template carries it and the driver maps it, so `"cpx32"` means something in exactly one module.
Five callbacks joined the three that were here — `shapes/1`, the machine shapes a driver sells;
`images/1`, the images a credential can make one from; `credential_fields/0`, the shape of the
secret that reaches its account; `required_template_fields/0`, which of `size` and `image` a
template must name for the driver to make anything from it; and `list/1`, the machines forge
made in that account, which nothing calls yet — and `impl/0` became a registry, so the driver is
resolved per machine from the row rather than per node from configuration. All of it is built.

**Nothing above the driver knows the provider.** Not the scheduler, not the channel, not the
worker. A module that pattern-matches on `"local"` outside `Forge.Provider.*` is the bug this
callback set exists to prevent, and the Hetzner implementation was the test of whether it
worked. **It did.** Writing it added two callbacks to the behaviour and changed nothing above
it; the one thing that had to move was the `KEY=VALUE` blob a machine is told about itself,
which lived in `LocalVm` while there was one driver and is `Forge.Provider.MachineConfig` now.
That is a shared detail finding its level, not a boundary leaking.

`Forge.Provider.LocalVm` boots the NixOS worker image under QEMU: a copy-on-write overlay on the
image so the base is never written, user-mode networking with no inbound ports, and a config disk
carrying the worker id, the token and the platform's address. `destroy` kills the process and
removes the overlay and the disk. `status` reads the process.

**One door, and it is shut by default.** A worker has no inbound port; that is the property the
direction of the channel exists to give. `ssh_key` and `ssh_port` open one anyway — a forward
from the platform host's loopback to the guest's sshd, with a key the config disk carries — and
two things need it. M4 measures cold-start phases from outside the guest
(`docs/design/measurement-harness.md` § M4), and a job that failed on a machine
about to be destroyed has left its stderr on that machine and nowhere else. Both are the
operator's own machine looking at its own VM. Neither is configured unless the operator does it,
and the Hetzner implementation in the closing step is free to have no equivalent.

**A driver that refuses is recorded on the row it refused.** `Workers.create_machine/1` inserts
the row before it asks the driver, so a refusal happens with a row already in hand — and until
`workers.last_error` existed, the driver's reason went back to the scheduler, which reads every
error alike as *not right now* and offers the job again next pass. A node with no image
configured therefore made a row, failed, swept it on the timeout and did it again for ever,
looking idle on every surface the operator has. That is how it was found, on a real node.

The row is left `creating` rather than destroyed, and that is deliberate: it holds its place
against `max_workers`, which is what rate-limits the retry to one attempt per sweep instead of
one per scheduling pass. § Managed and unmanaged already relies on the same fallback — a machine
that never spoke is swept on `inserted_at` — so the cleanup path needed nothing new.

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
process on the machine, including the agent — so the user data holding the worker token would be
one `curl` away from a job. (It used to hold the harness credential as well; a job's credential
now arrives with its assignment, `docs/design/credentials.md`.) The config unit drops the route to it once
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
closure — plus a BIOS boot partition and Limine, for the firmware that is not UEFI (below). There is no system profile and nothing to `nixos-rebuild`, because a worker is replaced
rather than updated. `make-disk-image.nix`, the usual route, was not taken: it can only make an
ext4 root, and the volume layer needs btrfs.

Two consequences the driver carries, and they are why `Forge.Provider.LocalVm` is not the
three-argument QEMU invocation it looks like it should be:

- **The local machine boots UEFI**, so the driver passes QEMU an OVMF code image and gives each
  machine its own writable copy of the variable store. The devshell exports both paths; nothing
  in the platform can guess them, so a driver without them refuses to create rather than
  starting a machine that hangs at the firmware.

**The image boots under BIOS as well, because a Hetzner x86 server has nothing else.** Its
firmware is SeaBIOS, which reads the disk's MBR and runs whatever boot code is there — and an
image that was UEFI only had none. Every machine the Hetzner driver made stopped at *Booting
from Hard Disk…*, was timed out by `sweep_unreachable/0` as *made a machine that never
connected*, and was replaced by another that did the same. So the image carries two boot paths
to the same system: systemd-boot and the unified kernel image under UEFI, and Limine under BIOS,
with its boot code in the MBR, its second stage in a BIOS boot partition, and the same kernel,
initrd and command line on the ESP. Limine rather than GRUB because `limine bios-install` writes
to an image file in the build sandbox, where GRUB's installer wants a block device. The kernel
and initrd are on the ESP twice, once inside the unified image and once beside it, which its
128 MiB holds with about 40 MiB to spare. `nix build .#checks.x86_64-linux.worker-image-boots`
boots the image under SeaBIOS and under OVMF and fails unless both reach a login prompt; it needs
KVM, so `bin/check` does not run it.
- **The image is small and the machine's disk is not.** repart minimises the root partition, so
  the overlay is created larger than the image it backs and the guest grows its partition and
  filesystem into it on the first boot. What has to fit is the Nix store, the seed and several
  build directories — none of which are in the image.

A repart image carries the closure's files but not the Nix store's database, so the image
registers it once at first boot, as the installer images do. Without that a fresh machine's
`nix` considers every path invalid and sets about fetching what it already has.

**The harness's credential is the job's, not the machine's.** This paragraph said the opposite
until `docs/design/credentials.md`: Claude Code's `ANTHROPIC_API_KEY` or
`CLAUDE_CODE_OAUTH_TOKEN` was injected at creation, by the same route that carries the worker
token (§ How a machine learns what it is), and every job on the machine spent it. The argument was
that a credential neither scoped to one job nor short lived does not belong in an assignment,
which `docs/design/worker-channel.md` reserves for credentials that are both. What it cost was
pooling, a second harness, and revocation — a token on a machine's disk cannot be taken back from
a machine that is already running — and the blast radius it protected was the job's slice, where
the agent could always read the token anyway. So a job picks a credential when it starts, and
the assignment carries it sealed for that worker and that job; the machine holds none between
jobs.

What is still injected at creation is what is still the machine's: the worker token and the
platform's address, and the model, which is an operator setting until the workflow grammar says
otherwise. The executable is not: the platform's is a path on the platform's host, and the image
has its own. `mix forge.worker.new` prints the same set for a machine the operator is provisioning
by hand.

## Scheduling

> **Extended by `docs/design/provisioning.md`, which is built and is the standard for the gate.**
> What is below is where it started: one slice size for every job, a memory-only gate, and one
> `max_workers` for the node. That note replaced the single number with resources declared per
> job, added `kind` and cores as gate dimensions, and moved `max_workers` and the idle period onto
> a worker template. The rule the gate exists to enforce did not change.

`Forge.Jobs.Scheduler` stopped counting jobs and started measuring memory.

A job's slice was `slice_bytes` — configuration, defaulting to **2.2 GiB**, which is M3's observed
peak (2009 MiB) plus its margin (`docs/measurements.md` § M3). It is now the last link of the chain
a job's memory resolves through, and what a workflow job declaring nothing gets
(`docs/design/provisioning.md` § What a job asks for). A worker's `memory_budget` is its RAM less
a reserve for the system and the Nix daemon. A job is assigned only when its slice fits what the
worker has left. That is the rule `docs/vision.md` states, and the reason it is a rule is the claim
the whole tier rests on: an out-of-memory build kills one job, not the machine.

Two gates were to compose, and they answer different questions:

1. **The window gate** (`docs/design/capacity.md` § Engine support, the third change): may we
   spend an invocation at all? It is per credential rather than node-wide: the pick passes over a
   credential whose window blocks, and a job whose every credential is limited waits, recorded as
   `limited` (`docs/design/credentials.md` § How a job picks).
2. **The memory gate**: does this job's slice fit on a worker we have, and if not, is it worth
   creating one?

The window gate runs first — the scheduler asks `Credentials.for_job/1` before `Workers.provide/2` —
because nothing is gained by creating a machine for a job that cannot start. **The spend gate runs
after placement.** The ticket's allowance and the node's daily cap are asked in
`Forge.Jobs.assign/2`, which runs only once `Workers.provide/2` has returned a worker, so a job the
caps refuse can already have had a machine created for it.

When no connected worker has room, the platform creates one from the smallest worker template
assigned to the job's project that holds it, up to that template's `max_workers`; there is no
node-wide ceiling (`docs/design/provisioning.md` § Whose account). A job that fits no worker and
cannot have one created — the template is at its ceiling, or a machine that exists could hold it
once free — stays `pending`; it is not an error, and the ticket stays `active`. It says why,
though: a `job.waiting` event carries the reason each time it changes, and the ticket's timeline
draws it (`docs/design/provisioning.md` § The gate). A job with no template to be made from —
none assigned, all disabled, none that both takes its kind and is big enough — is a different
answer: the ticket is stuck with that as its reason (`Scheduler.stick/2`), because nothing will
change it until a person does. A chat sticks nothing, not even a ticket chat's ticket — that
ticket's own work may place perfectly well — and waits, with that answer recorded as its wait
reason and drawn on its page.

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
tells a machine that a ticket merged or was abandoned — the platform's messages are `assign` and
`cancel`, and a conversation's `message`, `interrupt` and `close`. So a ticket volume
is swept by age like the job directories beside it, defaulting to two days: long enough to cover
a ticket blocked on a question overnight, short enough that a machine which never dies is not
holding a volume per ticket it ever touched. The exclusive bytes are what that ticket's builds
wrote, which M2 measured and which is the number that matters on a real host.

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

What that needs instead is the same operation pulled rather than pushed, and the transport is
already here: the store serves it blobs under scoped short-lived tokens, and the channel carries
platform-to-worker messages. An `update` message carrying a store key and a token, a fetch, a
symlink swap and a restart uses no new transport and no new kind of credential. What it adds is
a machine that stops taking work while it swaps, which this section once gave to `drain` — a
message nothing ever sent, and dropped (§ Idle destroy) — so `update` has to mean that itself,
and the platform has to stop assigning to a machine it has sent one to. It is not built, because
nothing yet runs a worker the operator cannot ssh to.

**A machine says which build it is running when it joins.** Once the release is separable from
the image, "what is this worker running" stops being answerable from the image, and the
application version does not answer it either — every release in the PoC was `0.1.0`. What
changes on a code edit is the store path, so the join line names it:

```
joined worker:8eaaacc1-… running 0.1.0 (8rh57whmgk6m); ready with 6176456704 bytes and 4 cores
```

which is the first twelve characters of what `nix build .#forge-worker` prints, so the operator
can compare the two without logging in.

**And it says so on the wire, which is where the platform can act on it.** The join carries
`protocol`, `release` and `build` (`docs/design/worker-channel.md` § Versions), the row keeps
them, and the platform refuses a protocol outside the range it accepts before the machine is
given any work. This was the second of two things this section said the release would need; it
is built:

- **The protocol is one number**, in `core/priv/worker_protocol`, read by `ForgeCore.WorkerProtocol`
  and by `flake.nix` and written down nowhere else. It moves only for a breaking change, and
  `worker-channel.md` § What needs a bump says what counts as one and how the minimum is raised.
- **A refused managed machine is destroyed on the spot**, and its template learns from the
  machine's first join what the image it was made from speaks. An image nothing has been heard
  from is probed by one machine at a time until that join, so a bad snapshot costs one machine
  rather than one per sweep or one per waiting job (`docs/design/provisioning.md` § A snapshot
  that speaks the wrong protocol). A refused permanent machine keeps its row, and the row says
  why.
- **Snapshots are labelled with what they carry.** `bin/hetzner-image` sets
  `forge-worker-build` and `forge-worker-protocol` on the snapshot from the flake outputs it
  builds, `Hetzner.images/1` reads them back, and a template stores both when it is saved. A
  snapshot made before the labels existed is *unlabelled*, which is unknown rather than
  compatible: the platform makes a machine from it, warns, and learns from the join.
- **The platform knows which build it ships with.** `flake.nix` builds the platform release
  knowing the first twelve characters of the `forge-worker` package's store hash — twelve and
  not thirty-two, because the full hash in the platform's closure is a runtime reference Nix
  would follow, and every platform install would drag the worker release in with it. The
  workers and templates pages set a machine's or a snapshot's build beside it: `current`, or
  `other build`. A hint, not a gate: nothing refuses a machine for its build, only for its
  protocol. A development node has no build to compare with and draws no hint.

What is left to need, and it still gets harder the longer it waits:

- **Rollback.** A release that will not start leaves a machine that will not work, and the
  symlink's previous target is the whole of the fix.
- **A pulled `update`.** The refusal says a machine is out of date; nothing yet brings one up to
  date on a provider, where there is no ssh door. The `update` message above is still the shape,
  and it would be the first breaking addition from the platform's side — a worker that ignored
  it would take work it had been told to stop taking.

**The live figures are memory-only.** A connected machine reports its CPU, memory and disk every
five seconds (`worker-channel.md` § Live figures) for the workers page to draw, and the platform
keeps the latest one as the channel's registry value and nothing else: no table, no history, and
a machine that is not connected shows no figures at all rather than old ones.

## What a machine that never dies accumulates

Four things grow without bound, because until a worker could be permanent the machine's own
destruction collected them. Each has a rule, and the rules are retention rather than lifecycle on
purpose: a worker cannot always tell whether a job will be resumed, and a sweep that only has to
know an age is a sweep that cannot get that wrong.

- **Job directories.** `<root>/jobs/<job_id>` holds the prompt, stderr and the agent's private
  `HOME` — which is where Claude Code keeps the session a resume needs, so it cannot simply go
  when the job ends. Beside it, `<root>/jobs/<job_id>.worker` holds what the worker writes and
  reads back: the transcripts, a command's log, the groups of files staged for upload. Not inside
  the job directory, whose every name the job's Unix user owns and could replace with a link to a
  file only the worker may read, which the worker would then upload; mode 0700, so no other job
  reads it either. Both are swept together. Directories untouched for `job_retention_ms` are removed
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
it. These four are shared or resumable, and deleting them eagerly would either break a resume
or throw away the warm start the seed exists to provide.

## Hibernation and resume

A job that is interrupted — cancelled, out of budget, a worker being destroyed — commits before
it stops. `docs/decisions.md`: jobs are disposable, anything that must survive is committed
to the branch or written to the store, history is squashed.

The sequence: SIGTERM the harness, wait the grace period, `git add -A` and commit in the worktree,
push to the ticket branch with the job's token, upload the transcript to the store, send
`hibernated` with the commit sha. The platform records the sha and sets the job `hibernated` — a
status that existed from milestone 1 and was unreachable until this one.

**Only one of those three interruptions reaches it for a workflow job.** The worker sends
`hibernated` when a `cancel` stopped the runner (`ForgeWorker.Link` maps `killed: :operator` to
it), and the platform sends `cancel` in one place: rejoin reconciliation, for a job it has
already finished with (`docs/design/worker-channel.md` § Reconnection). No operator action
sends one. Out of budget ends in a `result` like any other ending, and a worker that is lost or
swept re-queues its running jobs to `pending` (`Workers.sweep_unreachable/0`) rather than
hibernating them. A conversation is the exception
the other way: every chat ends by sending `hibernated`, and one whose run is lost is set
`hibernated` — dormant — by the platform (`docs/design/conversations.md` § Lifetime).

Resume reconstructs from the branch and the manifest, never from the conversation. The spec is
immutable and already in the row; inputs are re-pinned at run time as they are today; the worktree
is a fresh snapshot with the branch checked out at the commit the hibernation left — reset to it
even though the run is a resume, because a snapshot has no unfinished work of its own to keep
(`docs/design/job-prompt.md` § The continuation prompt). Resuming the harness session — a workflow
job's `--resume`; a chat never resumes one (`docs/design/conversations.md` § Lifetime) — is
attempted whenever a session was recorded, and succeeds only where the same worker still has the
same worktree path, because Claude Code's session lookup is per project directory and will not
find it anywhere else (`docs/design/claude-code-events.md`). When it is not found, the job is
re-queued without the session and runs from the full prompt and the artifacts, which is the
contract.

## Idle destroy

A worker with no running jobs goes `idle` and starts a timer: when its last job ends, or when it
reports `ready` with nothing running — a machine that came up and was never given anything is
idle from that moment, and a reconnect does not restart a clock already running. On expiry the
platform destroys the machine through the driver and marks the row `destroyed` — only once the
driver says it went (`Workers.destroy/2`). The next ticket creates a new one.
`Workers.sweep_idle/0` does it, only to a `managed` worker, at the end of every scheduling pass:
after the pass, because before it the sweep destroyed the machine the pass was about to use, and
whatever is still pending, because gating it on nothing pending let one job nobody could place —
a conversation in a project with no template — keep every idle machine on the node alive.

**No `drain` precedes it, and there is no `drain` any more.** This section said one would: a
worker that is `idle` has no job to wait for, so the sweep destroys it directly. Nothing ever
sent the message, and it was removed from both ends rather than kept for a use that might come
(`docs/design/worker-channel.md` § Messages).

The period is the machine's template's `idle_ms`, and the node's `idle_period_ms` for a template
that sets none or a machine with no template (`docs/design/provisioning.md` § Lifecycle is per
template). The node's default is now M4's rather than a guess: **five minutes**.
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

- **`slice_bytes` was one number for every job, and is not any more.** A state or the workflow's
  `defaults` declares `resources`, and `docs/design/provisioning.md` built the platform half;
  `docs/design/commands.md` § Resources holds the grammar half, and commands are what made the
  single number cost something: a command declaring the same 2.2 GiB as a prose-refining agent is
  the gate doing nothing. What stays open is evidence: nothing has shown that a refine job and a
  build job need different ceilings, `slice_bytes` is still what a workflow job declaring nothing
  gets. `resources` on a command is built with commands.
- **The 2 GiB reserve is traced to nothing.** `ForgeWorker.Config`'s `@reserve` is what a worker
  holds back from `memory_budget` for the system and the Nix daemon, and unlike every other
  constant here it has no measurement behind it, no comment, and no note. It is a fixed tax per
  machine sitting on a slice boundary: on an 8 GiB machine roughly 700 MiB of it is the difference
  between two slices and three. What it is really covering is the Nix daemon — the image sets no
  `MemoryMax` on `nix-daemon.service`, so a build the daemon runs is charged outside every job's
  slice — and how big that is depends on how much of a project's closure substitutes rather than
  builds, which is also unmeasured. **Measure the idle footprint and the daemon's
  `memory.peak` before moving it**, because the failure is asymmetric: too small a *slice*
  OOM-kills one job with `CONSTRAINT_MEMCG`, and too small a *reserve* lets the global OOM killer
  pick, which on this machine means the worker release.
- **`max_workers` was 1 for the PoC, and is 1 by default on a template.** Nothing in the
  scheduler assumes it; nothing has tested it above 1 either. `docs/design/provisioning.md` moved
  it onto a worker template, so every per-template ceiling there is a generalisation of a number
  that has only ever held one value.
- **Seed refresh has no schedule.** Someone runs the Mix task. How stale a seed may be before it
  costs more than it saves is a dogfooding question.
- **A partitioned worker is destroyed, not waited for.** Correct while jobs are re-runnable and
  machines are cattle; revisit if a job ever becomes expensive enough to want recovery.
- **The model a job asks for is not part of what makes a worker assignable.** It cannot bite
  while `max_workers` is 1, which is the item above that gates it: this matters only once the
  fleet is large enough to be heterogeneous. Stated once, in
  `docs/design/worker-channel.md` § Open, beside the `ready` message that carries the data it
  would be matched against.
