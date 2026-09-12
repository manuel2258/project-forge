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
        {
          services.forge = {
            enable = true;
            host = "forge.example.org";
            environmentFile = "/run/secrets/forge.env";   # see below
            # nixEnv = true;             wrap jobs in the project's `nix develop .#<env>`
            # digestHourUtc = 9;
          };
          # Put a TLS proxy in front, e.g. services.caddy with reverse_proxy :4000.
        }
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
FORGE_VAPID_PUBLIC_KEY=...          # from `bin/forge eval Forge.Release.generate_vapid_keys`
FORGE_VAPID_PRIVATE_KEY=...
FORGE_VAPID_SUBJECT=mailto:you@example.org
```

## First run

The service migrates the database on every start. Then, as root:

```
cd /var/lib/forge
sudo -u forge /nix/var/nix/profiles/system/sw/bin/forge eval 'Forge.Release.create_operator("you@example.org", "a long password")'
sudo -u forge forge eval 'Forge.Release.create_token("you@example.org", "laptop")'
sudo -u forge forge eval 'Forge.Release.register_project("game", "/var/lib/forge/repos/game.git")'
```

(`forge` here is `${services.forge.package}/bin/forge`; the systemd unit's `ExecStart` shows
the store path.) Push your project into the bare repository, with `.forge/workflow.yml` and
the prompts under `.forge/agents/` on the default branch:

```
git remote add forge forge@forge.example.org:/var/lib/forge/repos/game.git
git push forge main
```

Then log in at `https://forge.example.org`, admit a ticket through the API, and watch the
queue. Everything the Mix tasks do in development is available through `/api/v1`.

## What the module sets

- User `forge` with home `/var/lib/forge`; repositories under `repos/`, worktrees and job
  directories under `data/`.
- Postgres locally, reached over its Unix socket with peer authentication.
- `git`, `nix` and Claude Code on the service PATH; `FORGE_CLAUDE_EXECUTABLE` points at the
  packaged binary.
- Distribution off, port 4000 on localhost only through `PHX_HOST`; TLS is the proxy's job.

## Known limits in this mode

Jobs run as the `forge` user on the same host: not a sandbox. The worker tier (milestone 3)
moves them to their own machine and Unix user per job. Until then, run only your own
repositories here.
