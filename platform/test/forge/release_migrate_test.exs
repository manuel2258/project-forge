defmodule Forge.ReleaseMigrateTest do
  @moduledoc """
  `Forge.Release.migrate/0` against a database that is actually behind.

  `Forge.ReleaseTest` can only call it against an already-migrated one, where `all: true` and
  `step: 0` are indistinguishable: both return `:ok`, both change nothing. The container image's
  entrypoint calls this on every start, so what has to be true is not that it returns `:ok` but
  that the schema is current afterwards — and that can only be seen from behind.

  It lives in its own file because it cannot run inside the SQL sandbox. `Ecto.Migrator` runs each
  migration from a `Task` with its own connection, and a sandboxed test has exactly one; the
  migration waits on a connection the test is holding and times out. So this file takes the repo
  out of sandbox mode, does its work for real, and puts the schema and the mode back.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Forge.{Release, Repo}

  setup do
    Sandbox.mode(Repo, :auto)

    # Ordered so a failure part-way through still leaves the schema current for whatever runs
    # next: `mix test` migrates before it starts, but nothing else in this run would.
    on_exit(fn ->
      Release.migrate()
      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  test "migrate brings a database that is behind back up to date" do
    assert {:up, version, name} = List.last(Ecto.Migrator.migrations(Repo))

    Ecto.Migrator.run(Repo, :down, step: 1)
    assert {:down, ^version, _} = List.last(Ecto.Migrator.migrations(Repo))

    # The migrator compiles the file again on the way up, and a module compiled twice in one VM
    # warns. Forget the one the rollback loaded so the run under test is the only definition.
    forget(name)

    assert :ok = Release.migrate()
    assert {:up, ^version, _} = List.last(Ecto.Migrator.migrations(Repo))
  end

  defp forget(name) do
    module = Module.concat(Forge.Repo.Migrations, Macro.camelize(name))
    :code.purge(module)
    :code.delete(module)
  end
end
