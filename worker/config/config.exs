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
    log_stream: false

  config :logger, level: :warning
end
