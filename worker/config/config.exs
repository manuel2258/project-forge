import Config

# The release is configured by its environment, which cloud-init writes: FORGE_WORKER_ID,
# FORGE_WORKER_TOKEN, FORGE_PLATFORM_URL, FORGE_ROOT. See ForgeWorker.Config.
#
# Tests do not dial anything: they drive the link themselves.
config :forge_worker, connect: config_env() != :test

if config_env() == :test do
  config :forge_worker, nix_env: false, memory_budget: 8 * 1024 * 1024 * 1024
  config :logger, level: :warning
end
