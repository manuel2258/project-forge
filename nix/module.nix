# NixOS module for the forge platform: one systemd service running the release, local
# Postgres over its Unix socket, git, nix and Claude Code on the service's PATH.
{ forgePackage }:
{ config, lib, pkgs, ... }:
let
  cfg = config.services.forge;
  inherit (lib) mkEnableOption mkOption mkIf types;

  # What the release needs on PATH: git for repositories, a shell and coreutils for its hooks, and
  # Claude Code itself. `nix` is left from when the platform ran jobs and entered each project's
  # `nix develop`; nothing on the platform calls it now.
  #
  # No `openssh`: the `post-receive` mirror was its only caller, and the mirror speaks https now
  # (`docs/design/git-hosting.md` § What a mirror URL may be) — an `ssh://` or `git@host:` mirror
  # URL is refused before it is ever stored, so nothing on this path would run `ssh` anyway.
  # `nix/platform-image.nix` drops the same package for the same reason.
  servicePath = [ pkgs.git pkgs.nix pkgs.bash pkgs.coreutils cfg.claudePackage ];

  # The service's environment. `forge-admin` runs one-off commands with the same one.
  serviceEnv = {
    PHX_SERVER = "true";
    PHX_HOST = cfg.host;
    PORT = toString cfg.port;
    LANG = "C.UTF-8";
    HOME = cfg.dataDir;
    # Distribution is off, so the cookie protects nothing; the release script still wants one.
    RELEASE_DISTRIBUTION = "none";
    RELEASE_COOKIE = "forge-no-distribution";
    RELEASE_TMP = "${cfg.dataDir}/tmp";
    FORGE_DATA_DIR = "${cfg.dataDir}/data";
    FORGE_REPOS_DIR = "${cfg.dataDir}/repos";
    FORGE_CLAUDE_EXECUTABLE = lib.getExe cfg.claudePackage;
    FORGE_DIGEST_HOUR_UTC = toString cfg.digestHourUtc;
  } // lib.optionalAttrs cfg.database.createLocally {
    DATABASE_SOCKET_DIR = "/run/postgresql";
    DATABASE_NAME = "forge";
    DATABASE_USER = "forge";
  };

  # `forge-admin eval 'Forge.Release.create_operator(...)'`: runs `bin/forge` as the service
  # user with the service's environment and secrets, in a transient unit, so first-run
  # commands need no hand-assembled environment.
  forgeAdmin = pkgs.writeShellScriptBin "forge-admin" ''
    set -euo pipefail
    if [ "$#" -eq 0 ]; then
      echo "usage: forge-admin <bin/forge arguments>, e.g. forge-admin eval 'Forge.Release.list_tokens(\"you@example.org\")'" >&2
      exit 64
    fi
    # --expand-environment=no: the arguments are code to eval, and systemd would otherwise
    # substitute any ''${NAME} in them from the unit's environment before the release saw them.
    exec ${pkgs.systemd}/bin/systemd-run --quiet --pty --wait --collect --expand-environment=no \
      --uid=forge --gid=forge --working-directory=${cfg.dataDir} \
      ${lib.optionalString (cfg.environmentFile != null) "--property=EnvironmentFile=${cfg.environmentFile}"} \
      --setenv=PATH=${lib.makeBinPath servicePath} \
      ${lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "--setenv=${k}=${lib.escapeShellArg v}") (removeAttrs serviceEnv [ "PHX_SERVER" ]))} \
      -- ${cfg.package}/bin/forge "$@"
  '';
in
{
  options.services.forge = {
    enable = mkEnableOption "the forge platform";

    package = mkOption {
      type = types.package;
      default = forgePackage;
      description = "The forge release to run.";
    };

    host = mkOption {
      type = types.str;
      example = "forge.example.org";
      description = "Public host name, used for generated URLs.";
    };

    port = mkOption {
      type = types.port;
      default = 4000;
      description = "Port the platform listens on (put a TLS proxy in front).";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/forge";
      description = "Home of the service: bare repositories, the blob store, the local driver's machines.";
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Secrets as KEY=VALUE lines, not in the Nix store: SECRET_KEY_BASE (required),
        FORGE_VAPID_PUBLIC_KEY, FORGE_VAPID_PRIVATE_KEY, FORGE_VAPID_SUBJECT. No agent
        credential: each user adds their own in the product (docs/design/credentials.md).
      '';
    };

    database.createLocally = mkOption {
      type = types.bool;
      default = true;
      description = "Run Postgres on this host and connect over its Unix socket.";
    };

    claudePackage = mkOption {
      type = types.package;
      default = pkgs.claude-code;
      description = "The Claude Code package jobs run.";
    };

    digestHourUtc = mkOption {
      type = types.ints.between 0 23;
      default = 9;
      description = "Hour (UTC) of the daily digest push.";
    };
  };

  config = mkIf cfg.enable {
    # Claude Code is unfree in nixpkgs. The host allows it (see docs/deploy.md); setting
    # `nixpkgs.config` here would silently replace a predicate the host already has.
    assertions = [{
      assertion = cfg.claudePackage.meta.available or true;
      message = "services.forge.claudePackage is not available; allow the unfree \"claude-code\" package in nixpkgs.config.allowUnfreePredicate";
    }];

    environment.systemPackages = [ forgeAdmin ];

    users.users.forge = {
      isSystemUser = true;
      group = "forge";
      home = cfg.dataDir;
      createHome = true;
    };

    users.groups.forge = { };

    services.postgresql = mkIf cfg.database.createLocally {
      enable = true;
      ensureDatabases = [ "forge" ];
      ensureUsers = [{
        name = "forge";
        ensureDBOwnership = true;
      }];
    };

    systemd.services.forge = {
      description = "forge platform";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ] ++ lib.optional cfg.database.createLocally "postgresql.service";
      requires = lib.optional cfg.database.createLocally "postgresql.service";
      wants = [ "network-online.target" ];

      path = servicePath;
      environment = serviceEnv;

      serviceConfig = {
        User = "forge";
        Group = "forge";
        WorkingDirectory = cfg.dataDir;
        EnvironmentFile = mkIf (cfg.environmentFile != null) cfg.environmentFile;
        ExecStartPre = [
          "${pkgs.coreutils}/bin/mkdir -p ${cfg.dataDir}/tmp ${cfg.dataDir}/data ${cfg.dataDir}/repos"
          "${cfg.package}/bin/forge eval Forge.Release.migrate"
        ];
        ExecStart = "${cfg.package}/bin/forge start";
        Restart = "on-failure";
        RestartSec = 5;
        # The job runner needs a real filesystem view and process groups; no hardening
        # that would break `nix develop` or git worktrees. The worker tier is where
        # isolation is meant to live.
        NoNewPrivileges = true;
        PrivateTmp = true;
      };
    };
  };
}
