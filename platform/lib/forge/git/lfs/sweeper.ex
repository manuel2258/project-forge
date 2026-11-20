defmodule Forge.Git.Lfs.Sweeper do
  @moduledoc """
  Hourly, runs `Forge.Git.Lfs.sweep/2` for every project whose repository holds LFS objects and
  was last swept a day or more ago, so each is swept once a day with nobody to start it
  (`docs/design/git-hosting.md` § Git LFS). It runs where the scheduler does and is off in the
  suite, which calls `run/1`. One project failing is logged and does not stop the next.
  """

  use GenServer

  alias Forge.Git.Lfs
  alias Forge.Projects

  require Logger

  @interval :timer.hours(1)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    run(DateTime.utc_now())
    schedule()
    {:noreply, state}
  end

  @doc "Sweeps every project that is due as of `now`; the number of projects it ran for."
  @spec run(DateTime.t()) :: non_neg_integer()
  def run(now) do
    for project <- Projects.list(), Lfs.due?(Projects.repo_path(project), now), reduce: 0 do
      count ->
        case Lfs.sweep(project, now) do
          {:ok, %{deleted: 0}} ->
            :ok

          {:ok, %{deleted: deleted, bytes: bytes}} ->
            Logger.info("lfs: deleted #{deleted} object(s), #{bytes} bytes, of #{project.name}")

          {:error, reason} ->
            Logger.warning("lfs: did not sweep #{project.name}: #{inspect(reason)}")
        end

        count + 1
    end
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval)
end
