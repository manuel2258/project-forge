defmodule Forge.ProviderTest do
  @moduledoc """
  The local VM driver, as far as a machine without KVM can check it: the command it builds and
  the cloud-init it writes. That a machine boots from these is the operator's to prove, and
  M4 is the measurement that proves it — see `docs/design/worker-tier.md` § What cannot be
  verified without the operator's machine.
  """

  use ExUnit.Case, async: false

  alias Forge.Provider
  alias Forge.Provider.LocalVm

  setup do
    previous = Application.get_env(:forge, Provider, [])

    Application.put_env(
      :forge,
      Provider,
      Keyword.merge(previous,
        image: "/var/lib/forge/worker.qcow2",
        firmware_code: "/firmware/OVMF_CODE.fd",
        firmware_vars: "/firmware/OVMF_VARS.fd",
        cpus: 2,
        memory_mb: 4096
      )
    )

    on_exit(fn -> Application.put_env(:forge, Provider, previous) end)
    :ok
  end

  test "the machine gets its own overlay and no inbound ports" do
    {executable, args} =
      LocalVm.command("/var/lib/forge/machines/w-1", "w-1", "/firmware/OVMF_CODE.fd")

    joined = Enum.join(args, " ")

    assert executable == "qemu-system-x86_64"
    assert joined =~ "file=/var/lib/forge/machines/w-1/disk.qcow2"
    assert joined =~ "-netdev user,id=net0"
    refute joined =~ "hostfwd"
    assert joined =~ "-smp 2"
    assert joined =~ "-m 4096"
    assert joined =~ "accel=kvm:tcg"
    assert joined =~ "-pidfile /var/lib/forge/machines/w-1/qemu.pid"
  end

  test "the invocation is one QEMU will accept, and boots the image's firmware" do
    {_executable, args} =
      LocalVm.command("/var/lib/forge/machines/w-1", "w-1", "/firmware/OVMF_CODE.fd")

    # QEMU refuses `-nographic` together with `-daemonize`, so a driver that passes both never
    # starts a machine at all. The console still has somewhere to go.
    assert "-daemonize" in args
    refute "-nographic" in args
    assert args |> Enum.drop_while(&(&1 != "-display")) |> Enum.at(1) == "none"

    joined = Enum.join(args, " ")
    assert joined =~ "if=pflash,format=raw,unit=0,readonly=on,file=/firmware/OVMF_CODE.fd"

    assert joined =~
             "if=pflash,format=raw,unit=1,file=/var/lib/forge/machines/w-1/firmware-vars.fd"

    assert joined =~ "-serial file:/var/lib/forge/machines/w-1/console.log"
  end

  test "the ssh door is shut unless the operator opens it" do
    {_executable, args} =
      LocalVm.command("/var/lib/forge/machines/w-1", "w-1", "/firmware/OVMF_CODE.fd", 2222)

    assert Enum.join(args, " ") =~ "user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22"

    # And no key in the cloud-init while none is configured, so a forwarded port would reach
    # an sshd nobody can authenticate to.
    refute LocalVm.user_data(%{worker_id: "w", token: "t", platform_url: "u"}) =~
             "ssh_authorized_keys"
  end

  test "a driver with no firmware refuses to create rather than booting a machine that hangs" do
    Application.put_env(
      :forge,
      Provider,
      Keyword.drop(Application.get_env(:forge, Provider), [:firmware_code, :firmware_vars])
    )

    assert {:error, :no_firmware} =
             LocalVm.create(%{worker_id: "w-1", token: "t", platform_url: "http://localhost"})
  end

  test "cloud-init carries the identity and nothing about the image" do
    user_data =
      LocalVm.user_data(%{
        worker_id: "w-1",
        token: "the-token",
        platform_url: "http://10.0.2.2:4000"
      })

    assert user_data =~ "FORGE_WORKER_ID=w-1"
    assert user_data =~ "FORGE_WORKER_TOKEN=the-token"
    assert user_data =~ "FORGE_PLATFORM_URL=http://10.0.2.2:4000"
    assert user_data =~ "permissions: \"0600\""
    assert user_data =~ "systemctl, restart, forge-worker.service"

    # No credential given, no line written: the machine still boots and its jobs fail visibly.
    refute user_data =~ "ANTHROPIC_API_KEY"
    refute user_data =~ "CLAUDE_CODE_OAUTH_TOKEN"
  end

  test "the harness environment is injected at creation, indented into the env file" do
    user_data =
      LocalVm.user_data(%{
        worker_id: "w-1",
        token: "the-token",
        platform_url: "http://10.0.2.2:4000",
        harness_env: [{"CLAUDE_CODE_OAUTH_TOKEN", "sk-oauth"}, {"FORGE_CLAUDE_MODEL", "haiku"}]
      })

    # Every line of the file is one indent inside `content: |`, or cloud-init writes YAML
    # instead of an environment file.
    assert user_data =~ "\n      FORGE_WORKER_ID=w-1\n"
    assert user_data =~ "\n      CLAUDE_CODE_OAUTH_TOKEN=sk-oauth\n"
    assert user_data =~ "\n      FORGE_CLAUDE_MODEL=haiku\n"
    assert user_data =~ "\nruncmd:\n"
  end

  test "the cloud-init a machine boots with is written as a secret" do
    dir = Path.join(System.tmp_dir!(), "forge-provider-#{System.unique_integer([:positive])}")
    firmware = Path.join(dir, "vars.fd")
    File.mkdir_p!(dir)
    File.write!(firmware, "not really firmware")
    on_exit(fn -> File.rm_rf!(dir) end)

    Application.put_env(
      :forge,
      Provider,
      Keyword.merge(Application.get_env(:forge, Provider),
        dir: dir,
        firmware_vars: firmware,
        # No hypervisor here: the overlay and the boot are stubbed so the seed, which is
        # written between them, is what this test reaches.
        qemu_img: "true",
        qemu: "false"
      )
    )

    assert {:error, {:qemu, _code, _out}} =
             LocalVm.create(%{
               worker_id: "w-1",
               token: "the-token",
               platform_url: "http://x",
               harness_env: [{"CLAUDE_CODE_OAUTH_TOKEN", "sk-oauth"}]
             })

    for name <- ["user-data", "seed.iso"] do
      path = Path.join([dir, "machines", "w-1", name])
      assert File.exists?(path), "#{name} was not written"
      assert %File.Stat{mode: mode} = File.stat!(path)
      assert Bitwise.band(mode, 0o077) == 0, "#{name} is readable by someone other than us"
    end
  end

  test "a driver with no image refuses to create rather than booting something else" do
    Application.put_env(
      :forge,
      Provider,
      Keyword.delete(Application.get_env(:forge, Provider), :image)
    )

    assert {:error, :no_image} =
             LocalVm.create(%{worker_id: "w-1", token: "t", platform_url: "http://localhost"})
  end

  test "the fake records what it was asked for, which is what the platform's tests read" do
    Provider.Fake.watch()

    assert {:ok, %{provider_id: "fake-w-2"}} =
             Provider.Fake.create(%{worker_id: "w-2", token: "t", platform_url: "http://x"})

    assert_receive {:provider_create, %{worker_id: "w-2"}}
    assert :ok = Provider.Fake.destroy("fake-w-2")
    assert_receive {:provider_destroy, "fake-w-2"}
  end
end
