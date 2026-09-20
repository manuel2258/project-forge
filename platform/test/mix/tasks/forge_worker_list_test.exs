defmodule Mix.Tasks.Forge.Worker.ListTest do
  @moduledoc """
  The list an operator reads to decide whether a machine is still theirs to pay for.

  Its doc promises "live ones by default" and "`--all` destroyed rows too". A destroyed row is
  the platform's record that a machine is gone, and there are many more of them than live ones
  on any node that has been up a while — so a filter that showed the wrong side would bury the
  handful of machines that exist under the history of every machine that ever did, and an
  operator counting workers against `max_workers` would count the dead.

  Nothing else exercises this task, and the filter is one expression: reading it is not the same
  as running it.
  """

  use Forge.DataCase, async: false

  alias Forge.Workers
  alias Mix.Tasks.Forge.Worker.List, as: ListTask

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    {:ok, live, _token} = Workers.create(%{provider: "fake"})
    {:ok, live} = Workers.ready(live, %{"memory_budget" => 8_000_000_000})

    {:ok, gone, _token} = Workers.create(%{provider: "fake"})
    :ok = Workers.destroy(gone)

    %{live: live, gone: gone}
  end

  # Everything the task printed, as one string — the rows are one `Mix.shell().info/1` each.
  defp output do
    receive do
      {:mix_shell, :info, [line]} -> line <> "\n" <> output()
    after
      0 -> ""
    end
  end

  test "the plain list is the machines that still exist", %{live: live, gone: gone} do
    ListTask.run([])
    printed = output()

    assert printed =~ live.id
    refute printed =~ gone.id
  end

  test "--all adds the destroyed rows without dropping the live ones", %{live: live, gone: gone} do
    ListTask.run(["--all"])
    printed = output()

    assert printed =~ live.id
    assert printed =~ gone.id
    assert printed =~ "destroyed"
  end
end
