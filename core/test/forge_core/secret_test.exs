defmodule ForgeCore.SecretTest do
  @moduledoc """
  What a project secret may be called (`docs/design/secrets.md` § Names). The refusals are the
  point: each reserved name below is one that would let a secret redirect a job's traffic or load
  code into its harness.
  """

  use ExUnit.Case, async: true

  alias ForgeCore.Secret

  test "an upper-case environment-variable name is a secret's" do
    for name <- ~w(STRIPE_TEST_KEY X A1 CARGO_REGISTRY_TOKEN) do
      assert Secret.validate_name(name) == :ok, name
    end

    assert Secret.validate_name(String.duplicate("A", 64)) == :ok
  end

  test "anything else is refused for its format" do
    for name <- ["", "stripe_key", "Stripe", "1KEY", "_KEY", "KEY-1", "KEY 1", "KEY\n", "KÉ"] do
      assert Secret.validate_name(name) == {:error, :format}, inspect(name)
    end

    assert Secret.validate_name(String.duplicate("A", 65)) == {:error, :format}
    assert Secret.validate_name(nil) == {:error, :format}
    assert Secret.validate_name(:KEY) == {:error, :format}
  end

  # Ours: one of each prefix and each name, so dropping any entry fails here.
  test "a name the platform, the harness or the job's environment owns is reserved" do
    reserved =
      ~w(FORGE_GIT_TOKEN ANTHROPIC_BASE_URL CLAUDE_CODE_OAUTH_TOKEN NODE_OPTIONS BUN_OPTIONS
         NPM_CONFIG_SCRIPT_SHELL NIX_CONFIG GIT_SSH_COMMAND SSL_CERT_FILE BASH_ENV
         PATH HOME USER LOGNAME SHELL TERM HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY)

    for name <- reserved, do: assert(Secret.validate_name(name) == {:error, :reserved}, name)
  end

  # The harness's own lists: a name from each, so dropping any list from the union fails here.
  # `SHELLOPTS` and `PS4` together run a command in every bash a job starts; each other name is
  # one the harness itself treats as loading or running code.
  test "a name the harness treats as running code is reserved" do
    reserved = %{
      prefixes: ~w(LD_PRELOAD DYLD_INSERT_LIBRARIES LC_ALL DOTNET_STARTUP_HOOKS COR_PROFILER),
      shell: ~w(SHELLOPTS PS4 IFS GCONV_PATH GLOBIGNORE TMP LANG PWD ENV),
      search_paths: ~w(PYTHONPATH CLASSPATH),
      runs_code: ~w(MAKEFLAGS PAGER EDITOR RUSTC_WRAPPER JAVA_TOOL_OPTIONS PERL5OPT GOFLAGS),
      windows: ~w(COMSPEC PATHEXT),
      patterns:
        ~w(LUA_INIT TF_CLI_ARGS_PLAN CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUNNER CC_AARCH64
           DELTA_PAGER SVN_EDITOR HG_EXTERNAL_DIFF)
    }

    for {group, names} <- reserved, name <- names do
      assert Secret.validate_name(name) == {:error, :reserved}, "#{group}: #{name}"
    end
  end

  # A prefix is matched as a prefix, not as a substring: the rule is about what a program reads,
  # and nothing reads `MY_ANTHROPIC_KEY` because of its middle.
  test "a reserved word inside a name is not a reserved name" do
    for name <-
          ~w(APP_ANTHROPIC_KEY MY_PATH HOMEPAGE_TOKEN GITHUB_TOKEN ENVIRONMENT NODEJS_KEY
             CARGO_REGISTRY_TOKEN LDAP_PASSWORD CORS_SECRET CCACHE_KEY TEMPLATE_KEY) do
      assert Secret.validate_name(name) == :ok, name
    end
  end
end
