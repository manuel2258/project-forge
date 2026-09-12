# Sample workload

A small Rust binary with a dependency tree worth caching and a link worth measuring. It is
the workload the measurement harness is first run on. Nothing about it is the operator's
project, and nothing in the harness knows it is Rust: the toolchain lives in this flake and
in `measure/workloads/sample-rust.sh`, not in `bin/measure`.

Why Rust: `sccache` gives M1(b) a real answer rather than "toolchain has none", a
dependency-closure build directory can be produced by a Nix builder for M1(a), and the final
link is a separable heaviest step for M3. The dependency list in `Cargo.toml` is one line to
change — a game-shaped one (`bevy`) is the closest analogue to the operator's own project if
the numbers need to look more like it.

This directory is a template, not a repository. `bin/measure sample-init` copies it into the
scratch root, generates `Cargo.lock`, and makes the four branches M2 snapshots:

| Branch | What it changes | Divergence measured |
|---|---|---|
| `leaf` | one function in `geometry.rs` | 38 MiB |
| `core` | a type used by every module | 38 MiB |
| `wide` | every module | 38 MiB |
| `deps` | the dependency list | 43 MiB |

**Three of those four are the same measurement, and that is a fact about cargo rather than a
flaw in the branches.** `forge-sample` is a single crate and cargo's unit of compilation is the
crate, so editing one function, editing a shared type and editing every module all rebuild
exactly one crate and produce byte-identical exclusive bytes. Only `deps` differs, because it
genuinely adds a crate to compile.

The branches were written expecting a range of blast radii. Getting one needs a multi-crate
workspace, where an edit to a leaf member rebuilds that member and an edit to a shared member
rebuilds its dependents. That is worth doing before the operator's own project is measured in
the closing step, and it would invalidate the recorded M1 and M2 numbers, so it is not done
here. Until then M2 measures the divergence of one crate's rebuild, four times over, plus one
case that adds a dependency — which is a real number for the storage model and not a range.

The lockfile is generated rather than committed because it pins hundreds of crates whose
versions have nothing to do with forge; the branch SHAs are printed by `sample-init` so they
can be recorded in the workload config for a comparable re-run.
