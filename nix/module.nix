# NixOS module for the forge platform: one systemd service running the release, local
# Postgres over its Unix socket, git, nix and Claude Code on the service's PATH.
{ forgePackage }:
{ config, lib, pkgs, ... }:
let
  cfg = config.services.forge;
  inherit (lib) mkEnableOption mkOption mkIf types;
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
      description = "Home of the service: bare repositories, worktrees, job directories.";
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Secrets as KEY=VALUE lines, not in the Nix store: SECRET_KEY_BASE (required),
        ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN, FORGE_VAPID_PUBLIC_KEY,
        FORGE_VAPID_PRIVATE_KEY, FORGE_VAPID_SUBJECT.
      '';
    };

    database.createLocally = mkOption {
      type = types.bool;
      default = true;
      description = "Run Postgres on this host and connect over its Unix socket.";
    };

    nixEnv = mkOption {
      type = types.bool;
      default = true;
      description = "Run each job inside the project's `nix develop .#<env>`.";
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

      path = [ pkgs.git pkgs.nix pkgs.bash pkgs.coreutils cfg.claudePackage ];

      environment = {
        PHX_SERVER = "true";
        PHX_HOST = cfg.host;
        PORT = toString cfg.port;
        LANG = "C.UTF-8";
        HOME = cfg.dataDir;
        RELEASE_DISTRIBUTION = "none";
        RELEASE_TMP = "${cfg.dataDir}/tmp";
        FORGE_DATA_DIR = "${cfg.dataDir}/data";
        FORGE_NIX_ENV = if cfg.nixEnv then "1" else "0";
        FORGE_CLAUDE_EXECUTABLE = lib.getExe cfg.claudePackage;
        FORGE_DIGEST_HOUR_UTC = toString cfg.digestHourUtc;
      } // lib.optionalAttrs cfg.database.createLocally {
        DATABASE_SOCKET_DIR = "/run/postgresql";
        DATABASE_NAME = "forge";
        DATABASE_USER = "forge";
      };

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
