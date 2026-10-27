import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :pbkdf2_elixir, :rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
# Where the server is comes from the environment, because on a machine that is not an operator's
# there is no server until `bin/check` starts one: it makes a postgres for the length of the run,
# on a unix socket in a directory only that run can read, and names the directory here. Nothing
# else on a shared machine can reach that socket, so there is no password in this file for a job
# with a checkout to read, and nothing holding 5432 can be mistaken for it (`CLAUDE.md`
# § Quality gate). An operator with their own postgres sets nothing and gets localhost and the
# usual development password.
config :forge, Forge.Repo,
  username: "postgres",
  database: "forge_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

case System.get_env("FORGE_TEST_DB_SOCKET_DIR") do
  nil -> config :forge, Forge.Repo, hostname: "localhost", password: "postgres"
  dir -> config :forge, Forge.Repo, socket_dir: dir
end

# The server runs during test, because a job now reaches its repository over the platform's own
# git endpoint: a real `git clone` against a real socket is the only honest proof of it. Tests
# that run a job are `async: false`, and `Forge.DataCase.setup_sandbox/1` shares the connection
# for those, so the request process sees the test's data.
config :forge, ForgeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "r9SkKtYQxa5nfNBAIjrrB0CK9osMfY223Mzy75zOxWYusuvAaHxPslIeH3VkiV8z",
  server: true

# Where the credential check asks the provider. A `Req.Test` stub, whose ownership is per process:
# each test answers the request itself, and nothing writes node-global configuration while other
# modules run — which is how this suite has broken twice (`Forge.Harness.ClaudeCode`).
config :forge, Forge.Harness.ClaudeCode, req_options: [plug: {Req.Test, Forge.Harness.ClaudeCode}]

# What a merge did to the other open tickets is checked in the merging process rather than a task
# of its own, which would outlive the test that merged and write to a sandbox nobody owns.
config :forge, Forge.Merge.Watch, inline: true

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
config :forge, Forge.Provider,
  drivers: %{
    "fake" => Forge.Provider.Fake,
    "local" => Forge.Provider.LocalVm,
    "hetzner" => Forge.Provider.Hetzner
  },
  default: "fake"

# Push goes to a test double; keys are set so the feature counts as enabled.
config :forge, Forge.Push, sender: Forge.Push.TestSender

config :web_push_elixir,
  vapid_public_key: "test-public",
  vapid_private_key: "test-private",
  vapid_subject: "mailto:test@forge"
