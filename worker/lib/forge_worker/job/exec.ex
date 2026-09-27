defmodule ForgeWorker.Job.Exec do
  @moduledoc """
  What an agent's process and a command's share (`ForgeWorker.Job.Runner`,
  `ForgeWorker.Job.Command`): the environment they inherit from the worker, the `nix develop`
  wrapping, and the signal that reaches their whole process group.

  One definition, because the allowlist is what keeps the worker's own secrets — its channel
  identity, the store's keys — out of both, and two copies of it are two lists to keep in step.
  """

  @inherited ~w(PATH LANG LC_ALL TERM TMPDIR SSL_CERT_FILE NIX_SSL_CERT_FILE NIX_PATH NIX_REMOTE
                NIX_CONFIG HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy)

  @doc "The worker's variables a job's process may see: the allowlist, where they are set."
  @spec inherited_env() :: [{String.t(), String.t()}]
  def inherited_env, do: for(key <- @inherited, value = System.get_env(key), do: {key, value})

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
