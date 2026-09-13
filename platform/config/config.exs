# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :forge, :scopes,
  user: [
    default: true,
    module: Forge.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :binary_id,
    schema_table: :users,
    test_data_fixture: Forge.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :forge,
  ecto_repos: [Forge.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Where the platform keeps bare repositories, worktrees and job directories, and how the
# embedded local worker runs jobs. Overridden per environment and in runtime.exs.
config :forge, Forge.Jobs,
  data_dir: "tmp/forge",
  run_jobs: true,
  max_concurrent: 2,
  poll_ms: 2_000,
  wall_clock_ms: 3_600_000,
  nix_env: false,
  harness_opts: [],
  # A job reaches its repository over the platform's own git endpoint. The base URL is derived
  # from the endpoint unless something in front rewrites the host; the token outlives the job's
  # wall clock by a margin. See docs/design/git-hosting.md.
  git_base_url: nil,
  git_token_ttl_minutes: 90,
  git_max_body_bytes: 100 * 1024 * 1024

# Mailer for account emails (magic links). Local adapter in dev; see runtime.exs for prod.
config :forge, Forge.Mailer, adapter: Swoosh.Adapters.Local

# Swoosh API client is only needed for adapters that talk HTTP.
config :swoosh, :api_client, false

# Configure the endpoint
config :forge, ForgeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ForgeWeb.ErrorHTML, json: ForgeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Forge.PubSub,
  live_view: [signing_salt: "XxkpX512"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  path: System.get_env("MIX_ESBUILD_PATH"),
  forge: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  path: System.get_env("MIX_TAILWIND_PATH"),
  forge: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# The platform's own daily spend cap, in USD. `nil` means none. Unlike the ticket allowance, which
# a human resolves by raising it or rerouting, this one is resolved by midnight — so it pauses the
# node rather than sticking tickets, and never puts anything in the queue. See
# docs/design/capacity.md.
config :forge, Forge.Spend, daily_cost_usd: nil

# One unit of capacity is one percent of a five-hour window. `window_cost_usd` is the cost of a
# whole window: the only bridge from the cost the harness estimates to the unit the operator
# reads. PLACEHOLDER until dogfooding calibrates it — display only, nothing schedules or caps on
# it. See docs/design/capacity.md.
config :forge, :capacity, window_cost_usd: 5.0

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
