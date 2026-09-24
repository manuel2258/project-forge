# An OCI image carrying the platform and nothing else: no worker, no Postgres, no agent.
#
# The platform is the one tier that is a long-lived server rather than a machine created and
# destroyed, so it is the one tier a container suits. The worker is deliberately not here — it
# needs a kernel, systemd slices and a Nix store of its own (`docs/design/worker-tier.md`), all
# of which a container is the wrong shape for — and Postgres is not here because a database in
# the same image as the server is a database that is deleted with it.
#
# Built with the same `mixRelease` the NixOS module runs, so the two deployments differ in how
# the release is delivered and in nothing else. See `docs/deploy.md` § In a container.
#
# **It provisions no machines, and nothing in here is what stops it.** A machine is made from a
# worker template a node admin created and assigned to a project; a fresh node has none, so
# `Forge.Workers.create_machine/1` answers `{:no_template, :none_assigned}` and `Jobs.Scheduler`
# sticks the ticket with that reason. This image used to set `FORGE_MAX_WORKERS=0` and claim
# that was the mechanism — the variable had had no reader since `max_workers` moved onto the
# template (`docs/design/provisioning.md` § Lifecycle is per template), so the outcome was right
# and the explanation was wrong. What keeps it true is *not creating a template*: the one driver
# that could run from in here is Hetzner, and assigning a template that names it is how an
# operator opts in. `Forge.Provider.LocalVm` cannot — a container cannot boot a VM.
{ pkgs, forge, version }:

let
  inherit (pkgs) lib dockerTools;

  dataDir = "/var/lib/forge";

  # The image runs as a user, not as root. Docker gives a *named* volume the ownership the image
  # has at that path, so declaring it here is what makes the unprivileged default work without
  # the operator doing anything. A bind mount keeps the host's ownership and has to be chowned —
  # `docs/deploy.md` says so, because the failure is a permission error at boot and nothing else.
  uid = 1000;
  gid = 1000;

  # What the platform shells out to. `git` for repositories, worktrees and the http backend;
  # `bash` and coreutils because the hooks it installs are shell scripts with a
  # `#!/usr/bin/env bash` shebang — which is also why `usrBinEnv` is in `contents` below.
  #
  # **No ssh client ships.** The `post-receive` mirror was its only caller, and the mirror speaks
  # https now (`docs/design/git-hosting.md` § What a mirror URL may be) — a mirror URL is not
  # allowed to be `ssh://` or `git@host:` in the first place, so nothing here would ever run it.
  #
  # Not here, and each for a reason: `nix`, because the platform stopped running jobs in
  # milestone 3 and `nix develop` happens on the worker; Claude Code, because the platform
  # forwards a credential and never invokes a harness (`Forge.Workers.harness_env/0` says so);
  # `qemu`, because a container cannot boot a VM and § In a container explains what that costs.
  runtimeInputs = [ pkgs.git pkgs.bash pkgs.coreutils ];

  entrypoint = pkgs.writeShellApplication {
    name = "forge-entrypoint";
    runtimeInputs = runtimeInputs ++ [ forge ];
    text = ''
      # The three directories the release writes to. A named volume arrives empty, and a bind
      # mount arrives as whatever the host made it, so both need this and neither can assume it.
      mkdir -p "''${FORGE_DATA_DIR:-${dataDir}/data}" \
               "''${FORGE_REPOS_DIR:-${dataDir}/repos}" \
               "''${RELEASE_TMP:-${dataDir}/tmp}"

      # Migrate on every start, exactly as the systemd unit's ExecStartPre does. It is the same
      # release and the same command, so an image and a NixOS host reach the same schema.
      forge eval Forge.Release.migrate

      exec forge "$@"
    '';
  };
in
dockerTools.buildLayeredImage {
  name = "forge";
  tag = version;

  contents = [
    entrypoint
    forge
    dockerTools.usrBinEnv
    dockerTools.binSh
    dockerTools.caCertificates
  ] ++ runtimeInputs;

  # Under fakeroot, so the ownership actually takes: `extraCommands` cannot chown.
  fakeRootCommands = ''
    mkdir -p .${dataDir}/data .${dataDir}/repos .${dataDir}/tmp ./tmp
    chmod 1777 ./tmp
    chown -R ${toString uid}:${toString gid} .${dataDir}

    # **Real files in the image root, not a store path in `contents`, and that is not style.**
    # `contents` links a package in as *absolute symlinks into the store*, and `docker exec`
    # resolves the container user by reading `/etc/passwd` from outside the container, through a
    # resolver that refuses a symlink pointing out of the rootfs. Every `docker exec` then fails
    # with `path escapes from parent`, at any `-u`, while the container itself runs perfectly —
    # glibc inside follows the link without complaint. So the only thing it breaks is the
    # documented way to run every one-off command (`docs/deploy.md` § In a container), which is
    # also the only way to make the first node admin. Tested by running the image.
    #
    # Written out rather than taken from `dockerTools.fakeNss`, which provides `nobody` and not a
    # named user. `git` reads the passwd entry when nothing states an identity, and a release's
    # `RELEASE_TMP` and `HOME` both want a user that exists.
    mkdir -p ./etc
    cat > ./etc/passwd <<EOF
    root:x:0:0:root:/root:/bin/sh
    forge:x:${toString uid}:${toString gid}:forge:${dataDir}:/bin/sh
    EOF
    cat > ./etc/group <<EOF
    root:x:0:
    forge:x:${toString gid}:
    EOF
    # Without this, glibc resolves no hosts at all in a container: the database is reached by
    # name, and so is every mirror and push endpoint.
    cat > ./etc/nsswitch.conf <<EOF
    hosts: files dns
    EOF
  '';
  enableFakechroot = false;

  config = {
    Entrypoint = [ "${entrypoint}/bin/forge-entrypoint" ];
    # `start` and not `daemon`: a container's process manager is the container runtime, and a
    # release that daemonised would exit and take the container with it.
    Cmd = [ "start" ];

    User = "${toString uid}:${toString gid}";
    WorkingDir = dataDir;
    ExposedPorts = { "4000/tcp" = { }; };
    Volumes = { "${dataDir}" = { }; };

    Env = [
      "PATH=${lib.makeBinPath (runtimeInputs ++ [ forge ])}"
      "PHX_SERVER=true"
      "PORT=4000"
      "LANG=C.UTF-8"
      "HOME=${dataDir}"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"

      # Distribution is off, so the cookie protects nothing; the release script still wants one.
      # The same two lines the NixOS module sets, for the same reason.
      "RELEASE_DISTRIBUTION=none"
      "RELEASE_COOKIE=forge-no-distribution"
      "RELEASE_TMP=${dataDir}/tmp"

      "FORGE_DATA_DIR=${dataDir}/data"
      "FORGE_REPOS_DIR=${dataDir}/repos"
    ];

    Labels = {
      "org.opencontainers.image.title" = "forge";
      "org.opencontainers.image.description" = "The forge platform: server only, no worker and no database.";
      "org.opencontainers.image.version" = version;
    };
  };
}
