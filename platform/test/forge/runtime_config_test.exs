defmodule Forge.RuntimeConfigTest do
  @moduledoc """
  What `config/runtime.exs` decides for a release, read the way a release reads it.

  Two things live here: the endpoint's address, and what a release does about mail. Both are
  decided by files nothing else reads, in an order that is easy to get wrong.

  The endpoint's address is a security property rather than a preference. `force_ssl` is
  configured with `rewrite_on: [:x_forwarded_proto]`, so the platform decides it is on TLS by
  believing a request header, and that header is only trustworthy while the proxy is the only
  thing that can send one. An address the proxy does not own is an address from which a session
  cookie can be accepted over cleartext.

  Nothing else could have caught what this caught. `config/prod.exs` says loopback and says why;
  `runtime.exs` is read afterwards and `Config` deep-merges keyword lists, so a single
  `ip: {0, 0, 0, 0, 0, 0, 0, 0}` left there by the Phoenix generator won — quietly, on every
  release, in a file that reads as though the first one decided it. So this reads both files in
  order, merges them as `Config` does, and asserts the address that actually comes out.
  """

  use ExUnit.Case, async: false

  @prod Path.expand("../../config/prod.exs", __DIR__)
  @runtime Path.expand("../../config/runtime.exs", __DIR__)

  @required %{
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "DATABASE_URL" => "ecto://forge:forge@localhost/forge"
  }

  # Cleared for the duration: each one would otherwise let whatever is in the shell that ran the
  # suite decide what this reads, and two of them are exactly what is under test. `SSL_CERT_FILE`
  # is in the list because the mailer reads it for its trust anchors and a devshell sets it.
  @cleared ~w(FORGE_HTTP_IP PORT PHX_HOST FORGE_VAPID_PUBLIC_KEY SSL_CERT_FILE
              FORGE_MAX_WORKERS FORGE_MAIL_FROM FORGE_MAIL_FROM_NAME
              ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
              FORGE_CLAUDE_EXECUTABLE FORGE_CLAUDE_MODEL FORGE_CLAUDE_EFFORT
              FORGE_SMTP_HOST FORGE_SMTP_PORT FORGE_SMTP_TLS FORGE_SMTP_CACERTFILE
              FORGE_SMTP_USERNAME FORGE_SMTP_PASSWORD
              FORGE_OIDC_PROVIDERS
              FORGE_OIDC_ACME_NAME FORGE_OIDC_ACME_ISSUER FORGE_OIDC_ACME_CLIENT_ID
              FORGE_OIDC_ACME_CLIENT_SECRET FORGE_OIDC_ACME_SCOPE
              FORGE_OIDC_MY_IDP_ISSUER FORGE_OIDC_MY_IDP_CLIENT_ID
              FORGE_OIDC_MY_IDP_CLIENT_SECRET FORGE_OIDC_ACME_ID_TOKEN_ALG)

  setup do
    names = @cleared ++ Map.keys(@required)
    previous = Map.new(names, &{&1, System.get_env(&1)})

    Enum.each(@cleared, &System.delete_env/1)
    System.put_env(@required)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  defp release do
    @prod
    |> Config.Reader.read!(env: :prod)
    |> Config.Reader.merge(Config.Reader.read!(@runtime, env: :prod))
  end

  defp endpoint, do: get_in(release(), [:forge, ForgeWeb.Endpoint])
  defp mailer, do: get_in(release(), [:forge, Forge.Mailer])
  defp oidc, do: get_in(release(), [:forge, Forge.Accounts.Oidc])

  test "a release binds loopback, so only the proxy can claim the request was on TLS" do
    assert endpoint()[:http][:ip] == {127, 0, 0, 1}
    assert endpoint()[:http][:port] == 4000
  end

  test "FORGE_HTTP_IP is what widens it, and it survives the prod block" do
    System.put_env("FORGE_HTTP_IP", "10.0.2.2")

    assert endpoint()[:http][:ip] == {10, 0, 2, 2}

    # Widening the binding must not cost the port, which lives in the same keyword list.
    assert endpoint()[:http][:port] == 4000
  end

  test "an address that is not one is refused at boot rather than ignored" do
    System.put_env("FORGE_HTTP_IP", "0.0.0.0/0")

    assert_raise RuntimeError, ~r/FORGE_HTTP_IP must be an IP address/, &endpoint/0
  end

  # The host is what `check_origin` and every generated URL are built from, and it is the one
  # thing the proxy cannot supply for us.
  test "the public host comes from PHX_HOST" do
    System.put_env("PHX_HOST", "forge.example.org")

    assert endpoint()[:url][:host] == "forge.example.org"
    assert endpoint()[:url][:scheme] == "https"
  end

  # The probe is the one request with no proxy in front of it: a container runtime asks the
  # container's own address over cleartext, so with `/health` inside `force_ssl` it gets a 301
  # and reads the container as unhealthy. `ForgeWeb.HealthTest` proves the route answers; this
  # is the half of it that lives in configuration.
  test "the health probe is outside force_ssl, or it is answered with a redirect" do
    assert "/health" in endpoint()[:force_ssl][:exclude][:paths]

    # The hosts are Plug.SSL's own default, which naming `:exclude` at all replaces.
    assert "localhost" in endpoint()[:force_ssl][:exclude][:hosts]
  end

  # **The node's own key is gone** (`docs/design/credentials.md`): not a fallback, not a seed. A
  # node upgraded with either variable still set must not have it reach a machine or a job, so
  # what a release reads is asserted with both set.
  test "no node-wide agent credential is read, whatever the environment says" do
    System.put_env("ANTHROPIC_API_KEY", "sk-ant-api03-node")
    System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-node")

    harness_opts = get_in(release(), [:forge, Forge.Jobs, :harness_opts]) || []

    refute Keyword.has_key?(harness_opts, :credential)
    refute inspect(release(), limit: :infinity) =~ "sk-ant-api03-node"
    refute inspect(release(), limit: :infinity) =~ "sk-ant-oat01-node"
  end

  # **A variable that is present and empty is not a setting.** What this file can say is that
  # the platform's own release reads none of the three: `harness_env/0` forwards `model` and
  # `effort` to a machine it provisions, so an empty one would be minted into that machine, and
  # it never forwards `executable` at all.
  #
  # The broken spawn an empty `executable` causes belongs to the *worker's* release, which reads
  # the key — `ForgeWorker.Harness.ClaudeCode.command/3` — and
  # `worker/test/forge_worker/runtime_config_test.exs` is the test that holds that rule. Round
  # three of this ticket's review found this comment claiming the behaviour for the file it is
  # not in.
  test "a harness variable set to nothing configures nothing" do
    System.put_env("FORGE_CLAUDE_EXECUTABLE", "")
    System.put_env("FORGE_CLAUDE_MODEL", "")
    System.put_env("FORGE_CLAUDE_EFFORT", "")

    harness_opts = get_in(release(), [:forge, Forge.Jobs, :harness_opts]) || []

    refute Keyword.has_key?(harness_opts, :executable)
    refute Keyword.has_key?(harness_opts, :model)
    refute Keyword.has_key?(harness_opts, :effort)

    # And the fallback the absent key buys: a present-but-empty one used to win over it.
    assert Keyword.get(harness_opts, :executable, "claude") == "claude"
  end

  # The other half of the same rule: a variable that does say something is still read.
  test "a harness variable that names something is configured" do
    System.put_env("FORGE_CLAUDE_EXECUTABLE", "/bin/claude")
    System.put_env("FORGE_CLAUDE_MODEL", "opus")
    System.put_env("FORGE_CLAUDE_EFFORT", "high")

    harness_opts = get_in(release(), [:forge, Forge.Jobs, :harness_opts]) || []

    assert harness_opts[:executable] == "/bin/claude"
    assert harness_opts[:model] == "opus"
    assert harness_opts[:effort] == "high"
  end

  # `FORGE_MAX_WORKERS` was read into `Forge.Workers, :max_workers` long after its last reader
  # went: how many machines may exist is a template's column (`Forge.Workers.create_from/1`), and
  # a node-wide number that configures nothing is worse than no setting, because
  # `nix/platform-image.nix` set it to 0 and documented it as the reason a container provisions
  # nothing. Putting the key back makes this fail, which is the whole point of it.
  test "no node-wide machine ceiling is configured, whatever the environment says" do
    System.put_env("FORGE_MAX_WORKERS", "7")

    refute Keyword.has_key?(get_in(release(), [:forge, Forge.Workers]) || [], :max_workers)
  end

  describe "mail" do
    # Development and a node with no relay must both come out the other side unchanged: nothing
    # under `Forge.Mailer` here means `config.exs`'s local adapter is what runs.
    test "without a relay, runtime.exs decides nothing and the local adapter stands" do
      assert mailer() == nil
    end

    test "FORGE_SMTP_HOST switches the release onto SMTP" do
      System.put_env("FORGE_SMTP_HOST", "smtp.example.org")
      System.put_env("FORGE_SMTP_USERNAME", "forge@example.org")
      System.put_env("FORGE_SMTP_PASSWORD", "hunter2")
      System.put_env("SSL_CERT_FILE", "/etc/ssl/certs/ca-bundle.crt")

      config = mailer()

      assert config[:adapter] == Swoosh.Adapters.SMTP
      assert config[:relay] == "smtp.example.org"
      assert config[:port] == 587
      assert config[:username] == "forge@example.org"
      assert config[:password] == "hunter2"
      assert config[:auth] == :always
      assert config[:no_mx_lookups] == true
    end

    # gen_smtp's own default is `[{versions, [...]}]` and no verification at all, on the
    # connection that carries the relay password. Drop the options and this is what notices.
    test "STARTTLS is the default, and the certificate is actually checked" do
      System.put_env("FORGE_SMTP_HOST", "smtp.example.org")
      System.put_env("SSL_CERT_FILE", "/etc/ssl/certs/ca-bundle.crt")

      config = mailer()

      assert config[:ssl] == false
      assert config[:tls] == :always
      assert config[:tls_options][:verify] == :verify_peer
      assert config[:tls_options][:cacertfile] == ~c"/etc/ssl/certs/ca-bundle.crt"
      assert config[:tls_options][:server_name_indication] == ~c"smtp.example.org"

      # Without this, a certificate valid for any host verifies against every host: `verify_peer`
      # checks the chain, and the hostname match is a separate step OTP will skip by default for
      # a protocol it does not recognise.
      assert is_function(config[:tls_options][:customize_hostname_check][:match_fun], 2)
    end

    # Implicit TLS is a different key for the same check: gen_smtp makes that connection with
    # `sockopts` and never looks at `tls_options`, so verification set on the wrong one is
    # verification that does not happen.
    test "implicit TLS verifies through sockopts instead" do
      System.put_env("FORGE_SMTP_HOST", "smtp.example.org")
      System.put_env("FORGE_SMTP_TLS", "ssl")
      System.put_env("FORGE_SMTP_PORT", "465")
      System.put_env("FORGE_SMTP_CACERTFILE", "/srv/relay-ca.pem")

      config = mailer()

      assert config[:ssl] == true
      assert config[:port] == 465
      assert config[:sockopts][:verify] == :verify_peer
      assert config[:sockopts][:cacertfile] == ~c"/srv/relay-ca.pem"
      refute Keyword.has_key?(config, :tls_options)
    end

    # The named file wins over the ambient one, because a relay with its own CA is exactly the
    # case where the system bundle is the wrong answer.
    test "FORGE_SMTP_CACERTFILE outranks SSL_CERT_FILE" do
      System.put_env("FORGE_SMTP_HOST", "smtp.example.org")
      System.put_env("SSL_CERT_FILE", "/etc/ssl/certs/ca-bundle.crt")
      System.put_env("FORGE_SMTP_CACERTFILE", "/srv/relay-ca.pem")

      assert mailer()[:tls_options][:cacertfile] == ~c"/srv/relay-ca.pem"
    end

    # Not asserted, deliberately: with neither file named the anchors come from
    # `:public_key.cacerts_get/0`, which reads the machine's own trust store and raises on a
    # machine that has none. A test of that is a test of the machine the suite runs on.

    # A relay that wants no credentials must not be offered `nil` as a username, which is what
    # gen_smtp's `:if_available` would do with the keys present and empty.
    test "no username means no authentication rather than an empty one" do
      System.put_env("FORGE_SMTP_HOST", "smtp.example.org")
      System.put_env("SSL_CERT_FILE", "/etc/ssl/certs/ca-bundle.crt")

      config = mailer()

      assert config[:auth] == :never
      refute Keyword.has_key?(config, :username)
      refute Keyword.has_key?(config, :password)
    end

    test "a TLS mode that is not one is refused at boot rather than ignored" do
      System.put_env("FORGE_SMTP_HOST", "smtp.example.org")
      System.put_env("FORGE_SMTP_TLS", "maybe")
      System.put_env("SSL_CERT_FILE", "/etc/ssl/certs/ca-bundle.crt")

      assert_raise RuntimeError, ~r/FORGE_SMTP_TLS must be ssl, starttls or none/, &mailer/0
    end

    # The compiled default is `contact@example.com`, an address no node owns and a relay refuses.
    test "FORGE_MAIL_FROM replaces the placeholder sender" do
      System.put_env("FORGE_MAIL_FROM", "forge@example.org")

      assert get_in(release(), [:forge, :mail_from]) == {"Forge", "forge@example.org"}

      System.put_env("FORGE_MAIL_FROM_NAME", "acme forge")
      assert get_in(release(), [:forge, :mail_from]) == {"acme forge", "forge@example.org"}
    end
  end

  describe "OIDC providers" do
    # The key is written even when nobody configured an issuer, because `Oidc.providers/0`
    # reading an absent key and reading an empty list are otherwise the same answer.
    test "a node with no issuers still says so" do
      assert oidc()[:providers] == []
    end

    test "a named provider is built from its own prefixed variables" do
      System.put_env("FORGE_OIDC_PROVIDERS", "acme")
      System.put_env("FORGE_OIDC_ACME_ISSUER", "https://id.acme.example")
      System.put_env("FORGE_OIDC_ACME_CLIENT_ID", "forge")
      System.put_env("FORGE_OIDC_ACME_CLIENT_SECRET", "sh!")

      assert [provider] = oidc()[:providers]
      assert provider.id == "acme"
      assert provider.issuer == "https://id.acme.example"
      assert provider.client_id == "forge"
      assert provider.client_secret == "sh!"

      # The two defaults: the id stands in for a display name, and the scope is the one that
      # actually yields an address. `openid` is added by assent and is not named here.
      assert provider.name == "acme"
      assert provider.scope == "email profile"

      # Almost every issuer, and what `assent` would assume anyway.
      assert provider.id_token_alg == "RS256"
    end

    # An issuer on anything else could not be used at all before this existed: `assent` compares
    # the token's `alg` against one expected value, so the node refused every login and said only
    # what it says when an issuer is unreachable.
    test "an issuer that signs with something other than RS256 can be named" do
      System.put_env("FORGE_OIDC_PROVIDERS", "acme")
      System.put_env("FORGE_OIDC_ACME_ISSUER", "https://id.acme.example")
      System.put_env("FORGE_OIDC_ACME_CLIENT_ID", "forge")
      System.put_env("FORGE_OIDC_ACME_CLIENT_SECRET", "sh!")
      System.put_env("FORGE_OIDC_ACME_ID_TOKEN_ALG", "ES256")

      assert [provider] = oidc()[:providers]
      assert provider.id_token_alg == "ES256"
    end

    test "the display name and the scope can each be set" do
      System.put_env("FORGE_OIDC_PROVIDERS", "acme")
      System.put_env("FORGE_OIDC_ACME_ISSUER", "https://id.acme.example")
      System.put_env("FORGE_OIDC_ACME_CLIENT_ID", "forge")
      System.put_env("FORGE_OIDC_ACME_CLIENT_SECRET", "sh!")
      System.put_env("FORGE_OIDC_ACME_NAME", "Acme SSO")
      System.put_env("FORGE_OIDC_ACME_SCOPE", "email profile groups")

      assert [provider] = oidc()[:providers]
      assert provider.name == "Acme SSO"
      assert provider.scope == "email profile groups"
    end

    # The failure this prevents is a node that boots believing it has an issuer and answers every
    # login with a crash, instead of refusing to start where an operator can see it. `@enforce_keys`
    # does not catch it: it wants the key present, not the value non-nil.
    test "a provider named but not configured stops the release booting" do
      System.put_env("FORGE_OIDC_PROVIDERS", "acme")
      System.put_env("FORGE_OIDC_ACME_ISSUER", "https://id.acme.example")
      System.put_env("FORGE_OIDC_ACME_CLIENT_ID", "forge")

      assert_raise RuntimeError, ~r/FORGE_OIDC_ACME_CLIENT_SECRET is missing/, &oidc/0
    end

    test "each of the three required variables is required" do
      System.put_env("FORGE_OIDC_PROVIDERS", "acme")

      assert_raise RuntimeError, ~r/FORGE_OIDC_ACME_ISSUER is missing/, &oidc/0

      System.put_env("FORGE_OIDC_ACME_ISSUER", "https://id.acme.example")
      assert_raise RuntimeError, ~r/FORGE_OIDC_ACME_CLIENT_ID is missing/, &oidc/0
    end

    # An id is a URL segment and a variable-name fragment, and those disagree about punctuation.
    # Without the mangling, `my-idp` looks for `FORGE_OIDC_MY-IDP_ISSUER`, which no shell can set.
    test "an id with punctuation in it maps to a variable name a shell can export" do
      System.put_env("FORGE_OIDC_PROVIDERS", "my-idp")
      System.put_env("FORGE_OIDC_MY_IDP_ISSUER", "https://id.example.org")
      System.put_env("FORGE_OIDC_MY_IDP_CLIENT_ID", "forge")
      System.put_env("FORGE_OIDC_MY_IDP_CLIENT_SECRET", "sh!")

      assert [provider] = oidc()[:providers]
      assert provider.id == "my-idp"
      assert provider.issuer == "https://id.example.org"
    end

    test "the list is split on commas and tolerates the spaces around them" do
      System.put_env("FORGE_OIDC_PROVIDERS", " acme , my-idp ,")
      System.put_env("FORGE_OIDC_ACME_ISSUER", "https://id.acme.example")
      System.put_env("FORGE_OIDC_ACME_CLIENT_ID", "forge")
      System.put_env("FORGE_OIDC_ACME_CLIENT_SECRET", "sh!")
      System.put_env("FORGE_OIDC_MY_IDP_ISSUER", "https://id.example.org")
      System.put_env("FORGE_OIDC_MY_IDP_CLIENT_ID", "forge")
      System.put_env("FORGE_OIDC_MY_IDP_CLIENT_SECRET", "sh!")

      assert ["acme", "my-idp"] = Enum.map(oidc()[:providers], & &1.id)
    end
  end
end
