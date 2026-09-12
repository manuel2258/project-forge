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

config :forge, ForgeWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

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

if hour = System.get_env("FORGE_DIGEST_HOUR_UTC") do
  case Integer.parse(hour) do
    {h, ""} when h in 0..23 -> config :forge, Forge.Push, digest_hour_utc: h
    _ -> raise "FORGE_DIGEST_HOUR_UTC must be an hour from 0 to 23, got #{inspect(hour)}"
  end
end

if config_env() != :test do
  config :forge, Forge.Jobs,
    data_dir: System.get_env("FORGE_DATA_DIR") || "tmp/forge",
    repos_dir: System.get_env("FORGE_REPOS_DIR"),
    nix_env: System.get_env("FORGE_NIX_ENV") in ["1", "true"],
    harness_opts: harness_opts
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
