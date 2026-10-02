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

          # One version for the whole repository: the three `mix.exs` read the same file, and so
          # does `nix/worker-image.nix` through the flake. A release is one edit rather than five
          # — the state it was in, with four of the five reachable only by remembering them — and
          # the image tag this produces names one build, since `bin/release` refuses a version the
          # registry already holds.
          version = lib.fileContents ./VERSION;

          esbuildPath = "${pkgs.esbuild}/bin/esbuild";
          tailwindPath = "${pkgs.tailwindcss_4}/bin/tailwindcss";

          # Source for one Mix project plus what it depends on by path: core, for all
          # three. The platform stopped embedding the worker in milestone 3; they meet
          # over a channel now.
          pathDeps = _subdir: [ ./core ];

          # `ForgeCore.Workflow` reads this at compile time: the grammar an agent is handed to
          # write `.forge/workflow.yml` is the design note itself rather than a copy, so the
          # note is a source file of core and of everything that depends on it. Outside the
          # fileset the sandbox has no `docs/` at all and the compile fails on `File.read!` —
          # which `bin/check` cannot catch, because it never builds a release.
          #
          # Listed one by one and not as `./docs`: a whole directory here would put every note
          # in the store and rebuild the release whenever any of them changed, and only the
          # ones actually embedded are inputs.
          embeddedDocs = [ ./docs/design/workflow-grammar-v1.md ];

          # Each `mix.exs` reads `../VERSION`, so it is a build input of every project for the
          # same reason `embeddedDocs` are: outside the fileset the sandbox has no `VERSION` at
          # all and `mix` fails on `File.read!` before it compiles a line. It is in `depsSrc`
          # too, which evaluates `mix.exs` without any of the sources.
          versionFile = ./VERSION;

          projectSrc = subdir: lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions
              ([ (./. + "/${subdir}") versionFile ] ++ pathDeps subdir ++ embeddedDocs);
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
              versionFile
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
            hash = "sha256-afo51zwJb20Lr/qzUwRznxgdW5ghAPGtsmmhZxtzARo=";
          };

          platformDeps = mixDeps {
            name = "forge";
            subdir = "platform";
            hash = "sha256-f5gsN385ciaPh67MNTGOzOG5ODq5rUKiUbaJ6tu26cw=";
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
              # The build of the worker release this platform ships with, which `config.exs`
              # reads at build time so the workers and templates pages can say which machines
              # and snapshots run it (docs/design/worker-tier.md § Updating a worker).
              #
              # **The x86_64-linux worker, whatever this platform is built for**, because that is
              # the only worker there is: the image and every machine are x86_64
              # (`workerConfiguration`). An aarch64 platform taking its own system's worker would
              # have called every machine and snapshot "other build". Evaluated, not built.
              FORGE_WORKER_BUILD = workerBuild self.packages.x86_64-linux.forge-worker;
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
          } // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            # The platform as an OCI image. Linux only, because an image's contents are Linux
            # binaries: on darwin the release itself would not run inside it.
            platform-image = import ./nix/platform-image.nix { inherit pkgs forge version; };
          } // lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
            worker-image = workerImage pkgs.stdenv.hostPlatform.system;
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
                # `bin/hetzner-image` shells out to it. Hetzner Cloud has no image upload, so
                # putting the worker image in a project means driving a rescue server through
                # the CLI — see `docs/design/worker-tier.md` § Updating a worker.
                pkgs.hcloud
                # And talks to that rescue server over ssh, with the key a cloud session is given
                # as HETZNER_PRIVATE_KEY; `ssh-keygen` picks the project's matching key. A cloud
                # session's container has no ssh of its own.
                pkgs.openssh
                # `bin/release` copies the image tarball straight to the registry with it. No
                # Docker daemon is involved, which is the whole reason it is this and not
                # `docker load`.
                pkgs.skopeo
              ] ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
                pkgs.inotify-tools
                # What `Forge.Provider.LocalVm` shells out to: QEMU boots the machine and
                # overlays the image, genisoimage builds the config disk.
                pkgs.qemu
                pkgs.cdrkit
              ];

              env = {
                MIX_ESBUILD_PATH = esbuildPath;
                MIX_TAILWIND_PATH = tailwindPath;
                LANG = "C.UTF-8";
                ERL_AFLAGS = "-kernel shell_history enabled";
              } // lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
                # The worker image boots through systemd-boot from an ESP, so the machine needs
                # UEFI firmware. Two paths nothing can guess, which is why they are exported
                # here and read by platform/config/runtime.exs.
                FORGE_OVMF_CODE = "${pkgs.OVMF.fd}/FV/OVMF_CODE.fd";
                FORGE_OVMF_VARS = "${pkgs.OVMF.fd}/FV/OVMF_VARS.fd";
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

      # The worker channel protocol this build speaks: one number, in one file, which
      # `ForgeCore.WorkerProtocol` reads at compile time and this reads here. `bin/hetzner-image`
      # labels a snapshot with it through the worker image's passthru, so no script writes it
      # down either (docs/design/worker-channel.md § Versions).
      workerProtocol = nixpkgs.lib.toInt
        (nixpkgs.lib.removeSuffix "\n" (builtins.readFile ./core/priv/worker_protocol));

      # The first twelve characters of a worker release's store hash: what the worker logs and
      # sends as `build`, what a snapshot is labelled with, and what the platform is built
      # knowing.
      #
      # **Twelve, and never the whole hash.** A full store path in the platform's output is a
      # runtime reference: Nix scans outputs for the thirty-two-character hashes of their
      # inputs, and one it finds pulls that path — the whole worker release — into the
      # platform's closure. Twelve characters are not a hash Nix looks for. The context is
      # discarded for the same reason from the other side: the platform needs the worker's
      # *name*, not the worker built, so evaluating its path is enough and building it is not a
      # prerequisite.
      workerBuild = worker: builtins.substring
        (builtins.stringLength builtins.storeDir + 1) 12
        (builtins.unsafeDiscardStringContext worker.outPath);

      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # The machine a job runs on: a NixOS appliance that boots, learns who it is from a config
      # disk or a metadata service and runs the forge_worker release. docs/design/worker-tier.md § The worker
      # image. x86_64 only, because that is what `Forge.Provider.LocalVm` boots.
      workerConfiguration = system: nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          (import ./nix/worker-image.nix {
            workerPackage = self.packages.${system}.forge-worker;
            version = nixpkgs.lib.fileContents ./VERSION;
          })
          ({ lib, ... }: {
            # Claude Code is unfree; the image allows exactly that package, as the platform
            # host does (docs/deploy.md).
            nixpkgs.config.allowUnfreePredicate = pkg:
              builtins.elem (lib.getName pkg) [ "claude-code" ];
          })
        ];
      };

      # systemd-repart writes a raw image. The driver boots a qcow2 and overlays it, so the
      # conversion happens once here rather than on every machine.
      #
      # Before it, Limine's BIOS boot code goes into the MBR and its second stage into the BIOS
      # boot partition, which repart made and cannot fill: a Hetzner x86 server boots SeaBIOS,
      # and without this the image hangs at the firmware (nix/worker-image.nix). The partition
      # is found by its type, so the order repart writes partitions in is not load-bearing.
      workerImage = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          nixos = workerConfiguration system;
        in
        pkgs.runCommand "forge-worker-image"
          {
            nativeBuildInputs = [ pkgs.qemu-utils pkgs.limine pkgs.util-linux pkgs.jq ];
            passthru = {
              inherit nixos;
              # What `bin/hetzner-image` labels a snapshot of this image with, read from the
              # same evaluation that built it rather than typed: the worker release inside it,
              # and the protocol that release speaks.
              build = workerBuild self.packages.${system}.forge-worker;
              protocol = workerProtocol;
            };
          }
          ''
            cp ${nixos.config.system.build.image}/${nixos.config.image.filePath} raw.img
            chmod u+w raw.img

            index=$(sfdisk --json raw.img | jq -r '
              .partitiontable.partitions
              | to_entries[]
              | select(.value.type == "21686148-6449-6E6F-744E-656564454649")
              | .key + 1')
            [ -n "$index" ] || { echo "the image has no BIOS boot partition" >&2; exit 1; }

            limine bios-install raw.img "$index"

            mkdir -p $out
            qemu-img convert -f raw -O qcow2 raw.img $out/forge-worker.qcow2
          '';
    in
    {
      packages = forAllSystems (pkgs: let out = perSystem pkgs; in out.packages);
      devShells = forAllSystems (pkgs: let out = perSystem pkgs; in out.devShells);
      formatter = forAllSystems (pkgs: pkgs.nixpkgs-fmt);

      # Needs KVM, which `bin/check` cannot assume; see nix/worker-image-boots.nix.
      checks.x86_64-linux.worker-image-boots = import ./nix/worker-image-boots.nix {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        image = self.packages.x86_64-linux.worker-image;
      };

      # The worker at its memory ceiling and with its PID 1 wedged, on the real image. Needs KVM
      # too; see nix/worker-health.nix.
      checks.x86_64-linux.worker-health = import ./nix/worker-health.nix {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        image = self.packages.x86_64-linux.worker-image;
      };

      # `services.forge` for a NixOS host; the package defaults to this flake's release.
      nixosModules.forge = { pkgs, ... }: {
        imports = [ (import ./nix/module.nix { forgePackage = self.packages.${pkgs.stdenv.hostPlatform.system}.forge; }) ];
      };

      # The worker image's own NixOS configuration, so it can be inspected and evaluated
      # without building the disk.
      nixosConfigurations.worker = workerConfiguration "x86_64-linux";

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
