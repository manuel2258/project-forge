defmodule ForgeWorker.FixturesTest do
  @moduledoc """
  `ForgeWorker.Fixtures.reap/1`: a test's directory is not removed under a harness that still
  writes to it.
  """

  use ExUnit.Case, async: true

  import ForgeWorker.Fixtures

  defp sleeper(opts) do
    port =
      Port.open(
        {:spawn_executable, System.find_executable("sh")},
        [:binary, args: ["-c", "sleep 60"]] ++ opts
      )

    {:os_pid, pid} = Port.info(port, :os_pid)
    pid
  end

  # A killed process is a zombie for a moment, and a zombie's links answer nothing.
  defp working?(pid), do: match?({:ok, _}, File.read_link("/proc/#{pid}/cwd"))

  test "it kills what works in the directory, by where it is" do
    dir = tmp_dir("reap-cwd")
    pid = sleeper(cd: dir)
    assert working?(pid)

    reap(dir)

    refute working?(pid)
  end

  test "it kills what the directory is the job of, wherever it is" do
    dir = tmp_dir("reap-env")
    pid = sleeper(cd: "/", env: [{~c"FORGE_JOB", String.to_charlist(Path.join(dir, "j"))}])
    assert working?(pid)

    reap(dir)

    refute working?(pid)
  end

  test "it leaves alone what works somewhere else" do
    dir = tmp_dir("reap-mine")
    other = tmp_dir("reap-other")
    pid = sleeper(cd: other)

    reap(dir)

    assert working?(pid)
    reap(other)
  end

  # `tmp_dir/1` names are `<pid>-forge-<what>-<n>`, so the directory of another test can be this
  # one's name with more digits on it, and a prefix test that forgot the `/` would kill that
  # test's harness.
  test "it leaves alone what works in a directory whose name only starts with this one's" do
    dir = tmp_dir("reap-prefix")
    neighbour = dir <> "0"
    File.mkdir_p!(neighbour)
    pid = sleeper(cd: neighbour)

    env_pid =
      sleeper(cd: "/", env: [{~c"FORGE_JOB", String.to_charlist(Path.join(neighbour, "j"))}])

    reap(dir)

    assert working?(pid)
    assert working?(env_pid)
    reap(neighbour)
    File.rm_rf!(neighbour)
  end
end
