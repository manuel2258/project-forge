defmodule ForgeWorker.Archive do
  @moduledoc """
  The project's archive as a folder of a job directory (`docs/design/archive.md`): one server per
  job, one mount, and the order they come and go in.

  `start/3` is called by the runner once the job directory is prepared and the slice made; `release/1`
  when the job ends and **again before the files are handed back** (`ForgeWorker.Slice.leave/2` calls `release/1`),
  because a `chown -R` of a directory that holds a mount walks it — fetching everything in it, and
  failing on a read-only filesystem. Every call after the first finds nothing to do.
  """

  alias ForgeCore.Workflow
  alias ForgeWorker.Archive.{Mount, Server}
  alias ForgeWorker.Job.Dir

  require Logger

  @doc "The folder in a job directory."
  @spec dir(Path.t()) :: Path.t()
  def dir(job_dir), do: Path.join(job_dir, Workflow.archive_dir())

  @doc """
  Makes the folder for the job in `job_dir`. `grant` is `%{url: platform_url, token: git_token}`;
  the token stays behind a closure, which prints as a function in a crash report or
  `:sys.get_state/1` and not as the secret.

  Whatever an earlier run left at the path is released first, so a resume starts from nothing:
  a new socket, an empty cache.
  """
  @spec start(Path.t(), %{url: String.t(), token: String.t()}, String.t() | nil) ::
          :ok | {:error, term()}
  def start(job_dir, %{url: url, token: token}, job_id \\ nil) do
    mount = Mount.impl()
    release(job_dir)
    folder = dir(job_dir)

    # As root, in a job directory that the slice has handed to the job's user (the runner makes the
    # archive after `slice.prepare`): only exploitable by a process of that user that outlived a
    # killed worker and plants a link where the folder goes, which the worker's start does not look
    # for (`docs/design/archive.md` § Not here).
    File.rm_rf!(folder)
    File.mkdir_p!(folder)

    if mount.serves?() do
      socket_dir = make_socket_dir()
      socket = Path.join(socket_dir, "s")

      opts = [
        path: socket,
        remove_dir: socket_dir,
        cache_dir: Path.join(Dir.worker_dir!(job_dir), "archive-cache"),
        config: %{url: url, token: fn -> token end},
        job_id: job_id,
        name: name(job_dir)
      ]

      with {:ok, _pid} <- Server.start_link(opts),
           :ok <- mount.mount(socket, folder) do
        :ok
      else
        {:error, reason} ->
          release(job_dir)

          # Untested: reached only when `Server.start_link/1` fails before it listens, which no test
          # provokes (a mount that fails after it is cleaned by the server's own `terminate/2`, so
          # deleting this line changes nothing the suite can see). The cost of it going wrong is an
          # empty 0700 directory under the temporary one.
          File.rm_rf(socket_dir)
          {:error, reason}
      end
    else
      mount.mount(nil, folder)
    end
  end

  # **Not in the worker's directory beside the job**: a unix socket's path is at most 107 bytes,
  # and the socket would be `<root>/jobs/<uuid>.worker/archive.sock`, which is 76 bytes on the image
  # and more wherever `FORGE_ROOT` or a test's temporary directory is longer — a worker would then fail to
  # listen on a long root. A directory of its own under the temporary one, mode 0700 and named by
  # eight random bytes: `File.mkdir/1` refuses one that exists, so another user cannot have made it
  # first, and once it is 0700 only this process's user (and root) can enter it.
  defp make_socket_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "forge-archive-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      )

    :ok = File.mkdir(dir)
    File.chmod!(dir, 0o700)
    dir
  end

  @doc """
  What a job's archive is given: the platform and the job's own git token, which the platform
  accepts at its archive door. `nil` for an assignment without a token (a command's has no folder
  at all, and is not started with this).
  """
  @spec grant(map()) :: %{url: String.t(), token: String.t()} | nil
  def grant(%{"git" => %{"token" => token}}) when is_binary(token) do
    case ForgeWorker.Config.platform_url() do
      nil -> nil
      url -> %{url: url, token: token}
    end
  end

  def grant(_assignment), do: nil

  @doc "Unmounts the folder and stops its server. Idempotent: a job with none finds nothing to do."
  @spec release(Path.t()) :: :ok
  def release(job_dir) do
    case Mount.impl().unmount(dir(job_dir)) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("could not unmount #{dir(job_dir)}: #{inspect(reason)}")
    end

    case GenServer.whereis(name(job_dir)) do
      nil -> :ok
      pid -> Server.stop(pid)
    end
  end

  @doc """
  Unmounts every 9p mount under `root`, from `/proc/self/mountinfo`: what a worker that was killed
  left behind, before anything removes or walks a job directory under it.
  """
  @spec sweep(Path.t(), String.t() | nil) :: non_neg_integer()
  def sweep(root, mountinfo \\ nil) do
    case mountinfo || read_mountinfo() do
      nil ->
        0

      text ->
        text
        |> Mount.mounted()
        |> Enum.filter(&String.starts_with?(&1, Path.expand(root) <> "/"))
        |> Enum.count(fn mountpoint -> Mount.impl().unmount(mountpoint) == :ok end)
    end
  end

  defp read_mountinfo do
    case File.read("/proc/self/mountinfo") do
      {:ok, text} -> text
      {:error, _reason} -> nil
    end
  end

  defp name(job_dir), do: {:via, Registry, {ForgeWorker.Job.Registry, {:archive, job_dir}}}
end
