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

**Nor is a machine marked unhealthy**, whatever its status says. `unhealthy_at` is a mark beside
the status rather than a status of its own, as reachability is: a machine whose systemd stopped
answering is `busy` or `idle` in every other respect, and the status keeps meaning what it meant
for the sweeps that read it (§ A machine whose systemd stops answering).

### Managed and unmanaged

A `managed` worker is one the platform created through the driver and may therefore destroy. An
**unmanaged** worker is a machine its owner provisioned and told the platform about by minting
it — from *New machine* on `/workers`, or on the host with `mix forge.worker.new` or
`Forge.Release.new_worker/2`, all three `Forge.Workers.mint/2` (`docs/design/identity.md`
§ Minting a permanent machine) — long-lived, and not the platform's to power off. The column
exists because the two differ in exactly one way, and it is the only way that matters: *who may
end this machine's life.*

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
the part it is easy to get wrong. `Forge.Workers.mint/2` returns the whole environment a machine
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
@callback find(worker_id, credential) :: {:ok, provider_id | nil} | {:error, term}
@callback credential_fields() :: [%{key: String.t(), label: String.t()}]
@callback required_template_fields() :: [:size | :image]
@callback billed_increment_ms() :: pos_integer() | nil
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
A ninth came with billing: `billed_increment_ms/0`, how long a machine is billed for at a time
when every started increment is charged whole — an hour for Hetzner, nil for the local driver —
which is what keeps an idle machine to a leeway point of an hour it has paid for (§ The hour
already paid for). A tenth came with surviving a platform restart: `find/2`, the machine a driver
made for a worker row whose create never answered, by the name it gave it
(`docs/design/provisioning.md` § Whose account).

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
- A shell's worth of general tools for the agent, `jobTools` in `nix/worker-image.nix`: plain
  `python3` with no packages, `rg`, `fd`, `jq`, `yq`, grep, sed, awk, find, diff, patch, `file`,
  `which`, `ps`/`pkill`, `less`, `tree`, zip/unzip, xz, bzip2, `curl`, `wget`, `bc` and `make`.
  They are on the worker unit's `path` beside the worker's own tools (`servicePath`), and a job's
  `PATH` is the worker's (`ForgeWorker.Job.Exec`'s allowlist passes it through, for an agent and a
  command alike); `nix develop` only prepends the devshell's, so they are there whether or not the
  state names an env. They exist because an agent that asked for `python3` got "command not found"
  and fell back to sed. The line between them and a toolchain is that nothing here belongs to one
  project: a compiler, a linter or a Python library is the project's flake's to provide.

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
has its own. `Forge.Workers.mint/2` returns the same set for a machine its owner is provisioning
by hand, and the workers page and both host commands show what it returns.

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
systemd-run --pipe --wait --collect --expand-environment=no --unit=forge-job-<short id>
            --uid=<per-job user> --property=WorkingDirectory=<worktree>
            --property=MemorySwapMax=0 --property=OOMPolicy=continue
            --property=ExecStopPost=-+<the job's worker directory>/at-exit
            --property=MemoryMax=<slice> --property=CPUWeight=100
            --setenv=<name>=<value> ...
            --property=LoadCredential=forge-secrets:<the job's worker directory>/secrets.env
            -- <nix develop .#env --command> <the loader> <harness>
```

- **`MemorySwapMax=0`.** A slice allowed to swap does not die at its ceiling, it drags the machine
  down to disk speed and takes its neighbours with it. The ceiling should kill.
- **No ceiling below 512 MiB**, `ForgeCore.Workflow.Resources.minimum_memory/0` — the one
  definition, which the grammar, the new-chat form, the templates page, the workers page's offer
  form and the job row's changeset all refuse below, each with a message naming it, and which
  the worker checks again before it makes a unit (below). It is chosen, not measured: nothing
  here has measured Claude Code's footprint, and 512 MiB is a floor under which no agent is
  expected to run, so a smaller ceiling is never a job that runs slowly; at its smallest it is a
  machine that stops working (§ A machine whose systemd stops answering). **The worker refuses too**:
  an assignment whose `memory_max` is below the minimum — or is not a number — is not started,
  and ends at once as an error whose reason names the ceiling and the minimum (a workflow job's
  or a command's `result`, a chat's `failed`). It is the last place a nonsense ceiling can be
  kept from systemd, and it holds against a platform older than the worker. What a bare number
  means is not this rule's business: it is bytes, as it always was.
- **`OOMPolicy=continue`.** The default, `stop`, ends the whole unit the moment the kernel kills
  any process in it for memory — which is what milestone 3's demo recorded as `Failed with
  result 'oom-kill'` (`docs/measurements.md` § The isolation cross), and what turned an agent's
  Gradle daemon dying into the agent dying with it. With `continue` the process the kernel chose
  dies alone: the agent sees its command exit 137 (SIGKILL), and can run it again with less
  parallelism. When the kernel chooses the harness itself, the unit ends anyway, because its main
  process is gone. Under `continue` an OOM kill never touches the unit's result, so a harness
  killed for memory ends with result `signal` and never `oom-kill` — which is why the reading
  below exists. **Observed on the worker image** (systemd 261.2, `nix/worker-health.nix`,
  `docs/measurements.md` § The worker at its ceiling, on the image): a child allocating past a
  512 MiB ceiling was killed alone, its shell saw 137 and carried on, and the unit finished
  `success`; a main process killed there ended the unit with `signal`, `code=killed,
  status=9/KILL`, and `systemd-run` exited 255.
- **The job is told its ceiling**: `FORGE_MEMORY_MAX`, in bytes, in the environment of an agent
  and of a command, and a sentence in both preambles saying what a SIGKILL or an exit status of
  137 most likely means and what to do instead of trying again. The preamble names the variable
  rather than the size, because it is one document for every job and its hash is part of every
  spec.
- **Not `--quiet`.** Without it, `systemd-run` writes `Running as unit: forge-job-….service` once
  the unit exists, and a summary — *Finished with result*, *Main processes terminated with*,
  *Memory peak*, … — once it has ended, both into the same stderr the job writes to. The first
  line is half of what lets the worker believe a bus error (§ How a machine finds out): a job's
  own process only runs once the unit exists, so a stderr that never says the unit exists held
  nothing the job wrote — unless the job rewrote it, which is why the unit's last reading is the
  other half. The summary is taken out again wherever stderr's last line is used as a reason,
  since *Memory peak: 30M* names nothing. **Observed on the image**, where both differ a little
  from what this note first quoted: the unit line is `Running as unit: forge-job-….service;
  invocation ID: <32 hex>` whenever PID 1 had given the unit one, and the summary's labels are
  right-aligned, so each starts with spaces (`          Finished with result: success`).
  `own_line?/1` trims and matches on the prefix, and took both out.
- **The unit's last reading, `ExecStopPost=-+…/at-exit`.** `--collect` and the unit's end take its
  cgroup away, so a reading made from outside after the process has gone finds nothing, and one
  made every few seconds while it runs misses the kill that ended it. So the unit writes its own:
  a script the worker writes into the job's worker directory at `prepare/1`, run by systemd once
  the main process has ended and before the cgroup is removed. `+` runs it as root — the job's
  user may not write into the worker's directory, which is the point: nothing the job ran can
  forge the file — and `-` keeps a failure of it from failing the unit. It copies
  `memory.events`, `memory.peak` and `memory.max`, and the `EXIT_CODE`, `EXIT_STATUS` and `SERVICE_RESULT`
  systemd hands a stop command, into `at-exit.reading` beside it, which the slice reads and removes
  when the process ends (`Slice.ended/2`). POSIX `sh` and nothing else, so it needs no `PATH`. This is how a run knows its
  harness was killed for memory: its main process ended on `killed`/`KILL` and its cgroup
  counted an OOM kill. **Observed on the image**: the reading was root's, and held the events,
  the peak, the ceiling and `exit_code`, `exit_status` and `result` for a unit that finished and
  for one whose main process the kernel killed. It runs in the unit's own cgroup, which is what
  lets a job starve it (§ How a machine finds out).
- **Equal `CPUWeight`.** Proportional shares, not quotas: an agent waiting on inference donates its
  share to whoever is compiling, which is the behaviour `docs/decisions.md` asks for and quotas
  would prevent. `measure/`'s M2 already runs its builds this way.
- **A fresh Unix user per job**, created at assignment and removed after, owning the snapshot and
  the job directory. It is what stops one job reading another's worktree, credentials or outputs on
  a machine where several run at once.
- **Every git command in a job's worktree runs as the job's user, never as root.** A repository's
  hooks and its own configuration are programs — `.git/hooks/*`, `core.fsmonitor`, a filter or
  diff driver, a `url.*.insteadOf` onto `ext::` — and git runs them as whoever runs git. The job's
  user can write all of them, so git run by the worker as root in a tree the job has touched is
  that job's code run as root. Hence the order, which the job's owner (the link's task for a job or
  a command, the conversation's process for a chat) holds from start to end, around the runner
  rather than inside it:
  1. **The user is made first** (`Slice.enter/1`), before the worktree exists.
  2. **The worktree is the user's before any git runs in it** (`Slice.own/2`). Root runs git only
     to clone into an empty volume nothing of a job has touched. A snapshot of a seed or a
     ticket's template, and a tree left by an earlier attempt, are handed over first and
     refreshed as the user — a template's `.git` is the last job's, and a `post-checkout` hook in
     it would otherwise run as root at the next job's `checkout`.
  3. **Git runs as the user** (`Slice.as/3`: `setpriv` to the user's uid and gid, with a `HOME`
     that does not exist so root's own configuration is not read): refresh, a command's detach,
     every conversation turn's commit and push, a job's commit and push, and the head the worker
     reports.
  4. **The files come back to root and the user goes after the last git command**
     (`Slice.leave/2`), and before the worker keeps anything of the tree: a ticket's template must
     not belong to a uid the next `useradd` may hand to somebody else.

  This note said first that ownership was handed back *before* the worker committed, because git
  refuses to work in a repository owned by somebody else. That satisfied git's check and defeated
  its purpose: the owner changed and the hooks and configuration the job wrote did not, so the
  worker's `git commit` ran a job's `pre-commit` as root. A conversation, which commits after every
  turn while the job's user still owns the tree, could not commit at all — git refused, and each
  turn's work stayed on the machine until the agent pushed it itself.
- **`--pipe --wait`** so the runner's existing Port sees the harness's stdout and its exit, which is
  what `ForgeWorker.Job.Runner` is already built around. The unit is the wrapper, not a new
  execution model.
- **The environment is named, not inherited.** systemd starts the unit with its own default
  environment rather than `systemd-run`'s, so everything the runner composed — `PATH`, `HOME`, the
  job directory, the harness's own variables — is passed as `--setenv`. This is why the slice is
  told the environment in `prepare/1` rather than only the command in `wrap/3`.
- **A secret is never in the unit's environment.** It was: named as `--setenv=NAME` without its
  value, which `systemd-run` read from its own environment, on the reasoning that the value then
  reached systemd over the bus rather than sitting in an argument vector. The bus is the problem.
  A unit's `Environment=` is a property systemd shows every user on the machine — `systemctl show
  -p Environment` needs no privilege, and `systemd.exec(5)` says so under `Environment=` — so every
  job on a machine could read every other job's credential, git token and project secrets for as
  long as it ran, another project's included, and the forwarding shell had put each value in
  `env`'s argv besides. Now every `{:secret, _}` value is written to a file in the worker's own
  directory, which only root can enter, and the unit is handed the file with
  `LoadCredential=forge-secrets:<path>`: systemd reads it as root and gives the unit a copy only
  its user can read, at `$CREDENTIALS_DIRECTORY/forge-secrets`. A shell inside the process loads it
  and `exec`s the harness or the script, innermost, inside `nix develop`
  (`ForgeWorker.Job.Exec`). The bus carries the path; no argv carries a value; the worker removes
  the file when the process has ended. `Slice.Direct` has no unit, and its process reads the file
  where it is.
- **The command line reaches the process as written: `--expand-environment=no`.** By default
  systemd substitutes `${NAME}` anywhere in a unit's arguments, and an argument that is a whole
  `$NAME`, from the unit's environment before the process runs, and a name it does not know
  becomes nothing. The loader's `${CREDENTIALS_DIRECTORY-}` is one — systemd looks up a variable
  named `CREDENTIALS_DIRECTORY-` — so on the image the loader always fell back to the path in the
  worker's own directory, which the job's user cannot read, and every run holding a secret ended
  `Permission denied` before it started: every agent job and every chat, the credential being
  one. A command's argument holding `${...}` or a whole `$NAME` was rewritten the same way; a
  prompt never was, since it reaches the harness through stdin. The suite holds the flag
  (`Slice.Systemd.flags/1`); `nix/worker-health.nix`'s `secrets` item is written to show a value
  arriving through a real unit, and has not yet run. systemd 254 and later.

This is behind `ForgeWorker.Slice`, with two implementations: `Slice.Systemd` as above, and
`Slice.Direct`, which is what the runner does today — spawn the process with no unit and no limit.
`Direct` is not a mock. It is how the worker runs during development on a machine without systemd,
and it is the only implementation that can be exercised in a container. The same substitution is
what `measure/`'s selftest already makes for the same reason
(`docs/design/measurement-harness.md`), and stamping which one ran is part of the record there and
here.

### What the slice reads while a job runs

A ceiling that binds is visible from outside the job only in its cgroup, and the cgroup is plain
files: `/sys/fs/cgroup/system.slice/<unit>/` — `Slice.Systemd.unit_name/1` names the unit —
read with ordinary file reads, which is also why they still answer when PID 1 does not. Behind
`ForgeWorker.Slice` as `memory/1`, so the runner does not know which slice ran and `Slice.Direct`
simply has nothing to say:

- `memory.events` — `max` (the ceiling was reached and memory is being reclaimed or throttled),
  `oom` and `oom_kill` (a process in the job was killed for memory);
- `memory.current`, `memory.peak` and `memory.max` — now, the most so far, and the ceiling;
- `memory.pressure` — the `full avg10` figure: the share of the last ten seconds in which every
  process in the job was stalled on memory at once.

**Sampled every five seconds, and only while a run is live** (`:memory_sample_ms`): from the
process's spawn to its exit, each correction round from its own, a conversation for as long as
its process lives. What a sample means is `ForgeWorker.Job.Memory`'s, which is pure, and the
events it makes are `claude-code-events.md` § Memory's. What a run ends with — the ceiling, the
peak and the OOM kills — comes from the unit's own last reading (`at-exit`, above) when there is
one, and from the last sample when there is not.

**Sustained pressure is `full avg10` at or above 20% on two samples in a row.** Twenty percent is
a guess — nothing here has measured an agent at its ceiling — and it is a configuration key
(`:memory_pressure_full`) rather than a constant, so moving it is a change to the worker's
configuration and not to its code; nothing reads it from the environment, so on the image that
is still a new release. Two samples is ten seconds of
a job doing little but waiting for pages: short enough to say so while it is happening, long
enough that one bad second is not an episode.

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
- **A worktree is a volume however it was made, a cold clone included.** The warm paths snapshot
  *into* it, so there it is one before git sees it; a cold clone makes the empty volume first and
  clones into that, because `git clone` is happy with a directory that already exists as long as
  it is empty. A worktree the clone created itself is a plain directory, and `btrfs subvolume
  snapshot` refuses a source that is not a subvolume — so a ticket whose first job on the machine
  was a cold clone would promote nothing, find no template next time, and clone cold again for the
  whole life of the ticket. A volume the machine will not make is a warning and a colder next job,
  never a failed run: warmth is not correctness.

**Promotion happens only after the run committed and pushed**, and that is what makes the template
safe to snapshot without cleaning. `Checkout.squash/4` does `reset --soft origin/<branch>` then
`add -A`, so after a successful run every untracked file that was not ignored has been committed,
and what is left beside the checkout is the ignored build output the whole mechanism is for. A run
that failed before it pushed keeps its worktree's untracked debris, and promoting that would hand
the next job exactly the inheritance the clean rule exists to prevent. So a failed run promotes
nothing and the ticket keeps the template it had.

**And a state that declares no `changeset` promotes nothing either**, for the same reason read
the other way: it never commits, deliberately, so its tree is scratch to the end
(`docs/design/git-hosting.md` § Non-fast-forward on a ticket branch). Promoting it would let the
ticket's next job inherit work nobody accepted and commit it with its own `add -A` — the branch
reached by the long way, after the short one was closed. The ticket keeps the template it had and
the next job starts colder, which is what a cache is allowed to cost.

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

**A tool's dependency cache is build output like any other, and belongs in the checkout.** Every
job's `HOME` is its own and goes with the job directory, so a Gradle, npm or cargo cache in the
default place under `HOME` is fetched again by every job on every machine. Pointed at an ignored
directory inside the checkout instead — `GRADLE_USER_HOME="$PWD/.gradle-home"` — it is carried
exactly as the build directory is: in the seed when the seed was published with it warm, and in the
ticket's volume from one of its agent jobs to the next on the same machine. A command job snapshots
the ticket's volume where there is one and promotes nothing, since its tree is a commit. There is
no shared cache between jobs beyond these, and no key that declares one: the first project to hit
this measured 343 MB fetched per job. Pointing the cache at a
directory outside the checkout, which is the obvious fix, is the one that loses it — nothing
outside the checkout and the Nix store survives a job.

Forge itself is the worked example, in `bin/lib/mix-cache.sh`: Mix installs Hex into `MIX_HOME`
and Hex caches the registry and every tarball it downloads in `HEX_HOME`, both under `$HOME` by
default, so each job reinstalled Hex and refetched the registry however warm its `deps/` was. The
gate exports both into the checkout — `.mix-home/` and `.hex-home/`, ignored beside the build
directories — for its own processes only, so an operator's `~/.mix` is neither read nor written.
Every script here that runs `mix` sources that one file instead of exporting the pair itself, so
they cannot disagree about where Mix's home is: `bin/check` owns the caches and installs Hex when
they answer nothing, and `bin/e2e-chat` only borrows what the gate built and so asks first — with
`mix hex.info`, in the environment it would export, because a `.mix-home/` that exists and holds
no archive would otherwise take an operator with a warm `~/.mix` to no Hex at all. Asking whether
the directory is there instead is the validate-then-act trap `CLAUDE.md` § Rules names: the guard
has to ask the question the operation asks.

**What a carried `_build` does and does not save**, since the path changes every job and § Volumes
and the seed's 1.34× is the only figure this note had. `Mix.Tasks.Compile.Elixir` puts
`File.cwd!()` into its manifest's `cache_key` and `Mix.Compilers.Elixir` recompiles the app when
that key differs, and a job's worktree is `worktrees/<job_id>` — a new absolute path every job. So
**every dependency survives and the project's own sources do not**: at a new path with the volume's
`_build` in place, `platform` recompiles `forge_core`'s 29 files and its own 182 and leaves all
sixty-odd Hex dependencies alone, 13 seconds against 122 to build the same thing from fetched deps;
`core` and `worker` together, 3 seconds against 23. Measured here, and the tests pass on the result.

The residue is real but small — of the order of fifteen seconds a job across the three projects —
and nothing a build script can reach: the key is the working directory, not the build path, so
`MIX_BUILD_PATH` and `MIX_BUILD_ROOT` miss it, and a symlink misses it too because `File.cwd!()`
resolves to the physical path. Closing it means *giving* the job a stable absolute path — a bind
mount, or a worktree keyed on the ticket rather than the job — which changes the job slice rather
than a cache. Worth knowing before anyone reads a per-job recompile as the volume having failed.

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

- **Job directories.** `<root>/jobs/<job_id>` holds the prompt and the agent's private
  `HOME` — which is where Claude Code keeps the session a resume needs, so it cannot simply go
  when the job ends. Beside it, `<root>/jobs/<job_id>.worker` holds what the worker writes and
  reads back: the transcripts, the harness's stderr, a command's log, the groups of files staged
  for upload, the session staged for upload or restore. Not inside
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
it stops, when its state declares `changeset`. `docs/decisions.md`: jobs are disposable, anything
that must survive is committed to the branch or written to the store, history is squashed. For a
state that declares no `changeset` there is nothing that must survive: its tree is scratch, it is
never committed or pushed however the run ended, and it is discarded with the worktree
(`docs/design/git-hosting.md` § Non-fast-forward on a ticket branch).

The sequence, for a state that declares `changeset`: SIGTERM the harness, wait the grace period,
`git add -A` and commit in the worktree, push to the ticket branch with the job's token, upload
the transcript to the store, send `hibernated` with the commit sha. **For a state that declares
none the three git steps do not happen**: the transcript still goes to the store and `hibernated`
still carries a sha, but it is the branch head the run started from rather than one the run
made. The platform records the sha and puts a workflow job back to
`pending`, to resume from that commit wherever it is placed next; a conversation goes
`hibernated` — dormant — until a person reopens it. A workflow job used to be set `hibernated`
too, and nothing ever moved one on: the scheduler places only `pending` jobs, so the ticket sat
with no job running and nothing in the queue to say so.

**Only one of those three interruptions reaches it for a workflow job, and rarely.** The worker
sends `hibernated` when a `cancel` stopped the runner (`ForgeWorker.Link` maps `killed: :operator`
to it). The platform sends `cancel` in three places: rejoin reconciliation, for a job the machine
still runs that the platform does not have running there, as `not_ours`; a retired row's channel,
for its running jobs, as `retired`; and cancelling a ticket, as `ticket_cancelled`
(`docs/design/worker-channel.md` § Messages). The first two stop the run without a report, since
the platform has already given it up, and the third's report finds the job finished as cancelled
and settles what it spent. So a workflow job reaches `hibernate` running only from an older worker:
its report of a `not_ours` run, arriving after the scheduler handed the job straight back to the
same machine, which dropped that assignment as *already running* (`docs/design/worker-channel.md`
§ Delivery says what that costs). Out of budget ends in a `result` like any other ending, and a
worker that is lost or swept re-queues its running jobs to `pending`
(`Workers.sweep_unreachable/0`) rather than hibernating them. A conversation is the exception the
other way: every chat ends by sending `hibernated`, and one whose run is lost is set `hibernated` —
dormant — by the platform (`docs/design/conversations.md` § Lifetime).

Resume reconstructs from the branch and the manifest, never from the conversation. The spec is
immutable and already in the row; inputs are re-pinned at run time as they are today; the worktree
is a fresh snapshot with the branch checked out at the commit the hibernation left — reset to it
even though the run is a resume, because a snapshot has no unfinished work of its own to keep
(`docs/design/job-prompt.md` § The continuation prompt). Resuming the harness session — a workflow
job's `--resume`, a reopened chat's `--resume --fork-session` (`docs/design/conversations.md`
§ Lifetime) — is attempted whenever a session was recorded, on whichever machine the run lands:
the worker uploads the session's file after a run and puts it back before the resume
(`docs/design/claude-code-events.md` § Resume). When the harness cannot use it, a job is
re-queued without the session and runs from the full prompt and the artifacts, which is the
contract, and a conversation forgets it, so that its next reopen starts cold.

## Idle destroy

A worker with no running jobs goes `idle` and starts a timer: when its last job ends, or when it
reports `ready` with nothing running — a machine that came up and was never given anything is
idle from that moment, and a reconnect does not restart a clock already running. Once the period
is up and nothing has a claim on it — and, on a provider that bills by the hour, once the hour the
machine has paid for is nearly over (§ The hour already paid for) — the platform destroys the
machine through the driver and marks the row `destroyed`, only once the driver says it went
(`Workers.destroy/2`). The next ticket creates a new one.
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
approval gap without holding a machine through a lunch break — on a provider that bills nothing.
On one that bills by the hour the period is only the least a machine is kept, and it can be held
most of an hour past it (§ The hour already paid for).

The number is local, and the two phases that dominate it are the two the closing step makes
worse: the seed arrived over loopback and the Nix store came from the binary cache over the
host's own connection. On a provider both are network-bound, the cold start gets longer, and
the argument for a longer idle period goes with it. Re-measuring there is the closing step's.

### The hour already paid for

**The period is the least time an idle machine is kept, not the moment it goes.** On Hetzner the
difference is money, because of how Hetzner bills a server:

- **Every started hour is billed whole.** *"If you create a server just for a few minutes, we will
  still bill you for one whole hour"* ([Hetzner Cloud billing FAQ][hz-faq]); *"we round up
  partial hours"* ([Billing system at Hetzner][hz-billing]).
- **It bills while the server exists**, running or not: *"you pay for a server that has completed
  the creation process for as long as it exists, regardless of whether it is turned on or not"*
  ([FAQ][hz-faq]). Deleting it is the only thing that stops it — which is why a power-off is no
  cheaper than a destroy and this section has no suspend.
- **A month is capped** at the server type's monthly price, and the hourly rate times the hours
  is charged when it is less. The cap is reached only by a machine alive for most of a month.
- **The primary IPv4 is billed separately**, whether or not a server holds it (*ibid.*).

So a machine destroyed five minutes after it went idle, ten minutes into an hour, has paid for
fifty minutes it threw away, and a ticket arriving in those fifty minutes makes another machine,
pays that one's first hour too, and waits out a cold start besides. Holding the idle machine to
the end of its hour costs nothing: the hour is already charged.

**So on such a provider the machine is decided on at the leeway point of each billed hour** —
`billing_leeway_ms` (five minutes) before the hour ends, counting hours from when the machine was
made. At that point it goes only if nothing still has a claim on it:

- **no job running on it**, which includes a conversation until its own idle timeout
  (`docs/design/conversations.md` § Lifetime): a chat whose last message came at 0:55 holds its
  machine until 1:25, so at the 0:55 leeway point the machine is in use and takes the next hour;
- **no job parked on it whose commands have not timed out**, and no job that last ran on it
  come back to the queue within an idle period (below);
- **and its idle period ran out before the leeway point**, not merely before the hour's end.

Anything that still has a claim at the leeway point keeps the machine for **the whole next
hour**, and the question is asked again at that hour's leeway point. So in the example the chat
goes quiet at 1:25, the machine is idle from then, its period is over by 1:30, and it is destroyed
at 1:55 — the hour the chat ran into is used to its end rather than thrown away. Which provider
bills that way is the driver's to say — `Provider.billed_increment_ms/1`, an hour for Hetzner and
nil for the local driver, whose machines go at the period, or when a claim on them ends
(`docs/design/provisioning.md` § Where a machine comes from). The workers page draws when an idle
machine will go, from the same function the sweep asks (`Workers.goes_at/2`), which asks the
sweep's own question of the row — idle, the platform's, nothing running on it whatever its status
says — so the page cannot show a moment for a machine the sweep would not take.

- **The hour is counted from the row, which is earlier than Hetzner's clock.** The row is
  inserted before `POST /servers` is sent, so its `inserted_at` precedes the moment Hetzner
  starts billing by at least the create call, and an error in the anchor is always towards going
  a little early — never into an hour nobody meant to buy.
- **The leeway is the platform's own lag**, not Hetzner's: a scheduling pass every two seconds,
  a pass that waits on provider calls of up to thirty seconds each — the sweep destroys one
  machine after another, and a `GET` retries — and a `DELETE` that
  Hetzner finishes asynchronously. Five minutes is what the Jenkins plugin's hour-wrap policy
  leaves (`SHUTDOWN_TIME_BUFFER`); the TestFlows runners leave ten. A machine free at the
  leeway point is destroyed on the next pass, and asked again on every pass until the hour's
  **last call**.
- **No destroy is sent in an hour's last call**, `billing_last_call_ms` (a minute) before it
  ends: a `DELETE` sent then could complete in the next hour, which would be billed with the
  machine already gone. A machine not destroyed by then — a refused destroy, a node that was down
  across the leeway — is kept to the next hour's leeway point, which costs the same hour and keeps
  its use. So does one whose hour ended meanwhile.
- **A configuration that cannot work is refused when the node starts**
  (`Workers.check_billing!/0`): a leeway no longer than the last call never opens, so a billed
  machine would never be destroyed, and one as long as a billed increment destroys at the hour's
  end or after it. Both are whole seconds or more, since the rows and the sweep count in seconds.
- **Parked jobs aside, what it costs over going at the period is at most one hour, and only for
  a machine that was just in use.** A period that runs out before the leeway point is stretched
  to it, which is free. One that runs out after it — a job ended in the hour's last minutes —
  buys the next hour, which is the hour the next job, arriving soon after the last, is likeliest
  to use.

**A parked job keeps its machine while its commands can still finish.** A job parked on the
commands it invoked holds no slice (`commands.md` § Always park), so its machine is idle — and
was destroyed on its period while the command it waited on was still running, which lost the
Claude Code session the job would have resumed on it (`docs/design/provisioning.md` § Affinity
on resume). A job parked on a machine — `status: :parked`, its `worker_id` that machine, which is
also the one it prefers when it resumes — now counts as a claim on it until the last of its open
commands would time out: `timeout_ms` from when the command's row last changed, which is its
start, or its return to the queue after a lost worker. That bound is what keeps a command stuck in
the queue from holding a machine for ever. It is not exact: the worker starts a command's clock
only once it has prepared it, so the claim can end a preparation's length early.

When the commands are done the job goes back to the queue and is parked no longer — and its
machine, idle since the park, was destroyed by the very pass that had not placed it yet, which a
job whose credential is limited can miss for hours. So **a job that last ran on a machine and is
back in the queue** — resumed, reopened, requeued — is a claim on it too, for one idle period
from its return. That covers the gap between the resume and the pass that places it, and no
more: a job waiting a week for a rate limit does not hold a machine for the week. Both claims hold
for the local driver too, where they simply defer the period's end (`Workers.claimed_until/1`).

**A machine kept past its period yields its slot.** It still counts against its template's
`max_workers`, which is the point when the next job can use it and is a queue that does not move
when it cannot — a template edited since the machine was made, or a command needing a protocol
the machine does not speak. Without more, that job would wait for a leeway point instead of the
end of the period. So when a template is full and a job needs a machine from it, an idle machine
of that template past its period that could not hold the job even empty is **named** to give its
slot up (`Workers.provide/4` answers `{:yield, worker}`), and the scheduler hands the names to the
sweep at the end of its pass, which destroys each one still idle and past its period
(`by: :yielded`). The job has the slot on the next pass. One still inside its period is not
named; the job waits the period out, exactly as it did before this. A parked job's claim does not
stop a yield either: the job resumes on any machine, and a queue that does not move is worse than
a session that has to be rebuilt.

It was first a destroy on the spot, and the review of it found three things wrong with that, each
of which is why the rule is shaped as it is:

- **A younger job in the same pass could have used the machine.** The older job that could not
  fit destroyed it, and the younger one that could then waited for a cold boot. Destroyed at the
  pass's end, a machine the pass gave work to is busy and is left alone.
- **A refused destroy was asked again by every job that wanted the slot** — up to ten requests a
  pass against one account, and, against an API that hangs, minutes of a scheduler doing nothing
  else. At the pass's end it is asked once a pass, as every other sweep asks. A machine the
  driver has refused before is named last, so one whose account will not let it go does not
  stand in front of one that would.
- **It was destroyed before the create's other checks ran**, so a template whose image the
  platform refuses, or whose credential it may not spend, lost the machine and made nothing. A
  machine is named only once the create would go ahead.

A template whose `max_workers` was lowered below the machines it has gives one up a pass until
there is room, which is a pass's latency per machine over, in a case that is rare.

**Where the hour starts is inferred, not documented, and has not been observed here.** Hetzner
does not say whether an hour runs from the server's creation or from the clock. Two independent
autoscalers built against it both count from the server's `created`: the Jenkins plugin's
[hour-wrap policy][jenkins-hw] (`Helper.canShutdownServer`, a server's age modulo sixty minutes)
and the [TestFlows GitHub runners][testflows] (`end_of_life`, fifty minutes into each hour of a
server's age). One third-party write-up says the clock ([CloudTally][cloudtally]: *"Create a
server at 14:55 and destroy it at 15:05, and you have used parts of two hours: you are billed for
two"*). The platform takes creation. If the clock is right, what this costs is at most one extra
hour per machine's life, and only for one made more than the leeway into a clock hour; what it
saves is unchanged. Observing it is one machine: make one at hh:50, destroy it at hh:40 of the
next hour, and read the hours on the project's usage page — one hour if Hetzner counts from
creation, two if it counts the clock.

**Deliberately not here.**

- **The monthly cap.** A machine past its month's cap costs nothing more that month, so keeping
  it would be free. Reaching the cap takes most of a month of uptime, which an idle-destroyed
  fleet does not do, and knowing it needs the monthly price and the month's hours so far —
  `shapes/1` carries only the hourly one.
- **The IPv4 address.** It is billed beside the server, and its price is a rounding error on the
  server's. A worker dials out and needs no inbound address, but GitHub has no IPv6, so an
  IPv6-only worker could not fetch a flake input from it. Whether the address Hetzner makes with a
  server is deleted with it is not documented — the API reference defaults `auto_delete` to false
  for one made on its own — and has not been checked here; `list/1` lists servers, so an address
  outliving its server would be found in the console and not on the workers page.
- **Deciding to buy the next hour.** At each hour's end the real question is whether a job will
  arrive in the next one; the period is the operator's answer to it, set per template, and
  nothing here predicts arrivals.

[hz-faq]: https://docs.hetzner.com/cloud/billing/faq/
[hz-billing]: https://docs.hetzner.com/general/billing-and-account-management/billing-at-hetzner/billing-system-hetzner/
[jenkins-hw]: https://github.com/jenkinsci/hetzner-cloud-plugin
[testflows]: https://github.com/testflows/TestFlows-GitHub-Hetzner-Runners
[cloudtally]: https://cloudtally.eu/blog/hetzner-cloud-billing-explained

## A machine whose systemd stops answering

**What happened, on 2026-09-29, on release 0.6.0.** Gathered read-only from the production
database; nothing below was observed on the machine itself, which is gone.

1. A chat was created with `2` typed in the new-chat form's Memory field, meaning 2 GiB. A bare
   number is bytes (`workflow-grammar-v1.md` § Resources), so the job was stored with
   `memory_max = 2`, and nothing refused it.
2. It was placed on a fresh Hetzner machine — worker `4eb64045…`, 4 GiB, 2 cores — which accepted
   it and started the harness through `Slice.Systemd` with `--property=MemoryMax=2`.
3. The harness never said it started: 30 minutes of `job.harness.starting`, every two minutes,
   each with an empty stderr.
4. A second chat, sized correctly at 2 GiB, was then placed on the same machine. Its `starting`
   events carried `Failed to start transient service unit: Connection timed out` — `systemd-run`
   could not get an answer from PID 1. From then on the machine could run nothing, while its
   worker kept heartbeating and the platform kept placing work on it.
5. That second job sat in `starting` too, although `systemd-run` had plainly failed.

**The mechanism is confirmed on the worker image** (2026-09-30, systemd 261.2, `nix build
.#checks.x86_64-linux.worker-health`; `docs/measurements.md` § The worker at its ceiling, on the
image). Since v255 PID 1 starts a unit's process through `sd-executor`, with `CLONE_VFORK |
CLONE_INTO_CGROUP`: the child is born inside the unit's cgroup and PID 1 is suspended until the
child execs. With the worker's own flags and `MemoryMax=2` — which the cgroup holds as `0`, two
bytes rounding down to no pages — PID 1 sat in `D` state in `kernel_clone`, and the kernel
reported `Out of memory and no killable processes...` for the child over and over: it can
neither fault in what exec needs nor be killed, so PID 1 never resumes. Every bus call after that
times out, and new ssh logins hang, since they go through logind to PID 1. The kernel's
repetition also floods the journal: the wedged boot's journal kept its last 8 seconds, 711,949
lines, and rotated away everything before, the worker's own lines with it — the machine's log on
the platform (`worker-log.md`) is what survives. Ceilings of a sensible size behave as designed
(§ The job slice).

**Why the second job did not end is confirmed**, by reading the code: the relay in front of a
streaming harness waited on its stdin after `systemd-run` had exited, so nothing ever reported an
exit (`claude-code-events.md` § A harness that never starts). That is fixed, and a run that fails
to start now ends within seconds.

Three things answer it, and the first is the minimum (§ The job slice): a ceiling that small is no
longer made. The other two are for a machine that stops answering for any other reason.

### How a machine finds out

On the worker, and only under `Slice.Systemd` — `Slice.Direct` has no systemd to ask. Either of
two signals marks the machine unhealthy (`ForgeWorker.Health`):

- **A `systemd-run` that fails with a bus error.** When a run ends, the slice reads its output
  (`Slice.ended/2`): a line that starts `Failed to start transient service unit: ` or
  `Failed to connect to ` and ends in `Connection timed out`, `Transport endpoint is not
  connected` or `Connection reset by peer`. Those are what systemd prints —
  `bus_call_with_hint()` and `bus_log_connect_full()` in `run.c` and `bus-util.c`, with the errno
  as text — and they are one list, `Slice.Systemd`'s `@bus_errors`. **Observed on the image**: a
  `systemd-run` started while PID 1 was wedged gave up after 25 seconds (sd-bus's call timeout),
  exited 1, and printed exactly `Failed to start transient service unit: Connection timed out`,
  which `bus_error/1` found and `ended/2` believed.

  **The run that wedged PID 1 is not one of them.** Its start call is answered — queueing the
  start job needs no fork — and it is the next call that waits: after the same 25 seconds and with
  exit 1 it printed either `Failed to request invocation ID for unit: Connection timed out` alone,
  or `Running as unit: forge-job-….service` and then `Failed to query unit state: Connection timed
  out`, depending on how far PID 1 got (both seen). Neither is in the list, and the second follows
  a `Running as unit:`, so that run ends as the job's own failure and the probe below is what finds
  the machine. Whether the first should join the list is open (§ Open). The invocation-ID call is
  only made without `--quiet`, which is also why the 2026-09-29 chat that caused the wedge, under a
  worker that still passed `--quiet`, had an empty stderr.

  **It is believed only when the
  unit never existed**: stderr is shared with the job, and a job's flake can print anything from
  its `shellHook`. A job's own process runs only once its unit exists, and `systemd-run` says so
  first (`Running as unit:`, which is why it is no longer `--quiet`), so an output that never says
  the unit existed held nothing a job wrote — **until the job rewrites it**. With `--pipe` the
  job's stderr is the very file `systemd-run` writes to, and a process holding it can truncate it
  and put a bus error of its own where `Running as unit:` was; review found that, and reproduced
  it against `Slice.Systemd.ended/2`, which believed the forgery and would have stopped every job
  on the machine and rebooted it. So the output is not enough alone: a bus error is believed only
  when, besides, the unit left **no last reading** (`at-exit.reading`, § The job slice). That file
  is written by root, into the worker's own directory the job cannot reach, by a unit that
  existed and stopped; a job can neither write it nor remove it. A stale one is removed when the
  slice is prepared, so a reading from an earlier worker's run of the same job can neither hide a
  genuine bus error nor lend its exit to a run that never started.

  **What is left is not closed**, and a second review showed it is wider than it first looked:
  the job can stop its unit's stop command from writing at all. The stop command runs in the
  unit's own cgroup, and a job that fills that cgroup with pages that outlive its processes —
  files in `/dev/shm`, which is world-writable, and which `MemorySwapMax=0` keeps in memory — has
  the stop command killed for memory before it writes a byte. **Observed on the image, every
  time**: a job that truncated its stderr, wrote `Failed to connect to bus: Connection timed out`
  and filled `/dev/shm` until the writer was killed, then sixteen pages at a time after that, had its
  stop command killed as `(at-exit)` in `task_memcg=/system.slice/forge-job-….service` before it
  exec'd, left no reading, and was believed by `ended/2` — 10 times in 10 by hand and 5 in 5 in
  each run of the check; a single fill without the squeeze got through 3 times in 12. A job that
  does that takes its machine out of service — the thing this whole note exists to prevent.
  **Asking PID 1 once before believing would close it**, since a forged bus error comes from a
  machine whose PID 1 answers: straight after each forgery `probe/0` answered in 6 ms or less, and
  against a truly wedged PID 1 it fails in 10.0 seconds (`timeout`'s TERM; exit 124, no output).
  That is a change to the operator's rule that a bus error is enough on its own, so it is put to
  the operator rather than made here. Until then the probe alone would still find a real wedge,
  two minutes later. A job that fails
  this way is the machine's failure, not the job's: the worker does not report it (below), and the
  platform puts it back in the queue.
- **A probe that cannot get an answer from PID 1 twice in a row.** `timeout -k 5 10 systemctl show
  --property=Version --value`, once a minute (`:health_probe_ms`), in a task of its own, so a probe
  that hangs is killed by `timeout` and never holds up anything else the worker does. Twice
  because one missed answer on a loaded machine is not a wedge; two minutes is. **Observed on the
  image**: against a wedged PID 1 the probe failed in 10.0 seconds with exit 124 and no output (an
  unbounded `systemctl show` took 90 seconds to say `Transport endpoint is not connected`), and the
  worker's own health process marked the machine 94–97 seconds after the wedge in three runs of
  the check, and about two minutes after it on the local end-to-end run.

### What happens then

1. **The worker stops.** It writes `machine.unhealthy` with the reason (the machine's log,
   `worker-log.md`), stops every job it is running and reports none of them, and starts nothing
   it is given afterwards. The platform has put all of them back in the queue, and a result from
   this machine after that — its git token revoked, its slice broken — would be recorded as the
   job's answer (`worker-channel.md` § Delivery).
2. **It tells the platform**, over the channel: `unhealthy` with the reason, acked like a result
   (`worker-channel.md` § Messages), and its join says so until the worker restarts.
3. **The platform stops placing work on it at once** — `Workers.assignable/3` passes over a row with
   `unhealthy_at` set, and the channel puts back in the queue an assignment that reaches it after
   the mark — and treats its running jobs exactly as a lost machine's, through the same
   `requeue_running/2`: a chat goes dormant and can be reopened, a workflow job and a command go
   back to `pending`, and each job's `job.interrupted` says `worker_unhealthy`.
4. **It answers whether the machine should reboot**: yes for a managed machine that has not been
   told to within the hour (`reboot_interval_ms`), and the time it said so is kept on the row as
   `rebooted_at`. Asked again about the same episode — a reply lost to a dropped socket — it says
   yes again, since `rebooted_at` is not older than `unhealthy_at`.
5. **Only a managed machine reboots**, and it takes two keys: the platform's yes, and the machine's
   own `FORGE_MANAGED=1`, which `Forge.Provider.MachineConfig` writes for every machine a driver
   makes and `mix forge.worker.new` does not. So neither a platform's mistake nor a copied
   environment file reboots somebody's own computer. The reboot is `systemctl --force --force
   reboot`, behind a function the tests replace: with `--force` twice, `verb_start_special()`
   skips logind's inhibitor check and goes straight to `halt_now()`, which is `sync()` and
   `reboot(2)` with no bus call. **Observed with PID 1 wedged**: run by hand, the command printed
   `Rebooting.`; run through `ForgeWorker.Health.reboot/0`, the kernel said `reboot: Restarting
   system` and the console showed a login prompt again 7–8 seconds later, in the same QEMU. `/proc/sysrq-trigger` was not needed. Both
   `--force`s matter: with one, the wedged machine had not rebooted three minutes later.

**An unmanaged machine never reboots itself.** It is somebody's own computer. It says it is
unhealthy, the platform places nothing on it, and the workers page says so, until it joins again
without saying it — its owner restarted the machine, or the worker. There is no button to clear it
on the page: the worker's own belief is what refuses work, and a platform-side clear would place
jobs on a machine that still drops them. **Observed** with a machine from `mix forge.worker.new`
wedged on purpose: the platform answered *not rebooted: it is not the platform's machine, and its
owner restarts it*, and three minutes later it was still up and still wedged.

**No reboot loops.** A managed machine that goes unhealthy again within an hour of being told to
reboot is not told again. It stays unhealthy, holding its template's slot, and the workers page
says it is waiting for a person — who can destroy it there, as any managed machine. **Observed**:
wedged again a minute after it had rejoined from its reboot, a local machine was answered *not
rebooted: it was told to at 2026-09-30 11:35:34 UTC, within the hour, so it waits for a person*,
and its line on `/workers`
read *unhealthy since 11:39 UTC: PID 1 did not answer twice in a row: … — rebooted within the
hour, so not again: destroy it, or wait for it to rejoin healthy*
(`docs/measurements.md` § The unhealthy machine, end to end).

### The same machine, the same row

**Observed for the local driver; not on Hetzner.** `forge-worker-config.service` is a oneshot wanted by
`multi-user.target`, so it runs on every boot, not only the first; the blackhole route it puts on
`169.254.169.254` is runtime state that a reboot clears, so its fetch from the metadata service
works again, and `/etc/forge-worker.env` is written again with the same worker id and token — the
token is long lived and the row keeps its hash (`nix/worker-image.nix`). The local driver's config
disk stays attached across a guest reboot. The rejoin authenticates the row it always had; rows
are made only by a create and by minting one (`Forge.Workers.mint/2`). On the image under QEMU the unit ran again
on the new boot and wrote `/etc/forge-worker.env` byte for byte as before, from the config disk;
end to end, the rebooted machine joined as the same worker row, and the platform cleared its mark
(`docs/measurements.md` § The unhealthy machine, end to end). **The metadata service's half — the
route cleared, the fetch working again — has not been observed on a Hetzner machine.**

**Its rejoin waits for the platform to let go of the old socket.** A machine that reboots sends no
close, so the platform keeps its channel until the socket's read timeout, about a minute after the
last frame; until then every join is refused as `already_connected` (`worker-channel.md` § Authentication),
and the machine retries. Observed: the rebooted machine's joins were refused ten times, and it
joined 68 seconds after it was told to reboot, eight seconds after the platform logged
`disconnected: shut down: :read_timeout`. The grace below covers it with room to spare; whether the platform should close
the channel itself when it answers yes is open (§ Open).

What the platform's timers do to a machine gone for a minute or two:

- **The unreachable sweep would take it after `worker_timeout_ms`**, three minutes from its last
  heartbeat, and a managed one it takes is destroyed. So a row told to reboot, and still marked
  unhealthy, is left alone for `reboot_grace_ms` (ten minutes) from `rebooted_at`. Past that it is
  a machine that did not come back, and is lost like any other. **Observed**: a machine told to
  reboot and then frozen so it could not come back kept its row four minutes past a 15-second
  timeout, and `sweep_unreachable/0` took it the moment the grace was shortened to a second
  (`docs/measurements.md` § The unhealthy machine, end to end).
- **The idle sweep does not take it**: its jobs were requeued and nothing released it, so it is
  still `busy`. A machine that was already `idle` when it went unhealthy keeps its clock and can go
  at the end of its period, as it would have anyway.
- **It is not counted twice.** `Provisioning.live_count/1` counts rows and there is one. It is not
  assignable while it is marked, so a job that needs a machine meanwhile may have one made from
  its template, if the template has room — which is capacity, not a second count.
- **When it joins again without saying it is unhealthy**, the mark is cleared, its `ready` makes it
  `idle` with a fresh clock (it was `busy`), and it takes work again.

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

The demo's `oom-kill` was the unit's default `OOMPolicy=stop` ending the whole job for one killed
process. The unit now continues (§ The job slice), so a harness killed for memory is recognised
from the unit's last reading rather than from that result, which it no longer produces.

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
  OOM-kills a process in one job with `CONSTRAINT_MEMCG`, and too small a *reserve* lets the global OOM killer
  pick, which on this machine means the worker release.
- **`max_workers` was 1 for the PoC, and is 1 by default on a template.** Nothing in the
  scheduler assumes it; nothing has tested it above 1 either. `docs/design/provisioning.md` moved
  it onto a worker template, so every per-template ceiling there is a generalisation of a number
  that has only ever held one value.
- **Seed refresh has no schedule.** Someone runs the Mix task. How stale a seed may be before it
  costs more than it saves is a dogfooding question.
- **A partitioned worker is destroyed, not waited for.** Correct while jobs are re-runnable and
  machines are cattle; revisit if a job ever becomes expensive enough to want recovery.
- **Whether a bus error is believed only once PID 1 has also failed a probe.** The forgery in
  § How a machine finds out works on the image every time it is squeezed; after each one PID 1
  answered `probe/0` in 6 ms or less, and a truly wedged PID 1 fails it in 10.0 seconds. So one
  probe before believing would refuse every forgery seen and cost a genuine bus error ten
  seconds. It changes the rule that a bus error is enough on its own, which is the operator's.
- **Whether the run that wedges PID 1 is the machine's failure too.** It prints `Failed to request
  invocation ID for unit: Connection timed out`, or `Failed to query unit state: …` after a
  `Running as unit:`, and ends as the job's own failure while the probe finds the machine two
  minutes later. Adding the first to `@bus_calls` would requeue that job instead — and a job that
  wedges any machine it starts on would then be carried from machine to machine, one reboot each.
  Since the minimum, no ceiling of a job's can do it; nothing else that does is known.
- **Whether the platform closes a machine's channel when it tells it to reboot.** It does not, so
  the rebooted machine's joins are refused until the old socket's read timeout, about a minute
  (§ The same machine, the same row).
- **What a job leaves in `/dev/shm` outlives it.** Nothing at a job's end removes it, and its owner
  is a uid `useradd` may hand to the next job (`docs/measurements.md` § The worker at its ceiling,
  on the image). Found while reproducing the forgery; not otherwise looked at.
- **The model a job asks for is not part of what makes a worker assignable.** It cannot bite
  while `max_workers` is 1, which is the item above that gates it: this matters only once the
  fleet is large enough to be heterogeneous. Stated once, in
  `docs/design/worker-channel.md` § Open, beside the `ready` message that carries the data it
  would be matched against.
