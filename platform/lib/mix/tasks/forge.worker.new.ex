defmodule Mix.Tasks.Forge.Worker.New do
  @shortdoc "Mints a worker's credentials: mix forge.worker.new [PROJECT] [--out FILE]"

  @moduledoc """
  Creates a worker row and prints what a machine needs to become that worker, as shell
  assignments. The measurement harness boots a machine by hand with these (`bin/measure m4`);
  so does anyone debugging an image.

      eval "$(mix forge.worker.new demo)"

  With a PROJECT whose seed has been published, it also prints the seed's key and a token to
  fetch it with, because M4 times that fetch as a phase of the cold start.

  The worker token is returned once and only its hash is kept, exactly as it is when the provider
  driver asks for one. Nothing is created on any provider: the row exists and the machine does
  not, and it is up to whoever ran this to make one.

  **The agent's credential is printed too.** It is the machine's environment and not any job's,
  and the driver injects it into every machine it creates; this command stands in for the driver
  and so it does the same. That means this output is a secret in two ways rather than one — pipe
  it somewhere with a sane umask, not into a shell history.

  **The row is unmanaged, and so it is permanent.** Neither sweep will destroy it — not the idle
  period, and not the unreachable timeout, which re-queues its jobs and leaves the row so the
  machine can rejoin. That is what makes a long-lived worker possible, and it is also the catch:
  a row minted here and never used sits there counting against `max_workers` until somebody
  removes it. `mix forge.worker.list` shows them.
  """

  use Mix.Task

  alias Forge.{CLI, Jobs, Projects, Storage, Workers}

  @impl true
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: [out: :string])

    case positional do
      [] -> mint(nil, opts)
      [project] -> mint(project, opts)
      _other -> CLI.fail("usage: mix forge.worker.new [PROJECT] [--out FILE]")
    end
  end

  defp mint(name, opts) do
    CLI.boot()

    project = name && (Projects.by_name(name) || CLI.fail("unknown project #{name}"))

    # Unmanaged, always: this command exists because somebody is provisioning the machine
    # themselves, and a machine the platform did not create is not the platform's to destroy.
    # It is skipped by both sweeps; see docs/design/worker-tier.md § Managed and unmanaged.
    case Workers.create(%{provider: Forge.Provider.name(), managed: false}) do
      {:ok, worker, token} ->
        emit(Enum.join(assignments(worker, token, project), "\n"), Keyword.get(opts, :out))

      {:error, changeset} ->
        CLI.fail(inspect(changeset.errors))
    end
  end

  # 0600 before anything is written to it: the file carries the platform's Anthropic credential,
  # and a umask that would have made it readable is not the operator's mistake to discover later.
  defp emit(env, nil), do: Mix.shell().info(env)

  defp emit(env, path) do
    File.write!(path, env <> "\n")
    File.chmod!(path, 0o600)

    Mix.shell().info(
      "wrote #{path} (mode 0600); it holds this machine's token and the agent credential"
    )
  end

  defp assignments(worker, token, project) do
    [
      ~s(FORGE_WORKER_ID=#{worker.id}),
      ~s(FORGE_WORKER_TOKEN=#{token}),
      ~s(FORGE_PLATFORM_URL=#{platform_url()})
    ] ++ harness() ++ seed(project)
  end

  # The agent's credential and model, which the driver injects into a machine it creates. This
  # command stands in for the driver, so it injects them too: a machine minted without the
  # credential joins, reports `ready`, is scheduled, and fails every job with "Not logged in".
  defp harness do
    Enum.map(Workers.harness_env(), fn {name, value} -> ~s(#{name}=#{value}) end)
  end

  defp seed(%{seed_id: seed_id, name: name}) when is_binary(seed_id) do
    key = Storage.Key.seed(name, seed_id)
    [~s(FORGE_SEED_KEY=#{key}), ~s(FORGE_SEED_TOKEN=#{Storage.Token.sign(:get, key)})]
  end

  defp seed(_project), do: []

  # The same address the driver injects, for the same reason: a worker is a different machine
  # and the endpoint's own URL is localhost from where it is standing.
  defp platform_url, do: Jobs.config(:platform_url, nil) || ForgeWeb.Endpoint.url()
end
