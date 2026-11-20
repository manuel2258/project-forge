defmodule ForgeWorker.CleanupsTest do
  @moduledoc """
  What the sweeps tell the disk report (`docs/design/worker-tier.md` § The disk report): when each
  last ran and the bytes it removed, sized before the removal. One test module and not
  two sweeps' own, because the record is the machine's one file and a neighbour's sweep would
  overwrite it.
  """

  use ExUnit.Case, async: false

  alias ForgeWorker.{Config, Disk}
  alias ForgeWorker.Job.{Dir, Workspace}

  @week_ms 7 * 24 * 60 * 60 * 1000

  setup do
    base = Path.join(System.tmp_dir!(), "cleanups-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    File.rm(Config.cleanups_path())
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base}
  end

  # The file the disk process keeps, once it has handled the cast that wrote it.
  defp recorded do
    _sync = Disk.report()
    Config.cleanups_path() |> File.read!() |> Jason.decode!()
  end

  defp old(path), do: File.touch!(path, System.os_time(:second) - 30 * 24 * 60 * 60)

  test "a job directory swept is recorded with the bytes it held", %{base: base} do
    stale = Path.join(base, "11111111-1111-1111-1111-111111111111")
    File.mkdir_p!(stale)
    File.write!(Path.join(stale, "transcript"), :binary.copy("x", 1_000_000))
    old(stale)

    assert Dir.sweep(base, @week_ms) == 1
    assert %{"jobs" => %{"freed" => freed, "at" => at}} = recorded()
    assert freed >= 1_000_000
    assert abs(at - System.os_time(:millisecond)) < 60_000
  end

  test "a sweep that removed nothing still says it ran, and freed nothing", %{base: base} do
    File.mkdir_p!(Path.join(base, "22222222-2222-2222-2222-222222222222"))
    assert Dir.sweep(base, @week_ms) == 0
    assert %{"jobs" => %{"freed" => 0}} = recorded()
  end

  test "a ticket volume swept is recorded with the bytes it held", %{base: base} do
    volume = Path.join([base, "volumes", "ticket", "1"])
    File.mkdir_p!(volume)
    File.write!(Path.join(volume, "target"), :binary.copy("x", 2_000_000))
    old(volume)

    assert Workspace.sweep(base, 2 * 24 * 60 * 60 * 1000) == 1
    assert %{"volumes" => %{"freed" => freed}} = recorded()
    assert freed >= 2_000_000
  end

  test "a directory a job linked to something large is not counted as that", %{base: base} do
    big = Path.join(base, "big")
    File.write!(big, :binary.copy("x", 5_000_000))
    stale = Path.join(base, "33333333-3333-3333-3333-333333333333")
    File.mkdir_p!(stale)
    File.ln_s!(big, Path.join(stale, "elsewhere"))
    old(stale)

    swept = Path.join(base, "jobs")
    File.mkdir_p!(swept)
    File.rename!(stale, Path.join(swept, "33333333-3333-3333-3333-333333333333"))
    old(Path.join(swept, "33333333-3333-3333-3333-333333333333"))

    assert Dir.sweep(swept, @week_ms) == 1
    assert %{"jobs" => %{"freed" => freed}} = recorded()
    assert freed < 100_000
    assert File.exists?(big)
  end
end
