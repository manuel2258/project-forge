# Files people attach

Ticket 60. A person can attach files — images mostly, any bytes — wherever they write something
an agent will read, and the agent can open them. **The point is the agent**: an implementer that can
look at the screenshot of a bug, a chat agent that can see the picture just sent. The pages gain no
new way of showing a file; a person sees names as links, a Docs row, and what `ui.md` § References
already draws.

`docs/design/archive.md` is what a job may read of the project's *past*; `commands.md` § Groups of
files is what a *job* produces. This is the third kind of file in the system and the only one a
person writes.

## The pool

**One pool per ticket, one per project chat.** Every file a person attaches on a ticket — a ticket
chat's included — is in the ticket's pool; a project chat's are in that conversation's. A pool is a
set of artifacts named `attachments/<file>`, each a blob, each with versions like any artifact.
**Only people's files are in it.** `screenshots/*`, `package/*` and logs are a job's and are not
handed to anybody new: a job's package can be a gigabyte and every run downloads the pool.

**The same name twice is two versions of one file.** Nothing is overwritten. The artifact tables
stay as they are (`decisions.md`: artifacts are immutable); what is added is `attachments`
(`data-model.md`), one row per file attached in one act, beside the version that holds the bytes.

**The reserved name.** `attachments` and every name beginning `attachments/` is refused by the
workflow validator as anything a state or a command produces or consumes, as `answers.md` is
(`workflow-grammar-v1.md` § Validation), and by `ForgeCore.Workflow.document_name_error/1` for a
conversation's own documents. A person's file can therefore never collide with an artifact a job
writes, so it cannot cause the kind mismatch `proposal-artifact-kind-mismatch.md` describes. The
release's changelog section says so, because a hosted project's workflow could be using the name.

## Names

A file's name as uploaded is kept in `attachments.original_name` and is never trusted. The artifact
name is made from it, in this order:

1. the last segment after `/` or `\` — `../x` and `/etc/x` become `x`;
2. anything outside `[A-Za-z0-9._-]` becomes `-`, runs collapsed;
3. leading characters that are not letters or digits are stripped;
4. the extension is kept (cut to 40 bytes) and the whole is cut to 200 bytes;
5. an empty result is `file` plus the extension;
6. a stem ending in `.v<digits>` becomes `-v<digits>`, so a name can never read as another file's
   versioned spelling in the folder.

The result passes `ForgeCore.Workflow.valid_name?/1`, and the artifact is `attachments/<that>`. A
name never becomes a path: the worker checks it again before it writes (§ The folder).

## Limits

| Limit | Value | Counted |
|---|---|---|
| One file | 500 MiB | the bytes **received**, not a size announced |
| With one act | 10 files | the files attached to one message, document, answer, note or ticket |
| A pool | 100 files, 5 GiB | every live version counts; a withdrawn one and one not received do not |

A file that would pass a limit is refused saying which, and does not stop the others. The limits
live in `Forge.Attachments` and are overridable in configuration so the suite needs no large
files. **They hold under two uploads at once**: a claim locks the pool's row (`tickets` or `jobs`)
and counts under the lock, so two files that each fit cannot together pass the pool's. The page
also refuses early what it can see — a file over 500 MiB, an 11th file, a file past the room the
page was drawn with — before any bytes are sent, which is a courtesy and not the guard.

## Staging, claiming and the sweep

**An upload is staged first.** `POST /projects/:name/uploads` takes the bytes as a raw body and
keeps them under the store key `upload/<id>` with a row in `attachment_uploads`: the project, the
actor, the original name, the size the store wrote, a hash. Nothing counts a staged file, no agent
is handed it, and it is not in any pool. The reply is `{id, name, size}`; `DELETE
/projects/:name/uploads/:id` removes one the actor staged.

**The key is not `artifact/<sha256>`.** Content addressing would let two identical files share one
set of bytes, and withdrawing one would delete the other's. The hash is also unknown until the bytes
have arrived, and the key must exist before they do (`storage.md` § Keys).

**An act claims it.** The act is a message, a document version, the ticket, an answer or a note.
Two things must hold: **the files are in the pool before the job the act makes can be assigned** (a
file attached to an answer must reach the run that asked, `§ Delivery`), and **a refusal after an
act's git work cannot take back what it pushed** (a merge pushed, then the approval rolled back).
`Forge.Operator` therefore:

1. **checks a whole request (the API's) first**: `Attachments.preflight/4` applies the claim's limits
   to the batch without a lock, and a refusal is `422` before the act runs;
2. **for an act that makes the ticket** (admit, accept a proposal), runs the act and the claim in one
   transaction: nothing there pushes after commit, and the ticket — so its first job — does not exist
   until the transaction does;
3. **for an act on a ticket** (answer, edit, approve, transition, retry, extend), takes the ticket's
   **assignment lock** (`Attachments.hold/2`: a session advisory lock, class 60, on the ticket's
   id), runs the act in its own transaction as it always did, then runs the claim in a transaction
   of its own, lenient, and lets the lock go. `Forge.Jobs.pending/2` leaves out the jobs of a ticket
   whose lock is held, so the scheduler does not assign the job the act made until the claim has
   committed — or the act has failed. A file a race made impossible (the pool filled between the check
   and the claim) is *not received* and the act stands. A claim that raises is logged and the files
   stay staged for the sweep; the person is never told an act failed that did not.

A chat message is the exception: `Conversations.send/open` claim in their own multi, in the
message's transaction (nothing there pushes), anchored to the message's event directly. A repeated
id in a batch is one file.

`Forge.Attachments.claim/6`, with the staged ids the page or the API sent, does, in order:

1. lock the pool's row `FOR UPDATE`;
2. lock the staged rows, each owned by this actor and of this project; a missing or foreign id is
   not an error that leaks whose it was, it is a file *not received*;
3. count the pool;
4. per file, refuse one past a limit — recorded as not received (a whole claim would return the
   refusal; the Operator only asks it of the preflight);
5. write the version of `attachments/<name>` as a blob pointing at `store:upload/<id>`;
6. log one `attachment.added` event for the act, with the files, their versions and the names not
   received;
7. insert the `attachments` rows, anchored, and delete the staged rows.

**What the act wrote is the anchor.** The claim finds the row the act made — the artifact version
for the ticket and for a document, otherwise the first event of the act's type **by the same actor**
after a sequence number read before the act (`question.answered`, `approval.*`, `ticket.retried`,
`job.extended`, the transition's event) — and stores it as the attachment's `to_version_id` or
`to_event_seq`. When the act wrote nothing it can find, the anchor is the `attachment.added` event
itself. A label such as "the rejection note on plan.md v2" is derived when listed, in one function
with batched preloads; it is not stored.

**The API is whole or nothing.** A request with files is parsed after the caller is known to be
allowed to write there; every file is staged, and a refusal of any — a limit, a name — is `422
attachments_refused` naming the file and the limit, with the act not done and the staged files
removed. The body is read part by part and bounded in every part of it: a text field at a megabyte in
all, the headers of all the parts at a megabyte, the parts at a hundred, a file by the file limit and
the whole by ten files and the fields (each `413`), and each temporary copy is removed when its bytes
are in the store. What a request staged and the operation did not claim goes with a response of 400 or
more, and with a request an exception cut short (Phoenix answers 400 to one the action has no clause
for): the router's error handler discards it, since `before_send` does not run for that answer. A page's act is lenient: the text and the files that finished are sent, and a
file that failed or was cut off is named as not sent.

**The sweep.** `Forge.Attachments.Sweeper`, hourly, deletes staged rows older than 24 hours and
then their bytes, so a file uploaded and never sent — the page left, the form abandoned — leaves
nothing in the store and counted for nothing. It also deletes the bytes of any withdrawn version
still in the store, in case a delete after the commit failed. It deletes the bytes of the rows it
removed and not of every row it selected, so an upload an act claimed in between keeps its bytes. It
is off in the suite, which calls it directly.

## Delivery

**Every run gets the whole pool as it is when the run starts**: a job's first run, a resume after
an answer (so a file attached to the answer reaches the job that asked), an extended run, a restart,
a conversation's reopen. **A running workflow job is not given files mid-run**: a file attached
while it runs reaches its next run, or the next job. A job that waits on nothing has no moment to
be told of one; stopping it and running it again with a note is how a file that matters now reaches
it. **The act's own files are in the pool when that run is assigned**, which is what the assignment
lock of § Staging, claiming and the sweep is for: the run an act makes (a resume after an answer, a
retry, an extension, the next state after an approval) is not offered to a worker until the files that
came with the act are claimed. A chat's message claims in the transaction that records it.

**A chat gets files while it is in progress.** Its folder is brought up to the pool at the start of
every turn, so a file attached anywhere on the ticket while the chat runs is there from its next
turn, and a message's own files are in the folder before the turn that reads the message begins. The
`message` the worker is pushed carries the pool and names that message's files
(`conversations.md` § The wire).

**Commands are not given the pool.** A command is a fixed script that reads no manifest; skipping it
saves up to 5 GiB of download per build.

**Two shapes cross the channel.**

- **The spec** (`ForgeCore.Job.Spec.attachments`, filled at run time and never stored) carries what
  the manifest says of each file: the folder name, the artifact name, the version, the size, what it
  was attached to, who attached it and when, and the name as uploaded; plus the names of files
  attached but *not received*. It carries no key and no token.
- **The assignment** carries `attachments`, one entry per file with the key, the version id, the
  size, the hash and a store `get` token that outlasts the preparation margin, as a `history` file's
  does (`worker-channel.md` § Protocol 13).

**The folder spelling and the manifest are one function.** `Forge.Attachments.pool/1` returns the
live versions grouped by name with the spelling the folder uses — the newest live version keeps the
plain name, earlier live ones sit beside it as `stem.v001.ext`, as the archive spells them — and
the spec, the prompt's § Attached files and the worker all read that, so the prompt cannot name a
file the folder does not hold. A withdrawn version is not in it, and the version after a withdrawn
newest takes the plain name.

**The manifest** (`job-prompt.md` § Attached files) lists every file with its version, size, what
it was attached to, who and when. The continuation prompt always carries it, so a file attached with
an answer reaches the job that asked.

## The folder

`$FORGE_JOB/attachments/`, **read-only to the job**. **Two directories, and the split is the safety
property.** The worker downloads each version once into `<job>.worker/attachment-cache/<version id>`,
through a `.partial` file whose size and sha256 are checked (as `Archive.Client.fetch` does), in
a directory only it can enter. `<job>.worker/attachments/` holds only the names the pool spells,
each a link to a cached file, and is what is shown to the job. What is no longer in the pool is
removed from both, bytes included. A failed download is named to the agent as not received, with
*it could not be downloaded to this machine*, and is not a failed job.

**Why a mount.** A conversation syncs while its process runs, and the job owns `$FORGE_JOB`: it
could swap the folder for a link to anywhere between a check and a write. So the worker's directory
is shown to the job by a **read-only bind mount** at `$FORGE_JOB/attachments/`, and the worker
writes only where the job cannot reach. The mount is made where the archive's is, by
`Runner.with_attachments/3` beside `with_archive/3`, and released by `Archive.release/1`, through `ForgeWorker.Archive.Mount`, still the one module that runs
`mount`, which gains a `bind_ro/2` callback. It **shares the archive's accepted gap** (a process that
outlived a killed worker could plant a link where the folder goes before root mounts over it,
`Archive.start/3`'s comment). **The switch** is `FORGE_ATTACHMENTS=bind`, set on the
image: without it (a developer's machine, the suite) the worker copies into a plain folder, as the
archive falls back to a README.

**A name is never a path**, and the worker does not trust the platform's check: each name is
validated again with `valid_name?`, and one that is not is refused.

## Reading and serving

**Scoping is the artifact's.** A ticket's files are read by its project's members at the ticket's
file addresses (`ui.md` § Addressable artifact versions); a project chat's by whoever may open that
chat, at the chat's addresses, never resolved from another chat or a ticket. A node admin who is not
a member sees none. A job's token reaches the people's files of its own ticket or its own project
chat and nothing else. A ticket's files are also in the archive for the project's later jobs
(`archive.md`), as `<n>/attachments/<file>`; a withdrawn one is neither listed nor served.

**Bytes are served under the existing rules**: inline only for a raster image, everything else a
download, `nosniff` and the sandbox policy on every response. An `.html` or `.svg` file never runs
on a forge page.

**References resolve as they do** (`ui.md` § References): `![alt](attachments/shot.png)` is drawn by
the existing code in a ticket's text, its documents and its chats — and now in a project chat, for
that chat's own files, where it used to say *chats keep no images*. A non-raster file there is *not
drawn as an image*.

## Withdrawing

A file attached by mistake can be withdrawn. **By whom**: the person who attached it, or an admin of
the project, and by nobody else; a file a project token attached, by an admin only; a project token
may not withdraw. The guard is in `Forge.Attachments`, and the API's `DELETE` under a user token
asks the same rule.

**What it does.** One version, or every version of a name, as the person chooses. The bytes are
deleted from the store. The record stays — name, size, who attached it and when — with who
withdrew it, when, and an optional reason, on the `attachments` row, **beside the version and not in
it**: `artifact_versions` is append-only by trigger and stays so. A trigger on `attachments` refuses
a delete and any update but setting the withdrawal columns, once. Withdrawing is an event in
Activity, `attachment.withdrawn`, with who and the reason. No later run is handed the file; a
running chat's folder loses it at its next turn. Its address answers `410` — in the API as JSON —
saying it was withdrawn, by whom and when, instead of bytes; its Docs row and its link under the
message say *withdrawn*; an image reference to it is a muted *withdrawn* note. It stops counting
towards the pool's limits. **There is no undo.**

**What it cannot do, said in the confirm before it happens.** An agent that already read the file
may have quoted it in a reply, a document, a commit or a transcript, and a machine that downloaded
it may hold it until that job's directory goes. Withdrawing stops the file going further; it does
not recall what was read.

**This is the one way the bytes of a blob an act claimed leave the store.** The staging sweep deletes
only what no act ever claimed, and, for a delete that failed after a commit, the bytes of a version
already withdrawn. Nothing a job produced can be withdrawn.

## Not masked

**People's files are not masked.** The worker's masking of project secrets (`secrets.md` § Masking)
does not touch them: they are downloaded to the machine as they are and never uploaded by it, and
neither the sync nor the bind mount reads `Secrets`. Nothing tries to find a secret in a picture, or
scans an upload for malware. An attacher is a project member, and every project member can already
read every project secret (`secrets.md`).

## Security

- **Attaching has the guard of the act it rides on.** Whoever may send the message, write the
  document, admit the ticket, answer, approve, transition, retry or extend may attach to it, and
  nobody else. The context refuses, not just the page. A project token with *write* may; one with
  *read* is refused 403 as every write is; a job's token is refused.
- **A staged file is its stager's.** The claim checks the owner and the project of each staged id.
- **The limits count the bytes received** and hold under concurrent claims (§ Limits).
- **A name never becomes a path**, in the pool or in the folder (§ Names, § The folder).
- **The reading is scoped as every artifact is** (§ Reading and serving), and a project chat's
  files are never resolved from anywhere but that chat.
- **Who did it is kept**: each version records the person, or the token by name, and when, and the
  ticket's or chat's Activity says so.

## The API

An attached file is a `files[]` part of a `multipart/form-data` request on the writes that exist:
admit, accept a proposal, a new artifact version, an answer, an approval, a transition, a retry, an
extend (`api-and-ui.md`). It gains **no chat endpoints**. JSON requests are unchanged. A request is
kept whole or refused whole.

## Not built

A thumbnail, a gallery or a preview; withdrawing a file a job produced; resizing, transcribing or
cutting frames from a file for the agent; scanning; a project or node limit on the store, or
retention (`storage.md` § Open); giving a running workflow job a file mid-run; carrying a project
chat's files into a ticket it proposes (the accepted ticket starts with an empty pool); binding a
file to the document it came with; files on places no agent reads — a proposal's decline comment, a
title, a milestone's description. **A transition's comment has no box on the pages**, so it takes
files over the API only.

## Not verified here

- **The bind mount on a real machine.** The suite drives it through a recording double and the
  fallback copies; no kernel has mounted it.
- **Whether Claude Code and Codex can read an image from the folder.** Neither is observed here;
  Codex has never run against OpenAI. An agent is told where the file is, and what its harness makes
  of the bytes is the harness's.
- **Drop and paste on a real phone**, and the phone's own picker, camera and library.
- **A 500 MiB body through the deployment's proxy** (`deploy.md` § Behind a proxy).
- **Disk.** A job directory can now hold 5 GiB that provisioning's gate does not count.
- **Time.** Download time comes out of the hour-long preparation margin
  (`Forge.Jobs.preparation_margin_ms/0`); a pool near 5 GiB over a slow link may not fit it.
