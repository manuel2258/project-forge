defmodule Forge.Provider.LocalVm do
  @moduledoc """
  A local virtual machine under QEMU, booted from the NixOS worker image. The PoC's only
  provider; see `docs/design/worker-tier.md`.

  The image is never written: each machine gets a copy-on-write overlay on it, and destroying
  the machine removes the overlay. Networking is user-mode with no inbound ports, because
  nothing needs to reach the worker — it dials out.

  The machine learns its worker id, its token and where the platform is from a small disk this
  driver builds and attaches, labelled so the image knows it by name. On a provider the same
  bytes go in the server's user data instead; see `docs/design/worker-tier.md` § How a machine
  learns what it is, which is also where the reasoning for dropping cloud-init lives.

  **This is the part of the milestone that cannot be exercised without KVM.** What is tested
  is the command this builds and the states it maps; that a machine actually boots is the
  operator's machine to prove, and M4 is the measurement that proves it.
  """

  @behaviour Forge.Provider

  alias Forge.Provider
  alias Forge.Provider.MachineConfig

  # The contract with the image: a filesystem with this label holding this file. See
  # `docs/design/worker-tier.md` § How a machine learns what it is.
  @config_label "forge-config"
  @config_file "worker.env"

  require Logger

  @impl Provider
  def create(opts) do
    id = opts.worker_id
    dir = machine_dir(id)

    # Before anything is written: a driver with no image to boot, or no firmware to boot it
    # with, has nothing to do, and the error should name that rather than whatever fails first.
    with {:ok, image} <- image(),
         {:ok, code, vars} <- firmware(),
         :ok <- File.mkdir_p(dir),
         :ok <- write_overlay(dir, image),
         :ok <- write_firmware_vars(dir, vars),
         :ok <- write_config(dir, opts),
         :ok <- write_config_image(dir),
         {:ok, port} <- boot(dir, id, code) do
      File.write!(Path.join(dir, "qemu.port"), inspect(port))
      {:ok, %{provider_id: id, address: nil}}
    end
  end

  @impl Provider
  def destroy(provider_id, _credential \\ nil) do
    dir = machine_dir(provider_id)

    case pid(dir) do
      nil -> :ok
      pid -> System.cmd("kill", [to_string(pid)], stderr_to_stdout: true) |> elem(1) |> kill_ok()
    end

    File.rm_rf!(dir)
    :ok
  end

  @impl Provider
  def status(provider_id, _credential \\ nil) do
    dir = machine_dir(provider_id)

    cond do
      not File.dir?(dir) -> {:ok, :gone}
      pid(dir) == nil -> {:ok, :pending}
      running?(pid(dir)) -> {:ok, :running}
      true -> {:ok, :gone}
    end
  end

  @doc """
  The one shape this driver sells: whatever the operator configured the VM to be.

  There is no catalogue to fetch, because there is no vendor — a local machine is as big as
  `FORGE_WORKER_CPUS` and `FORGE_WORKER_MEMORY_MB` say and no bigger. The `size` is nil rather
  than a name, since nothing here would read one back
  (`docs/design/provisioning.md` § Where a machine comes from).

  It is reported all the same, rather than left unimplemented, so the template UI has something
  to offer for the local provider and one code path serves both. A driver that answered nothing
  would need a special case somewhere, and the special case is what the behaviour exists to
  avoid.
  """
  # **One default per key, because there were two.** `shapes/1` advertised 4096 MiB and 2 cores
  # while `command/4` booted the VM with 16384 and 4 — the same `:memory_mb` and `:cpus`, read
  # through the same `Forge.Provider.config/2`, with different fallbacks a few hundred lines
  # apart. `shapes/1` is what the template page offers an operator when they pick a machine size,
  # so the node advertised a quarter of the memory it would actually demand of the host, and
  # `docs/deploy.md` § Known limits told them to size the host from it.
  #
  # The VM's numbers win: the shape is a description of the machine that will be made, so when
  # the two disagree it is the description that is wrong.
  @default_memory_mb 16_384
  @default_cpus 4

  @impl Provider
  def shapes(_credential) do
    {:ok,
     [
       %{
         size: nil,
         memory: Provider.config(:memory_mb, @default_memory_mb) * 1024 * 1024,
         cores: Provider.config(:cpus, @default_cpus),
         price_hourly: nil
       }
     ]}
  end

  @doc """
  The machines this host is holding, read from the directories `create/1` makes.

  Implemented rather than stubbed so reconciliation is not a Hetzner special case: a leak here
  is an overlay and a QEMU process left behind by a `destroy` that did not finish, and it costs
  disk rather than money — but it is the same question and the same panel answers it.
  """
  @impl Provider
  def list(_credential) do
    case File.ls(machines_dir()) do
      {:ok, ids} -> {:ok, Enum.map(ids, &local_instance/1)}
      # No directory is no machines, not an error: nothing has been created on this host yet.
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, {:local, reason}}
    end
  end

  defp local_instance(id) do
    {:ok, state} = status(id)
    %{provider_id: id, name: "forge-" <> id, status: to_string(state), created_at: nil}
  end

  @doc """
  The one image this host boots, which is whatever the operator pointed it at.

  There is no catalogue and no upload: `FORGE_WORKER_IMAGE` is a path on this machine that
  `nix build .#worker-image` produced. Reported all the same so the template form has something
  to offer for the local provider and one code path serves both.
  """
  @impl Provider
  def images(_credential) do
    case image() do
      {:ok, path} -> {:ok, [%{id: path, name: Path.basename(path), status: "available"}]}
      {:error, _reason} -> {:ok, []}
    end
  end

  @doc """
  No credential: a machine on this host is made by this host, and there is no account to reach.

  An empty list rather than an unimplemented callback, so the form for a local template simply
  has no secret to ask for instead of the page needing to know which providers are special.
  """
  @impl Provider
  def credential_fields, do: []

  @doc """
  Nothing: a local machine boots this host's image at this host's size, and `create/1` reads
  neither from the template.
  """
  @impl Provider
  def required_template_fields, do: []

  @doc """
  Nothing: a machine on this host costs no more for being kept a minute longer, so an idle one
  goes at its period (`docs/design/worker-tier.md` § The hour already paid for).
  """
  @impl Provider
  def billed_increment_ms, do: nil

  @doc """
  The QEMU invocation for a machine. Public because it is the part of this driver that can be
  checked without a hypervisor, and a test that checked something else would be checking
  nothing.
  """
  @spec command(String.t(), String.t(), String.t(), pos_integer() | nil) ::
          {String.t(), [String.t()]}
  def command(dir, worker_id, firmware_code, ssh_port \\ nil) do
    {config(:qemu, "qemu-system-x86_64"),
     [
       "-name",
       "forge-worker-" <> worker_id,
       "-machine",
       "accel=kvm:tcg",
       "-cpu",
       "host",
       "-smp",
       to_string(config(:cpus, @default_cpus)),
       "-m",
       to_string(config(:memory_mb, @default_memory_mb)),
       # Not `-nographic`, which QEMU refuses to combine with `-daemonize`: the console goes
       # to a file below, and nothing is meant to watch it interactively.
       "-display",
       "none",
       # The image boots through systemd-boot from an ESP, so the machine needs UEFI firmware.
       # The variable store is per machine and writable; the code is shared and is not.
       "-drive",
       "if=pflash,format=raw,unit=0,readonly=on,file=#{firmware_code}",
       "-drive",
       "if=pflash,format=raw,unit=1,file=#{Path.join(dir, "firmware-vars.fd")}",
       "-drive",
       "file=#{Path.join(dir, "disk.qcow2")},if=virtio,format=qcow2",
       "-drive",
       "file=#{Path.join(dir, "config.iso")},if=virtio,format=raw,readonly=on",
       # User-mode networking: the guest reaches the platform, nothing reaches the guest —
       # unless the operator asked for the ssh door below, which is off by default.
       "-netdev",
       "user,id=net0" <> hostfwd(ssh_port),
       "-device",
       "virtio-net-pci,netdev=net0",
       "-pidfile",
       Path.join(dir, "qemu.pid"),
       "-daemonize",
       "-serial",
       "file:" <> Path.join(dir, "console.log")
     ]}
  end

  # The ssh door (`docs/design/worker-tier.md` § The provider driver): nothing by default, and a
  # forward from loopback when the operator configured a key to reach it with.
  defp hostfwd(nil), do: ""
  defp hostfwd(port), do: ",hostfwd=tcp:127.0.0.1:#{port}-:22"

  @doc """
  What this machine is told about itself, on its config disk.

  `Forge.Provider.MachineConfig` holds the lines every driver produces; this adds the one that
  is only ever local.
  """
  @spec config_blob(Provider.opts()) :: String.t()
  def config_blob(opts), do: MachineConfig.blob(opts, ssh_key_line(config(:ssh_key)))

  # The ssh door travels in the same file rather than by a mechanism of its own; the config unit
  # takes it out again before the release ever sees it.
  defp ssh_key_line(key) when is_binary(key), do: ["FORGE_SSH_KEY=#{String.trim(key)}"]
  defp ssh_key_line(_key), do: []

  # The worker token and the harness credential are in here, so it is written the way a secret
  # is written: to the owner only, and before anything is put in it.
  defp write_config(dir, opts) do
    write_private(Path.join(dir, @config_file), config_blob(opts))
    :ok
  end

  defp write_private(path, contents) do
    File.write!(path, "")
    File.chmod!(path, 0o600)
    File.write!(path, contents)
  end

  # The label is the contract: the guest looks for a filesystem called this and reads one file
  # out of it. Building it needs a tool that is on the operator's machine and in the devshell,
  # not in the release.
  defp write_config_image(dir) do
    args = [
      "-output",
      Path.join(dir, "config.iso"),
      "-volid",
      @config_label,
      "-joliet",
      "-rock",
      Path.join(dir, @config_file)
    ]

    case System.cmd(config(:iso_tool, "genisoimage"), args, stderr_to_stdout: true) do
      # The image carries the environment file, so it carries the token too.
      {_out, 0} -> File.chmod(Path.join(dir, "config.iso"), 0o600)
      {out, code} -> {:error, {:config_image, code, out}}
    end
  end

  defp image do
    case config(:image) do
      nil -> {:error, :no_image}
      image -> {:ok, image}
    end
  end

  # OVMF, as two files: the code, shared and read-only, and a template for the variable store,
  # which each machine gets its own writable copy of. Both are paths on the platform's host,
  # so they are configuration rather than anything this module can find.
  defp firmware do
    case {config(:firmware_code), config(:firmware_vars)} do
      {code, vars} when is_binary(code) and is_binary(vars) -> {:ok, code, vars}
      _other -> {:error, :no_firmware}
    end
  end

  defp write_firmware_vars(dir, vars) do
    target = Path.join(dir, "firmware-vars.fd")

    with {:ok, _bytes} <- File.copy(vars, target), do: File.chmod(target, 0o600)
  end

  # The image is read-only and shared: every machine writes to its own overlay. The overlay is
  # larger than the image it backs, because the image is built small and the machine's disk is
  # what a Nix store, a seed and several build directories have to fit in; the guest grows its
  # partition and filesystem into it on the first boot.
  defp write_overlay(dir, image) do
    args = [
      "create",
      "-f",
      "qcow2",
      "-F",
      "qcow2",
      "-b",
      image,
      Path.join(dir, "disk.qcow2"),
      "#{config(:disk_gb, 40)}G"
    ]

    case System.cmd(config(:qemu_img, "qemu-img"), args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:overlay, code, out}}
    end
  end

  # A door into the guest, for the measurement harness and for reading a job's stderr when
  # something went wrong on a machine that is about to be destroyed. Off unless the operator
  # configured a key: `docs/design/worker-tier.md` § The provider driver. The port is written
  # beside the machine because it is chosen here and read from outside.
  defp ssh_port(dir) do
    with base when is_integer(base) <- config(:ssh_port),
         port when is_integer(port) <- free_port(base, base + 63) do
      File.write!(Path.join(dir, "ssh.port"), to_string(port))
      port
    else
      _other -> nil
    end
  end

  defp free_port(port, last) when port > last, do: nil

  defp free_port(port, last) do
    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, reuseaddr: false]) do
      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)
        port

      {:error, _reason} ->
        free_port(port + 1, last)
    end
  end

  defp boot(dir, worker_id, firmware_code) do
    {executable, args} = command(dir, worker_id, firmware_code, ssh_port(dir))

    case System.cmd(executable, args, stderr_to_stdout: true) do
      {_out, 0} -> {:ok, pid(dir)}
      {out, code} -> {:error, {:qemu, code, out}}
    end
  end

  defp pid(dir) do
    case File.read(Path.join(dir, "qemu.pid")) do
      {:ok, contents} ->
        case Integer.parse(String.trim(contents)) do
          {pid, _rest} -> pid
          :error -> nil
        end

      {:error, _reason} ->
        nil
    end
  end

  defp running?(pid), do: File.dir?("/proc/#{pid}")

  defp kill_ok(0), do: :ok

  defp kill_ok(code) do
    Logger.warning("could not signal the machine's process (#{code}); removing it anyway")
    :ok
  end

  defp machine_dir(worker_id), do: Path.join(machines_dir(), worker_id)
  defp machines_dir, do: Path.join(root(), "machines")

  defp root, do: config(:dir) || Path.join(Forge.Jobs.data_dir(), "provider")

  defp config(key, default \\ nil), do: Forge.Provider.config(key, default)
end
