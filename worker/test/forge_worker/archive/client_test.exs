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
      for key <- [:req_options, :archive_connect_ms, :archive_receive_ms],
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

  test "each status is the errno an agent can act on", %{dir: dir} do
    for {status, errno} <- [
          {401, :eacces},
          {403, :eacces},
          {404, :enoent},
          {500, :eio},
          {302, :eio}
        ] do
      answer(fn conn -> Plug.Conn.send_resp(conn, status, "no") end)

      assert Client.listing(@config, :root) == {:error, errno}
      destination = Path.join(dir, "f#{status}")
      assert Client.fetch(@config, "1", @entry, destination) == {:error, errno}
      refute File.exists?(destination)
    end
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
