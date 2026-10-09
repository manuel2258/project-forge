defmodule ForgeWorker.Job.Exec do
  @moduledoc """
  What an agent's process and a command's share (`ForgeWorker.Job.Runner`,
  `ForgeWorker.Job.Command`): the environment they inherit from the worker, the `nix develop`
  wrapping, and the signal that reaches their whole process group.

  One definition, because the allowlist is what keeps the worker's own secrets — its channel
  identity, the store's keys — out of both, and two copies of it are two lists to keep in step.
  """

  alias ForgeWorker.Job.Dir

  @inherited ~w(PATH LANG LC_ALL TERM TMPDIR SSL_CERT_FILE NIX_SSL_CERT_FILE NIX_PATH NIX_REMOTE
                NIX_CONFIG HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy)

  @doc "The worker's variables a job's process may see: the allowlist, where they are set."
  @spec inherited_env() :: [{String.t(), String.t()}]
  def inherited_env, do: for(key <- @inherited, value = System.get_env(key), do: {key, value})

  # **Every `{:secret, _}` value reaches the process through a file, and only a file**: the
  # credential, the git token and the project's secrets alike (`docs/design/secrets.md`
  # § Delivery). Not the environment of anything outside the process: `systemd-run --setenv=NAME`
  # copies the value into the unit's `Environment=`, which systemd shows to every user on the
  # machine over its bus for the unit's whole life — another job's included (`systemd.exec(5)`,
  # under `Environment=`). Not an argument either: `env -i NAME="$NAME"` puts it in `env`'s argv,
  # in `/proc/<pid>/cmdline` for anyone to read until it execs.
  #
  # So the values are written, shell-quoted, into the worker's own directory, which is root's and
  # closed to every other user (`Dir.worker_dir!/1`). On the image the unit is handed the file with
  # `LoadCredential=` (`ForgeWorker.Slice.Systemd`): systemd reads it as root and puts a copy where
  # only the unit's user can read it, naming the place in `$CREDENTIALS_DIRECTORY`, and nothing of
  # it but the path is on the bus. `Slice.Direct` has no unit, and its process reads the file where
  # it is. Either way a shell inside the process loads it and `exec`s, so the values are in the
  # process's environment and in no argv, no unit property and no other process's environment.
  @secrets_credential "forge-secrets"

  @loader ~S(f="$1"; shift; if [ -n "${CREDENTIALS_DIRECTORY-}" ]; then ) <>
            ~S(f="$CREDENTIALS_DIRECTORY/) <>
            @secrets_credential <>
            ~S("; fi; ) <>
            ~S(set -a; . "$f" || exit 126; set +a; unset f; exec "$@")

  @doc """
  The name `LoadCredential=` gives the secrets file inside a unit: `$CREDENTIALS_DIRECTORY/` and
  this is where the loader reads it.
  """
  @spec secrets_credential() :: String.t()
  def secrets_credential, do: @secrets_credential

  @doc """
  Writes `secrets` for the process about to start in `job_dir` and returns the file, or removes
  any left over and returns nil when there are none. The file is in the worker's own directory,
  which no job's user can enter (`ForgeWorker.Job.Dir.worker_dir!/1`).
  """
  @spec write_secrets(String.t(), [{String.t(), String.t()}]) :: String.t() | nil
  def write_secrets(job_dir, []) do
    remove_secrets(job_dir)
    nil
  end

  def write_secrets(job_dir, secrets) do
    path = secrets_path(Dir.worker_dir!(job_dir))

    File.write!(
      path,
      Enum.map(secrets, fn {name, value} -> [name, "=", sh_quote(value), "\n"] end)
    )

    File.chmod!(path, 0o600)
    path
  end

  @doc "Removes the secrets file, once the process that read it has ended."
  @spec remove_secrets(String.t()) :: :ok
  def remove_secrets(job_dir) do
    File.rm(secrets_path(Dir.worker_dir(job_dir)))
    :ok
  end

  defp secrets_path(worker_dir), do: Path.join(worker_dir, "secrets.env")

  @doc """
  `executable` started by the loader: a shell that reads the secrets file — from
  `$CREDENTIALS_DIRECTORY` inside a unit, from `path` where there is none — into its environment,
  and `exec`s it. A file it cannot read stops it, with a non-zero status, before anything runs: a
  job is not started without the values it was given. Nothing to load is the process as it was.
  """
  @spec load_secrets(String.t(), [String.t()], String.t() | nil) :: {String.t(), [String.t()]}
  def load_secrets(executable, args, nil), do: {executable, args}

  def load_secrets(executable, args, path),
    do: {"/bin/sh", ["-c", @loader, "forge-secrets", path, executable | args]}

  # Single quotes keep every byte as it is — a newline, a `$`, a backslash — and a quote inside is
  # closed, escaped and reopened. A value has no NUL (`Forge.Secrets.Secret`), the one byte a shell
  # string cannot hold.
  defp sh_quote(value), do: "'" <> String.replace(value, "'", ~S('\'')) <> "'"

  @doc """
  The allowlist's names. A project secret may take none of them (`ForgeCore.Secret`), and the
  suite holds the two lists to that.
  """
  @spec inherited() :: [String.t()]
  def inherited, do: @inherited

  @doc """
  What a job is told of its ceiling: `FORGE_MEMORY_MAX`, in bytes, when the slice has one — for an
  agent and a command alike, so a build can size its own parallelism and an agent can tell a
  SIGKILL for what it most likely is (`docs/design/worker-tier.md` § The job slice). Nothing when
  there is no ceiling, rather than a figure nobody set.
  """
  @spec memory_env(map() | nil) :: [{String.t(), String.t()}]
  def memory_env(%{memory_max: bytes}) when is_integer(bytes),
    do: [{"FORGE_MEMORY_MAX", Integer.to_string(bytes)}]

  def memory_env(_slice_opts), do: []

  @doc "The command that runs `executable` inside the project's `env`, when asked to and named."
  @spec nix(String.t(), [String.t()], String.t() | nil, boolean()) :: {String.t(), [String.t()]}
  def nix(executable, args, env, true) when is_binary(env),
    do: {"nix", ["develop", ".##{env}", "--command", executable | args]}

  def nix(executable, args, _env, _nix), do: {executable, args}

  @doc """
  Sends `name` to the port's whole process group. The wrapper shell is the group's leader, so
  signalling the negative pid reaches the process and everything it spawned; killing only the
  leader would leave children holding the output pipe open, and the port would never report an
  exit.
  """
  @spec signal(port(), String.t()) :: term()
  def signal(port, name) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("kill", ["-#{name}", "--", "-#{os_pid}"], stderr_to_stdout: true)

      nil ->
        :ok
    end
  end
end
