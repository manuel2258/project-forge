defmodule ForgeWorker.LogTest do
  @moduledoc """
  This machine's lines for its log on the platform (`docs/design/worker-log.md`): what a line
  carries, how many are held while the platform is away, and the seed's two lines — which come
  from a job's own process and reach the link by name.

  Not async: the test stands in for the link by taking its registered name.
  """

  use ExUnit.Case, async: false

  import ForgeWorker.Fixtures

  alias ForgeWorker.Job.Seed
  alias ForgeWorker.Log

  defp standing_in_for_the_link(_context) do
    # Released with the test's process, as the link's own name is with the link's.
    Process.register(self(), ForgeWorker.Link)
    :ok
  end

  defp entry(n), do: %{"type" => "line", "message" => "#{n}"}

  describe "a line" do
    setup :standing_in_for_the_link

    test "reaches the link with the machine's time, its type and level, and its job" do
      before = DateTime.utc_now()
      job_id = uuid()

      :ok = Log.line("job.accepted", :info, "took on a workflow job, attempt 1", job_id: job_id)

      assert_receive {:log, entry}

      assert Map.delete(entry, "at") == %{
               "type" => "job.accepted",
               "level" => "info",
               "message" => "took on a workflow job, attempt 1",
               "job_id" => job_id
             }

      {:ok, at, 0} = DateTime.from_iso8601(entry["at"])
      assert DateTime.diff(at, before, :second) in 0..2
    end

    test "about no job carries no job" do
      :ok = Log.line("message.unknown", :warning, "unknown message")
      assert_receive {:log, entry}
      refute Map.has_key?(entry, "job_id")
      assert entry["level"] == "warning"
    end
  end

  # With no link — a job's task outliving it, or code run outside the release — a line is the
  # journal's and nobody else's, rather than a crash.
  test "with no link to hand it to, a line is only the journal's" do
    assert Process.whereis(ForgeWorker.Link) == nil

    # At warning, because the test config's journal drops anything quieter.
    assert ExUnit.CaptureLog.capture_log(fn ->
             assert :ok = Log.line("seed.missing", :warning, "nobody is listening")
           end) =~ "[warning] nobody is listening"

    # And a line about a job names it there, where there is no other column to.
    job_id = uuid()

    assert ExUnit.CaptureLog.capture_log(fn ->
             Log.line("seed.missing", :warning, "no seed", job_id: job_id)
           end) =~ "[warning] job #{job_id}: no seed"
  end

  describe "held while the platform is away" do
    test "the last hundred, oldest dropped first, and counted" do
      held = Enum.reduce(1..102, Log.empty(), &Log.hold(&2, entry(&1)))

      assert [dropped | lines] = Log.drain(held)
      assert Enum.map(lines, & &1["message"]) == Enum.map(3..102, &to_string/1)

      assert dropped["type"] == "log.dropped"
      assert dropped["level"] == "warning"
      assert dropped["message"] =~ "2 line(s) could not be kept"
      assert dropped["message"] =~ "these are the last 100"
    end

    test "the count is of what was dropped" do
      held = Enum.reduce(1..105, Log.empty(), &Log.hold(&2, entry(&1)))
      assert [%{"message" => dropped} | _lines] = Log.drain(held)
      assert dropped =~ "5 line(s) could not be kept"
    end

    test "a hundred fit, and nothing is said about dropping what was not dropped" do
      held = Enum.reduce(1..100, Log.empty(), &Log.hold(&2, entry(&1)))
      assert Log.drain(held) |> Enum.map(& &1["message"]) == Enum.map(1..100, &to_string/1)
      assert Log.drain(Log.empty()) == []
    end
  end

  test "how long a job ran, as the log says it" do
    assert Log.ran(4_900) == "4s"
    assert Log.ran(59_999) == "59s"
    assert Log.ran(60_000) == "1m 0s"
    assert Log.ran(723_000) == "12m 3s"
    assert Log.ran(3_600_000) == "1h 0m"
    assert Log.ran(7_500_000) == "2h 5m"
  end

  # A seed that could not be had is why the job after it is slow, and nothing on the platform
  # said so until this line.
  describe "a seed" do
    setup :standing_in_for_the_link

    setup do
      Application.put_env(:forge_worker, :platform_url, "http://platform.test")

      on_exit(fn ->
        Application.delete_env(:forge_worker, :req_options)
        Application.delete_env(:forge_worker, :platform_url)
      end)

      %{root: tmp_dir("root"), job_id: uuid()}
    end

    defp seeded(job_id),
      do: %{"job_id" => job_id, "seed" => %{"key" => "seed/demo/sha256-abc", "token" => "t"}}

    test "fetched is a line, tied to the job that fetched it", %{root: root, job_id: job_id} do
      dir = tmp_dir("published")
      File.write!(Path.join(dir, "warm.o"), "compiled\n")
      tarball = Path.join(tmp_dir("tar"), "seed.tar.gz")
      {_out, 0} = System.cmd("tar", ["-czf", tarball, "-C", dir, "."])
      body = File.read!(tarball)

      Application.put_env(:forge_worker, :req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 200, body) end
      )

      assert Seed.ensure(seeded(job_id), root)

      assert_receive {:log, %{"type" => "seed.fetched", "level" => "info"} = entry}
      assert entry["job_id"] == job_id
      assert entry["message"] =~ ~r/fetched seed seed\/demo\/sha256-abc in \d+ms/
    end

    test "missing is a warning, tied to the job that builds cold", %{root: root, job_id: job_id} do
      Application.put_env(:forge_worker, :req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 404, "no such key") end
      )

      assert Seed.ensure(seeded(job_id), root) == nil

      assert_receive {:log, %{"type" => "seed.missing", "level" => "warning"} = entry}
      assert entry["job_id"] == job_id
      assert entry["message"] =~ "no seed for seed/demo/sha256-abc"
      assert entry["message"] =~ "this job builds cold"
    end
  end

  describe "the types it sends" do
    # The platform keeps a type only if it is lower-case words and dots of at most 64 bytes, and
    # stores anything else as `unknown` (`docs/design/worker-log.md` § The `log` message).
    # `machine.not_rebooting` was sent for a whole branch and arrived as `unknown`, which no test on
    # either side could see: the worker's tests check what it sends and the platform's what it
    # keeps. So every type a `Log.line/4` call in the worker's source names is held to the
    # platform's rule here — which is only every type sent while each call names its type as a
    # literal, and so that is held too.
    setup do
      sources =
        for path <- Path.wildcard(Path.expand("../../lib/**/*.ex", __DIR__)), do: File.read!(path)

      %{sources: sources}
    end

    test "every one is lower-case words and dots, so the platform keeps it", %{sources: sources} do
      types =
        for source <- sources,
            [_call, type] <- Regex.scan(~r/Log\.line\(\s*"([^"]+)"/, source),
            do: type

      assert "machine.unhealthy" in types, "the scan found none of the types it knows are sent"

      assert Enum.reject(types, &(&1 =~ ~r/\A[a-z]+(\.[a-z]+)*\z/ and byte_size(&1) <= 64)) ==
               []
    end

    test "every one is named where it is sent, so the scan above sees it", %{sources: sources} do
      assert for(
               source <- sources,
               [call] <- Regex.scan(~r/Log\.line\(\s*[^"\s]/, source),
               do: call
             ) == []
    end
  end
end
