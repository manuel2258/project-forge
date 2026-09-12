# Workloads

A workload says what to build; `bin/measure` says how to measure it. Nothing in the harness
knows a language or a build tool: everything toolchain-specific is one of the keys in
`example.sh`, which documents all of them.

```
cp measure/workloads/example.sh measure/workloads/mygame.sh
$EDITOR measure/workloads/mygame.sh
bin/measure preflight --workload mygame
bin/measure m1 --workload mygame
```

A config is a sourced bash file, so a hook can be a command line or a function, and it can
interpolate the paths the harness exports before sourcing it: `FORGE_M_SCRATCH`,
`FORGE_M_CACHE_DIR`, `FORGE_M_VOLUME`, `FORGE_M_RUN_DIR`. It is also arbitrary code, which is
acceptable for a file the operator writes about their own machine and is why `bin/check`
lints these files along with the harness.

The three here:

- `sample-rust.sh` — the sample project the measurements are first run on, materialised by
  `bin/measure sample-init`. See `measure/sample/README.md`.
- `selftest.sh` — the fake workload `bin/measure selftest` drives. Not evidence: every record
  it produces is stamped, and the report refuses to render the docs-ready form for it.
- `example.sh` — the template.

A key left unset is a recorded result, not a skipped test: no `dep_seed_attr` makes M1(a)
`not_applicable` with `workload_has_no_dep_closure_builder`, and no `cache_env` makes M1(b)
report that the toolchain has no compilation cache. Neither ever counts as a pass.
