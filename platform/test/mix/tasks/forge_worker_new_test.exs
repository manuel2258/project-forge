defmodule Mix.Tasks.Forge.Worker.NewTest do
  @moduledoc """
  What `mix forge.worker.new` prints is the whole environment a hand-provisioned machine needs.

  This is tested rather than left to review because the failure is silent in every direction an
  operator can look: a machine minted with a piece missing joins the channel, reports `ready`,
  appears in `mix forge.worker.list`, is scheduled — and then fails every job it is given.
  """

  use Forge.DataCase, async: false

  alias Forge.Jobs
  alias Mix.Tasks.Forge.Worker.New

  setup do
    previous = Application.get_env(:forge, Jobs, [])
    on_exit(fn -> Application.put_env(:forge, Jobs, previous) end)
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  defp configure(opts) do
    current = Application.get_env(:forge, Jobs, [])
    Application.put_env(:forge, Jobs, Keyword.merge(current, opts))
  end

  defp mint(args \\ []) do
    New.run(args)
    assert_received {:mix_shell, :info, [output]}

    Map.new(String.split(output, "\n"), fn line ->
      [name, value] = String.split(line, "=", parts: 2)
      {name, value}
    end)
  end

  test "the machine gets an identity, a token and somewhere to dial" do
    configure(platform_url: "http://platform.example:4000")

    env = mint()

    assert env["FORGE_WORKER_ID"] =~ ~r/^[0-9a-f-]{36}$/
    assert byte_size(env["FORGE_WORKER_TOKEN"]) > 20
    assert env["FORGE_PLATFORM_URL"] == "http://platform.example:4000"
  end

  test "the agent's credential is minted with the rest of it" do
    configure(harness_opts: [credential: {:oauth, "sk-oauth-xyz"}, model: "claude-opus-5"])

    env = mint()

    assert env["CLAUDE_CODE_OAUTH_TOKEN"] == "sk-oauth-xyz"
    assert env["FORGE_CLAUDE_MODEL"] == "claude-opus-5"
  end

  test "an api key is minted the same way" do
    configure(harness_opts: [credential: {:api_key, "sk-ant-key"}])

    env = mint()

    assert env["ANTHROPIC_API_KEY"] == "sk-ant-key"
    refute Map.has_key?(env, "CLAUDE_CODE_OAUTH_TOKEN")
  end

  test "--out writes it at 0600 and keeps the credential off stdout" do
    configure(harness_opts: [credential: {:oauth, "sk-oauth-secret"}])
    path = Path.join(System.tmp_dir!(), "worker-#{System.unique_integer([:positive])}.env")
    on_exit(fn -> File.rm(path) end)

    New.run(["--out", path])
    assert_received {:mix_shell, :info, [said]}

    refute said =~ "sk-oauth-secret"
    assert said =~ path

    assert File.read!(path) =~ "CLAUDE_CODE_OAUTH_TOKEN=sk-oauth-secret"
    assert %File.Stat{mode: mode} = File.stat!(path)
    assert Bitwise.band(mode, 0o077) == 0
  end

  test "the row is unmanaged, which is what makes the machine permanent" do
    env = mint()

    worker = Forge.Repo.get!(Forge.Workers.Worker, env["FORGE_WORKER_ID"])
    refute worker.managed
  end
end
