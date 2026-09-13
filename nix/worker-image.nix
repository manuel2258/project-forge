# NixOS module for the forge worker image: a machine that boots, learns from cloud-init who it
# is and where the platform is, and runs the forge_worker release. One systemd unit, a btrfs
# root for the volume layer to snapshot, a Nix daemon pointed at the binary cache, and Claude
# Code. No project toolchain: that comes from the workload's own flake through `nix develop`.
#
# See docs/design/worker-tier.md § The worker image. The image pins nothing about any
# particular project, and it is meant to boot unchanged on a provider later.
{ workerPackage }:
{ config, lib, pkgs, modulesPath, ... }:
let
  root = "/var/lib/forge";
  envFile = "/etc/forge-worker.env";

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

  # -- cloud-init -----------------------------------------------------------------------------

  # How the machine learns its identity. Used rather than something simpler for a local VM
  # precisely because the same image has to boot on a cloud provider unchanged.
  services.cloud-init = {
    enable = true;
    network.enable = true;
    settings.datasource_list = [ "NoCloud" ];
  };

  # cloud-init configures the interface; systemd-networkd is what renders it.
  networking.useDHCP = false;
  networking.useNetworkd = true;
  systemd.network.wait-online.anyInterface = true;

  # -- the release ----------------------------------------------------------------------------

  # Modelled on nix/module.nix's systemd.services.forge. The unit is skipped at boot and started
  # by cloud-init's runcmd once the environment file exists: a machine that has not been told
  # who it is has nothing to dial, and that is a wait rather than a failure.
  systemd.services.forge-worker = {
    description = "forge worker";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "nix-daemon.service" "nix-store-register.service" ];
    wants = [ "network-online.target" ];
    requires = [ "nix-store-register.service" ];

    # Not optional: without the environment file the machine does not know who it is. The
    # condition is what keeps that a wait rather than a restart loop — cloud-init writes the
    # file and then starts the unit, and the condition is re-evaluated then.
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
  # guest, and an ssh key put there by cloud-init is how it gets in. Password login is off.
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

  # The service's own tools, plus what an operator needs to work out why a machine is not
  # doing what it should: cloud-init's client (the NixOS module puts it only on the service's
  # path) and curl, which is how the measurement harness fetches a seed from the guest.
  environment.systemPackages = servicePath ++ [ pkgs.cloud-init pkgs.curl ];

  # Nothing on this machine is worth keeping: it is created for a ticket and destroyed when it
  # has had nothing to do for a while.
  documentation.enable = false;
  documentation.nixos.enable = false;
}
