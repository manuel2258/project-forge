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
    refute LocalVm.config_blob(%{worker_id: "w", token: "t", platform_url: "u"}) =~
             "FORGE_SSH_KEY"
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

  test "the config blob carries the identity and nothing about the image" do
    blob =
      LocalVm.config_blob(%{
        worker_id: "w-1",
        token: "the-token",
        platform_url: "http://10.0.2.2:4000"
      })

    # An environment file and nothing else: the same bytes go on the local config disk and into
    # a provider's user data, so there is one shape and the guest has one parser.
    assert blob == """
           FORGE_WORKER_ID=w-1
           FORGE_WORKER_TOKEN=the-token
           FORGE_PLATFORM_URL=http://10.0.2.2:4000
           """

    # No credential given, no line written: the machine still boots and its jobs fail visibly.
    refute blob =~ "ANTHROPIC_API_KEY"
    refute blob =~ "CLAUDE_CODE_OAUTH_TOKEN"
  end

  test "the harness environment is injected at creation" do
    blob =
      LocalVm.config_blob(%{
        worker_id: "w-1",
        token: "the-token",
        platform_url: "http://10.0.2.2:4000",
        harness_env: [{"CLAUDE_CODE_OAUTH_TOKEN", "sk-oauth"}, {"FORGE_CLAUDE_MODEL", "haiku"}]
      })

    assert blob =~ "\nCLAUDE_CODE_OAUTH_TOKEN=sk-oauth\n"
    assert blob =~ "\nFORGE_CLAUDE_MODEL=haiku\n"
  end

  test "the ssh key travels in the same file, as one line the guest can lift out" do
    Application.put_env(
      :forge,
      Provider,
      Keyword.put(Application.get_env(:forge, Provider), :ssh_key, "ssh-ed25519 AAAAC3 me@host\n")
    )

    blob = LocalVm.config_blob(%{worker_id: "w-1", token: "t", platform_url: "u"})

    # One line, newline-terminated by the blob rather than by the key: a trailing newline in the
    # configured value would otherwise split the file and take the rest of it with it.
    assert blob =~ "\nFORGE_SSH_KEY=ssh-ed25519 AAAAC3 me@host\n"
    refute blob =~ "\n\n"
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

    for name <- ["worker.env", "config.iso"] do
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
    assert_receive {:provider_destroy, "fake-w-2", _credential}
  end

  describe "what the local host is holding" do
    setup do
      dir = Path.join(System.tmp_dir!(), "forge-local-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      Application.put_env(
        :forge,
        Provider,
        Keyword.put(Application.get_env(:forge, Provider), :dir, dir)
      )

      %{dir: dir}
    end

    # Reconciliation is not a Hetzner special case: a leak here is an overlay and a QEMU
    # process a `destroy` did not finish removing. It costs disk rather than money, but it is
    # the same question and the same panel answers it.
    test "the machine directories are what it holds", %{dir: dir} do
      File.mkdir_p!(Path.join([dir, "machines", "w-1"]))
      File.mkdir_p!(Path.join([dir, "machines", "w-2"]))

      assert {:ok, instances} = LocalVm.list(nil)
      assert Enum.map(instances, & &1.provider_id) |> Enum.sort() == ["w-1", "w-2"]
      assert Enum.all?(instances, &(&1.name =~ "forge-"))

      # A directory with no pidfile is a machine that was made and never booted.
      assert Enum.all?(instances, &(&1.status == "pending"))
    end

    # No directory is no machines, not an error: nothing has been created on this host yet, and
    # a panel that errored on a fresh node would report a problem where there is none.
    test "a host that has created nothing holds nothing", %{dir: dir} do
      refute File.dir?(Path.join(dir, "machines"))
      assert {:ok, []} = LocalVm.list(nil)
    end

    test "the configured image is the one image it offers" do
      assert {:ok, [image]} = LocalVm.images(nil)
      assert image.id == "/var/lib/forge/worker.qcow2"
      assert image.name == "worker.qcow2"
    end

    # A node with no image cannot make a machine, and the form should offer nothing rather than
    # an entry that would fail at create.
    test "a host with no image offers none" do
      Application.put_env(
        :forge,
        Provider,
        Keyword.delete(Application.get_env(:forge, Provider), :image)
      )

      assert {:ok, []} = LocalVm.images(nil)
    end
  end

  describe "the driver registry" do
    test "a name resolves to the module configured for it" do
      assert {:ok, Provider.Fake} = Provider.driver("fake")
      assert {:ok, LocalVm} = Provider.driver("local")
    end

    test "nothing named is the default" do
      assert Provider.driver(nil) == Provider.driver(Provider.default())
    end

    # **Never the default**, and this is the assertion worth having: a worker row naming a
    # provider this node no longer has configured is a machine nothing can destroy, and quietly
    # reaching for whichever driver *is* configured would ask it to destroy an id that means
    # something else entirely there.
    # A name no node will ever configure, rather than one that happens not to be configured
    # here: this test used `"hetzner"` until there was a Hetzner driver, at which point it
    # started asserting that a real provider was unknown.
    test "a name nothing is configured for is an error, not a fallback" do
      assert {:error, {:unknown_provider, "nowhere"}} = Provider.driver("nowhere")
      assert {:error, {:unknown_provider, "nowhere"}} = Provider.destroy("nowhere", "srv-1")
      assert {:error, {:unknown_provider, "nowhere"}} = Provider.shapes("nowhere")

      assert {:error, {:unknown_provider, "nowhere"}} =
               Provider.create(%{
                 provider: "nowhere",
                 worker_id: "w-1",
                 token: "t",
                 platform_url: "http://x"
               })
    end

    test "names lists every provider this node can speak to" do
      assert Provider.names() == ["fake", "hetzner", "local"]
    end

    test "a call reaches the driver its name selects, not the default" do
      Provider.Fake.watch()

      assert :ok = Provider.destroy("fake", "fake-w-9")
      assert_receive {:provider_destroy, "fake-w-9", _credential}

      # The local driver is not the default here, and reaching it is what proves the name is
      # doing the selecting rather than the configuration.
      assert {:ok, :gone} = Provider.status("local", "not-a-machine")
    end
  end

  defp after_flag(argv, flag), do: argv |> Enum.drop_while(&(&1 != flag)) |> Enum.at(1)
  defp megabytes_after(argv, flag), do: String.to_integer(after_flag(argv, flag)) * 1024 * 1024
  defp cores_after(argv, flag), do: String.to_integer(after_flag(argv, flag))

  describe "shapes" do
    test "the local driver sells exactly what the operator configured it to be" do
      assert {:ok, [shape]} = Provider.shapes("local")
      assert shape.cores == 2
      assert shape.memory == 4096 * 1024 * 1024

      # Nil rather than a name: there is no vendor catalogue to name anything from, and
      # `opts.size` would have nothing to read it back into.
      assert shape.size == nil
    end

    # **The unconfigured node, which is where the two used to disagree.** With `:cpus` and
    # `:memory_mb` set — as the setup above sets them, and as any node with
    # `FORGE_WORKER_MEMORY_MB` in its environment has them — `shapes/1` and `command/4` read the
    # same value and agree no matter what the fallbacks say. Without them they fell back to two
    # different numbers written a hundred lines apart: the catalogue offered 4 GiB and 2 cores
    # while the VM was booted with `-m 16384 -smp 4`. An operator picking a machine size on the
    # templates page was told a quarter of the memory the host would actually be asked for, and
    # `docs/deploy.md` § Known limits sent them to that number to size the host.
    #
    # Asserted against the argv rather than against a literal, so the two cannot drift again.
    test "the catalogue matches the VM on a node that configured neither" do
      Application.put_env(
        :forge,
        Provider,
        :forge |> Application.get_env(Provider, []) |> Keyword.drop([:cpus, :memory_mb])
      )

      assert {:ok, [shape]} = Provider.shapes("local")

      {_qemu, argv} =
        Forge.Provider.LocalVm.command("/tmp/forge-shape-test", "worker-1", "/dev/null")

      assert shape.memory == megabytes_after(argv, "-m")
      assert shape.cores == cores_after(argv, "-smp")
    end

    test "a driver is asked with the credential it was given" do
      Provider.Fake.watch()

      assert {:ok, shapes} = Provider.shapes("fake", %{"token" => "secret"})
      assert_receive {:provider_shapes, %{"token" => "secret"}}
      assert Enum.map(shapes, & &1.size) == ["small", "large"]
    end
  end
end
