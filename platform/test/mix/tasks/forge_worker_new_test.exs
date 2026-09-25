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
    # The machine has to be somebody's, and with no `--owner` it is the node's only node admin.
    %{admin: Forge.AccountsFixtures.node_admin_fixture()}
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

  test "the model is minted with the rest of it" do
    configure(harness_opts: [model: "claude-opus-5"])

    assert mint()["FORGE_CLAUDE_MODEL"] == "claude-opus-5"
  end

  # **A machine holds no agent credential**: each job brings its own in its assignment
  # (`docs/design/credentials.md`). This command used to print the node's; even a node configured
  # with one — which `config/runtime.exs` no longer reads — gets none minted into a machine.
  test "no agent credential is minted, whatever the node is configured with" do
    configure(harness_opts: [credential: {:oauth, "sk-oauth-node"}, model: "claude-opus-5"])

    env = mint()

    refute Map.has_key?(env, "CLAUDE_CODE_OAUTH_TOKEN")
    refute Map.has_key?(env, "ANTHROPIC_API_KEY")
    refute Enum.any?(Map.values(env), &(&1 =~ "sk-oauth-node"))
  end

  test "--out writes it at 0600 and keeps the worker token off stdout" do
    path = Path.join(System.tmp_dir!(), "worker-#{System.unique_integer([:positive])}.env")
    on_exit(fn -> File.rm(path) end)

    New.run(["--out", path])
    assert_received {:mix_shell, :info, [said]}

    written = File.read!(path)
    [_, token] = Regex.run(~r/FORGE_WORKER_TOKEN=(\S+)/, written)

    refute said =~ token
    assert said =~ path
    assert %File.Stat{mode: mode} = File.stat!(path)
    assert Bitwise.band(mode, 0o077) == 0
  end

  test "the row is unmanaged, which is what makes the machine permanent" do
    env = mint()

    worker = Forge.Repo.get!(Forge.Workers.Worker, env["FORGE_WORKER_ID"])
    refute worker.managed
  end

  # A machine is somebody's (`docs/design/identity.md` § Workers), and the command line resolves
  # whose the way `register_project/2` does: a named account, or the only node admin.
  test "the machine belongs to the node's only admin, or to whoever is named", %{admin: admin} do
    env = mint()
    assert Forge.Repo.get!(Forge.Workers.Worker, env["FORGE_WORKER_ID"]).user_id == admin.id

    other = Forge.AccountsFixtures.user_fixture()
    env = mint(["--owner", other.email])
    assert Forge.Repo.get!(Forge.Workers.Worker, env["FORGE_WORKER_ID"]).user_id == other.id
  end

  test "it will not guess between two node admins, and makes nothing when it will not" do
    Forge.AccountsFixtures.node_admin_fixture()

    assert_raise Mix.Error, ~r/more than one node admin/, fn -> New.run([]) end
    assert Forge.Repo.aggregate(Forge.Workers.Worker, :count) == 0
  end

  # With a project, the owner assigns it there — and only a member may, which is checked before
  # the row exists so a refusal leaves nothing behind to retire.
  test "a named project is assigned by the owner, who must be in it", %{admin: admin} do
    {:ok, project} =
      Forge.Projects.register(
        %{name: "minted", repo_path: Path.join(Forge.GitFixtures.tmp_dir("wn"), "p.git")},
        admin
      )

    env = mint(["minted"])
    worker = Forge.Repo.get!(Forge.Workers.Worker, env["FORGE_WORKER_ID"])
    assert [%{id: id}] = Forge.Workers.projects(worker)
    assert id == project.id

    outsider = Forge.AccountsFixtures.user_fixture()

    assert_raise Mix.Error, ~r/not a member of minted/, fn ->
      New.run(["minted", "--owner", outsider.email])
    end

    assert Forge.Repo.aggregate(Forge.Workers.Worker, :count) == 1
  end
end
