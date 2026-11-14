# What each forge release changed for the projects it hosts

This is written for a project hosted on forge: what its `.forge/` workflows, prompts and command
scripts may say, and what its jobs, conversations and members can use. It is not about running a
node. One section per release, newest first; the newest is the release this platform runs. 0.1.1,
the first release, is the baseline and has no section.

Each entry is marked **must change** (a project that uses the thing breaks or behaves differently
until it changes) or **may adopt** (new and optional). A project records the release it was last
brought up to in `.forge/forge-release`; `platform.md` § Upgrading to a newer forge says how an
upgrade goes.

## 0.20.0

- **must change** — budgets are counted in weighted tokens, not dollars. Replace `cost:` in every `budget` with `tokens:` and `limits.ticket_cost` with `limits.ticket_tokens`. A figure is an integer or a number with `k` or `M` (`800k`, `4M`, `84.2M`); the old dollar figures convert at 200k tokens a dollar, so `cost: 4.00` was `tokens: 800k`. Admitting a ticket on a workflow that still names either old key is refused, naming the replacement; a ticket already admitted keeps running on the converted figure. Giving both keys at once is an error. Before and after:

  ```yaml
  # before
  budget: { turns: 80, cost: 4.00 }
  limits:
    ticket_cost: 25.00
  # after
  budget: { turns: 80, tokens: 800k }
  limits:
    ticket_tokens: 5M
  ```

  (workflow-grammar.md § Semantics, Budget)

- **may adopt** — run a state on Codex CLI with `harness: codex` on it (`claude_code` is the other value and the default). A job's harness is its state's, else the project's setting, else Claude Code, so a workflow naming none behaves as before. `model` and `effort` apply to the job's harness, and a project holds a model and an effort for each harness. `turns` bounds a Claude Code run and not a Codex run; `tokens` bounds both. A conversation can also be opened on Codex. Codex needs a Codex credential in the project's pool (a ChatGPT login, a Codex access token or an API key). Nothing of the Codex side has yet run against OpenAI. (workflow-grammar.md § Semantics, Harness)

- **may adopt** — every job and conversation is handed this changelog as `$FORGE_JOB/platform/changelog.md`, and a project records the release it was last brought up to in `.forge/forge-release`, a version and a newline (`0.20.0`). The project page reads that file and says whether the project is current, behind, newer or not recorded; with no file it counts as 0.1.1. Ask a conversation to bring the project up to the latest forge release and it works through the sections after the recorded one. (platform.md § Upgrading to a newer forge)

- **may adopt** — a release workflow (`release: true`) gets a record and a tag when a release ticket ends `done`: the platform keeps a record, and tags the merge's commit `v<version>` when the release has a version. The record lists the files of the groups named in `release_files: [name/*, ...]`, the text of the document named in `release_notes: <document>` (also the tag's message), and the `links:` (`[{label, url}]`) in the front matter of the documents the release's jobs wrote. The project has a Releases page listing them. Both keys are refused without `release: true`; `release_files` entries must be groups some state or command produces, and `release_notes` a plain document a non-chat job state produces. (workflow-grammar.md § Release keys, platform.md § Releases)

## 0.19.0

- **may adopt** — Markdown a job or conversation writes can show and link the ticket's artifacts by relative path: `![the queue](screenshots/queue.png)` draws a raster image (`.png`, `.jpg`, `.jpeg`, `.gif`, `.webp`, `.avif`; never `.svg`) and `[the plan](plan.md)` links a document. A bare name is the version current when the text was written, `name@N` is exactly version N, `name@latest` follows the newest, and another ticket's artifacts are `archive/<n>/name`. The names must match exactly; one that does not resolve is drawn as a muted note and never fetched. It works in presentations, documents and conversation messages (a project chat links its own documents but draws no pictures), so a presenting prompt can show the screenshots a ticket produced. (platform.md § Referring to artifacts from Markdown)

## 0.18.0

Nothing for projects in this release.

## 0.17.0

- **may adopt** — make a state a conversation with `chat: true`. Entering it opens a conversation on the ticket and the ticket waits for a person; the person's Accept ends the step, and when the edge Accept takes has `approve`, Accept is that approval, pinned to the version they were shown. A chat step takes `prompt`, `inputs`, `produces` (documents only), `outcomes`, `env`, `model`, `effort`, `resources`, `secrets`, and is refused with `budget`, `may_invoke`, `exit`, `changeset`, `commit-message`, a group of files, or an `optional` naming its outcome. Its spend is added to the ticket's cost and counted by `limits.ticket_cost` for later jobs but never stops it, so raise the cap by the allowance you give the conversation. Edges on engine outcomes from a chat step never fire, so drop them. forge's `refining` went from a one-shot job to a conversation that grills the person, on opus. Before and after:

  ```yaml
  # before
  refining:
    prompt: agents/refine.md
    env: default
    model: sonnet
    effort: high
    inputs: [ticket]
    produces: [refinement.md]
    budget: { turns: 60, cost: 3.00 }
  # transitions
  - { from: refining, to: planning,  approve: [refinement.md] }
  - { from: refining, to: refining,  when: budget_exhausted, max: 1 }
  - { from: refining, to: refining,  when: did_not_converge, max: 1 }

  # after
  refining:
    chat: true
    prompt: agents/refine.md
    env: default
    model: opus
    effort: high
    inputs: [ticket]
    produces: [refinement.md]
  # transitions
  - { from: refining, to: planning,  approve: [refinement.md] }
  ```

  The prompt has to be written for a person present (ask, one question at a time, keep `refinement.md` current as you go) rather than for a job that restates the ticket. (workflow-grammar.md § Chat steps)

- **may adopt** — put approved merges through the merge queue by adding `queue: true` to every edge into a merging state (one with `on_enter: merge`). Approving such an edge records the approval and queues the ticket; a per-project runner then merges one ticket at a time, checks the front against the default branch, and sends a conflict down `on_conflict` while keeping its place. While a ticket is queued no other transition may be taken. A workflow with no `queue` key merges at once as before. `queue` on an edge to a state that does not merge, or on an edge out of a chat step, is refused. `approve` is optional on a queueing edge. Before and after:

  ```yaml
  # before
  - { from: review_ready, to: merged, approve: [changeset] }
  # after
  - { from: review_ready, to: merged, approve: [changeset], queue: true }
  ```

  (workflow-grammar.md § The merge queue)

- **may adopt** — give the `on_conflict` state two outcomes so that a mechanical conflict resolution goes back into the queue and anything else gets a fresh review. forge renamed its `integrating` state `rebasing` (the name is yours: nothing in the platform reads it; a ticket pinned earlier keeps the old name) and made it end on `done` or `needs_review`. `done` goes straight to the merging state with `queue: true` and merges with no second approval; `needs_review` goes back through `checking`, review and presentation to a fresh approval. Because the state now runs the gate itself, give it `may_invoke: { check: ... }`; and because the review and presentation of a rebased ticket read what the rebase did, add the new optional document to their `inputs`. A `done` edge skips a person, so the prompt must say when `done` is allowed (forge: only when the engine sent the ticket there, every resolution is mechanical, the gate passes and nothing else changed); the platform does not enforce it. Before and after:

  ```yaml
  # before
  merged: { on_enter: merge, on_conflict: integrating }
  integrating:
    prompt: agents/integrate.md
    produces: [integration.md, changeset]
  # transitions
  - { from: integrating, to: checking }

  # after
  merged: { on_enter: merge, on_conflict: rebasing }
  rebasing:
    prompt: agents/rebase.md
    may_invoke:
      check: { max: 3 }
    produces: [rebase.md, changeset]
    outcomes: [done, needs_review]
  # transitions
  - { from: rebasing, to: merged,   queue: true }
  - { from: rebasing, to: checking, when: needs_review }
  # and in reviewing and presenting
  inputs: [refinement.md, plan.md, implementation.md, report.md, rebase.md, changeset]
  ```

  The platform bounds the engine's conflict loop at three rebases in a row, so account for three of them in `limits.ticket_cost`. (workflow-grammar.md § The merge queue)

- **may adopt** — declare a workflow the project's release with a top-level `release: true` in one file under `.forge/workflows/`. A project admin then starts a release from the project page with an optional note (its `ticket` input), the type is left out of the new-ticket form, the ticket is titled "Release in progress" until a document of the ticket whose front matter carries `version: X.Y.Z` renames it, and it concludes by itself when its last edge has no `approve`. `release: true` is refused in `.forge/workflow.yml` and in a library; two type files setting it means the project has no release. forge's release workflow approves `release-notes.md` once, merges a good publish through the queue with no second approval, and sends a half-done publish to a human state through an outcome the workflow declares itself:

  ```yaml
  release: true
  # publishing
  outcomes: [done, snapshot_failed]
  # transitions
  - { from: refining,   to: publishing, approve: [release-notes.md] }
  - { from: publishing, to: merged,        queue: true }
  - { from: publishing, to: release_ready, when: snapshot_failed }
  - { from: release_ready, to: merged,     approve: [changeset], queue: true }
  ```

  (workflow-grammar.md § Location; platform.md § Releases)

- **may adopt** — every job and conversation has a read-only archive of the project's past at `$FORGE_JOB/archive/`: `index.md` with a line per ticket, `jobs.tsv` with one per job that ran, and each ticket's folder holding every version of every document and file (`plan.md` is the latest, `plan.v001.md` the first). It is fetched when opened and is live, not pinned: cite a version. The backlog's numbered files hold only a ticket's body, so a prompt that wants earlier tickets' documents should point at the archive; forge's refinement uses it to find earlier related work. (platform.md § Ticket proposals; the archive is described in preamble.md and chat-preamble.md)

- **may adopt** — a project can mint per-project tokens (named, with an API access level and a git access level) for the REST API under `/api/v1`: list and read tickets, events, reviews, jobs and artifacts, create tickets, edit a document, answer, approve, transition, retry, cancel, restore and decide proposals. Tokens are issued on project settings. A token a job holds is refused by the API. This is not described in `workflow-grammar.md` or `platform.md`; the detail is in `docs/design/api-and-ui.md` in forge's repository.

## 0.16.0

- **must change** — a workflow with a state that merges (`on_enter: merge`) must now have a job state that produces a plain document `commit-message`, the text of the merge commit, used exactly as written. Without one the file is refused, and a ticket reaching the merge without a version of it sticks in the merging state. It may not be `optional`, `commit-message/*` or `commit-message!`, a transition's `approve` may not name it, and in a state with outcomes other than `done` it may not come first in `produces` (the outcome document must). The text is a summary line, a blank line, then a body; no front matter and no trailers; the state's prompt has to ask for it.
  ```yaml
  # before
  presenting:
    produces: [presentation.md!]
  # after
  presenting:
    produces: [presentation.md!, commit-message]
  ```
  A conversation with a branch likewise writes its own `commit-message` document, or its page offers no merge. (`workflow-grammar.md` § Merging and § Validation; `platform.md`)
- **may adopt** — a job state may declare `effort` (for Claude Code `low`, `medium`, `high`, `xhigh` or `max`) beside `model`: `effort: high`. It falls back to the project's setting, then the machine's; the value is any non-empty string, not checked by the platform. It is refused on command and human states, as `model` is. (`workflow-grammar.md` § Semantics, the paragraph on Effort)

## 0.15.0

Nothing for projects in this release.

## 0.14.0

- **may adopt** — a name ending `!` in a job state's `produces` is a presentation: prose composed
  for the person deciding on the merge, shown view-only with no approval. Write
  `produces: [presentation.md!]`; the job writes `presentation.md` to `$FORGE_JOB/out/`. It cannot
  be an input, cannot be approved, and only a job state may declare one. (`workflow-grammar.md` § Semantics)
- **may adopt** — a job state may declare `optional: [name, ...]`, listing produced documents it
  may finish without writing. Names are the plain artifact names (`optional: [presentation.md]`
  for `produces: [presentation.md!]`); `changeset` and groups of files cannot be optional, and a
  state that declares outcomes other than `done` may not make its outcome document optional. A
  command or human state may not carry `optional`. Without the key every produced document is still
  required and a missing one ends the job in `error`. A document so excused counts as an optional
  input downstream. (`workflow-grammar.md` § Semantics and § Validation)
- **must change** — while a transition is waiting for approval, no other transition from the state
  can be taken; the pending decision has to be approved or rejected first. A project that moved a
  ticket by an API call or a chat while a decision was pending now gets a refusal.
  (`workflow-grammar.md` § Semantics)
- **may adopt** — a conversation on a ticket can move it: it writes `$FORGE_JOB/transition.json`
  with `{"to": "<state>", "comment": "..."}` to take a transition out of the current state, or
  `{"decision": "approved"|"rejected"}` to decide the pending one. The file is read once at the end
  of the turn, and the platform reports nothing back, so the chat must say what it asked for. A
  state reached by two transitions cannot be asked for. (`chat-preamble.md` § Moving the ticket)

## 0.13.0

- **must change** — a job state that does not declare `changeset` in `produces` now has a scratch
  worktree: nothing in it is committed or pushed, whatever the job left in the tree. Before, its
  edits could reach the ticket branch. A state whose prompt tells the agent to edit files and
  commit them must add `changeset` to `produces`; a state that only writes documents needs
  nothing, but its prompt must not promise that code changes survive. A conversation is
  unaffected: it declares no outputs and commits every turn to its own branch. Commands a
  `may_invoke` state asks for run against the branch as the job found it, without its edits, unless
  the state declares `changeset`. (`platform.md` § Tickets, states and jobs and § Branches and merging)
- **may adopt** — the project's repository can be browsed read-only on the project's pages
  (`/projects/<name>/repo`, and `/projects/<name>/repo/commits/<sha>` for one commit). (forge's
  repository, `docs/design/ui.md` § The project's repository)

## 0.12.2

Nothing for projects in this release.

## 0.12.1

Nothing for projects in this release.

## 0.12.0

Nothing for projects in this release.

## 0.11.0

- **must change** — only for a project that already has `.forge/workflows/<name>.yml` files next to
  a `.forge/workflow.yml`: the two forms together are now an error and nothing is admitted until
  one is removed. Keep the single file, or move it into `.forge/workflows/<type>.yml`.
  (workflow-grammar.md § Location)
- **must change** — jobs and conversations are told not to edit anything under `.forge/` (the
  workflows, imported libraries, prompts and command scripts alike), where before only
  `workflow.yml`, `agents/` and `commands/` were named. Changes to `.forge/` belong in a
  conversation. (preamble.md)
- **may adopt** — `on_conflict: <state>` on the merging state (`on_enter: merge`) routes a merge
  conflict to a job state (an "integrating" job that also sees the default branch) or to a human
  state, instead of refusing the approval. The target must have a transition out and be the `to`
  of no transition. Every merge now merges the `changeset` version its transition named, so an
  approval never merges a later version. After an integration the workflow decides: back to an
  approval step, or straight to the merging state. (workflow-grammar.md § Merging)
  ```yaml
  states:
    merged: { on_enter: merge, on_conflict: integrating }
  ```
- **may adopt** — ticket types: one complete workflow per kind of work in
  `.forge/workflows/<type>.yml`, chosen by a person when a ticket is admitted and kept for its
  life; `description:` says what each is for. A workflow may `import` libraries (files under
  `.forge/`, outside `workflows/`) holding `commands`, `defaults` and state templates, used with
  `extends: <template>`. A proposal may suggest a type with `type: bug` front matter above its H1
  when `tickets/index.md` lists types. A single `.forge/workflow.yml` still means no types.
  (workflow-grammar.md § Location, § Imports; platform.md, on ticket types)
- **may adopt** — project secrets: a job state or a command lists the ones it receives with
  `secrets: [NAME]` (names match `^[A-Z][A-Z0-9_]{0,63}$`, none reserved); they reach the job in its
  environment, are masked in what it uploads, and a conversation's are picked by the person opening
  it. Not allowed on command states, human states or `defaults`; a job naming a secret the project
  has not set waits until an admin sets it. (workflow-grammar.md § Secrets; platform.md § Secrets)

## 0.10.0

Nothing for projects in this release.

## 0.9.1

Nothing for projects in this release.

## 0.9.0

Nothing for projects in this release.

## 0.8.1

Nothing for projects in this release.

## 0.8.0

Nothing for projects in this release.

## 0.7.0

- **must change** — a `memory` under `resources` (on a state, a command, or under `defaults`) of less than 512 MiB is now refused ("must be at least 512MiB, the least a job can run in"). Raise any smaller figure. (`workflow-grammar.md` § Resources)
- **may adopt** — a job runs under a hard memory ceiling named by `$FORGE_MEMORY_MAX`, and every agent is told that exit status 137 usually means it was hit and to rerun with less parallelism. A command script can read the variable to size its own parallelism. (the job preamble, which is the prompt a job is given)

## 0.6.0

- **must change** — the shape of a `question` block changed. Options are no longer bare strings with a sibling `default`; each is a mapping with a `label` (at most 40 characters), a `detail` (a sentence, at most 140) and optionally `recommended: true` on at most one. `text` is at most 200 characters, and `key` must be unique within a document. A block with the old shape, or with a `default` key, is sent back to the job. Update any prompt under `.forge/agents/` that shows an example. For a non-blocking question, write the `assumption` as the option's `label` exactly. (`platform.md` § Questions; the full format is in `preamble.md`, in forge's repository)
```yaml
# before
options: [local-file, sqlite]
default: sqlite
# after
options:
  - label: "SQLite database"
    detail: "The scores already live there."
    recommended: true
  - label: "Local file"
    detail: "Simple, but another thing to back up."
```
- **may adopt** — a command's log, the name in its `produces` (not a group), can be listed in the `inputs` of a later state. It is always optional and inlined cut to its two ends. The job a failed command state sends the ticket to is handed that state's statuses and logs under "How you got here" whether or not it names them. (`workflow-grammar.md` § Semantics)
- **may adopt** — command scripts now start in the checkout, which `$FORGE_CHECKOUT` also names; `$FORGE_OUT` is where groups of files go and `HOME` is empty and never kept. The script runs from a pinned copy outside the checkout, so one that finds the repository with `cd "$(dirname "$0")/../.."` leaves it: use the working directory or `$FORGE_CHECKOUT`, and keep tool caches inside the checkout, ignored by git. (`workflow-grammar.md` § Commands)
- **may adopt** — a ticket's workflow, prompts and scripts stay pinned at admission, and a member can now re-pin a ticket to the default branch's head (refused while a job is live or an approval is pending), which is how a fix to a command script reaches a ticket that is failing on it. A proposal file is named for what it proposes; the platform adds the `proposal-` prefix, so do not write it. (`workflow-grammar.md` § Pinning)

## 0.5.0

- **may adopt** — in a prompt that teaches an agent to ask questions, show `text`, `anchor` and `assumption` in double quotes (an unquoted `: ` inside ends the document with `invalid documents`). A number or boolean in `text` is now read as the text it was written as. A job whose outputs the platform cannot accept (missing, undeclared, unparseable, an outcome the state does not allow) is now resumed twice with what is wrong before it is reported as `error`. (`platform.md` § Artifacts and versions; the question format is in `preamble.md`, in forge's repository)
- **may adopt** — members can run a ticket's current state again (a job or command state with nothing live in it, after a failure or a success) and cancel a ticket. A cancelled ticket is hidden everywhere, including the backlog every job reads, and its page offers Restore, which makes it stuck in the state it was in. Neither takes a transition, so no `max` counts a retry. (`workflow-grammar.md` § Semantics)
- **may adopt** — A transition whose `approve` names a document that has no version yet is no longer offered, so a failed refinement no longer offers `planning`. Nothing to change in the file.
- **may adopt** — Every job and conversation now has `git`, `python3`, `rg`, `fd`, `jq`, `yq`, `curl` and `make` on its `PATH`; a prompt need not ask for them from the devshell. (the job preamble, which is the prompt a job is given)

## 0.4.0

- **may adopt** — commands. A top-level `commands:` map declares fixed scripts under `.forge/` (read at the ticket's pinned commit), each with `run` and `timeout` (required, at most a day, like `20m`) and optionally `env`, `produces` and `resources`. A command state has `invoke: [build]` and an `exit:` map from exit status (or `"*"`) to an outcome, and no `prompt`, `inputs`, `produces`, `outcomes`, `budget`, `model`, `env` or `may_invoke`. A job state may carry `may_invoke: { build: { max: 3 } }`; its agent then writes `$FORGE_JOB/invoke.json` and ends its run, parks, and resumes with each command's status and log. Before this release these keys were refused as unknown. (`workflow-grammar.md` § Commands)
- **may adopt** — groups of files: `name/*` in `produces`, for a job state or a command (`produces: [package.log, package/*]`). Each file the job writes into `out/name/` becomes a downloadable blob on the ticket. A group cannot be an input or be approved, and was refused before. (`workflow-grammar.md` § Semantics)
- **may adopt** — a human state may declare `produces` with documents (never `changeset`) that a person writes on the ticket's Decide tab, for example `human_testing` producing `test-report.md`. It is always an optional input to later states. (`workflow-grammar.md` § Semantics)
- **may adopt** — an input a state reads may be written only by a later state that sends work back (`implementing` reading `review.md` from `reviewing`). It is now optional: absent on the first entry and named in the manifest as not written yet, where it used to leave the ticket stuck on entry. A job's manifest also gains "How you got here" with the comment on the transition that sent it back. (`workflow-grammar.md` § Semantics)
- **may adopt** — `resources` is also accepted on a command and on a command state, falling back from the command to the state to `defaults`. (`workflow-grammar.md` § Resources)

## 0.3.0

Nothing for projects in this release.

## 0.2.1

Nothing for projects in this release.

## 0.2.0

- **must change** — `resources` on a human state (a state with no `prompt`) is now refused with "not allowed on a human state"; nothing runs there, so there is nothing to size. Delete it from any human state. (`workflow-grammar.md` § Resources)
- **must change** — a state may no longer `produces` a name beginning `transcript-` (the platform stores job transcripts under it), and the name `proposals` and the prefix `proposal-` stay reserved; the same rule now applies to inputs. Rename any such document. (`workflow-grammar.md` § Validation)
- **may adopt** — a conversation can now write documents: files it puts in `$FORGE_JOB/out/` are recorded as versions of a document of the same name, on a ticket's conversation as that ticket's documents. A name is one path segment and may not be `ticket`, `answers.md`, `changeset`, `proposals`, or begin `proposal-` or `transcript-`. A reopened conversation finds what was said before in `$FORGE_JOB/conversation.md`, and its own documents in `inputs/`. (`platform.md` § Conversations; the writing rules are in `chat-preamble.md`, which is in forge's repository)
- **may adopt** — ending a conversation now deletes its branch if it was not merged, unless it would not merge cleanly, so work a person wants from a conversation is merged first. (`platform.md`)
