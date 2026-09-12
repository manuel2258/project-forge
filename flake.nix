{
  description = "forge: a self-hosted platform for supervised autonomous coding";

  inputs = {
    # Pinned to a revision so evaluation never needs the GitHub API.
    nixpkgs.url = "github:NixOS/nixpkgs/aff8a0b28396750446e5537a96461bc4facdb287";
  };

  outputs = { self, nixpkgs }:
    let
      perSystem = pkgs:
        let
          lib = pkgs.lib;
          # Erlang/OTP 28 package set with Elixir 1.18 as its default Elixir, so
          # mixRelease, fetchMixDeps and the devshell all agree on one toolchain.
          beam = pkgs.beam28Packages.overrideScope (final: prev: {
            elixir = prev.elixir_1_18;
          });
          elixir = beam.elixir;
          version = "0.1.0";

          esbuildPath = "${pkgs.esbuild}/bin/esbuild";
          tailwindPath = "${pkgs.tailwindcss_4}/bin/tailwindcss";

          # Source for one Mix project plus what it depends on by path: core for both,
          # and the worker for the platform, which embeds it as the local worker.
          pathDeps = subdir: if subdir == "platform" then [ ./core ./worker ] else [ ./core ];
          projectSrc = subdir: lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions ([ (./. + "/${subdir}") ] ++ pathDeps subdir);
          };

          # Only the files `mix deps.get` needs, so dependency fetching is not
          # invalidated by every source edit. After any mix.lock change, set the
          # matching hash below to lib.fakeHash and rebuild to learn the new one: a
          # fixed-output derivation with an unchanged hash is reused, never refetched.
          depsSrc = subdir: lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions ([
              (./. + "/${subdir}/mix.exs")
              (./. + "/${subdir}/mix.lock")
            ] ++ map (dep: dep + "/mix.exs") (pathDeps subdir));
          };

          mixDeps = { name, subdir, hash }: beam.fetchMixDeps {
            pname = "${name}-mix-deps";
            inherit version hash;
            src = depsSrc subdir;
            sourceRoot = "source/${subdir}";
          };

          workerDeps = mixDeps {
            name = "forge-worker";
            subdir = "worker";
            hash = "sha256-6J0MwqGJUIiaiCi/6KQz0j1cXXD0wnPosstWiUCzSIc=";
          };

          platformDeps = mixDeps {
            name = "forge";
            subdir = "platform";
            hash = "sha256-0wvoS0FbpkVRzoum5v5eN/4OW8kPG6C67HUGYldUU/Q=";
          };

          forge-worker = beam.mixRelease {
            pname = "forge-worker";
            inherit version;
            src = projectSrc "worker";
            sourceRoot = "source/worker";
            mixFodDeps = workerDeps;
          };

          forge = beam.mixRelease {
            pname = "forge";
            inherit version;
            src = projectSrc "platform";
            sourceRoot = "source/platform";
            mixFodDeps = platformDeps;
            env = {
              MIX_ESBUILD_PATH = esbuildPath;
              MIX_TAILWIND_PATH = tailwindPath;
            };
            # Assets are built after `mix compile` (colocated CSS is emitted by the
            # compiler) and before `mix release` (which copies priv/static).
            # `--no-deps-check` is needed because the fetched deps have no .git
            # directories, so Mix cannot verify git-sourced deps against the lock.
            # See https://github.com/phoenixframework/phoenix/issues/2690
            postBuild = ''
              mix do deps.loadpaths --no-deps-check, assets.deploy
            '';
          };
        in
        {
          packages = {
            inherit forge forge-worker;
            default = forge;
          };

          devShells = {
            default = pkgs.mkShell {
              packages = [
                elixir
                beam.erlang
                pkgs.postgresql_16
                pkgs.esbuild
                pkgs.tailwindcss_4
                pkgs.git
                # `bin/check` lints the measurement harness; the harness itself needs the
                # measure shell below.
                pkgs.shellcheck
                pkgs.shfmt
              ] ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.inotify-tools ];

              env = {
                MIX_ESBUILD_PATH = esbuildPath;
                MIX_TAILWIND_PATH = tailwindPath;
                LANG = "C.UTF-8";
                ERL_AFLAGS = "-kernel shell_history enabled";
              };
            };
          }
          # `bin/measure` (docs/design/measurement-harness.md). Linux only: btrfs-progs does
          # not exist on darwin, and the measurements are a Linux host's anyway. Deliberately
          # without pkgs.systemd, whose client must be the host manager's own, and without any
          # toolchain tool: those come from the workload's own flake via `nix develop .#<env>`.
          // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            measure = pkgs.mkShell {
              packages = [
                pkgs.bashInteractive
                pkgs.coreutils
                pkgs.findutils
                pkgs.gnugrep
                pkgs.gnused
                pkgs.gawk
                pkgs.util-linux
                pkgs.e2fsprogs
                pkgs.btrfs-progs
                pkgs.rsync
                pkgs.jq
                pkgs.git
              ];

              env.LANG = "C.UTF-8";
            };
          };

        };

      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: let out = perSystem pkgs; in out.packages);
      devShells = forAllSystems (pkgs: let out = perSystem pkgs; in out.devShells);
      formatter = forAllSystems (pkgs: pkgs.nixpkgs-fmt);

      # `services.forge` for a NixOS host; the package defaults to this flake's release.
      nixosModules.forge = { pkgs, ... }: {
        imports = [ (import ./nix/module.nix { forgePackage = self.packages.${pkgs.stdenv.hostPlatform.system}.forge; }) ];
      };

      # A minimal host using the module, so `nix eval` and `nix build` can check it.
      nixosConfigurations.example = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          self.nixosModules.forge
          ({ lib, ... }: {
            # Claude Code is unfree; the host allows exactly that package.
            nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "claude-code" ];

            services.forge = {
              enable = true;
              host = "forge.example.org";
              environmentFile = "/run/secrets/forge.env";
            };
            boot.loader.grub.enable = false;
            fileSystems."/" = { device = "/dev/null"; fsType = "ext4"; };
            system.stateVersion = "26.05";
          })
        ];
      };
    };
}
