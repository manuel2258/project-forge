# Deploying forge

Two ways to run the platform, from the same `mixRelease`: a NixOS module, and an OCI image.
They differ in how the release is delivered and in nothing else — same migrations, same
environment variables, same first-run commands.

| | NixOS module | Container (§ In a container) |
|---|---|---|
| Postgres | on the host, Unix socket | yours, over `DATABASE_URL` |
| Machines for jobs | local VMs under QEMU | none; workers dial in |
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
            # nixEnv = true;             wrap jobs in the project's `nix develop .#<env>`
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
ANTHROPIC_API_KEY=<key>             # or CLAUDE_CODE_OAUTH_TOKEN=<claude setup-token>
FORGE_VAPID_PUBLIC_KEY=...          # from `forge-admin eval Forge.Release.generate_vapid_keys`
FORGE_VAPID_PRIVATE_KEY=...
FORGE_VAPID_SUBJECT=mailto:you@example.org
```

## First run

The service migrates the database on every start. The module installs `forge-admin`, which
runs `bin/forge` as the service user with the service's environment and secrets, so one-off
commands are, as root:

```
forge-admin eval 'Forge.Release.create_operator("you@example.org", "a long password")'
forge-admin eval 'Forge.Release.create_token("you@example.org", "laptop")'
forge-admin eval 'Forge.Release.register_project("game", "/var/lib/forge/repos/game.git")'
```

`Forge.Release` also has `list_tokens(email)`, `revoke_token(email, name)` and
`generate_vapid_keys()`. Changing a user's password revokes their API tokens along with
their sessions. Projects registered through the API get their repository under
`/var/lib/forge/repos/<name>.git`; only the command line may point a project at another path.

Push your project into the bare repository, with `.forge/workflow.yml` and the prompts under
`.forge/agents/` on the default branch. The repository is served over the platform's own smart
HTTP endpoint as well as over SSH to the host; both reach the same bare repository:

```
git remote add forge forge@forge.example.org:/var/lib/forge/repos/game.git
git push forge main
```

The default branch is written by SSH and by the platform's merge only. A credential handed out
for the HTTP endpoint is scoped to one ticket branch, and the repository's own `pre-receive` hook
refuses everything else — including a credential trying to move the default branch. A short-lived
one for a clone or a look is printed by:

```
forge-admin eval 'Forge.Release.git_token("game")'          # read only
forge-admin eval 'Forge.Release.git_token("game", 12)'      # and may write ticket/12
```

Point the repository at a mirror so the host is never the only copy of the project. The default
branch is what mirrors; `--refs` widens it:

```
forge-admin eval 'Forge.Release.set_mirror("game", "git@github.com:you/game.git")'
```

The mirror is pushed by a `post-receive` hook and never fails a push: a failure is reported to
whoever pushed and logged, and the push stands. See `design/git-hosting.md`.

Then log in at `https://forge.example.org`, admit a ticket through the API, and watch the
queue. Everything the Mix tasks do in development is available through `/api/v1`.

## What the module sets

- User `forge` with home `/var/lib/forge`; repositories under `repos/`, job checkouts and job
  directories under `data/`.
- Postgres locally, reached over its Unix socket with peer authentication.
- `git`, `nix` and Claude Code on the service PATH; `FORGE_CLAUDE_EXECUTABLE` points at the
  packaged binary. `nix` on the PATH is what lets `nixEnv` enter a project's devshell; the
  service user needs to be allowed to talk to the Nix daemon (it is, by default).
- Distribution off (a fixed `RELEASE_COOKIE` satisfies the release script; it guards nothing),
  and port 4000 **on loopback** — see § Behind a proxy for why that is a security property and
  not a default.
- `forge-admin` in the system path for one-off release commands.

## In a container

`nix build .#platform-image` writes an OCI tarball; `nix/platform-image.nix` builds it from the
same `mixRelease` the module runs.

```
nix build .#platform-image
docker load < result
docker run -d --name forge \
  -p 127.0.0.1:4000:4000 \
  -v forge-data:/var/lib/forge \
  --env-file forge.env \
  -e DATABASE_URL=ecto://forge:pass@db.internal/forge \
  -e SECRET_KEY_BASE=... \
  -e PHX_HOST=forge.example.org \
  forge:0.1.0
```

`forge.env` is the same secrets file as above. `DATABASE_URL` is required — the container has no
Postgres and the socket-directory path the module uses does not apply. It migrates on every
start, exactly as the systemd unit's `ExecStartPre` does.

One-off commands are the same `Forge.Release` functions, through `exec` rather than
`forge-admin`:

```
docker exec forge forge eval 'Forge.Release.create_operator("you@example.org", "a long password")'
docker exec forge forge eval 'Forge.Release.git_token("game")'
```

**What it deliberately does not carry.** The worker is not in this image and cannot be: it wants
a kernel, systemd slices and a Nix store of its own (`design/worker-tier.md`). Nor is Postgres —
a database in the same image as the server is a database deleted with it. Nor `nix` or Claude
Code: the platform stopped running jobs in milestone 3, and it forwards a credential rather than
invoking a harness.

**It provisions no machines, and says so rather than failing.** `Forge.Provider.LocalVm` boots a
VM under QEMU, which a container cannot do, so the image sets `FORGE_MAX_WORKERS=0`:
`Workers.create_machine/0` refuses at capacity and never reaches the driver. Workers provisioned
elsewhere still dial in and are still assigned — an assignable worker is found before creation is
ever considered. Raise it only with a provider that works from inside a container.

Those workers reach the platform over the network rather than over loopback, so publishing the
port to `127.0.0.1` as above is only right when nothing else needs it. Widening it is the
security decision § Behind a proxy describes, unchanged by the container.

**Repositories are reached over HTTP, not SSH.** § First run offers both routes into a bare
repository; only one of them survives here, because the repositories are inside the volume and
there is no sshd in the image. Use the platform's own smart HTTP endpoint with a credential from
`Forge.Release.git_token/1`, which is the route `design/git-hosting.md` describes and the one the
`pre-receive` hook guards either way.

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
platform will then skip the redirect and accept a session cookie over cleartext. So:

- leave the endpoint on `127.0.0.1` and point the proxy at it;
- if a worker on another machine has to dial in, `FORGE_HTTP_IP` widens the binding — set it to
  the one interface those workers are on, never `0.0.0.0`, and firewall the port to them.

**Two of the five routes are not public.** `/worker` and `/store` are for machines, and with the
local-VM provider those machines are on this host. Routing them publicly adds attack surface and
nothing else.

| Route | Public | What it is |
|---|---|---|
| `/`, `/live` | yes | the operator, and the phone. Session cookie, CSRF, CSP |
| `/api/v1` | yes | bearer tokens, hashed at rest |
| `/git` | yes | cloning and pushing; HTTP Basic with scoped, expiring tokens |
| `/worker` | **no** | the worker channel |
| `/store` | **no** | blobs and seeds |

**Rate limiting is the proxy's job.** Nothing in the platform throttles, and three routes are
reachable without a session: `/users/log-in`, `/api/v1` and `/git`. A Traefik `rateLimit`
middleware on each is the whole fix.

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
```

Websockets need no special configuration in current Traefik; `PHX_HOST` must be the public
hostname, because it is what `check_origin` and every generated URL are built from.

**What a proxy log must never contain.** Both machine credentials travel in an
`Authorization: Bearer` header and never in a URL — see `docs/design/worker-channel.md`
§ Authentication. A proxy records request URIs, so a token in a query string is a token in the
access log; the worker's is long lived and grants the channel for the life of the machine. If
you add a provider whose workers dial in from outside, that property is what makes exposing
`/worker` survivable.

## Known limits

Jobs run on their own machine with a Unix user per job (`docs/design/worker-tier.md`), so the
platform host no longer runs agent code. What neither mode yet has:

- **No cloud provider.** Workers are local VMs, so the host needs KVM and enough memory for
  `max_workers × slice_bytes`. `max_workers` defaults to 1 and more than one has not been
  exercised. **This is what makes the container server-only**: a container cannot boot a VM,
  so until a driver exists that provisions machines over an API, a containerised platform is
  one whose workers are provisioned by hand and dial in.
- **The module does not configure the worker tier.** The image path, the OVMF firmware, KVM
  access and the tier's numbers are environment variables today; there are no module options for
  them yet.
- **Blobs and seeds live on this host** — the storage behaviour has one local implementation, so
  they do not survive it.
- **Rotating the agent credential reaches no existing machine.** A worker keeps the credential
  it was created with (issue #16).
- **Magic-link login does not work**: the mailer has no production adapter, so password login is
  the only one that functions.
