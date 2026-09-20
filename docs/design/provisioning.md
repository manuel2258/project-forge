# Provisioning: what a job asks for and where a machine comes from

Scope: how a job says what it needs, how a worker says what it will take, how the two are matched,
and whose account the machine is billed to. It replaces three single numbers — `slice_bytes`,
`machine_size` and `max_workers` — and one global config value, `Forge.Provider.impl/0`.

`docs/design/worker-tier.md` stays the standard for what a worker *is*: its lifecycle, its image,
its slices, its volumes. This note is about the tier becoming plural — more than one shape of
machine, more than one provider, and more than one person paying.

Nothing here is implemented. `docs/design/commands.md` § Resources drafted the job half of it and
`worker-tier.md` § Open has carried the rest as *"`slice_memory` is one number for every job"*
since the tier was written; this is where both land.

## There are no classes

The obvious design is a class: name a bucket, put jobs in it, put machines in it, refuse to mix.
It was drafted and dropped, because the bucket turns out to carry no information the two ends do
not already have.

**A job knows what it needs and what it is.** What it needs is memory and cores. What it is, is
already a column: `jobs.kind`, today `:workflow | :chat`, gaining `:command`
(`commands.md` § An invocation is a job).

**A worker knows what it has and what it will take.** What it has is memory and cores. What it
will take is a list of kinds.

The gate is then `job.kind in worker.accepts` and the resources fit. That is the whole matching
rule, and it does everything a class would:

- A machine that declares `accepts: [:command]` will never run inference. That is the property
  the class was wanted for, and it is one column.
- Two mid-sized commands share a node when both fit, with no bucket to invent for them.
- A class name can be misspelt into a job that schedules nowhere and errors never. `kind` is an
  `Ecto.Enum` and a list of them is checked against the same set.

**This is the shape `worker-channel.md` § Open already reached for.** It proposes matching the
model a job wants against `harness["models"]` on the worker row, and calls it *"a requirement
beside the slice"*. Requirement on the job, capability on the worker, matched at placement. The
same sentence describes kinds, memory and cores. What is here is that idea with three more
dimensions, not a new mechanism — and the model dimension should join it rather than being built
separately. That note also records the two traps waiting for whoever adds it, and they are the
shape of trap this gate has everywhere: a worker that reported **no** harness must stay
assignable, or a network blip during the probe idles the fleet; and the aliases are not in
`models`, so a requirement matched against ids alone refuses every workflow naming `opus`.

## Two tables, and the second is only a recipe

**A worker template** says how to make a machine. **A worker** is a machine. They are not the same
row and the second does not defer to the first.

```
worker_templates                     workers
  name                                 (existing: provider, provider_id, status, token_hash,
  provider_credential_id               memory_budget, harness, managed, ...)
  size            opaque               accepts         [:workflow, :chat] | [:command] | ...
  memory                               cores
  cores                                template_id     nullable
  accepts                              provider_credential_id
  max_workers                          user_id, credential_id   (identity.md § Workers)
  idle_ms
  user_id
```

**Values are copied at creation, not referenced.** A worker created from a template gets that
template's `accepts`, `memory`, `cores` and credentials written onto its own row. Editing the
template afterwards changes nothing about machines that already exist, and deleting it leaves
them running — `template_id` is provenance, not authority.

That is the whole reason for two tables rather than one with a nullable everything. The
alternative — workers reading through to a template — means an operator editing a row cannot
change a machine, a template edit silently re-sizes a running fleet, and a permanent machine
needs a template invented for it that the platform must never create from.

**A permanent worker is the same row with `template_id` null.** The operator provisions it with
`mix forge.worker.new`, sets its `accepts`, memory and cores in the UI, and `managed: false` keeps
the platform from destroying it (`worker-tier.md` § Managed and unmanaged). There is no second
concept for a machine the platform did not make, which is the same choice `managed` already
represents: one row shape, one column saying who may end its life.

## What a job asks for

`resources: {memory, cpu}`, valid on a command, on a job state, and as a project default, resolved
by the chain `model` uses: the command's, then the state's, then the project's default, then the
platform's `slice_bytes`. `commands.md` § Resources holds the grammar and the reasoning; two
things from it matter here.

**`cpu` is a reservation, not a quota.** The gate counts it when placing the job; the slice still
gets `CPUWeight`, so a command that finds the machine to itself uses all of it. `decisions.md`
chose proportional shares precisely so an agent idle on inference donates to whoever is compiling,
and a `CPUQuota` would trade that away.

**Two mid-sized commands on one node are why `cpu` is a gate dimension at all.** With one job per
machine it would be pure sizing and the gate would not need it; the moment two jobs share a node,
memory alone cannot tell you that two four-core commands do not fit on four cores.

**The numbers are denormalised onto the job row.** `spec` is the immutable record of what a job
was asked to do and `resources` belongs in it, but the scheduler has to *sum* them across a
worker's jobs, and summing `(spec->>'memory')::bigint` is a query nobody should have to read.
`jobs` gains `memory_max` and `cores`, written once at creation from the resolved chain and never
rewritten, exactly as `spec` is.

**A chat is the one kind with nothing to declare, and it gets its own number rather than a
build's.** `resources` is a workflow state's grammar and a conversation has no state, so it fell
off the end of the chain onto `slice_bytes` — which is M3's *cold build* peak, 2210 MiB. Nobody
decided that talking to an agent should reserve a machine's worth of memory; it was the last link
of a chain written for jobs that compile. So `chat_slice_bytes` sits beside `slice_bytes` as the
platform's other end of that chain, and `Forge.Jobs.default_resources/0` is where a chat reads it.

- **It is an estimate and says so.** A gibibyte is the harness process plus what it shells out
  to, rounded up: nothing has measured an agent, and `measurements.md` § M3 measured builds.
  Replacing it wants an M5, not a better guess. It is a config key so that a node whose chats do
  more than talk can raise it without touching what a workflow job gets.
- **The cost is that a chat cannot do a cold build.** `MemoryMax` is hard and swap is off, and
  M3 put a cold build of this repository at 1612 MiB debug and 1879 MiB release. A conversation
  asked to run the full gate is killed rather than slowed. Conversations are the common case and
  building is a workflow's job, which still resolves to `slice_bytes`.
- **Cores stay whole.** `cpu` is `pos_integer` through the grammar, the job row, the worker row
  and the gate's arithmetic, so there is no fraction to give a chat — and there is nothing to
  gain from one while `CPUWeight` is a share rather than a quota: a chat alone on a machine uses
  all of it whatever the gate reserved. Reserving less than a core would buy a slot in the gate's
  sums, which is a different feature and a migration.

## What a worker offers, and who says so

`workers.accepts`, `workers.memory_budget` and `workers.cores` are what the gate reads. They come
from the template at creation, or from the operator for a permanent machine.

**`ready` records what the machine says; the row decides what it gets.** The worker still reports
its own budget and core count (`worker-channel.md` § What a worker offers), and that report is
stored — but it is stored *beside* the scheduling values, not over them. A hand-edit on a
permanent worker survives every reconnect, which it does not today: `Workers.ready/3` writes
`memory_budget` from the message, so the UI field would be a lie the moment the machine came back.

**Silence is *unknown*, and unknown is not zero — except for memory.** A worker that has never
said how many cores it has is not gated on cores, and one that has never said which kinds it
takes takes anything. Both are the same rule and it is not laxity: nothing reported cores before
this existed, so reading a nil as zero would have idled the entire fleet the moment it shipped.
It is the trap `worker-channel.md` § Open already records for matching the model — a worker
reporting no harness must stay assignable, or a failed probe empties the fleet.

**Memory is deliberately not like that**, and the asymmetry should survive anyone tidying it: a
worker with no `memory_budget` has not reported `ready` *at all*, so handing it work is the
overcommit the tier exists to prevent. Missing cores means the machine spoke before the field
existed; a missing budget means it never spoke.

**A disagreement is shown, not resolved.** A machine reporting materially less than its row is
overcommitted, and the per-job ceiling cannot catch it: `MemoryMax` bounds one job, and what
overcommitment breaks is the *sum*, which the global kernel OOM killer finds instead — picking by
heuristic, and the largest thing outside the slices is the worker release itself. So the
difference is surfaced on the worker page and in the logs rather than being quietly split.

**This is a real risk accepted deliberately, and it is the one place this note trades safety for
predictability.** Trusting the row means capacity is knowable before a machine exists, which is
what makes "could never fit" answerable and what lets an operator correct a machine that
under-reports. The alternative — the machine always wins — means a template can create machines
that cannot take the job they were created for, in a loop. Neither is free. What makes this one
survivable is that the mismatch is visible; if it turns out operators do not look, the honest
next step is to refuse the join, not to change which number wins.

## The gate

`Forge.Jobs.Scheduler` stops reading one number and starts reading three.

```
assignable(kind, memory, cores) =
  first connected worker, oldest first, where
    kind in worker.accepts
    and worker.memory_budget - promised_memory(worker) >= memory
    and worker.cores        - promised_cores(worker)  >= cores
```

`promised` stops being `count * slice_bytes()` and becomes two sums over the worker's `:running`
and `:waiting` jobs, which is what the denormalised columns above are for.

**An unplaceable job is skipped and the pass continues.** That is what `assign_pending/0` does
today and it stays: a job that fits nothing is offered again next pass, which is a queue. Per
template `max_workers` already removes the starvation that mattered — one kind of work cannot eat
the fleet — and what remains is that a large job can be jumped by small ones indefinitely. **The
skip is recorded**, because the alternative is a job that never runs and no surface saying why.
An age-based reservation is the standard fix and § Open is where it waits.

**Could-never-fit is distinguished from does-not-fit-now.** A job declaring more than the largest
template assigned to its project can ever provide is stuck with that as the reason, through the
mechanism an exhausted allowance already uses. `forge_core` cannot make this call — it has no
database and cannot know what machines exist (`commands.md` § Resources) — so the validator
accepts `memory: 512GiB` and the scheduler is what says no. A job queued for ever against capacity
that will never exist is the failure this exists to prevent.

**And four answers, not two, because the operator's next move differs in each.** With no node
fallback (§ Whose account) every one of these is reachable, and a single `:no_template` covering
three of them would send somebody looking at the wrong thing:

| state | answer | what the operator does |
|---|---|---|
| nothing assigned to the project | `{:no_template, :none_assigned}` | assign one |
| everything assigned is disabled | `{:no_template, :all_disabled}` | fix the recipe, then enable |
| assigned, enabled, none big enough | `{:no_template, :none_fit}` | make a bigger one, or ask for less |
| one fits and is at `max_workers` | `:at_capacity` | nothing — it is a queue |

Only the last is a queue. The other three are a person being waited on, which is what the stick
mechanism is for — and it is why `Scheduler.stick/1` being a no-op for a chat (a chat has no
ticket to stick) is a real gap rather than a detail: a conversation blocked by any of the first
three sits dormant and silent. `conversations.md` § Lifetime is where that belongs.

## Where a machine comes from

**`Forge.Provider.impl/0` is a single global module today**, and it is the thing standing between
this design and a second provider. It becomes a registry keyed by the provider name:

```elixir
config :forge, Forge.Provider,
  drivers: %{"local" => Forge.Provider.LocalVm, "hetzner" => Forge.Provider.Hetzner}
```

The driver for a create is resolved from the template's credential, not from node configuration.
Adding a provider is a config line and a module implementing the behaviour; no platform code
learns its name.

**A fourth callback, `shapes/1`.** The template UI has to offer machine sizes, and the sizes are
the provider's. The driver answers — from the provider's API or from a table it embeds, which is
the driver's business and changeable without touching the platform:

```
@callback shapes(credential) :: {:ok, [shape]} | {:error, term}

shape :: %{size: String.t(), memory: pos_integer(), cores: pos_integer(),
           price_hourly: Decimal.t() | nil, currency: String.t() | nil}
```

`size` is opaque above the driver. The platform reads `memory`, `cores` and the price; it never
parses `"cpx32"`. **This is what keeps `decisions.md` intact** — *"Provider-specific surface is
confined to a driver... nothing in the design may assume it"* — while giving the operator a real
list of Hetzner machines to choose from. Putting a Hetzner table in the platform would have been
simpler to write and would have broken that rule outright.

**A catalogue is a question about an account, and is not asked before there is one.** `shapes/1`
and `images/1` take a credential because what is on offer differs per account, so a provider that
declares credential fields is not called at all until the form names one of the operator's
credentials — and the template form shows nothing past the provider and the credential until
then, because there is nothing to fill in yet. The rule is what the page's shape follows from: the
credential select offers only that provider's credentials and no *none*, since a template naming
no account could only fall back to the node's own token, which is the thing per-user credentials
replaced. Without the rule the page mounted on Hetzner, asked with no account, and rendered the
driver's *no Hetzner credential* twice in red before the operator had touched anything — a real
answer to a question nobody asked. A catalogue error is still shown when there *is* an account: a
revoked token or an API that is down leaves the fields typeable, which is what § Where a machine
comes from's driver boundary already allows for.

**`opts.size` finally has a consumer.** It has been declared on `Forge.Provider.opts` and read by
nobody since the driver was written. A template carries it, `create` passes it, the driver maps
it.

**Hetzner is the second driver, and two things about it are the design's rather than its own.**

- **It is given an image, not asked to make one.** Hetzner Cloud has no image upload, so a
  custom image means booting a rescue server, writing the disk, snapshotting it and throwing the
  server away (`worker-tier.md` § Updating a worker). `bin/hetzner-image` is that procedure as
  one command, and it deletes the rescue server whatever happened — a box left running is the
  hourly leak the workers page exists to catch.

  **A template names the image, and the node configures the fallback.** It was one
  `FORGE_HETZNER_IMAGE` per node, which is wrong the same way one `machine_size` was: two
  templates may want different images, and an operator rolling a new one wants both to exist
  while they move over. `images/1` lists the snapshots a credential can see so the form offers
  real ones; the id is opaque above the driver exactly like `size`. A template naming none falls
  back to the node's, which is what every template made before the column has.
- **The catalogue offers only what the node's location will sell.** `shapes/1` reads the
  datacenters as well as the server types and keeps the intersection, because a size that cannot
  be ordered where the platform creates fails at `create` with `422: unsupported location for
  server type` and nothing before that says so. **Support is not the question**: `fsn1` supports
  `cpx11` and will not sell one, so what is read is each datacenter's `server_types.available`.
  This was found on a node left on the driver's `fsn1` default, which was offering all
  twenty-five types while that datacenter had *none* orderable — every template made there
  failed, and the operator's only clue was the 422. It is the deprecated-type filter's argument
  one step further, and a location with nothing orderable is an error rather than an empty
  catalogue: empty leaves the form a free-text box, which invites typing a name and finding out
  at create.

  The price follows the same rule — this location's or none, never another's — because
  `max_workers` sits beside that figure and it is the only ceiling on the bill.
- **The catalogue's memory figure is gross, and the gate believes the template.** `server_types`
  reports the RAM Hetzner sells; a booted machine offers that less its own reserve for the system
  and the Nix daemon. So a template built straight from a shape promises more than its machines
  deliver, the first machine from it shows a disagreement on the workers page, and the number to
  correct is the template's. That is § What a worker offers' loop running as designed — one
  correction, not a running cost — and it is the argument for the reserve being measured rather
  than guessed, because the size of that correction is the size of the guess.

**`local` is a provider like any other, with no credential.** Its templates have
`provider_credential_id` null and `size` null, and `Forge.Provider.LocalVm` ignores both. One
creation path, and the driver boundary is exercised by two real implementations rather than one
plus a special case. `worker-tier.md` § The provider driver calls the Hetzner implementation *"the
test of whether it worked"*; keeping `local` inside the same path means the test starts before
Hetzner does.

## Whose account

**A provider credential is a thing a user owns**, which is `identity.md` § Credentials applied to
infrastructure rather than inference: *"Capacity and funding stop being node configuration and
become things a user owns."*

```
provider_credentials
  user_id
  name
  provider     "hetzner" | "local" | ...
  secret       encrypted map, shape owned by the driver
```

**A separate table from `identity.md`'s `credential`, and the reason is the spend query.** That
note defines a credential's spend as *"a query over the jobs that used it"*, and `jobs` gains
`credential_id` to make it one. Machine spend is not a query over jobs — it is hours times rate,
and it accrues with nothing running. Folding both into one table makes every existing spend query
carry a filter to stay correct, and makes `daily_limit_usd` mean two different things.

**The secret is a map, not a string.** Hetzner needs one token; another provider needs a key pair;
a third needs a service-account document. The driver owns the shape and validates it on save, so a
new provider is a module rather than a migration.

**A provider that takes no credential cannot have one**, and that is a rule rather than a hidden
form. `credential_fields/0` returning an empty list means this driver reaches its machines
without an account — the local one does — so a credential for it would be a row holding an empty
secret that nothing could ever spend. The form does not offer such a provider *and* the changeset
refuses one, because only the second is a rule. Its *templates* are unaffected: a local template
carries a null credential, which is the case § Where a machine comes from already describes.
Without the rule the failure is `secret is required` against a form with no fields in it, which
reads as a broken form rather than as a category that does not exist — which is how it was found.

**Ending a machine is an account operation too, and for a while only making one was.** `create`
took the template's credential from the day credentials existed; `destroy` and `status` kept the
signatures they had when the token was node configuration, so they reached for a node-wide token
that per-user credentials had replaced. On a node with none, the Hetzner driver refused before
sending a request — and `Forge.Workers.destroy/1` discarded the driver's answer and marked the
row `destroyed` regardless. The result was a leak with no visible symptom: the machine kept
running and billing, `live_count/0` stopped counting it, its `max_workers` slot came free, and
the scheduler made a replacement. One machine every sweep, three of them on the dev node before
anybody opened the provider's console. Both callbacks take a credential, and a worker's own
`provider_credential_id` is what its destroy is asked with.

**The row is the platform's claim that a machine is not billing, so it is written only when the
machine went.** A refusal keeps the row exactly where it is, with the driver's words in
`last_error`: the machine is still there, so it goes on holding its slot, which is what stops a
replacement being made for a machine that never left, and the next sweep tries again. The cost is
that a permanent refusal wedges the fleet at `max_workers` rather than leaking — which is the
right way round, because a stuck fleet is visible and a leaking one is not.

Two ways out, and they are different on purpose:

- **No driver at all is retired immediately.** A row naming a provider this node no longer has
  can never be destroyed from here, so retrying is the deadlock rather than an escape from it —
  the one `worker-tier.md` § What the operator's machine settled records finding the hard way.
  The reason goes on the row, because the machine may well still be running somewhere.
- **A driver that refused is retired only by a person**, with `mix forge.worker.retire --force`.
  What that writes down is a claim about the world the platform could not check, so it is not the
  platform's to make.

**A template is owned, and assigned to projects.** `project_template` — `project_id`,
`template_id` — created by the template's owner and only for a project they are a member of. This
is `identity.md` § Workers' `project_worker` with the noun changed, and it inherits that note's
argument unaltered: *"A project admin cannot reach for someone else's machine, because assigning
it spends its owner's credential and the money stays with whoever spends it."* It was true of a
machine's inference spend; it is true of its hourly bill for the same reason.

The scheduler, needing capacity for a job, looks at the templates assigned to that job's project
and creates from **the smallest** whose `accepts` includes the job's kind and whose resources fit.
Smallest rather than first: creating a thirty-two core machine for a job that declared one core is
how a fleet gets expensive without anybody deciding that it should. The machine inherits the
template's owner, its provider credential and its harness credential.

**A machine comes from a template or it does not come.** There is no node fallback: a project
with nothing assigned creates nothing, and the scheduler says so.

**This reverses what this note first said**, and the reversal is worth recording because the
original argument sounded right. It ran: templates are opt-in, a project with none assigned falls
back to the node's configured provider and `max_workers` — how every machine was made before
templates existed — and *"without that fallback, shipping this would stop every existing
deployment creating a machine at all."*

What happened instead is that the fallback stopped a deployment working while looking like it was
trying. On the node this was found on, a Hetzner template existed, was never assigned to a
project, and so was never used — and every scheduling pass took the fallback, made a `local`
machine, failed `:no_image`, swept it three minutes later and did it again. Five machines, none
of which could ever have run anything, and no surface said *nothing is assigned here* because
from the scheduler's point of view nothing was wrong. A default that silently substitutes a
different machine for the one you configured is not backwards compatibility; it is a wrong
answer given confidently, and the operator's own Hetzner account was the only place it was
visible.

The other half of the old argument — that the fallback is what gives *could never fit* its
meaning — is answered better by carrying the reason, which § The gate now does.

`machine_size` goes with it, having had one reader. Node-wide `max_workers` stops governing
creation entirely: every ceiling is a template's, which is where the money already is
(`ui.md` § The affordance rule puts `max_workers` beside the price for the same reason), so a
surface that renders the node's number as a ceiling is rendering one nothing enforces.

**The ceiling is per template and shared by the projects it is assigned to.** `live_count/1`
counts every machine carrying that `template_id`, whatever project asked for it, so a template
assigned to three projects gives those three a pool between them rather than one each. A project
that needs its own ceiling needs its own template. A failed create holds a slot until the sweep
retires it, which is deliberate: it rate-limits a broken template to one attempt per sweep
instead of one per scheduling pass.

**Spend is bounded by `max_workers` per template, and by nothing else.** A money ceiling was
considered and dropped: the machine count is already a bound, and with `price_hourly` on the shape
the UI can render it as euros per hour without anything having to enforce a second number. The
cost is that the bound is in machines, so raising a template's `max_workers` quietly raises the
bill — which is why that field belongs beside the price in the UI and not on another page.
`identity.md`'s node-wide daily cap still pauses the node, and the ticket allowance still sticks a
ticket; neither is touched.

## A template that cannot make a working machine is taken out of service

A recipe that does not work is a loop: the scheduler wants capacity, the template makes a machine
or fails to, the sweep retires it three minutes later, and the next pass starts again. Nothing in
the platform tires of this. On the node this was found on it ran for hours — first as `local`
machines refusing `:no_image`, then as real Hetzner machines that booted, could not reach a
platform on `localhost`, and were destroyed at the timeout. The second kind costs money every
turn.

**`worker_templates` gains `failures` and `last_error`, and disabled is derived from them.**
`disabled?` is `failures >= limit`, limit 3 and configurable; there is no third column saying so,
because a stored flag and a counter are two facts about one thing that can disagree. Enabling is
setting the counter back to zero.

**Two things count, and they are not the same failure.**

- **The driver refused.** No machine was made — a withdrawn size, an image the account cannot
  see, a location that will not sell.
- **A machine was made and never called home.** It is swept at `worker_timeout_ms` having never
  reached `ready`, which is `last_seen_at` still null. **This is the one that matters**, because
  every create succeeded in the case that cost money; a counter watching only refusals would have
  watched that loop run forever.

A worker reaching `ready` sets the counter to zero: the recipe demonstrably works, and a template
that has made a hundred good machines should not be disabled by three bad ones spread across a
year. Consecutive, not cumulative.

**A worker that connected and later went away is not a template's failure.** The machine worked;
something else happened to it. `last_seen_at` being null is what separates the two, and it is the
only thing that can.

**A disabled template stays assigned and stays listed.** It is skipped by `for_demand/2` and by
`could_ever_hold?/2` — not by `for_project/1`, which is what the page reads and what the operator
needs in order to enable it again.

**Only a person puts it back.** Editing a template does not re-enable it: a rename is not a fix,
and a template that quietly earns three more tries every time somebody touches it is the loop
again with extra steps. The page shows the count and the last error beside a `DISABLED` flag, and
`Enable` is its own action.

## Editing a template

`update_template/2` has existed since templates did and nothing could reach it. Every field is
editable, including the provider and the credential — `Template.changeset/2` already refuses a
credential belonging to a different provider — because a template only describes how *future*
machines are made. Values are copied at creation (§ Two tables, and the second is only a recipe),
so editing one never reaches a machine that exists, which is what makes editing safe rather than
alarming.

## Lifecycle is per template

`max_workers` and the idle-destroy period both move from node configuration onto the template, and
the second is the one that matters.

`worker-tier.md` § Idle destroy sets five minutes from M4's 35-second cold start. That number was
derived on one machine kind and it cannot serve two: an agent worker is cheap by the hour and its
warm Nix store is worth keeping, while a build machine is expensive by the hour and its warm store
is worth *more*, because a cold one re-fetches a whole toolchain over the provider's network
rather than over loopback. One number cannot be right for both, and which way it should be wrong
is different per template.

**The idle period is how a command worker stays warm, and that is load-bearing.**
`commands.md` § How a command gets the code is blunt about it — *"A command worker is warm or it
is not worth having"* — and argues it from measurements: M1 variant (c) puts a transplanted warm
build directory at 1.34× a warm local build, against M4's cold start, which is a seed fetch and a
Nix store population that M4 itself warns get worse on a real provider. A machine created per
invocation pays the second to avoid the first, for a build M1 times at about a second when warm.

That argument is a constraint on this design, not an observation beside it: **a per-template idle
period long enough to span the gap between a ticket's invocations is what makes commands
affordable at all.** Setting it short on a build template because the machine is expensive by the
hour is the mistake it warns against, and the number that decides it — how long between a ticket's
successive commands — is a dogfooding question nobody has answered.

**There is still no minimum warm count.** A floor — keep *n* machines of this template alive
whatever happens — bills with nothing running, and the idle period buys warmth for work that
actually arrives rather than work that might. It is deliberately not here, and if the idle period
turns out to be the wrong instrument it is one column on a table that already exists.

## Affinity on resume

`commands.md` § Always park frees a parked job's slice, which is the point of it. A consequence
that note did not follow through: a worker whose only job is parked has nothing running, is
therefore idle, and is destroyed on its template's period while the command it is waiting for is
still going.

**Nothing about correctness depends on this.** `worker-tier.md` § Hibernation and resume
reconstructs from the branch and the manifest, *never* from the conversation, and
`claude-code-events.md` § Resume is explicit: *"Resume is never required for correctness, and no
outcome depends on it."* A hibernated job resumes on any worker.

What is lost is the harness session, and that costs tokens. `commands.md` § Always park says the
first thing to measure is whether the session survives a park. **It is no longer a measurement.**
Two facts settle it: a parked job holds no slice, so its worker is idle-destroyable; and
`Workers.assignable/1` is first-fit by `inserted_at`, so even a surviving worker is not preferred.
Session reuse is unavailable by construction, most of the time.

**So prefer the worker that still holds the worktree, and fall through.** `assignable/1` is
already gaining arguments for kind and cores; a preferred worker id is the same change, and it
costs nothing when the machine is gone. With a per-template idle period long enough on the agent
side, it will usually hit. `may_invoke`'s `max` should still be set as a cap on park cycles rather
than a generous safety number, because the fallback is a re-composed prompt and context is this
system's expensive resource.

## What this gives up

- **The single number was legible, and a surface says so in words.** `/workers` currently renders
  *"A job is scheduled against memory, not against a count: one slice is 2.2 GiB, and a machine
  takes as many as its budget holds"* (`ForgeWeb.WorkersLive`), with `slices/1` dividing the
  budget by one constant. Every clause of that sentence stops being true here: jobs differ, cores
  count, and machines differ from each other. `docs/design/ui.md` § The workers page is where the
  replacement has to be designed, and there is no equally short true sentence — which is a real
  loss, not a formatting problem.
- **A template is a thing to get wrong.** Node configuration is reviewed when it is deployed; a
  row is edited by whoever has the page. Machine shapes that do not match reality now have a place
  to live, which is why the mismatch above is surfaced rather than silent.
- **Nothing here is measured.** The gate's cpu dimension is argued from the shape of the workload,
  not from a run: `docs/measurements.md` measured memory (M3) and contention on twelve cores (M2),
  and has never measured a machine whose cores are the binding constraint. § Open says what to
  measure first.
- **`max_workers` at 1 has never been exceeded.** `worker-tier.md` § Open has said so since the
  tier was written, and every per-template ceiling here is a generalisation of a number that has
  only ever held one value.
- **The headline property cannot be fully demonstrated yet.** *Keeping inference off the machine
  bought for builds* wants a worker declaring `accepts: [:command]`, and `:command` is not a job
  kind until `commands.md` lands. What is testable today is the same rule with the kinds that
  exist — a machine with sixty-four gigabytes going spare refusing a `:workflow` job because it
  takes only `:chat` — and that is what the suite asserts. The mechanism is proven; the case it
  was built for is one migration away.

## Open

- **A core reserve, if there is one.** Memory reserves 2 GiB for the system and the Nix daemon
  (`ForgeWorker.Config`). Cores reserve nothing, which is a guess in the other direction: on a
  two-core machine reserving one halves it. Start at zero and let a measurement move it. The
  memory reserve is no better founded — `worker-tier.md` § Open now records that it is traced to
  nothing and says what to measure — and both numbers decide how many slices a machine yields, so
  they are one piece of work rather than two.
- **Fractional cores.** Shared vCPU makes `cpu: 0.5` meaningful and the gate would work in
  millicores. Not in the first pass.
- **An age-based reservation**, so a large job stops being jumped by small ones. § The gate says
  why it is not here yet; the trigger is the first time a skip count gets large.
- **Caching `shapes/1`.** An API call per page render is wrong. Per credential, with a manual
  refresh, is the obvious shape and is not designed here.
- **Currency.** `capacity.md` § Spend caps is in dollars and Hetzner bills euros. A fleet spanning
  two providers has two currencies and nothing converts them.
- **`identity.md`'s residual, widened.** That note records that a worker assigned to two projects
  spends its owner's subscription on work other people authored. A *template* assigned to two
  projects does the same for the hourly bill, and the answer is the same one: not decided here.
