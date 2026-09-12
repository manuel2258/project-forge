# shellcheck shell=bash
# The sample workload: a Rust binary with a dependency tree and a heavy link, materialised by
# `bin/measure sample-init`. See measure/sample/README.md.
#
# Nothing here is known to bin/measure: every toolchain-specific thing a measurement needs is
# one of these keys. measure/workloads/example.sh documents all of them.
# shellcheck disable=SC2034

workload_name=sample-rust
workload_repo=$FORGE_M_SCRATCH/sample-rust/origin
# Replaced with the SHAs sample-init prints, so two runs are comparable. Until then the
# branch names resolve through the seed's remote-tracking refs.
workload_commit=main
workload_env=build
build_dir=target

# -v because parse_rebuilds below reads the `Running `rustc --crate-name ...`` lines, which
# only a verbose build emits. Without it the parser sees an empty log, reports nothing
# rebuilt, and every variant passes for the wrong reason.
build_cmd_debug="cargo build -v"
build_cmd_release="cargo build -v --release"
build_profiles=(debug release)
clean_cmd="cargo clean"
build_timeout_seconds=7200

own_sources=("src/*.rs")
# Cargo names a dependency's artefacts after the dependency, so the project's own output is
# what carries its own crate name.
own_paths=("debug/forge-sample" "debug/deps/forge_sample*" "release/forge-sample" "release/deps/forge_sample*")
dep_paths=("debug/deps/*" "debug/build/*" "release/deps/*" "release/build/*" "*/incremental/*")

# `cargo build -v` says out loud what it compiles, which is better evidence than mtimes and
# the only reading that sees work served entirely from the compilation cache.
parse_rebuilds=sample_rust_parse_rebuilds
sample_rust_parse_rebuilds() {
  sed -n 's/.*Running `.*rustc .*--crate-name \([A-Za-z0-9_]*\).*/\1/p' |
    awk '{ if ($1 == "forge_sample") print "own " $1; else print "dep " $1 }'
}

dep_seed_attr=".#deps-only"
dep_seed_subpath=target

cache_env=(RUSTC_WRAPPER=sccache "SCCACHE_DIR=$FORGE_M_CACHE_DIR/sccache" SCCACHE_CACHE_SIZE=20G)
cache_stats_cmd="sccache --show-stats"
# An sccache server that is already running ignores a changed SCCACHE_DIR, so variant (b)
# would otherwise measure the wrong cache.
cache_reset_cmd="sccache --stop-server || true"

m2_branches=(leaf:origin/leaf core:origin/core wide:origin/wide deps:origin/deps)
m2_volume_size=80G
m2_scaling_min_efficiency=0.5

mem_probe_max=infinity
# The link, isolated: everything else is brought up to date first, untimed.
heaviest_step_prepare_debug="cargo build"
heaviest_step_cmd_debug="touch src/main.rs && cargo build"
heaviest_step_prepare_release="cargo build --release"
heaviest_step_cmd_release="touch src/main.rs && cargo build --release"

repeats=1
