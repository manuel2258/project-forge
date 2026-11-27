import Config

# The release is configured by its environment, which cloud-init writes: FORGE_WORKER_ID,
# FORGE_WORKER_TOKEN, FORGE_PLATFORM_URL, FORGE_ROOT. See ForgeWorker.Config.
#
# Tests do not dial anything: they drive the link themselves.
config :forge_worker, connect: config_env() != :test

if config_env() == :test do
  # `stats_ms` far past any test's length, and the log stream off: a push in
  # `Slipstream.SocketTest` is a call the test must answer, so a reading or a line nobody asked
  # for would stall the link. The tests about each turn it back on.
  config :forge_worker,
    nix_env: false,
    memory_budget: 8 * 1024 * 1024 * 1024,
    stats_ms: :timer.hours(1),
    log_stream: false,
    lines_stream: false,
    # The same for the disk report: the application's own `Disk` measures one minute after the first
    # join, and `LinkTest` joins, so a report can land on a link whose test is not answering, and its
    # push is a call that times out after 5 s. (One gate's log showed a disk report with a 7 GB store
    # in the middle of 39 failing `LinkTest` tests; the cause is inferred from that, not reproduced.)
    # `disk_test.exs` starts its own `Disk` with its own intervals.
    disk_first_ms: :timer.hours(1),
    disk_report_ms: :timer.hours(1),
    disk_after_cleanup_ms: :timer.hours(1),
    # Nothing the suite starts may write to the machine's own update directory or `/run`: the
    # update and the disk report are started with the application, and each tests its own.
    update_dir: Path.join(System.tmp_dir!(), "forge-worker-test-update"),
    cleanups_path: Path.join(System.tmp_dir!(), "forge-worker-test-cleanups.json")

  config :logger, level: :warning
end
