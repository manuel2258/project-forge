# Deploying forge

Two ways to run the platform, from the same `mixRelease`: a NixOS module, and an OCI image.
They differ in how the release is delivered and in nothing else — same migrations, same
environment variables, same first-run commands.

| | NixOS module | Container (§ In a container) |
|---|---|---|
| Postgres | on the host, Unix socket | yours, over `DATABASE_URL` |
| Machines for jobs | none until a template is assigned; a `local` one needs the host set up by hand (§ Known limits) | none until a template is assigned; never a local VM |
| Endpoint binding | loopback | every interface, behind a proxy-only network |
| One-off commands | `forge-admin` | `docker exec … forge eval` |

## Flake

```nix
{
  inputs.forge.url = "github:manuel2258/project-forge";

  outputs = { nixpkgs, forge, ... }: {
    nixosConfigurations.vps = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        forge.nixosModules.forge
        ({ lib, ... }: {
          # Claude Code is unfree in nixpkgs; the host has to allow it.
          nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "claude-code" ];

          services.forge = {
            enable = true;
            host = "forge.example.org";
            environmentFile = "/run/secrets/forge.env";   # see below
            # digestHourUtc = 9;
          };
          # A TLS proxy in front is not optional. See § Behind a proxy.
        })
      ];
    };
  };
}
```

## Secrets file

Not in the store; readable by root only. Lines of `KEY=VALUE`:

```
SECRET_KEY_BASE=<mix phx.gen.secret>
FORGE_VAPID_PUBLIC_KEY=...          # from `forge-admin eval Forge.Release.generate_vapid_keys`
FORGE_VAPID_PRIVATE_KEY=...
FORGE_VAPID_SUBJECT=mailto:you@example.org
```

**No agent credential here.** `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` are not read by the
platform or by a worker: a person adds their own token in `/users/settings` and assigns it to the
projects it should pay for, and each job picks one from its project's pool
(`design/credentials.md`). `SECRET_KEY_BASE` is what seals those tokens at rest, so rotating it
makes every stored credential unreadable and each has to be added again.

**Mail, which is optional and is what magic-link login costs.** With no relay named the node
keeps the local adapter — a mailbox in memory that nothing reads — and password login is the only
one that works. Name one and both magic links and email-change confirmation start delivering:

```
FORGE_SMTP_HOST=smtp.example.org
FORGE_SMTP_PORT=587                 # default 587
FORGE_SMTP_USERNAME=forge@example.org
FORGE_SMTP_PASSWORD=<password>
FORGE_SMTP_TLS=starttls             # starttls (default), ssl for implicit TLS on 465, or none
FORGE_MAIL_FROM=forge@example.org   # the compiled default is a placeholder a relay will refuse
FORGE_MAIL_FROM_NAME=forge          # optional; "Forge" otherwise
```

The certificate is verified either way — `config/runtime.exs` § Mail writes the options out
rather than taking gen_smtp's, whose default is no verification at all on the connection that
carries that password. The trust anchors are `SSL_CERT_FILE`'s bundle, which the image sets and a
NixOS host has; `FORGE_SMTP_CACERTFILE` names another for a relay with its own CA. `none` is for a
relay on the same host and nothing else: it sends the password in the clear.

**Single sign-on, which is also optional.** Name the issuers you want and configure each under
its id; with none named nothing changes and the login page offers only what it did before.

```
FORGE_OIDC_PROVIDERS=oecis            # comma separated; the id is the URL segment
FORGE_OIDC_OECIS_ISSUER=https://id.oecis.io
FORGE_OIDC_OECIS_CLIENT_ID=forge
FORGE_OIDC_OECIS_CLIENT_SECRET=<secret>
FORGE_OIDC_OECIS_NAME=oecis           # optional; the button's label, the id otherwise
FORGE_OIDC_OECIS_SCOPE=email profile  # optional; `openid` is always added
FORGE_OIDC_OECIS_ID_TOKEN_ALG=RS256   # optional; what the issuer signs ID tokens with
```

`ID_TOKEN_ALG` is worth checking before the first login rather than after. The client compares
the token's `alg` against this one value and refuses anything else, so an issuer on `ES256` with
this left at its default fails *every* login, and says only "That login could not be completed"
— the same thing it says when an issuer is unreachable. The issuer's
`/.well-known/openid-configuration` lists what it will use under
`id_token_signing_alg_values_supported`.

The redirect URI to register with the issuer is `https://<PHX_HOST>/auth/oidc/<id>/callback` —
derived from the endpoint rather than configured, so it is right exactly when `PHX_HOST` is.
An `email` claim is required: the account row needs an address and there is nothing sensible to
invent, so a scope that does not yield one is a misconfiguration and the login says so.

**An OIDC login is authentication and not admission.** A first login makes a *pending* account,
and a node admin approves it at `/accounts` — where the row now says which issuer it came from,
or `local`. Refusing such an account suspends it; **deleting** it is the other button, and it is
there because a suspended row keeps the address. An issuer where anybody may
type any address into their own profile could otherwise park a colleague's on this node for
good. Only a never-approved account can be deleted, the database refuses it if anything at all
points at the row, and the `user.deleted` event outlives it. No claim, group or role from an issuer reaches a project; membership is
granted here and nowhere else (`design/identity.md` § The IdP is not the authority).

**An address that is already an account's is refused, never adopted.** Otherwise any issuer you
configure could assert your node admin's address and be them. To deliberately join the two — the
usual case being your own local account and your own SSO identity — do it from the host, where
the `sub` comes from the provider's console:

```
forge-admin eval 'Forge.Release.link_identity("you@example.org", "https://id.oecis.io", "SUBJECT")'
```

## First run

The service migrates the database on every start. The module installs `forge-admin`, which
runs `bin/forge` as the service user with the service's environment and secrets, so one-off
commands are, as root:

```
forge-admin eval 'Forge.Release.create_operator("you@example.org", "a long password", node_admin: true)'
forge-admin eval 'Forge.Release.create_token("you@example.org", "laptop")'
forge-admin eval 'Forge.Release.register_project("game", "/var/lib/forge/repos/game.git")'
```

**`node_admin: true` on the first account, and it has to be the first one**, whether or not you
go on to configure SSO — an issuer authenticates people, it does not admit them, so somebody has
to exist who can approve the second account. Nothing else on a fresh node can grant it: `/accounts` is where accounts are approved and it is behind
`require_node_admin`, so an ordinary first account can never admit a second — and step 3 refuses,
because `register_project/2` with no owner named resolves to the node's only admin and there is
none. Later accounts are made without it; `design/identity.md` § node_admin is account
governance, and nothing else says what the flag reaches and what it does not.

A project is administered by whoever registers it. `register_project/4` takes the owner's
address as a fourth argument; without one it resolves to the node's only admin and refuses when
there is more than one, because a project with no members is invisible to everyone — including
a node admin — and the only repair is SQL. See `design/identity.md` § Projects and members.

`Forge.Release` also has `add_member(project, email, role)` — the repair path for a project
whose admins have all gone, since there is then nobody the product's own membership page could
act through — `approve_user(email)` for the first account on a node, `list_tokens(email)`,
`revoke_token(email, name)` and `generate_vapid_keys()`. Changing a user's password revokes their API tokens along with
their sessions. Projects registered through the API get their repository under
`/var/lib/forge/repos/<name>.git`; only the command line may point a project at another path.

Push your project into the bare repository, with `.forge/workflow.yml` and the prompts under
`.forge/agents/` on the default branch. **There is one route in, the platform's own smart HTTP
endpoint, and one kind of credential, a token the platform minted.** There is no SSH *in*: the
service user has no shell, nothing listens, and the repository's `pre-receive` hook refuses a push
that carries no authority over the ref it names, however it arrived (`design/git-hosting.md`
§ Not built). There is no ssh client on the service's PATH either — the mirror, below, was its
only caller, and the mirror speaks https now.

Tokens are issued from `/projects/<name>/settings` once you can log in, and from the command line
before that:

```
forge-admin eval 'Forge.Release.git_token("game")'            # read only
forge-admin eval 'Forge.Release.git_token("game", 12)'        # and may write ticket/12
forge-admin eval 'Forge.Release.git_token("game", :default)'  # and may write the default branch
```

Each prints a clone URL with the token in it, once. Seed the repository with the third:

```
git remote add forge 'https://forge:TOKEN@forge.example.org/git/game.git'
git push forge main
```

The default branch takes exactly two writers: the platform's own merge, and a credential minted
for that branch by hand. It is fast-forward only for both. Every other credential — a job's
included — is scoped to one ticket or chat branch and is refused the default branch by the hook,
so a job cannot reach what it builds on.

Point the repository at a mirror so the host is never the only copy of the project, from
`/projects/<name>/settings`: name the mirror, give it a URL, and optionally a username and a
token. The URL must be `https://` or `http://` — nothing else is accepted, ssh included, and the
settings page says why (`design/git-hosting.md` § What a mirror URL may be). `http://` is allowed
but the page says what it costs: the credential crosses the network in clear. The list on that
page shows each mirror's status after its last attempt.

The same call is available from the command line before you can log in, with the same rules
enforced. The fourth argument is an option list: `refs:` widens which refs mirror from the
default branch alone to a glob, and `user:` and `token:` are the credential, which is stored
outside the repository and never in the URL:

```
forge-admin eval 'Forge.Release.set_mirror("game", "backup", "https://github.com/you/game.git", user: "you", token: "TOKEN")'
```

The mirror is pushed by a `post-receive` hook and never fails a push: a failure is reported to
whoever pushed and recorded on the mirror itself, and the push stands.
See `design/git-hosting.md`.

Then log in at `https://forge.example.org` and give the project something to pay for its jobs:
in `/users/settings`, add your Anthropic API key or `claude setup-token` subscription token as a
credential — it is tried against Anthropic before it is kept — and assign it to the project. A
project with none sticks every ticket saying so, and the ticket comes back by itself when one is
assigned. Then admit a ticket through the API and watch the queue. Everything the Mix tasks do
in development is available through `/api/v1`.

### Upgrading a node that ran on `ANTHROPIC_API_KEY`

**It stops running jobs until a person adds a credential**, deliberately and loudly — the node's
key is not read as a fallback and not turned into anybody's credential (`design/credentials.md`
§ The node's own key is gone). After the upgrade every ticket sticks with *no credential is
assigned to this project*. Add the token in `/users/settings`, assign it to the projects it
should fund, and the tickets come back by themselves. The variables can then be removed from the
secrets file; leaving them does nothing.

Machines are the other half. A worker running a release from before this ignores the credential
an assignment carries, so it is given no agent job, and `/workers` says so on its row: a managed
one idles out and its replacement boots the current image, and a permanent one needs
`bin/worker-update`. The same upgrade gives every machine an owner — its template's, or the
node's only node admin — and on a node with more than one node admin, a permanent machine with no
template is given to nobody until `Forge.Release.own_worker(worker_id, email)` names one.

## What the module sets

- User `forge` with home `/var/lib/forge`; repositories under `repos/`, and under `data/` the
  store, the local driver's machines and git's scratch files.
- Postgres locally, reached over its Unix socket with peer authentication.
- `git`, `nix` and Claude Code on the service PATH; `FORGE_CLAUDE_EXECUTABLE` points at
  the packaged binary. `nix` on the PATH dates from when the platform ran jobs: nothing in the
  platform runs `nix` now. A job's `nix develop` is the worker's, set by the worker's own
  `FORGE_NIX_ENV`, which the worker image turns on; the platform has no such setting. No ssh
  client: the mirror was its only caller and speaks https now.
- Distribution off (a fixed `RELEASE_COOKIE` satisfies the release script; it guards nothing),
  and port 4000 **on loopback** — see § Behind a proxy for why that is a security property and
  not a default.
- `forge-admin` in the system path for one-off release commands.

## In a container

The platform is published as an OCI image at `ghcr.io/manuel2258/forge`;
`nix/platform-image.nix` builds it from the same `mixRelease` the module runs.

### Publishing one

`bin/release` is the whole procedure, from a clean checkout of `main`:

```
bin/release                        # or --registry other.host/you/forge
```

It refuses anything but a clean `main`, tags `v<version>` and pushes the tag, builds
`.#platform-image`, copies the tarball to the registry as `:<version>`, copies that to `:latest`
inside the registry — the same digest, not a second upload — and prints the digest it published,
which is what a deployment pins. `:latest` only moves forward, since a release is only ever
published from `main`'s own `VERSION`; it is for finding the current release and for a quick try,
not for a deployment that should stay put. **No Docker daemon anywhere**: `nix build` writes a gzipped
docker-archive and `skopeo copy docker-archive:… docker://…` streams it to the registry,
decompressing on the way, so nothing has to load the image first. It spools the decompressed
archive through `$TMPDIR`, which needs room for an uncompressed image.

Credentials, in order: `GHCR_TOKEN` if it is set, else the GitHub CLI's own token when `gh` is
installed and logged in, else whatever `skopeo login ghcr.io` already stored. `GHCR_USER`
defaults to the registry path's owner. The token reaches skopeo on stdin and a temporary auth
file deleted on exit, never argv.

`--skip-tag` publishes without making the `v<version>` tag when none exists; a tag naming another
commit still stops the run. `--dry-run` makes no tag and copies nothing: it builds the image and
says what it would have done.

**The version is `VERSION` at the repository root and nothing else.** `flake.nix` reads it for
the image tag and each `mix.exs` reads it for the release, so a release is one edit: bump
`VERSION`, land it, run `bin/release`. An image tag is only worth pinning if it means one build,
and a git tag is what enforces that: a `v<version>` that already names a different commit stops
the run before anything is pushed, so a second release from a second commit has to bump `VERSION`
first.

Building one without publishing is still `nix build .#platform-image`, and `docker load < result`
puts it in a local daemon. That is for trying a change before it is a release, not for deploying.

### Running it

```
docker network create forge-net      # the proxy and the platform, and nothing else on it

docker run -d --name forge \
  --network forge-net \
  -v forge-data:/var/lib/forge \
  --env-file forge.env \
  -e DATABASE_URL=ecto://forge:pass@db.internal/forge \
  -e SECRET_KEY_BASE=... \
  -e PHX_HOST=forge.example.org \
  -e FORGE_HTTP_IP=0.0.0.0 \
  ghcr.io/manuel2258/forge@sha256:<digest>
```

`forge.env` is the same secrets file as above. `DATABASE_URL` is required — the container has no
Postgres and the socket-directory path the module uses does not apply. It migrates on every
start, exactly as the systemd unit's `ExecStartPre` does.

**`FORGE_HTTP_IP=0.0.0.0`, and there is no `-p`.** The release binds loopback by default and that
default is load-bearing on a host (§ Behind a proxy). In a container it serves nothing: the proxy
arrives from the bridge, not from the container's own loopback, so an endpoint on `127.0.0.1` is
one nothing outside the container can reach — a published port included, because Docker DNATs it
to the bridge address. There is no middle setting either: the bridge address is assigned at start
and cannot be named in advance. So the binding widens to everything and **the container network
takes over from the firewall**: no published port, and only the proxy attached to `forge-net`.
§ Behind a proxy says what that trust boundary is worth.

One-off commands are the same `Forge.Release` functions, through `exec` rather than
`forge-admin`:

```
docker exec forge forge eval 'Forge.Release.create_operator("you@example.org", "a long password", node_admin: true)'
docker exec forge forge eval 'Forge.Release.git_token("game")'
```

The first one is the same rule as § First run and matters more here: there is no way round it in
a container. `forge remote` needs distribution and the image turns it off, and a bare `forge eval`
cannot call `Forge.Accounts` directly, because starting the repo is something only `Forge.Release`
does.

**`/health` is the liveness probe**, unauthenticated, outside `force_ssl`, and it touches neither
the database nor anything that would say what version this is. The image carries no HTTP client,
so a `--health-cmd` has nothing to run inside it; probe it from the thing in front instead —
Traefik's `loadBalancer.healthCheck.path`, or a Kubernetes `httpGet`.

**What it deliberately does not carry.** The worker is not in this image and cannot be: it wants
a kernel, systemd slices and a Nix store of its own (`design/worker-tier.md`). Nor is Postgres —
a database in the same image as the server is a database deleted with it. Nor `nix` or Claude
Code: the platform stopped running jobs in milestone 3, and it forwards a credential rather than
invoking a harness. It does carry `git`, for the repositories — the smart HTTP endpoint and the
`post-receive` mirror. No ssh client: the mirror was its only caller and speaks https now, so
there is no key and no `known_hosts` to put in the volume.

**It provisions no machines**, and what keeps that true is that no worker template exists. A
machine is made from a template that its owner — any approved user — created and assigned to a
project they are a member of, so a fresh node
creates nothing: `Workers.create_machine/1` answers `{:no_template, :none_assigned}` and
`Jobs.Scheduler` sticks the ticket with *"no worker template is assigned to this project, so
there is nothing to make a machine from"* rather than failing at a driver.
`Forge.Provider.LocalVm` could not serve one anyway, because a container cannot boot a VM; the
Hetzner driver could, and assigning a template that names it is how an operator opts in. (This
image used to set `FORGE_MAX_WORKERS=0` and call that the mechanism. The outcome was right and
the explanation was wrong: that variable had had no reader since `max_workers` moved onto the
template, and it has now been removed rather than left looking like a switch.)

Workers provisioned elsewhere still dial in and are still assigned — an assignable worker is
found before creation is ever considered. They reach `/worker` over the network rather than over
loopback, which is one more thing the proxy has to be willing to route; § Behind a proxy says why
it should not be.

**Repositories are reached the same way as under the module**: the platform's own smart HTTP
endpoint, with a credential from `Forge.Release.git_token/1,2`. Nothing about the container
changes this — there was never a second route — and the `pre-receive` hook guards it either way.

**It runs as uid 1000, not root.** A *named* volume takes the ownership the image declares at
that path, so the command above needs nothing extra. A **bind mount keeps the host's ownership**
and must be chowned first, or the release fails at boot on a directory it cannot create:

```
mkdir -p /srv/forge && chown -R 1000:1000 /srv/forge
docker run … -v /srv/forge:/var/lib/forge …
```

## Behind a proxy

The platform expects to be reached through a TLS-terminating reverse proxy — Traefik here, but
the rules are the same for any of them.

**The endpoint listens on loopback, and that is load-bearing.** `force_ssl` is configured with
`rewrite_on: [:x_forwarded_proto]`, so the platform decides whether it is on TLS by *believing a
request header*. That header is only trustworthy if the proxy is the only thing that can send
one. Anything that reaches port 4000 directly can assert `X-Forwarded-Proto: https`, and the
platform will then skip the redirect and accept a session cookie over cleartext. So, on a host:

- leave the endpoint on `127.0.0.1` and point the proxy at it;
- if a worker on another machine has to dial in, `FORGE_HTTP_IP` widens the binding — set it to
  the one interface those workers are on and firewall the port to them.

**In a container the honest version is different, and worse.** There is no interface to name: the
proxy arrives on a bridge address assigned at start, so the binding is `0.0.0.0` or the endpoint
serves nobody. What that costs is exactly what the paragraph above says it costs — *every
container that can reach port 4000 can assert `X-Forwarded-Proto: https`*. The trust boundary
stops being "the proxy" and becomes "everything on the proxy's network", so that has to be a
network the proxy is alone on:

- **no published port.** `-p 127.0.0.1:4000:4000` does not narrow this; it widens it, because
  Docker DNATs a published port straight to the container and anything that can reach the host's
  loopback is then past the boundary.
- **a network of its own**, with the proxy and the platform on it and nothing else. Not the
  default bridge, which every container without a network joins.
- **the proxy is the only route in.** Traefik overwrites `X-Forwarded-Proto` on every request it
  forwards, so a forged one from a client cannot survive the hop; what it cannot do is stop a
  *sibling container* connecting to port 4000 directly.

That third point is the one worth fixing properly, and it cannot be fixed with a setting: Phoenix
reads `:force_ssl` with `Application.compile_env/2`, so anything trusting a named proxy rather
than a header — a `FORGE_TRUSTED_PROXY` whose address is the only one the rewrite is honoured
from, or simply asserting the scheme because Traefik is authoritative for it — is a change to
`config/prod.exs` and a rebuild, not a variable an operator sets. Until somebody wants it enough
to make that change, the network *is* the control.

**Two of the seven routes are not public.** `/worker` and `/store` are for machines, and with the
local-VM provider those machines are on this host. Routing them publicly adds attack surface and
nothing else.

| Route | Public | What it is |
|---|---|---|
| `/`, `/live` | yes | the operator, and the phone. Session cookie, CSRF, CSP |
| `/api/v1` | yes | bearer tokens, hashed at rest |
| `/git` | yes | cloning and pushing; HTTP Basic with scoped, expiring tokens |
| `/auth/oidc/:provider` | yes | starts a login at a configured issuer; no session needed |
| `/health` | proxy only | liveness. `ok`, to anyone, with no database behind it |
| `/worker` | **no** | the worker channel |
| `/store` | **no** | blobs and seeds |

**Rate limiting is the proxy's job.** Nothing in the platform throttles, and four public routes
are reachable without a session: `/users/log-in`, `/api/v1`, `/git` and `/auth/oidc`. A Traefik
`rateLimit` middleware on each is the whole fix. `/health` is a fifth and is deliberately left
out of it — a limiter that drops the liveness probe reports the container dead.

`/auth/oidc` earns its place on that list for a reason the others do not share: both legs make
the node talk to the issuer. `Assent.Strategy.OIDC` re-fetches
`/.well-known/openid-configuration` on every call and caches nothing, and the callback fetches
discovery again plus JWKS — so an unauthenticated request here costs an outbound HTTPS request,
and the callback leg is the one public route that can insert `users` and `identities` rows.

```yaml
http:
  middlewares:
    forge-ratelimit:
      rateLimit: { average: 20, burst: 40, period: 1m }
  routers:
    forge:
      rule: "Host(`forge.example.org`)"
      service: forge
      middlewares: [forge-ratelimit]
      tls: { certResolver: letsencrypt }
  services:
    forge:
      loadBalancer:
        servers: [{ url: "http://127.0.0.1:4000" }]
        healthCheck: { path: "/health", interval: 10s }
```

In a container the server URL is the container's name on the shared network — `http://forge:4000`
— rather than loopback, and nothing else about the router changes.

Websockets need no special configuration in current Traefik; `PHX_HOST` must be the public
hostname, because it is what `check_origin` and every generated URL are built from.

**What a proxy log must never contain.** Both machine credentials travel in an
`Authorization: Bearer` header and never in a URL — see `docs/design/worker-channel.md`
§ Authentication. A proxy records request URIs, so a token in a query string is a token in the
access log; the worker's is long lived and grants the channel for the life of the machine. If
you add a provider whose workers dial in from outside, that property is what makes exposing
`/worker` survivable.

## Upgrading

What changes for a node that is already running, where the change is in what the platform does
with rows it already has. Newest first.

- **0.7.0: workers before protocol 4 are refused** (`design/worker-channel.md` § What needs a bump,
  and raising the minimum). Protocol 4 and the floor arrive together, so the order is: deploy the
  platform; every managed machine still running a protocol 3 snapshot rejoins, is refused and
  destroyed, and its jobs go back to the queue; a template labelled 3 makes nothing, and says so
  on `/templates`. Then build a snapshot from the release's commit (`bin/hetzner-image`) and point
  each template at it. Until then no managed machine runs anything. A permanent machine is refused
  but kept: `bin/worker-update` it.

- **Workers say which protocol they speak, and the platform can refuse one.** Nothing is refused
  by this upgrade: a worker that says nothing is protocol 0, and the platform accepts 0 to the
  current one (`design/worker-channel.md` § Versions). What changes is what is recorded — each
  row's release, build and protocol from its next join — and that snapshots made before now read
  *unlabelled* on `/templates`: unknown, not compatible. A machine is still made from one; if its
  join is refused it is destroyed and the template stops making more. `bin/hetzner-image` labels
  every snapshot it makes and now builds the image itself from `--flake` (default `.`); its
  `--image` option is gone, because a label could not be trusted for an image built elsewhere.

- **A Hetzner template that names no image stops making machines.** Such a template used to fall
  back to the node's image setting, which is the local driver's disk image — a file path from
  `FORGE_WORKER_IMAGE`, and never an image Hetzner has. Now the Hetzner driver refuses the create
  before sending anything, with *the template names no image* (`design/provisioning.md` § Where a
  machine comes from). Every refusal counts against the template, and after three in a row
  (`failure_limit` under `config :forge, Forge.Provisioning`) it is disabled: skipped when
  machines are made, and — once every template assigned to a project is disabled — that
  project's tickets stick with *every worker template assigned to this project is disabled after
  failing to make a machine*, and its conversations wait with the same words. A template cannot
  be saved without an image any more, so only one saved before that rule is affected. Before
  upgrading, give every Hetzner template on `/templates` an image (`bin/hetzner-image` makes
  one). One that was disabled first is put back with *Enable* once it names one; editing it does
  not re-enable it.

## Known limits

Jobs run on their own machine with a Unix user per job (`docs/design/worker-tier.md`), so the
platform host no longer runs agent code. What neither mode yet has:

- **The local provider needs a host.** A `local` template boots a VM under QEMU, so the host
  needs KVM and enough memory for `max_workers × the VM's own size` — the template's
  `max_workers` is a ceiling that has never been raised above 1, and the VM's size is
  `FORGE_WORKER_MEMORY_MB`, **16 GiB when it is unset**. Not `slice_bytes`: that is a node-wide
  number (2210 MiB) and it is the memory a *job* is promised for the scheduling gate, not the
  memory a machine is made with — `docs/design/provisioning.md` supersedes it, and no template
  has such a column. Sizing a host from it would budget 2.2 GiB for a VM that asks for sixteen.
  **This is what makes the container server-only in practice**: a
  container cannot boot a VM, so a containerised platform's workers are the Hetzner driver's or
  are provisioned by hand and dial in. The Hetzner driver has created and destroyed real Hetzner
  machines, but none has yet connected to a platform and run a job (`design/provisioning.md`
  § A template that cannot make a working machine is taken out of service).
- **The module does not configure the worker tier.** The image path, the OVMF firmware, KVM
  access and the tier's numbers are environment variables today; there are no module options for
  them yet, and QEMU is not on the service's PATH.
- **Nothing is backed up, and three things here do not survive this host.** Postgres, the bare
  repositories under `repos/`, and the store under `data/store/`. The repositories have a mirror
  if you set one; the other two have nothing, and the database is what gives a blob its name. A
  dump of Postgres plus those two directories, taken off the host on a schedule, is the whole of
  what is missing — and it is missing, not merely undocumented. Object storage for the store is
  *not* the answer to this and is not planned: `design/storage.md` § What would move this to S3.
- **The store only grows.** Nothing deletes a transcript or a superseded seed, so the host's disk
  is the ceiling — a number to watch on a real host, where a seed is hundreds of megabytes per
  project.
- **A credential is used for a job that has already started until the job ends.** Revoking one,
  or taking it out of a project, reaches every job that has not started and every one that starts
  again, on the next scheduling pass; a harness process already running keeps the token it was
  spawned with. Rotating a token is therefore: add the new one, assign it, revoke the old.
- **An OIDC account cannot be un-linked from here.** `Forge.Release.link_identity/3` attaches an
  identity and nothing detaches one; a person who changes issuer needs a node admin, a shell and
  a `DELETE`. It has not come up on a one-operator node, and the row is small enough that when it
  does the fix is a second release command.
- **Mail is only as good as the relay you give it.** With `FORGE_SMTP_HOST` set, magic-link login
  and email-change confirmation both deliver; with it unset the node keeps the local adapter and
  password login is the only one that functions. Nothing retries a failed send, and nothing
  surfaces one to the operator — it is a log line.
