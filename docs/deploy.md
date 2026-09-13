# Deploying forge on NixOS

One host runs the platform, its Postgres, and the embedded local worker (milestone 1 to 2
mode). The flake exports `nixosModules.forge`.

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
          # Put a TLS proxy in front, e.g. services.caddy with reverse_proxy :4000.
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
- Distribution off (a fixed `RELEASE_COOKIE` satisfies the release script; it guards
  nothing), port 4000 on all interfaces; TLS and access are the proxy's job.
- `forge-admin` in the system path for one-off release commands.

## Known limits in this mode

Jobs run as the `forge` user on the same host: not a sandbox. The worker tier (milestone 3)
moves them to their own machine and Unix user per job. Until then, run only your own
repositories here.
