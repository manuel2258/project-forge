import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :pbkdf2_elixir, :rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :forge, Forge.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "forge_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# The server runs during test, because a job now reaches its repository over the platform's own
# git endpoint: a real `git clone` against a real socket is the only honest proof of it. Tests
# that run a job are `async: false`, and `Forge.DataCase.setup_sandbox/1` shares the connection
# for those, so the request process sees the test's data.
config :forge, ForgeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "r9SkKtYQxa5nfNBAIjrrB0CK9osMfY223Mzy75zOxWYusuvAaHxPslIeH3VkiV8z",
  server: true

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# In test we don't send emails
config :forge, Forge.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Tests drive jobs explicitly; the scheduler stays off and data lives under tmp/test.
config :forge, Forge.Jobs, data_dir: "tmp/test", run_jobs: false

config :forge, Forge.Storage, dir: "tmp/test/store"

# No machine is created in tests; the fake records what the platform asked for.
config :forge, Forge.Provider, impl: Forge.Provider.Fake, name: "fake"

# Push goes to a test double; keys are set so the feature counts as enabled.
config :forge, Forge.Push, sender: Forge.Push.TestSender

config :web_push_elixir,
  vapid_public_key: "test-public",
  vapid_private_key: "test-private",
  vapid_subject: "mailto:test@forge"
