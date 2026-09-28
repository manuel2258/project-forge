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

# Where the platform keeps its data — the store, the local driver's machine directories and git's
# scratch space — and how jobs are scheduled and bounded. The platform runs no job itself: a
# worker does, and how it enters a project's environment is the worker's own setting
# (`FORGE_NIX_ENV` in worker/config/runtime.exs). Overridden per environment and in runtime.exs.
config :forge, Forge.Jobs,
  data_dir: "tmp/forge",
  run_jobs: true,
  poll_ms: 2_000,
  wall_clock_ms: 3_600_000,
  # The worker starts a job's clock only once its clone and seed are ready, so a store token
  # spent after that — the transcript's, a conversation's history — has to outlive the
  # preparation too. An hour, generously. Not from M4's 35-second cold start, which is mostly boot
  # and the Nix store, both outside this window: what is inside it is the seed, 3.3 seconds over
  # loopback in M4, and a provider's network makes that slower by an amount nobody has measured.
  # See docs/design/storage.md § Serving.
  preparation_margin_ms: 3_600_000,
  harness_opts: [],
  # A job reaches its repository over the platform's own git endpoint. The base URL is derived
  # from the endpoint unless something in front rewrites the host; the token outlives the job's
  # wall clock by a margin. See docs/design/git-hosting.md.
  git_base_url: nil,
  git_token_ttl_minutes: 90,
  git_max_body_bytes: 100 * 1024 * 1024

# Blobs and worker seeds. One implementation in the PoC: a directory on this host, served over
# HTTP to the worker with a short-lived per-key token. See docs/design/storage.md.
config :forge, Forge.Storage,
  impl: Forge.Storage.Local,
  dir: "tmp/forge/store",
  token_max_age: 900

# Where machines come from. A local VM under QEMU for the PoC; Hetzner is the closing step's,
# behind the same behaviour. See docs/design/worker-tier.md.
config :forge, Forge.Provider,
  drivers: %{"local" => Forge.Provider.LocalVm, "hetzner" => Forge.Provider.Hetzner},
  default: "local",
  # Where Hetzner machines are made. Named rather than left to the driver's fallback, which was
  # `fsn1` — a datacenter that currently sells no x86 server type at all, so every template made
  # against it failed at create with `422: unsupported location for server type`. Nuremberg is
  # the nearest one with stock. A snapshot is project-global, so an image made anywhere boots
  # here; what is location-bound is which server types can be ordered.
  location: "nbg1"

# The worker tier's numbers. `slice_bytes` is M3's observed peak plus its margin
# (docs/measurements.md § M3) and `idle_period_ms` is set from M4's cold start (below). Both are
# the sample's, not the operator's.
config :forge, Forge.Workers,
  slice_bytes: 2210 * 1024 * 1024,
  # What a chat gets instead, because `slice_bytes` is a cold *build*'s peak and a chat is an
  # agent that talks. A crude estimate of the harness process and what it shells out to, not a
  # measurement — `Forge.Workers.chat_slice_bytes/0` says what it is made of and what it costs.
  chat_slice_bytes: 1024 * 1024 * 1024,
  cpu_weight: 100,
  # M4: a machine goes from nothing to able to build in about 35 seconds (docs/measurements.md
  # § M4), so being wrong about this costs 35 seconds, less than the operator's own round trip
  # to approve an artifact. Five minutes covers an approval gap without holding a machine
  # through a lunch break — where nothing is billed; on a provider that bills by the hour it is
  # only the least a machine is kept (billing_leeway_ms, below). The closing step re-measures it
  # on a provider, where the seed and the Nix store stop arriving over loopback and the cold
  # start gets longer.
  idle_period_ms: 300_000,
  # On a provider that bills every started hour, a machine is decided on this long before each
  # hour it has paid for ends: destroyed if it has been idle past its period by then and nothing
  # has a claim on it, kept for the whole next hour otherwise (docs/design/worker-tier.md § The
  # hour already paid for). It covers the platform's own lag — a pass every two seconds that may
  # wait on a provider's API, and a delete the provider finishes asynchronously — and is what the
  # Jenkins Hetzner plugin leaves; the TestFlows runners leave ten.
  billing_leeway_ms: 300_000,
  # And no destroy is sent in an hour's last minute: one sent then could complete in the next
  # hour, billed with the machine already gone, so a machine not destroyed by now keeps the next
  # hour instead. A provider call waits up to thirty seconds; this is twice that.
  billing_last_call_ms: 60_000,
  # How long a worker may be out of touch before the platform stops waiting for it. Three
  # missed heartbeats would be a minute; this is generous because a machine that is booting
  # has not reported yet and is timed from when its row was made.
  worker_timeout_ms: 180_000,
  # The worker build this platform ships with: the first twelve characters of the `forge-worker`
  # package's store hash, which `flake.nix` sets while building the release — so it is read here,
  # at build time, and baked in, not read from the running host's environment. Unset outside a
  # Nix build, and then the pages draw no hint (docs/design/worker-tier.md § Updating a worker).
  current_build: System.get_env("FORGE_WORKER_BUILD")

# Mailer for account emails (magic links, email-change confirmation). The local adapter is a
# mailbox in memory: it is what development wants, and it is what a release keeps until
# FORGE_SMTP_HOST names a relay — see runtime.exs § Mail.
config :forge, Forge.Mailer, adapter: Swoosh.Adapters.Local

# Who account email comes from. A placeholder, and deliberately one: an address this node does
# not own is refused by any relay worth using, so FORGE_MAIL_FROM is read beside the SMTP
# settings and a node that sets one without the other has changed nothing.
config :forge, :mail_from, {"Forge", "contact@example.com"}

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

# Both asset tools come from `flake.nix` (`MIX_ESBUILD_PATH`, `MIX_TAILWIND_PATH`), and both
# libraries still want a `version` — they compare it with the binary and warn when it differs.
#
# **Asked of the binary rather than written down beside it.** A literal here is a second copy of
# a number the flake already fixes, and it goes stale the moment nixpkgs moves: both of these
# were stale, and the warning they printed on every boot said to run `mix tailwind.install`,
# which downloads a *different* binary and defeats the pin the flake exists to hold. This is not
# loosening a pinned version — the pin is the flake, and this reads it rather than guessing.
#
# The fallback is for a checkout with no devshell, where the library downloads its own binary and
# the version is then the only thing saying which.
version = fn
  nil, _args, default ->
    default

  path, args, default ->
    # Rescued, not merely matched: the variable can point at a Nix store path that has since
    # been collected, and `System.cmd` raises on a missing executable. A stale path must degrade
    # to the literal, never take the whole configuration down with it.
    try do
      case System.cmd(path, args, stderr_to_stdout: true) do
        {out, 0} ->
          case Regex.run(~r/(\d+\.\d+\.\d+)/, out) do
            [_match, found] -> found
            nil -> default
          end

        _other ->
          default
      end
    rescue
      _error -> default
    end
end

esbuild_path = System.get_env("MIX_ESBUILD_PATH")
tailwind_path = System.get_env("MIX_TAILWIND_PATH")

config :esbuild,
  version: version.(esbuild_path, ["--version"], "0.25.4"),
  path: esbuild_path,
  forge: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# `tailwindcss --version` is not a flag it has; the banner it prints before its help is where the
# version is, and it exits 0.
config :tailwind,
  version: version.(tailwind_path, ["--help"], "4.3.0"),
  path: tailwind_path,
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

# What the request and LiveView event logs print as `[FILTERED]`: any parameter whose name
# contains one of these. Phoenix's default is `password` alone, which let a provider credential's
# `token` and an inference credential's `secret` through to the debug log of every form that
# carries one — a LiveView logs the params of every event, and a form with `phx-change` sends
# every field on every keystroke. See `docs/design/credentials.md` § Checked on save.
config :phoenix, :filter_parameters, ["password", "secret", "token"]

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
