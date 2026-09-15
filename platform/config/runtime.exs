import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/forge start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :forge, ForgeWeb.Endpoint, server: true
end

# Only when PORT is actually set. The generated line defaults it to 4000, and because
# runtime.exs is evaluated last that default overrode config/test.exs's 4002 — so the whole
# suite refused to start whenever a dev node was running on this machine, which is exactly when
# somebody is most likely to run it.
if port = System.get_env("PORT") do
  config :forge, ForgeWeb.Endpoint, http: [port: String.to_integer(port)]
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :forge, ForgeWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
        # Gettext translations
        ~r"priv/gettext/.*\.po$",
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/forge_web/router\.ex$",
        ~r"lib/forge_web/(controllers|live|components)/.*\.(ex|heex)$"
      ]
    ]
end

# Job execution settings for any environment, from the environment.
credential =
  cond do
    key = System.get_env("ANTHROPIC_API_KEY") -> {:api_key, key}
    token = System.get_env("CLAUDE_CODE_OAUTH_TOKEN") -> {:oauth, token}
    true -> nil
  end

harness_opts =
  Enum.reject(
    [
      credential: credential,
      executable: System.get_env("FORGE_CLAUDE_EXECUTABLE"),
      model: System.get_env("FORGE_CLAUDE_MODEL")
    ],
    fn {_key, value} -> is_nil(value) end
  )

# Web push needs VAPID keys; generate them once with `mix generate.vapid.keys`.
if public = System.get_env("FORGE_VAPID_PUBLIC_KEY") do
  config :web_push_elixir,
    vapid_public_key: public,
    vapid_private_key: System.fetch_env!("FORGE_VAPID_PRIVATE_KEY"),
    vapid_subject: System.get_env("FORGE_VAPID_SUBJECT") || "mailto:operator@localhost"
end

if cap = System.get_env("FORGE_DAILY_COST_USD") do
  case Float.parse(cap) do
    {value, ""} when value > 0 -> config :forge, Forge.Spend, daily_cost_usd: value
    _ -> raise "FORGE_DAILY_COST_USD must be a positive number, got #{inspect(cap)}"
  end
end

if hour = System.get_env("FORGE_DIGEST_HOUR_UTC") do
  case Integer.parse(hour) do
    {h, ""} when h in 0..23 -> config :forge, Forge.Push, digest_hour_utc: h
    _ -> raise "FORGE_DIGEST_HOUR_UTC must be an hour from 0 to 23, got #{inspect(hour)}"
  end
end

# Settings that are only settings when someone set them: an absent variable must leave the
# compiled default alone rather than overwrite it with nil.
set = fn pairs -> Enum.reject(pairs, fn {_key, value} -> is_nil(value) end) end

integer_env = fn name ->
  case System.get_env(name) do
    nil ->
      nil

    value ->
      case Integer.parse(value) do
        {number, ""} -> number
        _other -> raise "#{name} must be an integer, got #{inspect(value)}"
      end
  end
end

# The worker is a different machine, so the endpoint's own URL says nothing useful about where
# it should dial: under QEMU's user-mode networking the platform is the guest's gateway, which
# is http://10.0.2.2:4000. FORGE_PLATFORM_URL is read for the socket the worker joins, the
# store it fetches from, and — unless FORGE_GIT_BASE_URL says otherwise — the git URL the job
# clones from.
if config_env() != :test do
  data_dir = System.get_env("FORGE_DATA_DIR") || "tmp/forge"

  config :forge,
         Forge.Jobs,
         set.(
           data_dir: data_dir,
           repos_dir: System.get_env("FORGE_REPOS_DIR"),
           platform_url: System.get_env("FORGE_PLATFORM_URL"),
           nix_env: System.get_env("FORGE_NIX_ENV") in ["1", "true"],
           # Set this where something in front of the platform rewrites the host, so a job's
           # clone URL is the one a client outside the node would use.
           git_base_url: System.get_env("FORGE_GIT_BASE_URL"),
           harness_opts: harness_opts
         )

  # The store lives beside the rest of the platform's data unless it is told otherwise; the
  # S3 implementation in the closing step replaces the implementation, not the path.
  config :forge, Forge.Storage,
    dir: System.get_env("FORGE_STORE_DIR") || Path.join(data_dir, "store")

  # Where machines come from, and what shape they are. The image and the UEFI firmware are
  # paths on this host — `nix build .#worker-image` makes the first, and the devshell exports
  # the other two — so nothing here can guess them.
  config :forge,
         Forge.Provider,
         set.(
           image: System.get_env("FORGE_WORKER_IMAGE"),
           firmware_code: System.get_env("FORGE_OVMF_CODE"),
           firmware_vars: System.get_env("FORGE_OVMF_VARS"),
           dir: System.get_env("FORGE_MACHINES_DIR"),
           cpus: integer_env.("FORGE_WORKER_CPUS"),
           memory_mb: integer_env.("FORGE_WORKER_MEMORY_MB"),
           disk_gb: integer_env.("FORGE_WORKER_DISK_GB"),
           # The ssh door, shut unless both are set: see docs/design/worker-tier.md § The
           # provider driver for the two things that need it and why it is not on by default.
           ssh_key: System.get_env("FORGE_WORKER_SSH_KEY"),
           ssh_port: integer_env.("FORGE_WORKER_SSH_PORT")
         )

  # The tier's numbers. All three are the sample project's or a labelled guess, and
  # docs/measurements.md says the operator's own project replaces them: they are settings so
  # that replacing one is a setting, not a patch.
  config :forge,
         Forge.Workers,
         set.(
           slice_bytes: integer_env.("FORGE_SLICE_BYTES"),
           max_workers: integer_env.("FORGE_MAX_WORKERS"),
           idle_period_ms: integer_env.("FORGE_IDLE_PERIOD_MS"),
           worker_timeout_ms: integer_env.("FORGE_WORKER_TIMEOUT_MS")
         )
end

# The worker reaches the platform over the network, not over loopback, and both dev and prod bind
# to 127.0.0.1. FORGE_HTTP_IP is what the endpoint binds to when something else has to reach it.
#
# Widening this is a security decision, not a convenience: `force_ssl` trusts `x-forwarded-proto`,
# so every address this listens on is an address from which that header can be forged. Set it to
# the one interface the workers are on, never 0.0.0.0, and firewall the port — docs/deploy.md
# § Behind a proxy.
if ip = System.get_env("FORGE_HTTP_IP") do
  case :inet.parse_address(String.to_charlist(ip)) do
    {:ok, address} -> config :forge, ForgeWeb.Endpoint, http: [ip: address]
    {:error, _reason} -> raise "FORGE_HTTP_IP must be an IP address, got #{inspect(ip)}"
  end
end

if config_env() == :prod do
  pool_size = String.to_integer(System.get_env("POOL_SIZE") || "10")
  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # A local Postgres over its Unix socket (peer authentication) when DATABASE_SOCKET_DIR is
  # set, as the NixOS module does; otherwise DATABASE_URL. One of the two is required.
  case {System.get_env("DATABASE_SOCKET_DIR"), System.get_env("DATABASE_URL")} do
    {socket_dir, _} when is_binary(socket_dir) ->
      config :forge, Forge.Repo,
        socket_dir: socket_dir,
        database: System.get_env("DATABASE_NAME") || "forge",
        username: System.get_env("DATABASE_USER") || "forge",
        pool_size: pool_size

    {nil, url} when is_binary(url) ->
      config :forge, Forge.Repo,
        # ssl: true,
        url: url,
        pool_size: pool_size,
        socket_options: maybe_ipv6

    {nil, nil} ->
      raise """
      set DATABASE_URL (for example ecto://USER:PASS@HOST/DATABASE) or DATABASE_SOCKET_DIR
      (a local Postgres over its Unix socket)
      """
  end

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :forge, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :forge, ForgeWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :forge, ForgeWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :forge, ForgeWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
