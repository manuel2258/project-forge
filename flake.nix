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
            hash = "sha256-22onCzlOK4qUcCo0eqUbujHCHdT3TL62FgVlOtX4EoE=";
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

          devShells.default = pkgs.mkShell {
            packages = [
              elixir
              beam.erlang
              pkgs.postgresql_16
              pkgs.esbuild
              pkgs.tailwindcss_4
              pkgs.git
            ] ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.inotify-tools ];

            env = {
              MIX_ESBUILD_PATH = esbuildPath;
              MIX_TAILWIND_PATH = tailwindPath;
              LANG = "C.UTF-8";
              ERL_AFLAGS = "-kernel shell_history enabled";
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
    };
}
