# NixOS module for the forge worker image: a machine that boots, learns who it is and where the
# platform is from a config disk or a metadata service, and runs the forge_worker release. A
# btrfs root for the volume layer to snapshot, a Nix daemon pointed at the binary cache, Claude
# Code — installed at first boot rather than carried, see claudeExecutable below — and a shell's
# worth of general tools for the agent (jobTools below). No project toolchain: that comes from
# the workload's own flake through `nix develop`.
#
# See docs/design/worker-tier.md § The worker image. The image pins nothing about any
# particular project, and it is meant to boot unchanged on a provider later.
{ workerPackage, version }:
{ config, lib, pkgs, modulesPath, ... }:
let
  root = "/var/lib/forge";
  envFile = "/etc/forge-worker.env";

  # The contract between the provider driver and the machine: a filesystem with this label
  # holding this file, or a metadata service returning the same bytes.
  configLabel = "forge-config";
  configFile = "worker.env";

  # The release the unit actually runs, as a symlink rather than a store path: see
  # docs/design/worker-tier.md § Updating a worker. The image is the wrong size to ship a code
  # change through, so the release is separable from it.
  releaseLink = "${root}/release";
  gcRoot = "/nix/var/nix/gcroots/forge-worker-release";

  # Claude Code, and the one piece of this image's base that does not wait for a replaced image:
  # see docs/design/worker-tier.md § Updating a worker. **Not `pkgs.claude-code`.** nixpkgs wraps
  # that one with `DISABLE_AUTOUPDATER=1` set rather than set-default — no caller's environment
  # can turn it back on — around a binary that sits read-only in `/nix/store` owned by root, so
  # there is no file a self-update could replace even if it ran. So the image carries no Claude
  # Code at all and installs one at first boot, with Claude's own installer, into a path the
  # worker owns: the same move `releaseLink` above makes, and for the same reason.
  claudeExecutable = "${claudeHome}/bin/claude";
  claudeInstaller = "https://claude.ai/install.sh";

  # What goes on a `systemd.services.<name>.path`, which is **not** a list of directories: NixOS
  # runs it through `makeBinPath`, so each entry gets `/bin` and `/sbin` appended. A literal
  # `${root}/.local/bin` there becomes `${root}/.local/bin/bin` and the install is not on the
  # PATH at all. So the prefix is the entry and `claudeExecutable` above adds the `/bin` itself.
  claudeHome = "${root}/.local";

  # What claude-code-update.service writes and `ForgeWorker.ClaudeUpdate.status/1` reads: the one
  # thing the attempt leaves behind, so the outcome reaches the operator over the channel rather
  # than only into this machine's journal (criterion 5 of the ticket; worker-tier.md § Updating a
  # worker).
  claudeUpdateStatus = "${root}/claude-code-update.json";

  # What the attempt is allowed to take. The inner bound is the one that fires on a machine with
  # no route out, and it is the one that matters: a script killed by its own `timeout` still
  # writes "failed", where one killed by `TimeoutStartSec` writes nothing at all. The unit's
  # bound is therefore the longer of the two, the backstop for a hang `timeout` cannot see, and
  # both sit well inside the three minutes nix/worker-image-boots.nix gives the image to reach a
  # login prompt.
  claudeTimeout = 120;
  claudeUnitTimeout = 150;

  # What the worker itself needs to do its work and to confine a job: git for the clone and the
  # push, nix for `nix develop`, btrfs-progs for the volume layer, tar and gzip for the seed,
  # shadow and systemd for the per-job user and its transient unit. Claude Code is not here —
  # it is installed to claudeExecutable above, and `${root}/.local/bin` joins this list on the
  # unit's `path` below.
  #
  # bubblewrap and socat are, and they were not before: `pkgs.claude-code`'s wrapper put them on
  # a PATH only the binary it wrapped could see, and dropping the package would have taken them
  # off the machine along with it. They are what Claude Code's own sandbox reaches for, and this
  # change is about where Claude Code comes from rather than about what it can do.
  servicePath = [
    pkgs.git
    pkgs.bash
    pkgs.coreutils
    pkgs.gnutar
    pkgs.gzip
    pkgs.btrfs-progs
    pkgs.shadow
    pkgs.util-linux
    config.nix.package
    config.systemd.package
    pkgs.bubblewrap
    pkgs.socat
  ];

  # What the *agent* reaches for in its own shell, as opposed to what the worker needs. A job's
  # PATH is the worker's (ForgeWorker.Job.Exec passes PATH through), and `nix develop .#<env>`
  # only prepends the devshell's to it, so whatever is here is on every job's PATH whether or not
  # its state names an env. Without it an agent asking for `python3` or `rg` got "command not
  # found" and edited with sed. General-purpose tools for reading and changing code only: plain
  # python3 with no packages, and nothing that belongs to one project — a project's compilers,
  # linters and libraries come from its own flake's devshell.
  jobTools = [
    pkgs.python3
    pkgs.ripgrep
    pkgs.fd
    pkgs.jq
    pkgs.yq-go
    pkgs.gnugrep
    pkgs.gnused
    pkgs.gawk
    pkgs.findutils
    pkgs.diffutils
    pkgs.gnupatch
    pkgs.file
    pkgs.which
    pkgs.procps
    pkgs.psmisc
    pkgs.less
    pkgs.tree
    pkgs.unzip
    pkgs.zip
    pkgs.xz
    pkgs.bzip2
    pkgs.curl
    pkgs.wget
    pkgs.bc
    pkgs.gnumake
  ];
in
{
  imports = [
    "${modulesPath}/image/repart.nix"
    "${modulesPath}/profiles/qemu-guest.nix"
  ];

  system.stateVersion = "26.05";
  system.image.id = "forge-worker";
  # The repository's one version, handed in by `flake.nix` from `VERSION`.
  system.image.version = version;

  # -- the image ------------------------------------------------------------------------------

  # An appliance image: no system profile, nothing to `nixos-rebuild`. The bootloader is
  # installed by putting systemd-boot and one unified kernel image into the ESP, because the
  # image is built offline and there is no machine to run an installer on.
  #
  # **And Limine, for BIOS.** A Hetzner x86 server boots SeaBIOS, which runs the MBR's boot code
  # and nothing else; a UEFI-only image has none and hangs at "Booting from Hard Disk...". So the
  # ESP also holds Limine's config and second stage, and the same kernel, initrd and command
  # line the unified image carries. `flake.nix` writes the MBR and the BIOS boot partition with
  # `limine bios-install`, which is the one step repart cannot do. UEFI never reads any of it.
  # See docs/design/worker-tier.md § The worker image.
  boot.loader.grub.enable = false;
  boot.loader.timeout = 0;

  image.repart = {
    enable = true;
    name = "forge-worker";
    # OVMF does not work with repart's default 4096-byte sectors.
    sectorSize = 512;
    compression.enable = false;

    partitions = {
      # Where `limine bios-install` puts its second stage: GPT leaves no gap after the MBR for
      # one, so a BIOS machine's boot code needs a partition of its own to jump to. Unformatted,
      # and named so it sorts first: `flake.nix` finds it by type rather than by position.
      bios-boot = {
        repartConfig = {
          Type = "21686148-6449-6e6f-744e-656564454649";
          Label = "bios-boot";
          SizeMinBytes = "1M";
          SizeMaxBytes = "1M";
        };
      };

      esp = {
        contents =
          let
            efiArch = pkgs.stdenv.hostPlatform.efiArch;
          in
          {
            "/EFI/BOOT/BOOT${lib.toUpper efiArch}.EFI".source =
              "${config.systemd.package}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi";
            "/EFI/Linux/${config.system.boot.loader.ukiFile}".source =
              "${config.system.build.uki}/${config.system.boot.loader.ukiFile}";

            # The BIOS path. The command line is the unified image's own, so the two firmwares
            # boot the same system with the same parameters.
            "/limine/limine-bios.sys".source = "${pkgs.limine}/share/limine/limine-bios.sys";
            "/limine/kernel".source =
              "${config.system.build.kernel}/${config.system.boot.loader.kernelFile}";
            "/limine/initrd".source =
              "${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";
            "/limine/limine.conf".source = pkgs.writeText "limine.conf" ''
              timeout: 0
              serial: yes

              /forge-worker
                  protocol: linux
                  path: boot():/limine/kernel
                  module_path: boot():/limine/initrd
                  cmdline: ${config.boot.uki.settings.UKI.Cmdline}
            '';
          };

        repartConfig = {
          Type = "esp";
          Format = "vfat";
          Label = "ESP";
          SizeMinBytes = "128M";
          SizeMaxBytes = "128M";
        };
      };

      root = {
        storePaths = [ config.system.build.toplevel ];
        contents = {
          # The image carries the closure's files but not the store database; see
          # systemd.services.nix-store-register below.
          "/nix-path-registration".source =
            "${pkgs.closureInfo { rootPaths = [ config.system.build.toplevel ]; }}/registration";
        };

        repartConfig = {
          Type = "root";
          Format = "btrfs";
          # systemd-repart's Label= is the GPT partition label, which is what fileSystems."/"
          # below names the device by.
          Label = "root";
          Minimize = "guess";
          # Enough slack to boot and start growing. The machine's real disk is the overlay the
          # provider driver creates, which is larger; boot.growPartition fills it.
          PaddingMinBytes = "1G";
        };
      };
    };
  };

  # btrfs, because the volume layer below snapshots subvolumes of it: a job's worktree is a
  # snapshot of the seed, made and deleted per job (docs/design/worker-tier.md § Volumes).
  fileSystems."/" = {
    device = "/dev/disk/by-partlabel/root";
    fsType = "btrfs";
    autoResize = true;
    options = [ "compress=zstd:1" ];
  };

  # The image is small and the machine's disk is not: the driver creates a bigger overlay on
  # it, and the partition and the filesystem grow into it on the first boot.
  boot.growPartition = true;

  # The console the provider driver captures (`-serial file:…`), and a video console so the
  # same image is debuggable with a display attached.
  boot.kernelParams = [ "console=tty0" "console=ttyS0,115200" ];

  # -- the Nix store --------------------------------------------------------------------------

  # The image copies the closure's *files* in, but not the store database, so a fresh machine's
  # `nix` would consider every path invalid and set about fetching what it already has. The
  # installer images register it at first boot for the same reason.
  systemd.services.nix-store-register = {
    description = "Register the image's Nix store paths";
    wantedBy = [ "multi-user.target" ];
    before = [ "nix-daemon.service" "forge-worker.service" ];
    unitConfig.ConditionPathExists = "/nix-path-registration";

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      ${lib.getExe' config.nix.package.out "nix-store"} --load-db < /nix-path-registration
      rm -f /nix-path-registration
    '';
  };

  # `nix develop .#<env>` on the project's flake is the whole point of the machine, and it must
  # be a download rather than a build.
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    substituters = [ "https://cache.nixos.org/" ];
    trusted-public-keys = [ "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" ];
    # A cold machine's first job populates the store; two jobs doing it at once should share.
    max-jobs = "auto";

    # Every project a worker ever builds leaves its closure behind, and a worker that is never
    # destroyed never stops accumulating them. The daemon collects *during a build* when free
    # space drops below min-free, up to max-free — rather than on a timer, which fires when
    # nothing is wrong and not when something is. The cost is that a seldom-used project may
    # have to fetch its closure again; the alternative is a full disk, which costs every
    # project at once. See docs/design/worker-tier.md § What a machine that never dies
    # accumulates.
    min-free = 5 * 1024 * 1024 * 1024;
    max-free = 20 * 1024 * 1024 * 1024;
  };

  # -- learning what this machine is ------------------------------------------------------------

  # docs/design/worker-tier.md § How a machine learns what it is. The image is identical for
  # every worker, so the identity and the secrets arrive at boot: from a labelled disk the local
  # driver attaches, or from the provider's metadata service. Same content either way — a file of
  # KEY=VALUE lines — so there is one parser and one contract.
  systemd.services.forge-worker-config = {
    description = "Fetch this worker's identity";
    wantedBy = [ "multi-user.target" ];
    before = [ "forge-worker.service" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    path = [ pkgs.util-linux pkgs.curl pkgs.coreutils pkgs.iproute2 ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      set -euo pipefail
      umask 077

      # A disk the driver attached. Its device node is root's, so a job cannot read it even
      # while it is mounted.
      if device=$(blkid -L ${configLabel} 2> /dev/null); then
        mkdir -p /run/forge-config
        mount -o ro,nosuid,nodev,noexec "$device" /run/forge-config
        cp /run/forge-config/${configFile} ${envFile}
        umount /run/forge-config
        echo "identity: ${configLabel}"
      else
        # A metadata service lives on a link-local address, and a link-local address is not
        # routable unless something says it is on-link. The provider's own images get that from
        # their DHCP; this one uses plain DHCP and does not, which the local network stack made
        # plain by refusing to forward to 169.254.169.254 at all. Cheap to add, total to omit.
        iface=$(ip -o route show default | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
        host=$(printf '%s' "''${FORGE_CONFIG_URL}" | sed -n 's|^[a-z]*://\([^/:]*\).*|\1|p')
        if [ -n "$iface" ] && [ -n "$host" ]; then
          ip route replace "$host/32" dev "$iface" 2> /dev/null || true
        fi

        if curl -fsS --max-time 20 -o ${envFile} "''${FORGE_CONFIG_URL}"; then
          echo "identity: ''${FORGE_CONFIG_URL}"
        else
          echo "no identity: no ${configLabel} disk and nothing at ''${FORGE_CONFIG_URL}" >&2
          exit 1
        fi
      fi

      chmod 0600 ${envFile}

      # The ssh door, when the operator opened one. Carried in the same file rather than by a
      # mechanism of its own, and removed from it so the release is not handed a stray variable.
      key=$(sed -n 's/^FORGE_SSH_KEY=//p' ${envFile})
      if [ -n "$key" ]; then
        mkdir -p /root/.ssh
        printf '%s\n' "$key" > /root/.ssh/authorized_keys
        chmod 0600 /root/.ssh/authorized_keys
        sed -i '/^FORGE_SSH_KEY=/d' ${envFile}
      fi

      # The metadata service answers every process on the machine, including the agent, and what
      # it answers with is the worker token and the harness credential. Nothing needs it once
      # this unit has run, so the route added above — or the provider's own — is replaced by one
      # that goes nowhere. Locally there is nothing there and this is a no-op.
      # Only a link-local one. The property being closed is "unauthenticated, answers every
      # process, on an address nobody routes deliberately" — that is a metadata service, not
      # any host an operator might point FORGE_CONFIG_URL at. Blackholing one of those would
      # be a machine cutting off something it was told to talk to.
      case "''${host:-}" in
        169.254.*) ip route replace blackhole "$host/32" || true ;;
        *) ;;
      esac
      ip route replace blackhole 169.254.169.254/32 || true
    '';

    environment.FORGE_CONFIG_URL = "http://169.254.169.254/hetzner/v1/userdata";
  };

  # Plain DHCP on whatever interface the machine has. This was cloud-init's to render; it is one
  # line, and a worker that cannot reach the platform is no worker at all.
  networking.hostName = "forge-worker";
  networking.useDHCP = true;
  networking.useNetworkd = true;
  systemd.network.wait-online.anyInterface = true;

  # -- Claude Code ----------------------------------------------------------------------------

  # Claude Code's native install is a generic dynamically-linked ELF — `interpreter
  # /lib64/ld-linux-x86-64.so.2` — and a stock NixOS has no such file, so the binary does not run
  # at all until something puts one there. `pkgs.claude-code` closed that gap with
  # `autoPatchelfHook`; a binary the machine installs for itself has nobody to close it, so the
  # machine does, with glibc's own loader. This is the one line that makes the install runnable.
  environment.ldso = pkgs.stdenv.cc.bintools.dynamicLinker;

  # Install or update Claude Code once, before the worker can report `ready`. Modelled on
  # forge-worker-config.service above, and ordered the same way: `before` the release, which
  # `requires` it, so the attempt has finished — succeeded, failed or skipped — before any job
  # can be taken (docs/design/worker-tier.md § Updating a worker).
  #
  # **`RemainAfterExit` is what makes it once rather than once per start of the release.** A
  # oneshot that does not remain goes back to inactive when it finishes, and forge-worker's
  # `Restart = on-failure` would pull it in again on every restart — a re-install mid-life, which
  # is out of scope on this ticket. Staying active (exited) makes the second pull a no-op, and a
  # reboot the only thing that runs it again.
  systemd.services.claude-code-update = {
    description = "Install or update this worker's Claude Code";
    wantedBy = [ "multi-user.target" ];
    before = [ "forge-worker.service" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    # A shell's worth of what a third-party installer script expects to find, since this one is
    # fetched rather than vendored and nothing here pins what it reaches for. The literal path is
    # last, because that is where the installer puts `claude` and the update branch has to find
    # the one already installed rather than one from the store.
    path = [
      pkgs.bash
      pkgs.coreutils
      pkgs.curl
      pkgs.gnugrep
      pkgs.gnused
      pkgs.gawk
      pkgs.gnutar
      pkgs.gzip
      pkgs.jq
      # Both optional to the installer and both worth having: with `jq` it reads the release
      # manifest rather than its own fallback parser, and with `zstd` it fetches the compressed
      # binary rather than the whole one — which is the difference that matters against the
      # timeout above.
      pkgs.zstd
      claudeHome
    ];

    environment = {
      HOME = root;
      SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "${toString claudeUnitTimeout}s";
    };

    # **Every failure is caught here and written to the status file rather than left to the exit
    # code, and the script ends in `exit 0`.** That is what lets forge-worker.service `require`
    # this unit without a machine that cannot reach the installer becoming a machine that never
    # starts: criterion 4 of the ticket, and the reason `set -e` is deliberately not on.
    script = ''
      # **`set +e`, deliberately.** NixOS puts `set -e` above this script, and errexit is the one
      # thing that would defeat the design: a `grep` that matches nothing or a `mktemp` that
      # fails would kill the script before it could write its outcome, which is the
      # machine-that-never-starts this unit exists not to produce.
      set +e
      set -uo pipefail

      # umask 022, not the config unit's 077: a job runs as its own Unix user and execs the
      # binary the installer is about to write, so what it writes under ${root} has to be
      # readable by someone who is not root. ${root} itself is 0711 (systemd.tmpfiles.rules
      # below) — traversable, not listable — which is what lets that work without opening the
      # directories beside it.
      umask 022

      # The installed version, or nothing at all. A binary that is not there, or that the loader
      # refuses, or that hangs, has to read as "nothing installed" rather than stop the script.
      installed() {
        [ -x ${claudeExecutable} ] || return 0
        timeout 20 ${claudeExecutable} --version 2> /dev/null | head -1 || true
      }

      log=$(mktemp)
      before=$(installed)

      if [ -n "$before" ]; then
        echo "claude-code-update: updating $before"
        timeout ${toString claudeTimeout} ${claudeExecutable} update > "$log" 2>&1 || true
      else
        echo "claude-code-update: installing from ${claudeInstaller}"
        timeout ${toString claudeTimeout} bash -c \
          'curl -fsSL "$1" | bash' bash ${claudeInstaller} > "$log" 2>&1 || true
      fi

      after=$(installed)

      # Nothing installed after the attempt is the only failure: the machine has no Claude Code
      # and the operator has to know. The same version either side is `skipped` — already
      # current, which on a freshly built image is the common case and not a fault.
      if [ -z "$after" ]; then
        outcome=failed
      elif [ -z "$before" ] || [ "$after" != "$before" ]; then
        outcome=succeeded
      else
        outcome=skipped
      fi

      error=""
      if [ "$outcome" = failed ]; then
        error=$(grep -v '^[[:space:]]*$' "$log" | tail -3 | tr '\n' ' ' | cut -c 1-400 || true)
        [ -n "$error" ] || error="no Claude Code after the attempt, and it said nothing"
      fi

      # jq rather than printf: the error is whatever curl or the installer said, and a quote or a
      # backslash in it must not be able to produce a file `ClaudeUpdate.status/1` cannot read.
      if jq -n --arg outcome "$outcome" --arg version "$after" --arg error "$error" \
        '{ outcome: $outcome }
           + (if $version == "" then {} else { version: $version } end)
           + (if $error == "" then {} else { error: $error } end)' > "$log.json"; then
        mv "$log.json" ${claudeUpdateStatus}
      fi

      rm -f "$log" "$log.json"
      echo "claude-code-update: $outcome ''${after:-none}"
      exit 0
    '';
  };

  # -- the release ----------------------------------------------------------------------------

  # Modelled on nix/module.nix's systemd.services.forge. It is ordered after the unit that
  # fetches the identity and requires it, so there is no window in which the release is up and
  # unconfigured — and no restart to arrange, which is what this cost while cloud-init owned
  # the file and had to poke the unit afterwards.
  systemd.services.forge-worker = {
    description = "forge worker";
    wantedBy = [ "multi-user.target" ];

    after = [
      "network-online.target"
      "nix-daemon.service"
      "nix-store-register.service"
      "forge-worker-config.service"
      "claude-code-update.service"
    ];

    wants = [ "network-online.target" ];

    # claude-code-update.service sits here and not in any Elixir-side wait: this is what
    # withholds `ready` until the attempt has finished, exactly as the Nix store's registration
    # already withholds it until the store is usable (docs/design/worker-tier.md § Updating a
    # worker). It cannot stop the worker starting — see its script's last line.
    requires = [
      "nix-store-register.service"
      "forge-worker-config.service"
      "claude-code-update.service"
    ];

    # Belt as well as braces: a config unit that succeeded without writing anything would
    # otherwise start a release with no identity, which only fails once it tries to dial.
    unitConfig.ConditionPathExists = envFile;

    # The worker's tools and the agent's: a job inherits this PATH. `claudeHome` is where Claude
    # Code now lives, so an agent's own `claude` resolves the way its `git` does.
    path = servicePath ++ jobTools ++ [ claudeHome ];

    environment = {
      LANG = "C.UTF-8";
      HOME = root;
      # Distribution is off, so the cookie protects nothing; the release script still wants one.
      RELEASE_DISTRIBUTION = "none";
      RELEASE_COOKIE = "forge-no-distribution";
      RELEASE_TMP = "${root}/tmp";
      FORGE_ROOT = root;
      # The slice is real on this machine: one transient unit per job, with the ceiling that
      # makes an out-of-memory build kill one job rather than the machine.
      FORGE_SLICE = "systemd";
      # The root is btrfs for exactly this: a job's worktree is a snapshot of the project's
      # seed, and costs nothing until the job writes to it.
      FORGE_VOLUME = "btrfs";
      FORGE_NIX_ENV = "1";
      FORGE_CLAUDE_EXECUTABLE = claudeExecutable;
      SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
      NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
    };

    serviceConfig = {
      # Root, because the slice makes a Unix user per job and runs it in a transient unit.
      User = "root";
      WorkingDirectory = root;
      EnvironmentFile = envFile;
      ExecStartPre = [
        "${pkgs.coreutils}/bin/mkdir -p ${root}/tmp ${root}/jobs ${root}/worktrees ${root}/volumes"
        # A machine with nothing overriding it runs the release the image was built with. Only
        # when absent, so an update put here by hand survives a reboot — which is the whole
        # point of the indirection.
        "${pkgs.bash}/bin/sh -c '[ -e ${releaseLink} ] || ln -sfn ${workerPackage} ${releaseLink}'"
        # An *indirect* GC root, the way a NixOS profile is one: nix follows the symlink, so
        # whatever the link currently points at is protected from the min-free sweep. Without
        # this, a release copied here by hand is collectable the moment the disk gets tight.
        "${pkgs.bash}/bin/sh -c 'mkdir -p $(dirname ${gcRoot}) && ln -sfn ${releaseLink} ${gcRoot}'"
      ];

      ExecStart = "${releaseLink}/bin/forge_worker start";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # Traversable but not listable: a job runs as its own Unix user and has to reach its own
  # worktree under here, while the directories beside it are the slice's to close (0700, owned
  # by the job's user). A root that nobody but root may traverse stops the unit at CHDIR.
  systemd.tmpfiles.rules = [ "d ${root} 0711 root root -" ];

  # -- the rest -------------------------------------------------------------------------------

  # No inbound port is needed — the worker dials out — but M4 measures phases from outside the
  # guest, and a key the config disk carries is how it gets in. Password login is off.
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  # A serial console to read when a boot goes wrong, which is the only way in before the
  # network is up.
  systemd.services."serial-getty@ttyS0".enable = true;

  # The service's own tools and the agent's, so a shell over ssh sees what a job sees. curl is
  # among them: how the config unit reads a metadata service, and how the measurement harness
  # fetches a seed from inside the guest.
  environment.systemPackages = servicePath ++ jobTools;

  # And Claude Code, which is not a package and so cannot be in the list above. pam_env puts this
  # on every login shell's PATH, which is where `pkgs.claude-code` used to reach an operator who
  # ssh'd in. Written out in full, unlike a unit's `path` above: `sessionVariables` is joined with
  # `:` as given and nothing appends `/bin` to it.
  environment.sessionVariables.PATH = [ "${claudeHome}/bin" ];

  # Nothing on this machine is worth keeping: it is created for a ticket and destroyed when it
  # has had nothing to do for a while.
  documentation.enable = false;
  documentation.nixos.enable = false;
}
