defmodule ForgeWorker.RuntimeConfigTest do
  @moduledoc """
  What `config/runtime.exs` decides for a worker release, read the way a release reads it.

  The whole file sits behind `if config_env() != :test`, so nothing in it applies to this suite
  and nothing in this suite could reach it by accident. `Config.Reader` with `env: :prod` is what
  a release does, and it is the only way to assert on these values at all.

  **One rule lives here and nowhere else: a variable that is present and empty is not a
  setting.** `ClaudeCode.command/3` reads the executable as
  `Keyword.get(opts, :executable, "claude")`, which hands back `""` for a key that is present and
  empty — so a machine booted with `FORGE_CLAUDE_EXECUTABLE=` spawned
  `nix develop … --command "" …` and failed every job on it. The fallback to `claude` only happens
  when the key is *absent*, which is what the filter in that file makes it. The platform's own
  `runtime_config_test.exs` cannot cover this: the platform spawns no harness and never forwards
  this key to a machine.
  """

  use ExUnit.Case, async: false

  @runtime Path.expand("../../config/runtime.exs", __DIR__)

  # Cleared for the duration, or whatever is in the shell that ran the suite decides what this
  # reads — and all three are what is under test.
  @cleared ~w(FORGE_CLAUDE_EXECUTABLE FORGE_CLAUDE_MODEL FORGE_CLAUDE_EFFORT
              FORGE_NIX_ENV FORGE_SLICE)

  setup do
    previous = Map.new(@cleared, &{&1, System.get_env(&1)})
    Enum.each(@cleared, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  defp harness_opts do
    @runtime
    |> Config.Reader.read!(env: :prod)
    |> get_in([:forge_worker, :harness_opts]) || []
  end

  test "a harness variable set to nothing configures nothing" do
    System.put_env("FORGE_CLAUDE_EXECUTABLE", "")
    System.put_env("FORGE_CLAUDE_MODEL", "")
    System.put_env("FORGE_CLAUDE_EFFORT", "")

    opts = harness_opts()

    refute Keyword.has_key?(opts, :executable)
    refute Keyword.has_key?(opts, :model)
    refute Keyword.has_key?(opts, :effort)

    # The whole point of the key being absent rather than empty: this is what the driver does
    # with it, and `""` would have won over the default.
    assert Keyword.get(opts, :executable, "claude") == "claude"
  end

  test "a harness variable that names something is configured" do
    System.put_env("FORGE_CLAUDE_EXECUTABLE", "/bin/claude")
    System.put_env("FORGE_CLAUDE_MODEL", "opus")
    System.put_env("FORGE_CLAUDE_EFFORT", "high")

    opts = harness_opts()

    assert opts[:executable] == "/bin/claude"
    assert opts[:model] == "opus"
    assert opts[:effort] == "high"
  end

  # **No credential, on a machine either** (`docs/design/credentials.md` § The node's own key is
  # gone): a job brings its own in the assignment. A machine upgraded with either variable still
  # set must not have it reach the harness.
  test "no machine-wide agent credential is read, whatever the environment says" do
    System.put_env("ANTHROPIC_API_KEY", "sk-ant-api03-machine")
    System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-machine")

    on_exit(fn ->
      System.delete_env("ANTHROPIC_API_KEY")
      System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")
    end)

    config = Config.Reader.read!(@runtime, env: :prod)

    refute Keyword.has_key?(get_in(config, [:forge_worker, :harness_opts]) || [], :credential)
    refute inspect(config, limit: :infinity) =~ "sk-ant-api03-machine"
    refute inspect(config, limit: :infinity) =~ "sk-ant-oat01-machine"
  end
end
