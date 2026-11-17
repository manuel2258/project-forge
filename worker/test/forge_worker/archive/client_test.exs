defmodule ForgeWorker.Archive.ClientTest do
  @moduledoc """
  The archive door from the worker's side (`docs/design/archive.md` § The worker's side): every
  failure is a word the agent can act on, a stalled transfer is cut off, and nothing that failed
  is left looking complete.
  """

  # The Req plug and the timeouts are the application's environment, which is global.
  use ExUnit.Case, async: false

  import ForgeWorker.Fixtures

  alias ForgeWorker.Archive.Client

  @config %{url: "http://platform.test", token: &__MODULE__.token/0}
  @bytes "hello\0world\xFF"
  @sha :crypto.hash(:sha256, @bytes) |> Base.encode16(case: :lower)
  @entry %{"ref" => "r", "size" => byte_size(@bytes), "sha256" => @sha}

  def token, do: "secret-token"

  setup do
    on_exit(fn ->
      for key <- [:req_options, :archive_connect_ms, :archive_receive_ms, :archive_retry],
          do: Application.delete_env(:forge_worker, key)
    end)

    %{dir: tmp_dir("client")}
  end

  defp answer(fun), do: Application.put_env(:forge_worker, :req_options, plug: fun)

  test "a listing is the platform's JSON, asked for with the job's token as a header" do
    test = self()

    answer(fn conn ->
      send(
        test,
        {:asked, conn.request_path, Plug.Conn.get_req_header(conn, "authorization"),
         conn.query_string}
      )

      Req.Test.json(conn, %{"tickets" => [1]})
    end)

    assert Client.listing(@config, :root) == {:ok, %{"tickets" => [1]}}
    assert_received {:asked, "/archive", ["Bearer secret-token"], ""}

    assert {:ok, _} = Client.listing(@config, {:ticket, "12"})
    assert_received {:asked, "/archive/tickets/12", _, ""}
  end

  test "each status is the errno an agent can act on, and a refusal or a fault is asked once",
       %{dir: dir} do
    clock()

    for {status, errno} <- [
          {401, :eacces},
          {403, :eacces},
          {404, :enoent},
          {500, :eio},
          {302, :eio}
        ] do
      counter = counting_all(fn conn -> Plug.Conn.send_resp(conn, status, "no") end)

      assert Client.listing(@config, :root) == {:error, errno}
      assert asked(counter) == 1, "listing #{status}"
      destination = Path.join(dir, "f#{status}")
      assert Client.fetch(@config, "1", @entry, destination) == {:error, errno}
      assert asked(counter) == 2, "fetch #{status}"
      refute File.exists?(destination)
    end

    assert pauses() == []
  end

  # -- a busy platform is waited out -------------------------------------------------------------

  # Time that moves only when the client sleeps, so that no test waits a real second: `sleep`
  # records each pause and advances the clock by it, and `jitter` is whatever the test says. The
  # bound is the client's own, 30 s, unless a test hands another: so every test here holds it.
  defp clock(jitter \\ fn _max -> 0 end, bound_ms \\ :production) do
    {:ok, time} = Agent.start_link(fn -> {0, []} end)

    Application.put_env(
      :forge_worker,
      :archive_retry,
      [
        clock: fn -> Agent.get(time, &elem(&1, 0)) end,
        sleep: fn ms -> Agent.update(time, fn {now, all} -> {now + ms, all ++ [ms]} end) end,
        jitter: jitter
      ] ++ if(bound_ms == :production, do: [], else: [bound_ms: bound_ms])
    )

    Process.put(:time, time)
  end

  defp pauses, do: Agent.get(Process.get(:time), &elem(&1, 1))

  # A plug that counts what it is asked, and answers by `fun.(n, conn)` for the n-th request.
  defp counting(fun) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    answer(fn conn ->
      n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      fun.(n, conn)
    end)

    counter
  end

  defp counting_all(fun), do: counting(fn _n, conn -> fun.(conn) end)

  defp asked(counter), do: Agent.get(counter, & &1)

  defp busy(conn, status, retry_after \\ nil) do
    conn =
      if retry_after, do: Plug.Conn.put_resp_header(conn, "retry-after", retry_after), else: conn

    Plug.Conn.send_resp(conn, status, "slow down")
  end

  test "a file answered 429 with Retry-After is asked for again once that long has gone",
       %{dir: dir} do
    clock()

    counter =
      counting(fn
        1, conn -> busy(conn, 429, "1")
        _n, conn -> Plug.Conn.send_resp(conn, 200, @bytes)
      end)

    destination = Path.join(dir, "late")
    assert Client.fetch(@config, "1", @entry, destination) == :ok
    assert File.read!(destination) == @bytes
    assert asked(counter) == 2
    assert [pause] = pauses()
    assert pause >= 1_000
    assert File.ls!(dir) == ["late"]
  end

  test "a listing answered 503 and then 200 is listed" do
    clock()

    counting(fn
      1, conn -> busy(conn, 503)
      _n, conn -> Req.Test.json(conn, %{"tickets" => [1]})
    end)

    assert Client.listing(@config, :root) == {:ok, %{"tickets" => [1]}}
    assert [pause] = pauses()
    assert pause > 0
  end

  test "429, 502, 503 and 504 are all waited out, on a listing and on a file", %{dir: dir} do
    clock()

    for status <- [429, 502, 503, 504] do
      counter =
        counting(fn
          1, conn -> busy(conn, status)
          _n, conn -> Plug.Conn.send_resp(conn, 200, @bytes)
        end)

      assert Client.fetch(@config, "1", @entry, Path.join(dir, "f#{status}")) == :ok, "#{status}"
      assert asked(counter) == 2

      counter =
        counting(fn
          1, conn -> busy(conn, status)
          _n, conn -> Req.Test.json(conn, %{})
        end)

      assert Client.listing(@config, :root) == {:ok, %{}}, "#{status}"
      assert asked(counter) == 2
    end
  end

  test "a file that stays busy fails as a timeout, within the bound, and leaves nothing",
       %{dir: dir} do
    clock()
    counting_all(&busy(&1, 429, "2"))

    assert Client.fetch(@config, "1", @entry, Path.join(dir, "never")) ==
             {:error, :etimedout, 429}

    assert File.ls!(dir) == []
    assert Enum.sum(pauses()) <= 30_000
    assert Enum.sum(pauses()) > 25_000

    assert Client.listing(@config, :root) == {:error, :etimedout, 429}
  end

  test "a platform that stays busy with no Retry-After is asked a few times, with growing pauses" do
    clock()
    counter = counting_all(&busy(&1, 503))

    assert Client.listing(@config, {:ticket, "3"}) == {:error, :etimedout, 503}

    pauses = pauses()
    assert asked(counter) == length(pauses) + 1
    assert length(pauses) in 4..20
    assert Enum.all?(pauses, &(&1 > 0))
    assert Enum.sum(pauses) <= 30_000
    # Each pause is longer than the one before it, bar the last, which is cut to what is left.
    grown = Enum.drop(pauses, -1)
    assert grown == Enum.sort(Enum.uniq(grown))
  end

  test "Retry-After with a zero is still a pause, never an immediate retry" do
    clock()

    counting(fn
      1, conn -> busy(conn, 429, "0")
      _n, conn -> Req.Test.json(conn, %{})
    end)

    assert {:ok, _} = Client.listing(@config, :root)
    assert [pause] = pauses()
    assert pause > 0
  end

  test "reads waiting together do not wait the same time" do
    jitter = fn max -> max end
    clock(jitter)

    counting(fn
      1, conn -> busy(conn, 503)
      _n, conn -> Req.Test.json(conn, %{})
    end)

    {:ok, _} = Client.listing(@config, :root)
    [with_jitter] = pauses()
    clock(fn _max -> 0 end)

    counting(fn
      1, conn -> busy(conn, 503)
      _n, conn -> Req.Test.json(conn, %{})
    end)

    {:ok, _} = Client.listing(@config, :root)
    [without] = pauses()
    assert with_jitter > without
  end

  test "a Retry-After that would pass the bound fails the read at once, with no pause" do
    clock()
    counter = counting_all(&busy(&1, 429, "3600"))

    assert Client.listing(@config, :root) == {:error, :etimedout, 429}
    assert asked(counter) == 1
    assert pauses() == []
  end

  test "a Retry-After that is only just inside the bound is waited for" do
    clock()

    counter =
      counting(fn
        1, conn -> busy(conn, 429, "30")
        _n, conn -> Req.Test.json(conn, %{})
      end)

    assert {:ok, _} = Client.listing(@config, :root)
    assert asked(counter) == 2
    assert pauses() == [30_000]
  end

  test "the platform's own bound is 30 seconds: 30 is waited for and 31 is not" do
    clock()

    counter =
      counting(fn
        1, conn -> busy(conn, 429, "31")
        _n, conn -> Req.Test.json(conn, %{})
      end)

    assert Client.listing(@config, :root) == {:error, :etimedout, 429}
    assert asked(counter) == 1
    assert pauses() == []
  end

  test "without a Retry-After the pause starts at 250 ms and doubles, to the end of the bound" do
    clock()
    counting_all(&busy(&1, 503))

    assert Client.listing(@config, :root) == {:error, :etimedout, 503}
    # The last is what was left of 30 s after the six before it: 30_000 - 15_750.
    assert pauses() == [250, 500, 1_000, 2_000, 4_000, 8_000, 14_250]
  end

  test "the random addition is at most half of the pause it is added to" do
    test = self()

    clock(fn max ->
      send(test, {:jitter, max})
      max
    end)

    counter =
      counting(fn
        n, conn when n < 4 -> busy(conn, 503)
        _n, conn -> Req.Test.json(conn, %{})
      end)

    assert {:ok, _} = Client.listing(@config, :root)
    assert asked(counter) == 4
    assert_received {:jitter, 125}
    assert_received {:jitter, 250}
    assert_received {:jitter, 500}
    # And all of it is added: 250 + 125, 500 + 250, 1000 + 500.
    assert pauses() == [375, 750, 1_500]

    # A named wait takes the same share of its own length.
    clock(fn max ->
      send(test, {:jitter, max})
      max
    end)

    counting(fn
      1, conn -> busy(conn, 429, "4")
      _n, conn -> Req.Test.json(conn, %{})
    end)

    assert {:ok, _} = Client.listing(@config, :root)
    assert_received {:jitter, 2_000}
    assert pauses() == [6_000]
  end

  test "the bound is spent exactly: a wait that uses it all is followed by no more" do
    clock()

    counter =
      counting(fn
        1, conn -> busy(conn, 429, "30")
        # A client that does not stop is let through after a while, so that it fails, not hangs.
        n, conn when n > 20 -> Req.Test.json(conn, %{})
        _n, conn -> busy(conn, 503)
      end)

    assert Client.listing(@config, :root) == {:error, :etimedout, 503}
    assert asked(counter) == 2
    assert pauses() == [30_000]
  end

  test "a Retry-After that is not whole seconds is not obeyed, and never crashes or stretches" do
    for value <- ["1.5", "soon", "-1", "Wed, 21 Oct 2099 07:28:00 GMT", "", " 5", "5s"] do
      clock()
      counting_all(&busy(&1, 429, value))

      assert Client.listing(@config, :root) == {:error, :etimedout, 429}, value
      # The first pause is the backoff's own 250 ms, not what the header seemed to say.
      assert [250 | _] = pauses(), value
      assert Enum.sum(pauses()) <= 30_000, value
    end

    # A whole number of seconds, however large, is read as one and refused as too long, at once.
    clock()
    counting_all(&busy(&1, 429, "99999999"))
    assert Client.listing(@config, :root) == {:error, :etimedout, 429}
    assert pauses() == []
  end

  test "every try is the same address with the same token, and no redirect is followed" do
    clock()
    test = self()

    counting(fn
      1, conn ->
        send(
          test,
          {:asked, conn.host, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")}
        )

        busy(conn, 503)

      2, conn ->
        send(
          test,
          {:asked, conn.host, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")}
        )

        conn
        |> Plug.Conn.put_resp_header("location", "http://elsewhere.test/")
        |> Plug.Conn.send_resp(302, "")
    end)

    assert Client.listing(@config, :root) == {:error, :eio}
    assert_received {:asked, "platform.test", "/archive", ["Bearer secret-token"]}
    assert_received {:asked, "platform.test", "/archive", ["Bearer secret-token"]}
  end

  test "a body that arrives after a busy answer is not added to the one before", %{dir: dir} do
    clock()

    counting(fn
      1, conn -> busy(conn, 503)
      _n, conn -> Plug.Conn.send_resp(conn, 200, @bytes)
    end)

    destination = Path.join(dir, "once")
    assert Client.fetch(@config, "1", @entry, destination) == :ok
    assert File.read!(destination) == @bytes
  end

  test "a connection that cannot be made is not waited for" do
    clock()
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
    Application.put_env(:forge_worker, :req_options, plug: {Req.Test, __MODULE__})

    assert Client.listing(@config, :root) == {:error, :etimedout}
    assert pauses() == []
  end

  test "a listing that is not JSON is damaged" do
    answer(fn conn -> Plug.Conn.send_resp(conn, 200, "not json") end)
    assert Client.listing(@config, :root) == {:error, :eio}
  end

  test "bytes come through as they are, once they are what was promised", %{dir: dir} do
    answer(fn conn -> Plug.Conn.send_resp(conn, 200, @bytes) end)
    destination = Path.join(dir, "ok")

    assert Client.fetch(@config, "1", @entry, destination) == :ok
    assert File.read!(destination) == @bytes
    refute File.exists?(destination <> ".partial")
  end

  # A listing that kept no hash still says how long the bytes are, and that is checked alone.
  test "a body of the wrong length is damaged even when no hash was kept", %{dir: dir} do
    answer(fn conn -> Plug.Conn.send_resp(conn, 200, "short") end)
    destination = Path.join(dir, "damaged")

    assert Client.fetch(@config, "1", %{"ref" => "r", "size" => 9, "sha256" => nil}, destination) ==
             {:error, :eio}

    assert File.ls!(dir) == []
  end

  test "a body of the wrong length or hash is damaged and leaves nothing", %{dir: dir} do
    answer(fn conn -> Plug.Conn.send_resp(conn, 200, "short") end)

    for entry <- [@entry, %{@entry | "size" => 5}, %{"ref" => "r", "size" => 5, "sha256" => @sha}] do
      destination = Path.join(dir, "damaged")
      assert Client.fetch(@config, "1", entry, destination) == {:error, :eio}
      assert File.ls!(dir) == []
    end
  end

  test "a platform that is not there is a timeout, and a hash is not asked for when none was kept",
       %{dir: dir} do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
    Application.put_env(:forge_worker, :req_options, plug: {Req.Test, __MODULE__})

    assert Client.listing(@config, :root) == {:error, :etimedout}
    assert Client.fetch(@config, "1", @entry, Path.join(dir, "x")) == {:error, :etimedout}

    answer(fn conn -> Plug.Conn.send_resp(conn, 200, "any") end)

    assert Client.fetch(
             @config,
             "1",
             %{"ref" => "r", "size" => 3, "sha256" => nil},
             Path.join(dir, "y")
           ) == :ok
  end

  # A real socket, because a plug cannot go quiet: one that accepts and says nothing.
  test "a transfer that goes silent is cut off, and so is a listing that does", %{dir: dir} do
    Application.put_env(:forge_worker, :archive_receive_ms, 150)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    config = %{@config | url: "http://127.0.0.1:#{port}"}
    started = System.monotonic_time(:millisecond)

    assert Client.fetch(config, "1", @entry, Path.join(dir, "stalled")) == {:error, :etimedout}
    assert System.monotonic_time(:millisecond) - started < 5_000
    assert File.ls!(dir) == []

    assert Client.listing(config, :root) == {:error, :etimedout}
  end
end
