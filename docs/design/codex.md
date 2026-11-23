# Codex, the second harness

Scope: how forge runs OpenAI's Codex CLI beside Claude Code (`docs/decisions.md` § Harnesses),
on a ChatGPT login or a Codex access token. Usage in weighted tokens, which this ticket brought
for every harness, is `docs/design/capacity.md` § Usage in weighted tokens; the credential
mechanism is `docs/design/credentials.md`. This note is the Codex-specific half and the
standard the driver is written against.

**Status.** Built, and **none of it has run against OpenAI**: the sandbox this was written in has
no `codex` binary and no ChatGPT account. What is built: the driver and its conversation with the
app-server (`ForgeWorker.Harness.Codex`, tested against a stand-in written to OpenAI's description,
`worker/test/support/fake_codex.sh`), the credential kinds, shape check, holds and returns on the
platform, the delivery and return of a login on the worker, masking, a machine offering the
harnesses it can run, and the screens that take a credential and a project's and a conversation's
harness. Also built, and no more checked against OpenAI than the rest: carrying a Codex session
between machines (§ Sessions), `codex-update.service` on the image (§ On the image), the workers
page listing every harness an offer carries, and masking the tokens of an `auth.json` Codex
rewrote (§ Masking). § Not verified here lists what a first real run has to confirm; the message names in this
note were written from OpenAI's description, and `codex app-server generate-json-schema` from an
installed version is what to check them against, recording the version here.

## Why the app-server and not `codex exec`

Forge stops a run itself, during the run, once its usage passes its budget (criterion 9;
`capacity.md` § Stopping a job already running). That needs a token count after each model call.
`codex exec --json` reports usage once, at the end; `codex app-server` (JSON-RPC over stdio)
streams `thread/tokenUsage/updated` after each call and `account/rateLimits/updated` as the
account's windows move, takes `turn/start` and `turn/interrupt` (a chat's messages while it is
working and its interrupt), and `thread/resume`. So jobs and chats use the same transport.

**If the app-server cannot be driven this way, the driver is not written quietly on `exec`**:
that fails the criterion it exists for, and it is a finding for planning.

## The driver

`Forge.Harness.Codex` on the platform, `ForgeWorker.Harness.Codex` on the worker, named
`codex` in `ForgeCore.Harness.names/0` beside `claude_code`.

- The worker writes `initialize`, then `thread/start` (or `thread/resume` with the stored session
  id), then `turn/start` with the prompt. In prompt mode `turn/completed` is `finished` and the
  runner closes stdin; in a chat it is the end of the turn. A message sent during a turn is held
  and sent after `turn/completed`; an interrupt is `turn/interrupt`. Since protocol 15 the
  **worker** holds a chat's messages for every harness, and reports each one delivered when it
  writes it (`conversations.md` § Turns); this driver's own queue then only holds the first message
  of a chat while the app-server initialises. A Codex chat's messages therefore stop reading
  *queued* for good.
- Environment: `CODEX_HOME=$HOME/.codex` (the job's own home), and the update check turned off with
  `-c check_for_update_on_startup=false` on the command line. **The rest is in the messages, not
  the environment or `-c`**: `thread/start` (and `thread/resume`) carry `approvalPolicy: never`,
  `sandbox: danger-full-access` — the job's slice is the sandbox, as it is for Claude Code — and the
  model when one is set; `turn/start` carries the model and the effort when set. Nothing names
  `CLAUDE.md`: **Codex reads `AGENTS.md` only**, and this repository has none. The machine's own
  `FORGE_CLAUDE_EXECUTABLE`, `_MODEL` and `_EFFORT` are Claude Code's and are not handed to Codex
  (`ForgeWorker.Harness.machine_opts/2`); its binary is `FORGE_CODEX_EXECUTABLE` and falls back
  to `codex` on the `PATH`.
- No turn limit: `budget.turns` bounds a Claude run and not a Codex one.

### Events

Normalised into the `job.harness.*` schema of `claude-code-events.md`:

| Codex | forge |
|---|---|
| thread id | `started.session_id` |
| agent message | `text` |
| command, file change, MCP item | `tool_use` / `tool_result` |
| `thread/tokenUsage/updated`, its *last* breakdown | `usage` |
| `account/rateLimits/updated`, primary / secondary window | `rate_limit` (`five_hour` / `seven_day`, utilization, reset) |
| a usage-limit error | the failure Claude's limit gives, so the job goes back to pending |
| a `warning` starting `Code Mode is unavailable` | a `notice`, and every turn of the thread that would have ended `success` ends `error_during_execution` with that text (§ On the image) |
| any other `warning` (`Falling back from WebSockets to HTTPS transport…`) | a `notice`, and nothing more |

Usage by kind: fresh input = input − cached input, cache read = cached input, cache write = 0
(Codex has none), output as reported. Whether reasoning tokens are inside the reported output is
read from the schema and recorded here; if they are not, they are added.

## Credentials

Two kinds, both ChatGPT: **`chatgpt_login`** (Plus or Pro: the `auth.json` a `codex login`
writes) and **`access_token`** (Business or Enterprise: a fixed token the workspace issues). No
OpenAI API key, by decision.

Kinds declare what differs (`credentials.md` § One mechanism, differences declared per kind):

| kind | exclusive | returns | checked on save |
|---|---|---|---|
| Claude token, Claude API key | no | no | against the provider |
| `chatgpt_login` | **yes** | **yes** | shape only |
| `access_token` | no | no | shape only |

**Shape check.** A login is at most 64 KB of JSON in ChatGPT mode carrying `tokens.access_token`,
`refresh_token`, `id_token` and `tokens.account_id`; an access token is one non-empty line. Every
failure is a fixed phrase. A `Jason.DecodeError` is never formatted: its message carries the
input. The account id and the plan (a claim of the id token, decoded without verification and for
display only) are stored in the clear; the secret itself is sealed with the Vault.

**Delivery.** The login reaches the process through the loader file as one variable; a fixed
`sh -c` prefix writes it to `$CODEX_HOME/auth.json` under umask 077, unsets the variable and
`exec`s Codex — never argv, never the unit. An access token is delivered in the form OpenAI's
CI/CD auth guide documents, through the same loader.

**Holding.** OpenAI's guide says one `auth.json` per runner or per serialized stream, because
Codex refreshes it about every eight days and writes the new tokens back, and a copy another run
refreshed first stops working. So a login is held by one live run at a time: `job_runs.exclusive`,
copied from the kind when the run opens, and a partial unique index on live exclusive runs per
credential. A hold is a live run and ends with it however it ends.

**Returning.** After the process exits, and after every chat turn, the worker reads `auth.json`;
if its hash differs from what was delivered it seals the file to its token and the job and puts it
in the result as `credential_return`. The platform keeps it only if the run is this job's, on this
worker, on this credential, of a kind that returns, and the account id is the stored one. Refused
returns keep the stored login, are recorded as `credential.renewal_refused` with a fixed reason,
and never change the job's outcome.

## Sessions

A Codex run's thread is a rollout file, `home/.codex/sessions/<year>/<month>/<day>/rollout-<time>-<thread>.jsonl`
under the job's own `HOME` (`CODEX_HOME=$HOME/.codex`). The driver declares `session_layout:
:rollout` in its capabilities, `resume: true`, and `ForgeWorker.Job.Session` and
`ForgeWorker.Job.Dir` do the rest as they do for Claude Code's session (`claude-code-events.md`
§ Resume): after a run, or a chat turn, the rollout named by the thread id is staged and uploaded
(masked) under the job's own key; before a resume it is fetched, checked, and put back under
`sessions/` for `thread/resume`.

- **Found by walking `sessions/` and nowhere else**, at most four directories deep, each of which
  `list_dir` reads only if it is a directory and not a link. `.codex/` itself, and `auth.json` in
  it, are never looked at, so the login cannot leave in a session upload (criterion 41); the file
  is then copied by the same owner-and-size-checked, `lstat`-first copy Claude's session uses.
- **Checked before a resume**: every line JSON, and a `session_meta` record whose payload names the
  thread. Anything else starts cold, as a Claude session that fails its check does.
- **The version check** is the same: a rollout written by another version of `codex` is not
  resumed, since the machine's probe version is compared with the one recorded at upload.
- **Placed** under today's date directory with a name of the form Codex writes. **Whether
  `thread/resume` finds a file by that name in that place is not verified here.**

## On the image

`nix/worker-image.nix` has `codex-update.service`, `claude-code-update.service`'s twin: wanted by
the worker unit and ordered before it, so a worker is not `ready` until it has finished, and bounded
by the same probe and kill timeouts. OpenAI publishes a static musl build of each release, so it
needs no loader of the `environment.ldso` kind: the unit fetches the latest release's
**`codex-package-x86_64-unknown-linux-musl.tar.gz`**, which is the whole install, and not the
`codex` binary alone.

**Why the package.** Codex runs every shell and tool call through `codex-code-mode-host`, which it
looks for **beside its own executable once links are followed** (it reads `/proc/self/exe`). The
single-binary asset `codex-x86_64-unknown-linux-musl.tar.gz`, which this unit fetched first
(ticket 43) holds the one file, so every Codex run on a machine installed from it could talk and
could not run a command: the app-server warned `Code Mode is unavailable because failed to spawn
code-mode host …` and every tool call failed closed (ticket 49). The package has no top-level
directory and holds `bin/{codex,codex-code-mode-host,codex-exec-server}`, `codex-package.json`
(`entrypoint`, `execServer`), `codex-path/rg` and `codex-resources/` (`bwrap`, `voice/`). Runs keep
`sandbox: danger-full-access`, so the package's `bwrap` adds no sandbox. It is 192 MB to fetch and
475 MB unpacked against the binary's 118 and 294 (`rust-v0.169.0`): it downloaded in 0.6 s on the
machine this was diagnosed on, and the bound is curl's own `--max-time 100` (the unit's 120 s is the
outer `timeout`), which is a datacenter link's to meet.

**The install** is `nix/codex-update.sh`, a file of its own so that the gate runs it
(`worker/test/forge_worker/codex_update_test.exs`, against a stand-in `curl` serving a
package-shaped tarball). It unpacks into `$root/.local/codex/codex.XXXXXX` — **the same filesystem
as the link, so the swap is a `rename(2)`** — and checks the package whole: `codex-package.json`
parses, its `entrypoint` and `execServer` and `bin/codex-code-mode-host` are executable files
inside the package, and the new `codex` answers `--version`. Only then does `$root/.local/bin/codex`,
a link, become a link to the new `bin/codex` (made beside the old one and moved over it), and every
directory under `codex/` the link does not point at goes, which also clears what a killed run left.
A fetch that dies half way, or a package with a part missing, leaves the installed one as it was.
The installed version it reads is `--version` **of an install that has the host**, so a machine
migrating from the lone binary, at the same version, is `succeeded` and not `skipped`, and a failed
fetch over it is `failed`. It writes `codex-update.json` (`succeeded`, `skipped`, `failed`, the
version, the error) for `ForgeWorker.ClaudeUpdate.status/2`, the one reader of both files, to put in
the worker's `ready`: on Codex's own entry in `harnesses`, and, when there is no binary to answer
`--version`, as an entry of its own with no `credential` key, which `Forge.Workers.runs?/2` reads as
"runs nothing".

**The offer checks the host too.** `ForgeWorker.Harness.Codex.probe/1` follows the executable's
links, one at a time, and looks for `codex-code-mode-host` beside what they lead to: a regular file
with the execute bit **for others**, since a job runs as another user than the worker's. When it is
not there the probe carries a `problem`, and `ForgeWorker.Link` offers Codex with its version, the
`problem` and **no `credential`**: that machine takes no Codex job, and a Codex job waits for a
machine, as it does for a worker with no Codex. The reason is on the offer and not in `update`,
because a new release on an old image still reads `succeeded`. `/workers` draws each harness beyond
the first with its version, its `problem` in error colour, and the outcome of its update, in error
colour only when it failed.

**A run that gets the warning anyway fails.** The app-server sends it once per thread, on the
thread's first `turn/start` and before that turn begins; the driver keeps it, and every turn of the
thread that would have ended `success` then ends `error_during_execution` with `is_error` and the
warning's text as `result` — at the turn's end, not where the warning arrives; a turn that failed or
was interrupted for another reason keeps its own. A job reads as `harness error: error_during_execution:
Code Mode is unavailable …`; a chat shows the turn as failed (`conversations.md` § Turns). **The match
is on OpenAI's wording** (`Code Mode is unavailable`), as the warning carries no code: a release that
rewords it makes it a notice again, which is why the offer's check is not left to it.

The script was run against a stand-in `curl` in the gate (a fresh install, the same version again, a
newer one, a package without the host, a download that dies half way and one that fails after a whole
tarball, a refused fetch, the lone binary of the old image, a manifest path that climbs out of the
package), and the configuration evaluates (`nix eval .#nixosConfigurations.worker`); the image has
not been booted with it (§ Not verified here).

## Masking

The job's own credential is masked wherever project secrets are: a Claude token or key, a login's
whole text and each of its three tokens, an access token. A login Codex rewrote has tokens the
sealed copy does not hold, so `ForgeWorker.Job.Secrets` is given the job's directory and reads
`auth.json` (a regular file in a real directory, 64 KB at most, `Dir.read_auth/1`) whenever it masks:
the transcript, the session upload, a report, a chat turn, and the events a *conversation* streams.
**A workflow job's live event sink is built with the delivered login only** (`Link.start_runner/6`
holds a struct with no directory), so a token Codex wrote during the run and printed into a streamed
event is not masked there; it is masked in the transcript, the upload and the report.

## Not verified here

- **Every message and field name the driver reads or writes** (`thread/tokenUsage/updated`'s
  `last` and `total`, `account/rateLimits/updated`'s `primary` and `secondary` with
  `usedPercent` and `resetsAt`, `item/*`'s types, `turn/interrupt`'s params), and whether reasoning
  tokens are inside `outputTokens`.
- **How an access token is delivered**: `CODEX_ACCESS_TOKEN` is a guess at the form OpenAI's
  CI/CD auth guide documents; a login's delivery (a file under umask 077) is what `codex login`
  itself writes.
- ~~What `codex --version` prints~~ — **seen** on `rust-v0.169.0` (2026-11-16): `codex-cli 0.169.0`,
  of which the probe takes the last word.
- The wording of a usage-limit error, which the driver matches on `usage limit`, `rate limit` or
  `limit reached`.
- `auth_mode` and the absence of `OPENAI_API_KEY` as what marks a ChatGPT login.

- A real ChatGPT login, `codex login --device-auth`, and a real renewal.
- The app-server against OpenAI: every message name in this note.
- Whether an access token is accepted in the form the CI/CD guide documents.
- The image's `codex-update.service` booting (`nix eval` of the configuration and a run of
  `nix/codex-update.sh` against a stand-in `curl` are all the gate can do).
- **What the first real Codex runs on production showed (2026-11-15, ticket 49), and what was seen
  afterwards on a machine without a login (2026-11-16, `rust-v0.169.0`).** Login, the app-server
  transport, streaming, usage, the rate-limit windows and the held-login queue worked. The image's
  install did not: the lone `codex` binary answers `--version` and the app-server then warns
  `Code Mode is unavailable because failed to spawn code-mode host <dir>/codex-code-mode-host: host
  executable was not found. Code mode will fail closed; …` — `{"method":"warning","params":{"threadId",
  "message"},"emittedAtMs"}`, once per thread, on its first `turn/start`, before the response and
  before `turn/started` — and every tool call failed, while the turn still completed. The release
  assets are `codex-x86_64-unknown-linux-musl.tar.gz` (the binary), `codex-code-mode-host-…tar.gz`
  and `codex-package-x86_64-unknown-linux-musl.tar.gz` (what is installed now). With the host beside
  the binary, and with the package's `bin/codex`, no warning was sent, and a link to the package's
  `bin/codex` found the host in the package. Benign, and not failures: the `warning` `Falling back
  from WebSockets to HTTPS transport…`, the `configWarning` about bubblewrap not on `PATH`, and an
  `error` `Reconnecting... n/5` with `willRetry: true`. A failed turn's `turn/completed` has
  `turn.status: "failed"` and `turn.error.message`. **Not seen: a command running on the
  package's install** — there was no login on that machine — so that commands now run is the
  ticket's evidence plus the warning's absence, and the next real run on a rebuilt image confirms it.
- `thread/resume` finding a rollout placed by `Dir`, and a thread surviving the move between
  machines.
- The exact shape of a usage-limit error.
