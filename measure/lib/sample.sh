# shellcheck shell=bash
# Materialises measure/sample into a standalone repository with the four branches M2 needs.
# The template is in the repository; the working copy is scratch, so a re-init is free.
# See measure/sample/README.md.
#
# Workload keys come from the config that common.sh sources.
# shellcheck disable=SC2154

sample_git() {
  git -C "$1" -c user.email=measure@forge -c user.name="forge measure" "${@:2}"
}

sample_commit() {
  local repo=$1 message=$2
  sample_git "$repo" add -A
  sample_git "$repo" commit --quiet -m "$message"
}

# `path:` rather than `.`, because the scratch root is ignored by forge's own repository and
# a bare `.` resolves upwards to it: nix would refuse an untracked path. Only used before
# `git init`, while the tree is still a template copy, so nothing large is copied to the
# store; once the repository exists a plain `.` is both correct and cheaper.
sample_lockfile() {
  local repo=$1
  (cd "$repo" && nix develop "path:$repo#build" --command cargo generate-lockfile) ||
    die "cargo generate-lockfile failed in $repo"
}

cmd_sample_init() {
  [ $# -eq 0 ] || die "sample-init: unknown argument $1"
  local origin=$FORGE_M_SCRATCH/sample-rust/origin branch sha
  have git || die "sample-init needs git"
  have nix || die "sample-init needs nix to generate the lockfile"

  section "sample project"
  rm -rf "$origin"
  mkdir -p "$origin"
  cp -a "$FORGE_M_ROOT/measure/sample/." "$origin/"
  rm -f "$origin/README.md"

  section "lockfile"
  # Generated rather than committed: it pins hundreds of crates that have nothing to do with
  # forge, and the harness only needs it to be the same across a run.
  sample_lockfile "$origin"

  sample_git "$origin" init --quiet --initial-branch=main
  sample_commit "$origin" "sample workload"

  section "branches"
  sample_git "$origin" checkout --quiet -b leaf main
  sed -i 's|(self.x \* self.x + self.y \* self.y).sqrt()|self.x.hypot(self.y)|' "$origin/src/geometry.rs"
  sample_commit "$origin" "leaf: one function in one module"

  sample_git "$origin" checkout --quiet -b core main
  sed -i 's|pub x: f64,|pub x: f64,\n    pub weight: f32,|' "$origin/src/geometry.rs"
  sed -i 's|                x: angle.cos(),|                x: angle.cos(),\n                weight: 1.0,|' "$origin/src/geometry.rs"
  sample_commit "$origin" "core: a type every module sees"

  sample_git "$origin" checkout --quiet -b wide main
  for file in "$origin"/src/*.rs; do
    printf '\n// widened for the measurement branch\npub const REVISION: u32 = 2;\n' >> "$file"
  done
  sample_commit "$origin" "wide: every module"

  sample_git "$origin" checkout --quiet -b deps main
  sed -i 's|^rayon = "1"|rayon = "1"\nitertools = "0.13"|' "$origin/Cargo.toml"
  sample_lockfile "$origin"
  sample_commit "$origin" "deps: a new dependency"

  sample_git "$origin" checkout --quiet main

  section "record these in measure/workloads/sample-rust.sh"
  echo "workload_commit=$(sample_git "$origin" rev-parse main)"
  printf 'm2_branches=('
  for branch in leaf core wide deps; do
    sha=$(sample_git "$origin" rev-parse "$branch")
    printf '%s:%s ' "$branch" "$sha"
  done
  printf ')\n'
  info "origin: $origin"
}
