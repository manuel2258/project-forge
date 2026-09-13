defmodule Mix.Tasks.Forge.Worker.New do
  @shortdoc "Mints a worker's credentials: mix forge.worker.new [PROJECT]"

  @moduledoc """
  Creates a worker row and prints what a machine needs to become that worker, as shell
  assignments. The measurement harness boots a machine by hand with these (`bin/measure m4`);
  so does anyone debugging an image.

      eval "$(mix forge.worker.new demo)"

  With a PROJECT whose seed has been published, it also prints the seed's key and a token to
  fetch it with, because M4 times that fetch as a phase of the cold start.

  The token is returned once and only its hash is kept, exactly as it is when the provider
  driver asks for one. Nothing is created on any provider: the row exists and the machine does
  not, which is what a failed `create` leaves and what the platform recovers from — so a row
  minted here and never used is swept and marked `destroyed` after `worker_timeout_ms`, and
  costs nothing but a line in the table.

  **It counts against `max_workers` until then.** On a platform with pending work that is a
  machine's worth of capacity spent on a measurement, which is why a measurement run wants a
  quiet platform anyway.
  """

  use Mix.Task

  alias Forge.{CLI, Jobs, Projects, Storage, Workers}

  @impl true
  def run(args) do
    case args do
      [] -> mint(nil)
      [project] -> mint(project)
      _other -> CLI.fail("usage: mix forge.worker.new [PROJECT]")
    end
  end

  defp mint(name) do
    CLI.boot()

    project = name && (Projects.by_name(name) || CLI.fail("unknown project #{name}"))

    case Workers.create(%{provider: Forge.Provider.name()}) do
      {:ok, worker, token} ->
        Mix.shell().info(assignments(worker, token, project) |> Enum.join("\n"))

      {:error, changeset} ->
        CLI.fail(inspect(changeset.errors))
    end
  end

  defp assignments(worker, token, project) do
    [
      ~s(FORGE_WORKER_ID=#{worker.id}),
      ~s(FORGE_WORKER_TOKEN=#{token}),
      ~s(FORGE_PLATFORM_URL=#{platform_url()})
    ] ++ seed(project)
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
