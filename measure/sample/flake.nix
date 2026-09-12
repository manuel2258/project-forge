{
  description = "Sample workload for forge's measurement harness: a dependency tree and a heavy link";

  inputs = {
    # The same revision as the repository's own flake, so the store is shared and the
    # measurement does not spend its first minutes downloading a second nixpkgs.
    nixpkgs.url = "github:NixOS/nixpkgs/aff8a0b28396750446e5537a96461bc4facdb287";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # `nix develop .#build`, which is what the workload's environment command enters. The
      # compilation cache M1(b) transplants comes from here, not from forge's own shell.
      devShells = forAllSystems (pkgs: {
        build = pkgs.mkShell {
          packages = [ pkgs.cargo pkgs.rustc pkgs.sccache pkgs.pkg-config ];
          env.LANG = "C.UTF-8";
        };
        default = self.devShells.${pkgs.stdenv.hostPlatform.system}.build;
      });

      # M1(a): a build directory produced from the dependency closure alone, with a stub for
      # the project's own sources, so what it contains is exactly the dependencies' output.
      # Only present once `cargo generate-lockfile` has run; `bin/measure sample-init` does
      # that, and until then variant (a) has nothing to build.
      packages = forAllSystems (pkgs:
        nixpkgs.lib.optionalAttrs (builtins.pathExists ./Cargo.lock) {
          deps-only = pkgs.stdenv.mkDerivation {
            name = "forge-sample-deps-only";
            src = nixpkgs.lib.fileset.toSource {
              root = ./.;
              fileset = nixpkgs.lib.fileset.unions [ ./Cargo.toml ./Cargo.lock ];
            };
            cargoDeps = pkgs.rustPlatform.importCargoLock { lockFile = ./Cargo.lock; };
            nativeBuildInputs = [
              pkgs.cargo
              pkgs.rustc
              pkgs.rustPlatform.cargoSetupHook
            ];
            buildPhase = ''
              runHook preBuild
              mkdir -p src
              echo 'fn main() {}' > src/main.rs
              cargo build --offline
              # The stub's own artefacts are not dependency output and would make M1(a) look
              # like it had cached the project itself.
              rm -f target/debug/forge-sample target/debug/forge_sample*
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p $out
              cp -a target $out/target
              runHook postInstall
            '';
          };
        });
    };
}
