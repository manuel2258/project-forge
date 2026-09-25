defmodule Forge.Migrations do
  @moduledoc """
  For tests that roll the schema back to before a migration and bring it forward again — the
  upgrade path of a backfill, checked against a database filled the way an old node's would be.

  Such a test cannot run in the SQL sandbox: `Ecto.Migrator` runs each migration from its own
  connection (`Forge.ReleaseMigrateTest` says why). So it takes the repo out of sandbox mode,
  records what it writes, and deletes it and puts the schema back on exit.
  """

  alias Forge.Repo

  @doc "Rolls the schema back to before `version`, which rolls back every migration after it too."
  def back_to(version) do
    forget(version)
    Ecto.Migrator.run(Repo, :down, to: version, log: false)
  end

  @doc "Runs the migrations up to and including `version`."
  def up_to(version) do
    forget(version)
    Ecto.Migrator.run(Repo, :up, to: version, log: false)
  end

  @doc """
  Forgets the modules of every migration from `version` on. The migrator compiles each file again
  on the way up, and forgetting the modules the rollback loaded keeps a warning about redefining
  them out of the run.
  """
  def forget(version) do
    for {from, file} <- migrations(), from >= version do
      module =
        file
        |> File.read!()
        |> then(&Regex.run(~r/defmodule ([\w.]+) do/, &1, capture: :all_but_first))
        |> hd()
        |> then(&Module.concat([&1]))

      :code.purge(module)
      :code.delete(module)
    end
  end

  defp migrations do
    for file <-
          Path.wildcard(Path.join(Application.app_dir(:forge, "priv/repo/migrations"), "*.exs")) do
      [version | _rest] = file |> Path.basename() |> String.split("_", parts: 2)
      {String.to_integer(version), file}
    end
  end
end
