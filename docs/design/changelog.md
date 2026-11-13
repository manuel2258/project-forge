# The changelog: forge to the projects it hosts

A project on forge is written against a forge release: its `.forge/` workflows and prompts say
things the grammar of that release understood, and its jobs and members use what that release
offered. The next release may change what a key means, refuse one, or offer something new.
Before this note, the only record was `docs/deploy.md` § Upgrading, which is for the node's
operator, and the commit that ported forge's own workflows to 0.17 (`e71a8c9`), done by hand from
the design notes. This is the record for the project.

**The changelog is addressed to a project, not to an operator.** It is `platform/priv/changelog.md`
in forge's repository, built into the platform, and every job and every conversation finds it as
`$FORGE_JOB/platform/changelog.md` beside `platform.md` and `workflow-grammar.md`. forge's
developers write it, one section per release, in the release (§ Writing a section). A hosted
project writes none of it. The text is the same for every project and holds nothing about any of
them.

A change that only concerns running a node — a protocol bump, a snapshot, a database migration,
an environment variable — is not in it. It stays in `deploy.md` § Upgrading.

## The file

One H1 and a short preamble, then one `## X.Y.Z` section per release, **newest first**. The
preamble has no `##` heading. The platform parses only the `## N.N.N` headings (§ The one list),
never what a section says.

0.1.1, the first version `VERSION` held, is the baseline and has no section. 0.2.0 to 0.19.0 were
written together, from the history of `VERSION`; every release after is written by that release.

### An entry

Each entry is a list item starting with its mark, in bold: **must change** or **may adopt**.

- **must change**: a project that uses the thing breaks, or behaves differently, until it
  changes. The agent applies it without asking.
- **may adopt**: new and optional. The agent lists it when the project does not use it and
  adopts it only when the person picks it.

An entry says what to change, gives a short before and after where a file changes, and names where
the detail is: `workflow-grammar.md § …` or `platform.md § …`, the two files a hosted agent
has, or the job or chat preamble, which is the prompt it was given. A `docs/design/` note is named
only when none of them covers the change, and the entry then says the note is in forge's
repository.

```markdown
## 0.17.0

- **must change** — `produces` on a state is a list: `produces: plan.md` becomes
  `produces: [plan.md]`. (`workflow-grammar.md` § Documents)
- **may adopt** — a state may declare `resources`. (`workflow-grammar.md` § Resources)
```

A release with nothing for projects still has a section, and it says exactly
*Nothing for projects in this release.*

## Writing a section

A release writes its own section; the forge changes it covers write nothing. `refining` in
`release.yml` writes it as `changelog-section.md` beside `release-notes.md`, and the one approval
covers both. The `release` skill, which releases forge without a ticket, writes it too. No release
reaches `main` without one: `Forge.ChangelogTest` fails when the newest section is not the version
`VERSION` names.

**The range** is everything since the last release, read from the history of `VERSION`, not from
commit subjects, because 0.13.0 to 0.15.0 have none (`publishing: attempt 1`):

```
git log --format=%h -n 2 -- VERSION      # the release commit and the one before it
```

**What to diff** are the surfaces a project reads: `docs/design/workflow-grammar-v1.md`,
`core/priv/platform.md`, `core/priv/preamble.md`, `core/priv/chat-preamble.md`,
`core/lib/forge_core/workflow/`, and the API and token routes in `platform/lib/forge_web/router.ex`.
Then read the log bodies for what a person or a job can newly do.

**What is left out**: anything about running a node. A change in `platform/` that only an
operator sees is not an entry.

The section starts `## X.Y.Z`, with the version in `release-notes.md`, and is committed
unchanged by `publishing` through `bin/changelog-add`, which refuses a section that does not
start with `## <VERSION>`, inserts it above the newest, does nothing when the same section is
already there and refuses a different one under the same heading.

## The recorded release

A project records the forge release it was last brought up to in **one file**,
`.forge/forge-release`, holding one version and a newline (`0.19.0`). It is one file per project
whatever its workflow files are, because a project with types would otherwise state it once per
type file and those could disagree, and because some changes (the API) are not workflow changes
at all. A project without the file counts as being at 0.1.1.

### The one list

**A forge release** is 0.1.1 or a release the changelog has a section for. The platform and the
agent judge the recorded value by that list: `0.12.9`, well formed but with no section, is not a
release to either.

The list holds nothing newer than the node's own release, so a literal reading would turn every
newer value into *not a release* and the *newer* case could never be reached. Both therefore apply
this rule, in this order:

1. No file: **not recorded**.
2. Larger than 64 bytes, or not of the form `N.N.N` after trimming whitespace (`v0.17.0`, text):
   **not a release**.
3. Greater than the release the platform runs: **newer**.
4. In the list (0.1.1 plus the section headings): **current** when equal to the running release,
   **behind** when lower.
5. Anything else, such as `0.12.9`: **not a release**.

*The release the platform runs* is the newest section of the changelog the job was handed; for the
platform it is the application's own version, and a test holds the two equal.

## How an upgrade goes

A person tells a project's agent, in a conversation, to bring the project up to the latest forge
release. It is a conversation's work and not a job's, since a job is told not to edit anything
under `.forge/`. `platform.md` § Upgrading to a newer forge says all of this to every agent, so no
project needs instructions of its own.

1. Read `.forge/forge-release` and judge it by the rule above. *Newer*: say so and change
   nothing. *Not a release*: say so and ask the person which release the project is really at.
2. Read each section after the recorded release, oldest first.
3. Apply every **must change** that concerns what the project already uses, without asking. Do
   not adopt a feature the project does not use yet.
4. List the **may adopt** features the project does not use, and adopt only the ones the person
   picks.
5. Set `.forge/forge-release` to the release the platform runs, **last**, only when every
   *must change* since the old value applied and every new feature was offered. An upgrade cut
   off halfway leaves the old value in place.
6. Commit on the conversation's branch for the person to merge. Raising the recorded release is
   a commit like any other change to `.forge/`; no job, conversation or token gains anything to do it.

A conversation that writes a project's first workflow also writes `.forge/forge-release` with the
release the platform runs, so a new project starts current (`core/priv/chat-preamble.md`).

## Delivery

The platform sends the changelog in the assignment, as `"changelog"` beside `"backlog"`, for an
agent job and a chat alike; a command does not get it. The worker writes it to
`platform/changelog.md`, mode 0444, when the field is a string, and writes nothing when it is
absent. The `platform/` folder is removed and rewritten on every prepare, so a resume gets the
platform's current text.

**It is not compiled into `forge_core` as `platform.md` is**, for two reasons. A release whose
Hetzner verdict is *Not needed* builds no new worker, so a compiled-in copy would lag the platform
it must match. And a file under `core/` would put `core` into every release's verdict diff, so every
verdict would come out *Recommended*.

**No protocol bump.** `worker-channel.md` § What needs a bump counts a new field whose absence
already has a meaning the receiver honours as no bump. An older worker drops the field; its
compiled-in `platform.md` does not mention the changelog either, so its agent is not misled, it
just is not told. The first release after this one changes `worker/`, so its verdict is
*Recommended*, which is how a running fleet gets the change.

## The project page

The platform reads the recorded release itself and shows it (`ui.md` § The project page). The
page and the agent read the same file at the same path, and a test holds the path in
`platform.md`.

- It reads from the **tip of the default branch**, the same commit the page's Workflow view
  reads, through git's object store by the fixed path and never from a checkout on disk, so a
  symlink committed in its place is never followed: the blob git holds is the link's target path,
  and that text is judged like any other content (`../VERSION` is *not a release*; a link whose
  target is the text `0.19.0` would read as `0.19.0`, which is what a file holding it says too).
- **With no default branch** — nothing to read the file from — the *forge release* fact says *not
  recorded* and no notice is drawn, since the Workflow view's own "cannot take a ticket" notice
  already speaks for that repository.
- It reads at most 64 bytes, the bound a release record uses for a version. A larger file is
  *not a release* and is never read. A directory or a submodule at the path is *not recorded*.
- What the file holds is shown as plain text, with control characters collapsed to spaces and cut
  at 40 characters, never as markup or a link.
- The page's chat link has a request written by the platform that names only the release the
  platform runs. Nothing from the file reaches it. Opening it writes nothing; the person sends the
  message.
- Nothing is a new write or a new permission. The fact and the notice are read-scoped as the
  page is.

## Not verified here

- **An agent doing the upgrade on a real project.** The changelog and `platform.md` say how, and
  tests hold the files, the rule and the page; no conversation has yet brought a project up from
  one release to another. forge's own `.forge/forge-release` is deliberately not written by the
  ticket that built this: the first real upgrade of forge is the notice's link on its own project
  page after landing.
- **The 23 backfilled sections** were written from the history by a reader, one range at a time. They
  are as accurate as that reading, and a project that finds one wrong has found a defect in the
  changelog to fix, not a rule.
- **A running fleet** keeps the workers it has until a release's snapshot replaces them; such a
  worker drops the field and its agents are not told the changelog exists (§ Delivery).
