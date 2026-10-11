defmodule Mix.Tasks.Forge.Worker.List do
  @shortdoc "Lists workers: mix forge.worker.list [--all]"

  @moduledoc """
  Lists the machines the platform knows about, live ones by default.

  There is no "connected" column, and there cannot be: whether a worker is connected lives in a
  registry inside the running platform, and this task is a different node. `last seen` is what
  the database knows, and it is the same figure the unreachable sweep judges on.

  `managed` says whether the platform created this machine and may destroy it. An unmanaged one
  was minted by its owner — from *New machine* on `/workers`, or with `mix forge.worker.new` —
  is skipped by both sweeps, and goes away only when somebody retires it, on that page or with
  `mix forge.worker.retire` — which is what makes it permanent and is also the reason to look at
  this list now and then.

      mix forge.worker.list
      mix forge.worker.list --all      # destroyed rows too
  """

  use Mix.Task

  alias Forge.{CLI, Workers}

  @impl true
  def run(args) do
    {opts, [], _} = OptionParser.parse(args, strict: [all: :boolean])
    CLI.boot()

    all? = Keyword.get(opts, :all, false)
    workers = Enum.filter(Workers.list(), &(all? or &1.status != :destroyed))

    if workers == [] do
      Mix.shell().info("no workers")
    else
      Mix.shell().info("ID                                    STATUS     MANAGED  LAST SEEN")

      Enum.each(workers, &Mix.shell().info(row(&1)))
    end
  end

  defp row(worker) do
    [
      String.pad_trailing(worker.id, 38),
      String.pad_trailing(to_string(worker.status), 11),
      String.pad_trailing(to_string(worker.managed), 9),
      to_string(worker.last_seen_at || "never")
    ]
    |> Enum.join("")
  end
end
