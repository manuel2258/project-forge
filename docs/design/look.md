# Looking at the platform

`bin/look` opens a page of the platform in headless Chromium, as a fixture user, over made-up
data, runs a short list of steps and writes screenshots. It exists so that a change to what an
operator sees is **looked at**: the implementing agent photographs each changed screen, reads the
pictures against `ui.md` and the ticket's "What a person sees" criteria, fixes and goes again; a
reviewer that did not write the change then judges the pictures it is told were kept; the
presentation shows them to the person deciding on the merge (§ How `dev` and `bug` use it).

It is a test tool, not a feature of the platform: it runs in the `test` environment, from the
devshell, against a database of its own, and ships in no release.

## Using it

```
bin/look --setup NAME --as USER [--timeout SECONDS] < steps
```

The steps are read from standard input, **not kept**: the setups are code in the repository and
reusable, the list of what to click is a throwaway. One step a line, `#` comments, quoted arguments:

| Step | Does |
|---|---|
| `width phone` / `width desktop` | resize the window to 390×844 or 1280×800 |
| `visit /path` / `visit :name` | go to a path on the app, or to a path the setup names |
| `click <css>` / `click text "T"` | click the first match; text names the deepest element holding it |
| `fill <css> "value"` | type into a field |
| `wait <css>` / `wait text "T"` | wait (up to `--timeout`, default 5 s) for it to appear |
| `text <css>` | print an element's text |
| `shot page <file>` | the whole page: the window is grown to the document's height (capped at 12,000 px) and restored |
| `shot <css> <file>` | one element, by WebDriver's own element screenshot |

It prints a line a step as it runs, and on a failure `FAILED step N: <the step as written>` and the
reason. **Exit 0** every step passed; **1** something the caller gave or changed is wrong; **2**
the machine could not run the tool. The line is who is at fault, because the prompts excuse an
implementer from pictures on a 2 and the review lens decides nothing on one:

- **Exit 1 is the caller's or the change's**: a failed step; a page that breaks while logging in (a
  script error shared by every page, a crash the platform reports — the login page is the first to
  load the app's script); an app that will not compile or assets that will not build (the build
  output is printed); a step list that does not parse, a `visit` that is not a path, a named path
  the setup lacks; an unknown setup or user; no steps on standard input. A crash inside
  `mix forge.look` itself (a migration, a setup's `build/0`) is Mix's own exit 1 and is in this
  class too.
- **Exit 2 is the machine's**: no Chromium or driver, no network namespace, a tailwind or esbuild
  path that is not executable, a build killed for memory (137), `mix deps.get` failing, a
  throwaway postgres that would not start, a browser that would not start, a login that failed
  without the page breaking.

A relative `shot` path is relative to where `bin/look` was run. No step writes anywhere but the
paths a `shot` names; the run's own temporary directory (data directory and store) is removed when
it ends. The code is
`platform/test/support/look/`, compiled in `test` only and counted by the coverage floor.

### What fails a step

The tool fails a run on its own for the things a machine can see, and for nothing else — the rest
is judged by eye:

- the platform's side, which the browser cannot report (`Forge.Look.Watch`): a response of 500 or
  more, an exception in a LiveView's `mount`, `handle_params` or `handle_event`, and any
  error-level log, which is what a crashed LiveView process makes;
- a script error in the browser;
- a `wait` for something that never appears;
- a `visit` after which the LiveView never connected;
- at phone width, a page wider than the viewport (`scrollWidth` past `clientWidth`);
- a page that is not on the app's origin (below).

### Setups

A setup is a module with `build/0`, listed in `Forge.Look.Setups`, returning
`%{users: %{name => user}, paths: %{name => path}}` built from the suite's own fixtures into the
look's throwaway database. `setups_test.exs` builds every registered one, so a setup that rots
fails the gate and not the next ticket. One ships — `ticket`: a project, a member, a ticket with a
document, giving the queue, the project and the ticket pages. The review page needs a git
repository behind its ticket, which the fixtures make (`Forge.GitFixtures`) and this one does not;
the next ticket that photographs it adds a setup beside this. **Never a project secret's value** in
a setup: nothing masks a picture (`secrets.md`, which this leaves as written).

## What it is built on

**Wallaby** drives Chromium through chromedriver (`only: :test, runtime: false`): one language and
no Node. It brings `web_driver_client`, `tesla`, `hackney` and `httpoison` with it, which is the
cost of not hand-writing a WebDriver client. Chromium and chromedriver come from the devshell
(`FORGE_CHROMIUM`, `FORGE_CHROMEDRIVER`), at one version — 153.0.8010.36 both — so the driver is
the one built for the browser. Linux only, as nixpkgs ships no Chromium for darwin; bubblewrap
comes with them for the namespace below.

`bin/look` is a bash wrapper that builds the assets (`tailwind forge`, `esbuild forge`, into the
ignored `priv/static/assets`), enters a network namespace, starts a postgres of its own and runs
`mix forge.look` inside. The Mix task builds the setup into the database, starts the app on
`127.0.0.1` with a port the kernel picks (the URL host is set to match, or LiveView's origin check
refuses the socket), and calls `Forge.Look.run/2` — the same function the gate's browser test
calls, so the test runs the code an agent runs.

## Security: two ways in, locked from both sides

A look serves made-up data on a loopback port, and a machine runs several jobs.

**Nothing outside the run can reach the app, or the browser.** Two locks, because they guard
different things:

1. *The namespace.* `bin/look` re-executes itself in `bwrap --unshare-net --unshare-pid`: a
   loopback of its own that no other process on the machine can connect to. chromedriver listens
   unauthenticated and launches any binary it is told to, so a check inside the app would leave the
   worse hole open — this is what closes it. There is no weaker mode: if the namespace cannot be
   made the tool exits 2 with bubblewrap's reason.
2. *The app's own check* (`Forge.Look.Guard`). With a token configured, every request — a page, a
   LiveView socket, the worker and git endpoints — must carry it in the `_forge_look` cookie, or it
   gets a `403 forbidden` and nothing of the app. The token is `:crypto.strong_rand_bytes/1`,
   per run, held in application environment and never on a command line. **It is checked before
   socket dispatch**, which is the placement that matters: `use Phoenix.Endpoint` makes
   `socket_dispatch` among the plugs ahead of the endpoint's own, so a plug of the endpoint's own runs after a socket has been
   upgraded. The endpoint registers `Forge.Look.Guard.__before_compile__` after Phoenix's own, which
   wraps the generated `call/2`; only in the `test` environment, and with no token configured
   (the suite, a release) it passes everything. `guard_test.exs` is the proof, not the placement: a
   page, `/live/websocket`, `/worker/websocket` and `/git` without the cookie get the 403.

   The 403 has a word in it on purpose. Chromium replaces an *empty* error response with an error
   page of an origin of its own, where no cookie can be set, and the browser has to set one on
   this very answer.

**The browser goes only to the app.** Three locks, since a page can navigate by itself:

1. a `visit` must be a path — one leading `/`, no `//` or `/\`, no scheme, no space or control
   character — and is refused with its step number, text and reason **before a browser exists**
   (`Forge.Look.Steps.check_path/1`; a `visit :name` is checked when the setup's path is read);
2. the browser starts with `--proxy-server=127.0.0.1:1` and a bypass list of the app's own
   `host:port` alone (`<-loopback>` removes the implicit loopback bypass), so any other request —
   another job's port, a link, a redirect — goes to a port nothing listens on;
3. after every step the page's origin must be the app's, or the step fails "navigated outside the
   app".

The browser test drives all three: no page of the platform has an outside link, so it writes a
page that has one (a static file under `priv/static/images/look-test/`, removed after, served
behind the guard), points the link at a socket the test listens on, clicks it, and asserts the step
fails "navigated outside the app" **and that nothing connected to the socket**. Removing the proxy
flag, removing `<-loopback>` from the bypass list and removing the origin check each fail it, which
was run. The same static-page device gives the tests for a script error, a page wider than the
phone and a LiveView that never connects, none of which a page of the platform exhibits.

**Only made-up data.** The database is the run's own: a postgres on a unix socket in a directory
only that run can read, no TCP port (`bin/lib/test-postgres.sh`, shared with `bin/check`, which
keeps the probe that decides whether to start one; `bin/look` **always** starts its own and never
reads the operator's). The data directory and the store are in a temp directory of the run's. It
logs in as a fixture user through the app's own magic link (`/users/log-in/:token`), so the login
that runs is the app's and not a shortcut around it.

**What it prints** names steps, paths and reasons. The guard token and the login token are
removed from every step text and reason before they are printed or returned, because a library's
error message quotes the selector it was given; the browser's console, which Wallaby prints by
default, is switched off for the same reason and for the noise.

**Two looks at once on one machine** share no port and no database: each has its own namespace,
so each has its own loopback, and each its own postgres. The gate's browser test is the exception
— it runs outside any namespace on the suite's endpoint on 4002 and chromedriver is on the
machine's shared loopback for its seconds, as the suite's endpoint already is. That is the class
the open proposal *Jobs on one machine share a loopback* names, a worker change for every job and
not this note's.

Chromium's own sandbox is on. `FORGE_LOOK_NO_SANDBOX=1` turns it off, for a machine that refuses
user namespaces; the browser then loads only the app's made-up pages inside a namespace of its own.
It was not needed where this was built.

## What a look costs

Measured on 2026-11-08 in this ticket's `implementing` job (2 cores, no cgroup file to read):
**645 MiB** peak, the summed proportional set size (`/proc/<pid>/smaps_rollup`) of every process
under `bin/look` sampled every 200 ms — Chromium 465, the BEAM 113, postgres 43, chromedriver 17 (638 of the 645; the rest is bash and the crash handler) —
over a nine-step list at both widths. A 200 ms sampler can miss a spike. The agent that runs it is
about 300 MiB (the `claude` process's resident size), so a job that looks needs about **945 MiB**;
with a quarter of room, rounded up to 256 MiB, 1280 MiB. `implementing` is given the default
2200 MiB, which is above that, so neither `dev.yml` nor `bug.yml` declares anything of its own and
each says why in a comment. A heavier page, or a suite run beside it, is not what was measured.

Time: a nine-step look took 17 s start to finish, almost all of it building the assets, compiling
and starting the app; a step is a fraction of a second. The gate's browser module (`bin/check` runs
it with the rest of the suite) added about **14 s** when it was five tests, and about **38 s** at eleven tests, which is what was timed (it has grown since, and each test starts
a browser and logs in; 38.6 s for the whole look directory, as timed at eleven, 0.6 s without the browser module), and
about **450 MiB** to its peak, measured at five tests, one browser at a time (Chromium 428 + chromedriver 18), inside the 4 GiB the `check` command asks for.

The gate builds the assets itself (`mix check` runs `tailwind forge` and `esbuild forge` before the
suite): they are an ignored directory, so a fresh clone and any ticket that never ran `bin/look`
has none, and without them the browser test fails "LiveView did not connect". Checked by moving
`priv/static/assets` away and running the two tasks and the module.

## How `dev` and `bug` use it

When a changeset touches `platform/lib/forge_web/` or `platform/assets/`, `implementing` needs
screenshots, unless `implementation.md` says in a sentence why nothing visible changed. The rule is
a path match so that it can be checked; nothing checks that it was followed, **by decision**: the
prompts (`agents/implement.md`, `agents/implement-bug.md`) say how, and the review lens is what
reads the result.

- The pictures are `screenshots/*`, produced by `implementing`, named
  `<screen>-<state>-<phone|desktop>.png`: each changed screen's main view at both widths, and every
  state a "What a person sees" criterion describes at phone width (desktop too where the layout
  differs). No cap, and told to photograph what changed, not the platform.
- `implementation.md` lists the ones its run kept under `## Screenshots`. **Only the list counts**:
  a name an earlier round kept and this one did not is still on the ticket and the archive does not
  say which job wrote which version, so the list is what tells a current picture from a leftover.
- `reviewing` has a fifth lens, *Screenshots*, on `sonnet` (`agents/review.md` § The lenses). It
  reads the listed pictures from `$FORGE_JOB/archive/<ticket>/screenshots/` and judges them against
  `ui.md` and the criteria; a rejection is a finding and sends the ticket back, drawn beside the
  finding with `![](screenshots/<name>)`. From round two a screenshot finding is only a criterion
  unmet, a `ui.md` rule broken or screenshots missing with no reason, and the lens runs only if the
  new commits touched the web layer or the list changed. A look that could not run is named in the
  report and decides nothing: a machine's fault does not send the ticket round the loop.
- `presenting` shows the listed pictures beside the paragraph about each, with the references
  ticket 35 built, says plainly when a web change has none and why, and says nothing about
  screenshots for a change outside the web layer.
- **The pictures are trusted to show the final code.** The prompt says to take the final set again
  as the last step; nothing checks it. A picture taken before a later change can be approved and
  presented as if it showed the final code. The reviewer judges what it is given and runs no
  browser.

Who sees them is whoever can open the ticket, behind the artifact route's existing check; nothing
is new. Nothing in a screenshot is masked and nothing looks for a secret in one.

## Budgets

Raised without a measurement, and said so where they are written (`.forge/common.yml`):
`implementing` $15 → $20, `reviewing` $35 → $40, `limits.ticket_cost` $361 → $421. They are
estimates to be corrected from the first tickets that run the new states.

## Not verified here

- That `bin/look` runs on any machine but the one it was built on: the namespace and the whole
  tool were exercised there. The gate's browser test (Chromium and the driver, no namespace) has
  also passed on the `check` command's machine.
- That an agent following `agents/implement.md` produces good pictures, and that the lens judges
  them well: the prompts are untried. The pictures this note's author looked at were three.
- `nix build .#forge` and the worker image with the new devshell: the release's dependency hash
  was recomputed with the new lock and **did not change** (`fetchMixDeps` runs `mix deps.get` for
  production, which does not fetch a `only: :test` dependency), so no hash was edited; the release
  itself was not built. The devshell's `FORGE_CHROMIUM` and `FORGE_CHROMEDRIVER` evaluate, and the
  Chromium and chromedriver they name were downloaded and run.
