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
#
# **No credential.** `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` are not read, as a fallback
# or as anything else: a job picks a credential its owner assigned to the job's project and
# carries it in the assignment (`docs/design/credentials.md` § The node's own key is gone). A node
# that still sets them is setting variables nothing reads.
harness_opts =
  Enum.reject(
    [
      executable: System.get_env("FORGE_CLAUDE_EXECUTABLE"),
      model: System.get_env("FORGE_CLAUDE_MODEL"),
      effort: System.get_env("FORGE_CLAUDE_EFFORT")
    ],
    # Unset and set-to-nothing are the same statement: this node has no opinion.
    #
    # **`executable` is why this filter cannot be pruned.** For the two dials it is defence in
    # depth — `Workers.harness_pair/3` and the driver's `flag_args/3` each refuse `""` on their
    # own — but nothing downstream refuses an empty executable: `Keyword.get(opts, :executable,
    # "claude")` returns `""` for a key that is present and empty, so a node with
    # `FORGE_CLAUDE_EXECUTABLE=` spawned `nix develop … --command "" …` and failed every job on
    # the machine. Dropping the `""` here restores that, which is what
    # `runtime_config_test.exs` holds this line to.
    fn {_key, value} -> value in [nil, ""] end
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
           # Set this where something in front of the platform rewrites the host, so a job's
           # clone URL is the one a client outside the node would use.
           git_base_url: System.get_env("FORGE_GIT_BASE_URL"),
           harness_opts: harness_opts
         )

  # The store lives beside the rest of the platform's data unless it is told otherwise. A
  # second implementation would replace the implementation, not this path — see
  # docs/design/storage.md § What would move this to S3, which is also why there isn't one.
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
  #
  # **No `FORGE_MAX_WORKERS`**, and its absence is the point. How many machines may exist is a
  # worker template's `max_workers` — `Forge.Workers.create_machine/1` compares
  # `Provisioning.live_count/1` with the template's own column, and nothing reads a node-wide
  # number (`docs/design/provisioning.md` § Lifecycle is per template). The variable was still
  # read here long after its last reader went, which made it look like a way to stop a node
  # provisioning; it was not, and `nix/platform-image.nix` said so on the container's behalf.
  config :forge,
         Forge.Workers,
         set.(
           slice_bytes: integer_env.("FORGE_SLICE_BYTES"),
           idle_period_ms: integer_env.("FORGE_IDLE_PERIOD_MS"),
           worker_timeout_ms: integer_env.("FORGE_WORKER_TIMEOUT_MS")
         )
end

# ## OIDC
#
# Zero or more issuers, named by a list of ids: FORGE_OIDC_PROVIDERS=acme,google. Each one then
# reads its own variables under the id, upper-cased with anything that is not a letter or a digit
# turned into an underscore — FORGE_OIDC_ACME_ISSUER and so on.
#
# **Unset means no providers and no change to anything**, which is what development and every
# node that does not want SSO get. `docs/design/identity.md` § Authentication.
#
# Read outside the `:prod` block on purpose: pointing a development node at a real issuer is how
# anybody finds out whether the redirect URI is right, and a test that sets the variables gets
# the same reading as a release.
oidc_providers =
  case System.get_env("FORGE_OIDC_PROVIDERS") do
    nil ->
      []

    list ->
      list
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn id ->
        prefix = "FORGE_OIDC_" <> String.upcase(String.replace(id, ~r/[^A-Za-z0-9]/, "_"))

        required = fn name ->
          System.get_env(prefix <> "_" <> name) ||
            raise "#{prefix}_#{name} is missing, and #{id} is named in FORGE_OIDC_PROVIDERS"
        end

        %Forge.Accounts.Oidc.Provider{
          id: id,
          name: System.get_env(prefix <> "_NAME") || id,
          issuer: required.("ISSUER"),
          client_id: required.("CLIENT_ID"),
          client_secret: required.("CLIENT_SECRET"),
          scope: System.get_env(prefix <> "_SCOPE") || "email profile",
          id_token_alg: System.get_env(prefix <> "_ID_TOKEN_ALG") || "RS256"
        }
      end)
  end

# Set even when empty: `Oidc.providers/0` reading a key that is simply absent and one that is
# absent *because nobody configured any* are the same answer, and writing it down is what lets
# a release be asked what it thinks it has.
config :forge, Forge.Accounts.Oidc, providers: oidc_providers

# A node whose SECRET_KEY_BASE opens none of the credentials it holds refuses to start
# (`Forge.Credentials.KeyCheck`, docs/deploy.md § Secrets file) unless this says the rotation was
# meant.
config :forge, Forge.Credentials.KeyCheck,
  accept: System.get_env("FORGE_ACCEPT_NEW_SECRET_KEY_BASE") in ["1", "true"]

# Both dev and prod bind to 127.0.0.1. FORGE_HTTP_IP is what the endpoint binds to when something
# else has to reach it: a worker on another machine, or a proxy in another container.
#
# Widening this is a security decision, not a convenience: `force_ssl` trusts `x-forwarded-proto`,
# so every address this listens on is an address from which that header can be forged. On a host,
# set it to the one interface those clients are on and firewall the port.
#
# **Under a container runtime there is no such interface to name.** The proxy arrives on a bridge
# address assigned at start, so 0.0.0.0 is the only value that serves at all, and what replaces
# the firewall is the container network: publish no host port, and let the proxy be the only
# thing attached to it. docs/deploy.md § Behind a proxy says what that trust boundary becomes.
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

  # ## Mail
  #
  # Account email is magic-link login and email-change confirmation, and until this existed
  # neither worked on a release: `config.exs` sets `Swoosh.Adapters.Local`, a mailbox in memory,
  # and nothing overrode it — so `docs/deploy.md` § Known limits had to say password login was
  # the only one that functioned.
  #
  # **FORGE_SMTP_HOST is the switch.** Unset, the local adapter stands, which is what development
  # wants and what a node with no relay should keep doing rather than failing at boot. Set, every
  # other variable is read around it.
  if relay = System.get_env("FORGE_SMTP_HOST") do
    # gen_smtp's own default `tls_options` is `[{versions, [...]}]` and nothing else — no
    # verification at all, on the connection that carries the relay password. So the options are
    # written out here rather than left to the library, and the certificate is checked against a
    # bundle: the image ships one and points SSL_CERT_FILE at it, a NixOS host sets the same
    # variable, and `:public_key.cacerts_get/0` is the fallback for a machine that does neither.
    anchors =
      case System.get_env("FORGE_SMTP_CACERTFILE") || System.get_env("SSL_CERT_FILE") do
        nil -> [cacerts: :public_key.cacerts_get()]
        file -> [cacertfile: String.to_charlist(file)]
      end

    verify =
      [
        verify: :verify_peer,
        depth: 3,
        server_name_indication: String.to_charlist(relay),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ] ++ anchors

    # Two different keys for the same certificate check, because gen_smtp makes the TLS
    # connection in two different places: `sockopts` for implicit TLS, which is already
    # encrypted when the first byte is sent, and `tls_options` for the STARTTLS upgrade.
    transport =
      case System.get_env("FORGE_SMTP_TLS") || "starttls" do
        "ssl" -> [ssl: true, sockopts: verify]
        "starttls" -> [ssl: false, tls: :always, tls_options: verify]
        "none" -> [ssl: false, tls: :never]
        other -> raise "FORGE_SMTP_TLS must be ssl, starttls or none, got #{inspect(other)}"
      end

    # A relay that is named is a relay that is meant: an MX lookup on its domain would let DNS
    # choose a different host for the credentials. `auth` is `:never` without a username rather
    # than gen_smtp's `:if_available`, which would offer `nil` as one.
    credentials =
      case {System.get_env("FORGE_SMTP_USERNAME"), System.get_env("FORGE_SMTP_PASSWORD")} do
        {nil, _password} -> [auth: :never]
        {username, password} -> [auth: :always, username: username, password: password]
      end

    config :forge,
           Forge.Mailer,
           [
             adapter: Swoosh.Adapters.SMTP,
             relay: relay,
             port: integer_env.("FORGE_SMTP_PORT") || 587,
             no_mx_lookups: true,
             retries: 1
           ] ++ transport ++ credentials
  end

  # Who that email is from. The compiled default is a placeholder address this node does not own,
  # which a relay worth using refuses, so setting this is part of setting up mail.
  if from = System.get_env("FORGE_MAIL_FROM") do
    config :forge, :mail_from, {System.get_env("FORGE_MAIL_FROM_NAME") || "Forge", from}
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

  # **No `:http` key here, deliberately.** The binding is `config/prod.exs`'s — loopback — and
  # `FORGE_HTTP_IP` above is the one thing that widens it. The generated line set
  # `ip: {0, 0, 0, 0, 0, 0, 0, 0}` at this point, and because runtime.exs is read after prod.exs
  # and `Config` deep-merges keyword lists, it silently won: every release bound every interface,
  # the loopback binding prod.exs calls load-bearing was dead, and so was FORGE_HTTP_IP. That
  # matters because `force_ssl` decides it is on TLS by believing `x-forwarded-proto`, so an
  # address the proxy does not own is an address that can assert it. See docs/deploy.md
  # § Behind a proxy, and `Forge.RuntimeConfigTest`.
  config :forge, ForgeWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
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
