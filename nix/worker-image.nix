# NixOS module for the forge worker image: a machine that boots, learns who it is and where the
# platform is from a config disk or a metadata service, and runs the forge_worker release. A
# btrfs root for the volume layer to snapshot, a Nix daemon pointed at the binary cache, and Claude
# Code. No project toolchain: that comes from the workload's own flake through `nix develop`.
#
# See docs/design/worker-tier.md § The worker image. The image pins nothing about any
# particular project, and it is meant to boot unchanged on a provider later.
{ workerPackage }:
{ config, lib, pkgs, modulesPath, ... }:
let
  root = "/var/lib/forge";
  envFile = "/etc/forge-worker.env";

  # The contract between the provider driver and the machine: a filesystem with this label
  # holding this file, or a metadata service returning the same bytes.
  configLabel = "forge-config";
  configFile = "worker.env";

  # What the worker needs to do its work and to confine a job: git for the clone and the push,
  # nix for `nix develop`, btrfs-progs for the volume layer, tar and gzip for the seed, shadow
  # and systemd for the per-job user and its transient unit, and Claude Code itself.
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
    pkgs.claude-code
  ];
in
{
  imports = [
    "${modulesPath}/image/repart.nix"
    "${modulesPath}/profiles/qemu-guest.nix"
  ];

  system.stateVersion = "26.05";
  system.image.id = "forge-worker";
  system.image.version = "0.1.0";

  # -- the image ------------------------------------------------------------------------------

  # An appliance image: no system profile, nothing to `nixos-rebuild`. The bootloader is
  # installed by putting systemd-boot and one unified kernel image into the ESP, because the
  # image is built offline and there is no machine to run an installer on.
  boot.loader.grub.enable = false;
  boot.loader.timeout = 0;

  image.repart = {
    enable = true;
    name = "forge-worker";
    # OVMF does not work with repart's default 4096-byte sectors.
    sectorSize = 512;
    compression.enable = false;

    partitions = {
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
      elif curl -fsS --max-time 20 -o ${envFile} "''${FORGE_CONFIG_URL}"; then
        echo "identity: ''${FORGE_CONFIG_URL}"
      else
        echo "no identity: no ${configLabel} disk and nothing at ''${FORGE_CONFIG_URL}" >&2
        exit 1
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
      # this unit has run. Locally there is nothing there and this is a no-op.
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
    ];

    wants = [ "network-online.target" ];
    requires = [ "nix-store-register.service" "forge-worker-config.service" ];

    # Belt as well as braces: a config unit that succeeded without writing anything would
    # otherwise start a release with no identity, which only fails once it tries to dial.
    unitConfig.ConditionPathExists = envFile;

    path = servicePath;

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
      FORGE_CLAUDE_EXECUTABLE = lib.getExe pkgs.claude-code;
      SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
      NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
    };

    serviceConfig = {
      # Root, because the slice makes a Unix user per job and runs it in a transient unit.
      User = "root";
      WorkingDirectory = root;
      EnvironmentFile = envFile;
      ExecStartPre =
        "${pkgs.coreutils}/bin/mkdir -p ${root}/tmp ${root}/jobs ${root}/worktrees ${root}/volumes";
      ExecStart = "${workerPackage}/bin/forge_worker start";
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

  # The service's own tools, plus curl: how the config unit reads a metadata service, and how
  # the measurement harness fetches a seed from inside the guest.
  environment.systemPackages = servicePath ++ [ pkgs.curl ];

  # Nothing on this machine is worth keeping: it is created for a ticket and destroyed when it
  # has had nothing to do for a while.
  documentation.enable = false;
  documentation.nixos.enable = false;
}
