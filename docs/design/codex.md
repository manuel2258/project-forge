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
  and sent after `turn/completed`; an interrupt is `turn/interrupt`.
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
needs no loader of the `environment.ldso` kind: the unit fetches
`codex-x86_64-unknown-linux-musl.tar.gz` from the latest release, unpacks it into a directory of its
own and moves the binary over `$root/.local/bin/codex` only if the whole of it arrived, so a fetch
that dies half way leaves the installed one as it was. It writes `codex-update.json`
(`succeeded`, `skipped`, `failed`, the version, the error) for `ForgeWorker.ClaudeUpdate.status/2`,
the one reader of both files, to put in the worker's `ready`: on Codex's own entry in `harnesses`,
and, when there is no binary to answer `--version`, as an entry of its own with no `credential`
key, which `Forge.Workers.runs?/2` reads as "runs nothing". `/workers` draws each harness beyond the
first with its version and the outcome of its update, in error colour only when it failed.

The script was run against a fake `curl` for its three outcomes (first install, same version again,
a failed fetch over an installed binary), and the configuration evaluates (`nix eval
.#nixosConfigurations.worker`); the image has not been booted with it (§ Not verified here).

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
- What `codex --version` prints, of which the probe takes the last word.
- The wording of a usage-limit error, which the driver matches on `usage limit`, `rate limit` or
  `limit reached`.
- `auth_mode` and the absence of `OPENAI_API_KEY` as what marks a ChatGPT login.

- A real ChatGPT login, `codex login --device-auth`, and a real renewal.
- The app-server against OpenAI: every message name in this note.
- Whether an access token is accepted in the form the CI/CD guide documents.
- The image's `codex-update.service` booting (`nix eval` of the configuration and a run of the
  script against a fake `curl` are all the gate can do), and the asset name OpenAI publishes for
  the release it fetches.
- `thread/resume` finding a rollout placed by `Dir`, and a thread surviving the move between
  machines.
- The exact shape of a usage-limit error.
