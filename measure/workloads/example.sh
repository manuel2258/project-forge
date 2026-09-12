# shellcheck shell=bash
# Template for a workload. Copy it, name it after the project, and fill it in:
#   cp measure/workloads/example.sh measure/workloads/mygame.sh
#   bin/measure preflight --workload mygame
#
# The four parameters docs/poc-plan.md names are workload_repo, workload_env,
# build_cmd_debug and build_dir. Everything else exists so that bin/measure never has to
# know what language or build tool this is. Keys left unset are recorded as not_applicable
# with a reason, which is a result, not a skipped test.
#
# These are read by the harness, not by this file.
# shellcheck disable=SC2034

# --- identity ----------------------------------------------------------------

workload_name=example
# Cloned into the scratch root and never mutated in place. A path or a URL.
workload_repo=/srv/git/example.git
# Pinned, so two runs are comparable. A SHA in a real workload.
workload_commit=0000000000000000000000000000000000000000
# The <env> in `nix develop .#<env>`, the same form the worker uses. Empty means no Nix.
workload_env=default
# Relative to the worktree: the directory the build command warms.
build_dir=build

# --- building ----------------------------------------------------------------

# Shell strings, run under `bash -o pipefail -c` inside the entered environment.
build_cmd_debug="make"
build_cmd_release="make RELEASE=1"
build_profiles=(debug release)
clean_cmd="rm -rf build"
build_timeout_seconds=7200

# --- what counts as the project's own work (M1) --------------------------------

# Touched to build the warm_own reference: the local equivalent of what each variant is
# asked to do, and the denominator of the 2x rule.
own_sources=("src/*.c" "src/**/*.c")
# Globs under build_dir. Anything matching neither list is reported as unclassified.
own_paths=("obj/example/*")
dep_paths=("obj/vendor/*")

# Optional and much better evidence than mtimes where the toolchain says out loud what it
# compiles: a function reading the build log on stdin and printing one `own <unit>` or
# `dep <unit>` per line.
parse_rebuilds=""

# --- M1 (a): the dependency closure as a build directory -----------------------

# A flake attribute whose output holds a build directory built from the dependency closure
# alone. Unset records variant (a) as not applicable.
dep_seed_attr=""
dep_seed_subpath=build

# --- M1 (b): a compilation cache -----------------------------------------------

# Unset records "toolchain has none", which is a legitimate answer for M1(b).
cache_env=()
# Defaults to a build in the warm tree with cache_env set.
cache_populate_cmd=""
cache_stats_cmd=""
# A cache daemon that is already running ignores a changed cache directory, so it has to be
# stopped between phases or variant (b) measures the wrong cache.
cache_reset_cmd=""

# --- M2 ------------------------------------------------------------------------

# At least four, pinned. Realistic: what one ticket's branch actually changes.
m2_branches=(one:sha1 two:sha2 three:sha3 four:sha4)
m2_volume_size=80G
# Four concurrent builds within twice the time of one.
m2_scaling_min_efficiency=0.5

# --- M3 ------------------------------------------------------------------------

# infinity: a binding ceiling would suppress the peak by forcing reclaim.
mem_probe_max=infinity
mem_sweep_factors=(1.5 1.25 1.0 0.75)
m3_sweep_max_inflation=1.25
m3_safety_margin=1.1
# The heaviest step, isolated. The prepare command brings everything else up to date and is
# not timed. Unset records that the toolchain exposes no separable step.
heaviest_step_prepare_debug=""
heaviest_step_cmd_debug=""
heaviest_step_prepare_release=""
heaviest_step_cmd_release=""

# --- general --------------------------------------------------------------------

# One sample is noise; three is the recommendation for the references.
repeats=1
# Pin the build's own parallelism if it should not follow the machine.
build_jobs_env=()
# M1's pass criteria, as thresholds rather than constants, because they are judgements.
m1_time_factor=2
m1_file_slack=1.10
