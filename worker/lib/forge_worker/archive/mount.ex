defmodule ForgeWorker.Archive.Mount do
  @moduledoc """
  Where the archive's folder comes from on this machine (`docs/design/archive.md` § The worker's
  side). A behaviour, as `ForgeWorker.Slice` is, and chosen the same way: `FORGE_ARCHIVE=9p` on the
  image, nothing elsewhere.

  - `NineP` mounts the server's socket with the kernel's 9p client, read-only.
  - `None` is a machine that cannot: the folder holds one file saying so.
  """

  @doc "Makes `dir` show what the server on `socket` serves."
  @callback mount(socket :: Path.t(), dir :: Path.t()) :: :ok | {:error, term()}

  @doc "Removes the mount at `dir`; a `dir` that is not mounted is not an error."
  @callback unmount(dir :: Path.t()) :: :ok | {:error, term()}

  @doc """
  Whether there is a server to start for the folder `dir`: `None` has none. Every implementation in
  production answers the same for every folder; the argument is there so that a test's mount can
  answer for the folders of its own test and for no other's (`ForgeWorker.RecordingMount`).
  """
  @callback serves?(dir :: Path.t()) :: boolean()

  @doc """
  Shows `source`, a directory of the worker's own, at `dir` **read-only** (`docs/design/attachments.md`
  § The folder): the files people attached. A bind mount where the machine can make one; a plain
  copy where it cannot, which `refresh/2` brings up to date after the worker has changed `source`.
  """
  @callback bind_ro(source :: Path.t(), dir :: Path.t()) :: :ok | {:error, term()}

  @doc """
  Makes `dir` show what `source` holds now. A bind mount always does, and has nothing to do; a copy
  is made again.
  """
  @callback refresh(source :: Path.t(), dir :: Path.t()) :: :ok | {:error, term()}

  @doc "The module in use on this machine."
  @spec impl() :: module()
  def impl, do: Application.get_env(:forge_worker, :archive_mount, ForgeWorker.Archive.Mount.None)

  @doc """
  The module the attached files' folder is made by. **Its own setting**, `FORGE_ATTACHMENTS=bind` on
  the image, and not `:archive_mount`'s: a machine can bind a directory without having a kernel
  that speaks 9p, and the other way round.
  """
  @spec attachments_impl() :: module()
  def attachments_impl,
    do: Application.get_env(:forge_worker, :attachments_mount, ForgeWorker.Archive.Mount.None)

  @doc "The options the kernel's client is given, in the order they are passed."
  @spec options() :: [String.t()]
  def options do
    # `ro`, `nosuid`, `nodev` and `noexec` are the mount's own refusal to be written to or run
    # from; the server refuses a write as well, and neither relies on the other.
    ~w(trans=unix version=9p2000.L ro nosuid nodev noexec access=any cache=none)
  end

  @doc "The mounts of a 9p filesystem in `/proc/self/mountinfo` text, as the paths they are at."
  @spec mounted(String.t()) :: [Path.t()]
  def mounted(mountinfo) do
    mountinfo
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      # `id parent major:minor root mountpoint options [optional fields] - fstype source options`
      with [before, after_dash] <- String.split(line, " - ", parts: 2),
           [fstype | _] <- String.split(after_dash, " "),
           "9p" <- fstype,
           [_id, _parent, _dev, _root, mountpoint | _] <- String.split(before, " ") do
        [unescape(mountpoint)]
      else
        _other -> []
      end
    end)
  end

  @doc "Every mountpoint in `/proc/self/mountinfo` text, whatever it is a mount of."
  @spec mountpoints(String.t()) :: [Path.t()]
  def mountpoints(mountinfo) do
    mountinfo
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      with [before, _after_dash] <- String.split(line, " - ", parts: 2),
           [_id, _parent, _dev, _root, mountpoint | _] <- String.split(before, " ") do
        [unescape(mountpoint)]
      else
        _other -> []
      end
    end)
  end

  # mountinfo writes a space, tab, newline or backslash in a path as a three-digit octal escape.
  defp unescape(path) do
    Regex.replace(~r/\\([0-7]{3})/, path, fn _all, octal ->
      <<String.to_integer(octal, 8)>>
    end)
  end

  defmodule NineP do
    @moduledoc false
    @behaviour ForgeWorker.Archive.Mount

    @impl true
    def serves?(_dir), do: true

    @impl true
    def mount(socket, dir) do
      args = ["-t", "9p", "-o", Enum.join(ForgeWorker.Archive.Mount.options(), ","), socket, dir]

      case System.cmd("mount", args, stderr_to_stdout: true) do
        {_out, 0} -> :ok
        {out, code} -> {:error, {:mount, code, String.trim(out)}}
      end
    end

    # Lazy, so that a process still inside the folder does not make a job's end wait; the mount is
    # detached from the tree at once and goes when the last of them leaves.
    @impl true
    def unmount(dir) do
      if mounted?(dir) do
        case System.cmd("umount", ["-l", dir], stderr_to_stdout: true) do
          {_out, 0} -> :ok
          {out, code} -> {:error, {:umount, code, String.trim(out)}}
        end
      else
        :ok
      end
    end

    # A bind mount, and then the same one read-only: the first `mount` ignores `ro`, so the options
    # are applied by a remount of it. `nosuid`, `nodev` and `noexec` are the mount's own refusal to
    # run from it.
    @impl true
    def bind_ro(source, dir) do
      with :ok <- run("mount", ["--bind", source, dir]),
           :ok <- run("mount", ["-o", "remount,bind,ro,nosuid,nodev,noexec", dir]) do
        :ok
      else
        {:error, reason} ->
          unmount(dir)
          {:error, reason}
      end
    end

    @impl true
    def refresh(_source, _dir), do: :ok

    defp run(command, args) do
      case System.cmd(command, args, stderr_to_stdout: true) do
        {_out, 0} -> :ok
        {out, code} -> {:error, {:mount, code, String.trim(out)}}
      end
    end

    defp mounted?(dir) do
      case File.read("/proc/self/mountinfo") do
        {:ok, text} ->
          dir in ForgeWorker.Archive.Mount.mounted(text) or
            dir in ForgeWorker.Archive.Mount.mountpoints(text)

        {:error, _reason} ->
          false
      end
    end
  end

  defmodule None do
    @moduledoc false
    @behaviour ForgeWorker.Archive.Mount

    @readme """
    # The archive is not mounted on this machine

    This worker was not set up to mount the project's archive (`FORGE_ARCHIVE=9p`), so there is
    nothing to read here. The tickets' bodies are in ../tickets/ and the pinned inputs in ../inputs/.
    """

    @impl true
    def serves?(_dir), do: false

    @impl true
    def mount(_socket, dir) do
      File.write!(Path.join(dir, "README.md"), @readme)
      :ok
    end

    @impl true
    def unmount(_dir), do: :ok

    # The fallback for the attached files: a copy, made again by `refresh/2`. Nothing stops the job
    # writing to it, which is why it is the fallback and not the image's setting.
    @impl true
    def bind_ro(source, dir) do
      File.mkdir_p!(dir)
      copy(source, dir)
    end

    @impl true
    def refresh(source, dir) do
      File.rm_rf!(dir)
      File.mkdir_p!(dir)
      copy(source, dir)
    end

    defp copy(source, dir) do
      case File.cp_r(source, dir) do
        {:ok, _files} -> :ok
        {:error, reason, _file} -> {:error, {:copy, reason}}
      end
    end
  end
end
