# shellcheck shell=bash
# The fake workload the self-test drives. No compiler, no Nix, no systemd: it exists to
# exercise the harness's own paths, never to produce evidence.
# shellcheck disable=SC2034

workload_name=selftest
workload_repo=$FORGE_M_SCRATCH/selftest/origin
# Branch names rather than SHAs, because the fixture is recreated on every run. A real
# workload pins commits so that two runs are comparable.
workload_commit=main
workload_env=""
build_dir=build

build_cmd_debug="./build.sh"
build_cmd_release="./build.sh release"
build_profiles=(debug release)
clean_cmd="rm -rf build"
build_timeout_seconds=300

own_sources=("src/*.c")
own_paths=("own/*")
dep_paths=("dep/*")

# No dependency-closure builder: variant (a) records not_applicable, which is a result the
# self-test asserts rather than a path it skips.
dep_seed_attr=""
# A stand-in for a compilation cache, so variant (b) runs rather than reporting that the
# toolchain has none.
cache_env=(SELFTEST_CACHE=1)
cache_stats_cmd="echo 'selftest cache: no statistics'"

m2_branches=(one:origin/one two:origin/two three:origin/three four:origin/four)
m2_volume_size=1G

heaviest_step_prepare_debug="./build.sh"
heaviest_step_cmd_debug="./link.sh"
heaviest_step_prepare_release="./build.sh release"
heaviest_step_cmd_release="./link.sh"
