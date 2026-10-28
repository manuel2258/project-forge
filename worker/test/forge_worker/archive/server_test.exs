defmodule ForgeWorker.Archive.ServerTest do
  @moduledoc """
  The archive's 9P server, spoken to over its socket as the kernel's client would
  (`docs/design/archive.md` § The worker's side): the criteria about what costs a request, what
  fails and how, and what cannot be written.
  """

  # The Req plug and the intervals are the application's environment, which is global.
  use ExUnit.Case, async: false

  import ForgeWorker.Fixtures

  alias ForgeWorker.Archive.Server

  @ref_plan "11111111-1111-1111-1111-111111111111"
  @ref_old "22222222-2222-2222-2222-222222222222"
  @ref_bin "33333333-3333-3333-3333-333333333333"
  @binary <<0, 255, 254, "text", 0, 128>>
  @plan "# The plan\n"

  @eio 5
  @enoent 2
  @eacces 13
  @erofs 30
  @etimedout 110
  @ebadf 9
  @enotdir 20
  @eisdir 21
  @enodata 61

  setup do
    dir = tmp_dir("srv")
    requests = start_supervised!({Agent, fn -> [] end})
    # What the platform answers for a content request, changeable by a test.
    content = start_supervised!({Agent, fn -> :ok end}, id: :content)
    extra = start_supervised!({Agent, fn -> [] end}, id: :extra)

    Application.put_env(:forge_worker, :req_options,
      plug: fn conn -> platform(conn, requests, content, extra) end
    )

    on_exit(fn ->
      for key <- [:req_options, :archive_listing_ttl_ms],
          do: Application.delete_env(:forge_worker, key)
    end)

    %{dir: dir, requests: requests, content: content, extra: extra}
  end

  defp platform(conn, requests, content, extra) do
    Agent.update(requests, &(&1 ++ [conn.request_path]))

    case conn.request_path do
      "/archive" ->
        Req.Test.json(conn, %{
          "taken_at" => "now",
          "tickets" => [1, 2],
          "files" => [
            %{
              "path" => "index.md",
              "ref" => nil,
              "size" => 5,
              "sha256" => nil,
              "inline" => "hello"
            }
          ]
        })

      "/archive/tickets/1" ->
        files =
          [
            entry("plan.md", @ref_plan, @plan),
            entry("plan.v001.md", @ref_plan, @plan),
            entry("reports/out.bin", @ref_bin, @binary)
          ] ++ Agent.get(extra, & &1)

        Req.Test.json(conn, %{"files" => files})

      "/archive/tickets/1/" <> ref ->
        content(conn, Agent.get(content, & &1), ref)

      _other ->
        Plug.Conn.send_resp(conn, 404, "")
    end
  end

  defp content(conn, :ok, @ref_plan), do: Plug.Conn.send_resp(conn, 200, @plan)
  defp content(conn, :ok, @ref_old), do: Plug.Conn.send_resp(conn, 200, "old")
  defp content(conn, :ok, @ref_bin), do: Plug.Conn.send_resp(conn, 200, @binary)
  defp content(conn, {:status, status}, _ref), do: Plug.Conn.send_resp(conn, status, "no")
  defp content(conn, :short, _ref), do: Plug.Conn.send_resp(conn, 200, "x")

  defp content(conn, :unreachable, _ref),
    do: Req.Test.transport_error(conn, :econnrefused)

  defp content(conn, {:hold, test}, _ref) do
    send(test, {:held, self()})

    receive do
      :release -> Plug.Conn.send_resp(conn, 200, @plan)
    after
      5_000 -> Plug.Conn.send_resp(conn, 500, "")
    end
  end

  defp entry(path, ref, bytes) do
    %{
      "path" => path,
      "ref" => ref,
      "size" => byte_size(bytes),
      "sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    }
  end

  defp start_server(%{dir: dir}) do
    path = Path.join(dir, "a.sock")
    cache = Path.join(dir, "cache")

    {:ok, pid} =
      Server.start_link(
        path: path,
        cache_dir: cache,
        config: %{url: "http://platform.test", token: fn -> "tok" end},
        job_id: "j"
      )

    {:ok, socket} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :raw])
    on_exit(fn -> if Process.alive?(pid), do: Server.stop(pid) end)
    {pid, socket, path, cache}
  end

  # -- the wire, as the kernel's client would speak it -------------------------------------------

  defp str(text), do: <<byte_size(text)::16-little, text::binary>>

  defp send_t(socket, type, tag, body),
    do:
      :gen_tcp.send(
        socket,
        <<byte_size(body) + 7::32-little, type, tag::16-little, body::binary>>
      )

  defp recv(socket, timeout \\ 3_000) do
    with {:ok, <<size::32-little>>} <- :gen_tcp.recv(socket, 4, timeout),
         {:ok, rest} <- :gen_tcp.recv(socket, size - 4, timeout) do
      <<type, tag::16-little, body::binary>> = rest
      {type, tag, body}
    end
  end

  defp t(socket, type, tag, body) do
    :ok = send_t(socket, type, tag, body)
    recv(socket)
  end

  defp attach(socket) do
    {101, _, _} = t(socket, 100, 0xFFFF, <<65_536::32-little>> <> str("9P2000.L"))

    {105, _, _} =
      t(
        socket,
        104,
        1,
        <<1::32-little, 0xFFFFFFFF::32-little>> <> str("root") <> str("") <> <<0::32>>
      )
  end

  defp walk(socket, fid, newfid, names, tag \\ 2) do
    body =
      <<fid::32-little, newfid::32-little, length(names)::16-little>> <>
        Enum.map_join(names, &str/1)

    t(socket, 110, tag, body)
  end

  defp lopen(socket, fid, flags \\ 0, tag \\ 3),
    do: t(socket, 12, tag, <<fid::32-little, flags::32-little>>)

  defp read_all(socket, fid) do
    {117, _, <<count::32-little, data::binary-size(count)>>} =
      t(socket, 116, 4, <<fid::32-little, 0::64-little, 65_000::32-little>>)

    data
  end

  defp errno({7, _tag, <<errno::32-little>>}), do: errno
  defp errno(_other), do: nil

  # The names in a readdir reply.
  defp names(socket, fid, offset \\ 0) do
    {41, _, <<count::32-little, data::binary-size(count)>>} =
      t(socket, 40, 5, <<fid::32-little, offset::64-little, 8_000::32-little>>)

    entries(data, [])
  end

  defp entries(<<>>, acc), do: Enum.reverse(acc)

  defp entries(
         <<_qid::binary-size(13), _offset::64-little, _type, len::16-little,
           name::binary-size(len), rest::binary>>,
         acc
       ),
       do: entries(rest, [name | acc])

  defp requests(%{requests: agent}), do: Agent.get(agent, & &1)
  defp contents(context), do: Enum.filter(requests(context), &(&1 =~ ~r{/archive/tickets/\d+/.}))

  # Opens a path from the root on a fresh fid and returns its reply.
  defp open(socket, fid, names) do
    {111, _, _} = walk(socket, 1, fid, names)
    lopen(socket, fid)
  end

  # -- what costs a request ----------------------------------------------------------------------

  test "starting, attaching and looking at the root fetch nothing", context do
    {_pid, socket, _path, _cache} = start_server(context)
    attach(socket)

    {25, _, _} = t(socket, 24, 2, <<1::32-little, 0x7FF::64-little>>)
    {9, _, _} = t(socket, 8, 3, <<1::32-little>>)
    assert requests(context) == []
  end

  test "listing the root fetches the root listing and no ticket's, and reading the index no content",
       context do
    {_pid, socket, _path, _cache} = start_server(context)
    attach(socket)

    {13, _, _} = lopen(socket, 1)
    assert names(socket, 1) == [".", "..", "1", "2", "index.md"]
    assert requests(context) == ["/archive"]

    {111, _, _} = walk(socket, 1, 2, ["index.md"])
    {13, _, _} = lopen(socket, 2)
    assert read_all(socket, 2) == "hello"
    assert requests(context) == ["/archive"]
  end

  test "walking into a ticket fetches one listing, and no content", context do
    {_pid, socket, _path, _cache} = start_server(context)
    attach(socket)

    {111, _, _} = walk(socket, 1, 2, ["1"])
    {13, _, _} = lopen(socket, 2)
    assert names(socket, 2) == [".", "..", "plan.md", "plan.v001.md", "reports"]
    assert requests(context) == ["/archive", "/archive/tickets/1"]
    assert contents(context) == []

    # A ticket that is not in the root is not asked for at all.
    assert errno(walk(socket, 1, 3, ["9"])) == @enoent
    assert length(requests(context)) == 2
  end

  test "a file is fetched when opened, once, and bytes arrive as they are", context do
    {_pid, socket, _path, cache} = start_server(context)
    attach(socket)

    {13, _, _} = open(socket, 2, ["1", "plan.md"])
    assert read_all(socket, 2) == @plan
    {121, _, _} = t(socket, 120, 6, <<2::32-little>>)

    {13, _, _} = open(socket, 3, ["1", "plan.v001.md"])
    assert read_all(socket, 3) == @plan
    {13, _, _} = open(socket, 4, ["1", "plan.md"])
    assert read_all(socket, 4) == @plan
    assert contents(context) == ["/archive/tickets/1/#{@ref_plan}"]
    assert File.exists?(Path.join(cache, @ref_plan))

    # NUL, high bytes and invalid UTF-8, in a group's folder.
    {13, _, _} = open(socket, 5, ["1", "reports", "out.bin"])
    assert read_all(socket, 5) == @binary
  end

  test "a read past the end is empty, and a read of a part is that part", context do
    {_pid, socket, _path, _cache} = start_server(context)
    attach(socket)
    {13, _, _} = open(socket, 2, ["1", "plan.md"])

    {117, _, <<3::32-little, "The">>} =
      t(socket, 116, 4, <<2::32-little, 2::64-little, 3::32-little>>)

    {117, _, <<0::32-little>>} = t(socket, 116, 4, <<2::32-little, 999::64-little, 3::32-little>>)
  end

  # -- failures ----------------------------------------------------------------------------------

  test "a failed fetch is the errno that says why, leaves no file, and is tried again", context do
    {_pid, socket, _path, cache} = start_server(context)
    attach(socket)

    for {state, expected} <- [
          {{:status, 500}, @eio},
          {{:status, 404}, @enoent},
          {{:status, 401}, @eacces},
          {:short, @eio},
          {:unreachable, @etimedout}
        ] do
      Agent.update(context.content, fn _ -> state end)
      before = length(contents(context))

      assert errno(open(socket, 2, ["1", "plan.md"])) == expected, inspect(state)
      assert length(contents(context)) == before + 1
      refute File.exists?(Path.join(cache, @ref_plan))
      assert File.ls!(cache) == []
    end

    # The platform is back: the same read now works, because nothing remembered the failure.
    Agent.update(context.content, fn _ -> :ok end)
    {13, _, _} = open(socket, 2, ["1", "plan.md"])
    assert read_all(socket, 2) == @plan
  end

  test "a listing that cannot be fetched is an error on the walk, not a hang", context do
    Application.put_env(:forge_worker, :req_options,
      plug: fn conn -> Plug.Conn.send_resp(conn, 401, "") end
    )

    {_pid, socket, _path, _cache} = start_server(context)
    attach(socket)

    assert errno(walk(socket, 1, 2, ["1"])) == @eacces
  end

  test "an interrupted open is flushed and its answer never sent", context do
    test = self()
    Agent.update(context.content, fn _ -> {:hold, test} end)
    {_pid, socket, _path, _cache} = start_server(context)
    attach(socket)
    {111, _, _} = walk(socket, 1, 2, ["1", "plan.md"])

    :ok = send_t(socket, 12, 7, <<2::32-little, 0::32-little>>)
    assert_receive {:held, held}, 3_000

    # The kernel gives up on the open and flushes it; the flush is answered at once.
    assert {109, 8, <<>>} = t(socket, 108, 8, <<7::16-little>>)
    send(held, :release)

    # The server goes on serving, and the open it dropped is not answered.
    assert {:error, :timeout} = recv(socket, 300)
    {9, _, _} = t(socket, 8, 9, <<1::32-little>>)
  end

  # -- read-only ---------------------------------------------------------------------------------

  test "every message that would change anything is refused as a read-only filesystem", context do
    {_pid, socket, _path, _cache} = start_server(context)
    attach(socket)
    {111, _, _} = walk(socket, 1, 2, ["index.md"])

    for type <- [14, 16, 18, 20, 26, 32, 50, 70, 72, 74, 76, 118, 122, 102] do
      assert errno(t(socket, type, 20, <<2::32-little, 0::64>>)) == @erofs, "type #{type}"
    end

    assert errno(t(socket, 30, 20, <<2::32-little, 3::32-little>> <> str("user.x"))) == @enodata
    assert errno(t(socket, 22, 20, <<2::32-little>>)) == 22
    assert errno(t(socket, 52, 20, <<2::32-little>>)) == 95
    assert errno(t(socket, 200, 20, <<>>)) == 38
  end

  test "an open that would write is refused, whatever the file", context do
    {_pid, socket, _path, _cache} = start_server(context)
    attach(socket)
    {111, _, _} = walk(socket, 1, 2, ["index.md"])

    for flags <- [1, 2, 0o100, 0o1000, 0o2000, 0o1101] do
      assert errno(lopen(socket, 2, flags)) == @erofs, "flags #{flags}"
    end

    # The root as well, and a plain read of it is still fine.
    assert errno(lopen(socket, 1, 1)) == @erofs
    {13, _, _} = lopen(socket, 1, 0)
  end

  test "reading a folder, listing a file, or an unopened fid, are errors", context do
    {_pid, socket, _path, _cache} = start_server(context)
    attach(socket)
    {13, _, _} = lopen(socket, 1)

    assert errno(t(socket, 116, 4, <<1::32-little, 0::64, 10::32-little>>)) == @eisdir
    {111, _, _} = walk(socket, 1, 2, ["index.md"])
    assert errno(t(socket, 116, 4, <<2::32-little, 0::64, 10::32-little>>)) == @ebadf
    {13, _, _} = lopen(socket, 2)
    assert errno(t(socket, 40, 5, <<2::32-little, 0::64, 10::32-little>>)) == @enotdir
    assert errno(t(socket, 24, 6, <<77::32-little, 0::64>>)) == @ebadf
  end

  test "a name cannot walk out of the tree or hide a path in itself", context do
    {_pid, socket, _path, _cache} = start_server(context)
    attach(socket)

    # `..` is navigation and stops at the root.
    assert {111, _, <<2::16-little, _::binary>>} = walk(socket, 1, 2, ["..", ".."])
    assert errno(walk(socket, 1, 3, ["1", "..", "..", "etc", "passwd"])) == nil
    assert errno(walk(socket, 1, 4, ["../etc"])) == @enoent
    assert errno(walk(socket, 1, 4, ["1/plan.md"])) == @enoent
    # Under a ticket: one name with a `/` in it must not reach a group's file as `group/file`.
    {111, _, _} = walk(socket, 1, 5, ["1"])
    assert errno(walk(socket, 5, 6, ["reports/out.bin"])) == @enoent
    assert errno(walk(socket, 1, 4, ["a" <> <<0>>])) == @enoent
    assert errno(walk(socket, 1, 4, [""])) == @enoent
    assert errno(walk(socket, 99, 4, ["1"])) == @ebadf
  end

  # -- refreshing --------------------------------------------------------------------------------

  test "a ticket in flight shows a new version after the interval, and an open folder keeps what it listed",
       context do
    Application.put_env(:forge_worker, :archive_listing_ttl_ms, 150)
    {_pid, socket, _path, _cache} = start_server(context)
    attach(socket)

    {111, _, _} = walk(socket, 1, 2, ["1"])
    {13, _, _} = lopen(socket, 2)
    first = names(socket, 2)
    refute "plan.v002.md" in first

    Agent.update(context.extra, fn _ -> [entry("plan.v002.md", @ref_old, "old")] end)
    # Within the interval nothing is asked again.
    {111, _, _} = walk(socket, 1, 3, ["1"])
    assert length(requests(context)) == 2
    Process.sleep(250)

    {111, _, _} = walk(socket, 1, 4, ["1", "plan.v002.md"])
    {13, _, _} = lopen(socket, 4)
    assert read_all(socket, 4) == "old"

    # The folder opened before the refresh lists what it opened.
    assert names(socket, 2) == first
  end

  test "a refresh that fails keeps what was listed", context do
    Application.put_env(:forge_worker, :archive_listing_ttl_ms, 100)
    {_pid, socket, _path, _cache} = start_server(context)
    attach(socket)
    {111, _, _} = walk(socket, 1, 2, ["1", "plan.md"])

    Application.put_env(:forge_worker, :req_options,
      plug: fn conn -> Plug.Conn.send_resp(conn, 500, "") end
    )

    Process.sleep(200)
    {111, _, _} = walk(socket, 1, 3, ["1", "plan.md"])
  end

  # -- the connection ----------------------------------------------------------------------------

  test "only the first connection is accepted, and the socket and cache go with the server",
       context do
    {pid, socket, path, cache} = start_server(context)
    attach(socket)

    assert {:error, _} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false])
    assert File.exists?(cache)

    :ok = Server.stop(pid)
    refute File.exists?(path)
    refute File.exists?(cache)
  end

  test "the server ends when the kernel closes the connection", context do
    {pid, socket, path, _cache} = start_server(context)
    ref = Process.monitor(pid)
    :gen_tcp.close(socket)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    refute File.exists?(path)
  end

  test "a message that is not the protocol closes the connection", context do
    {pid, socket, _path, _cache} = start_server(context)
    ref = Process.monitor(pid)
    :gen_tcp.send(socket, <<1, 0, 0, 0, 0>>)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  test "a client that asks for another protocol is told there is none", context do
    {_pid, socket, _path, _cache} = start_server(context)

    assert {101, _, <<0::32-little, 7::16-little, "unknown">>} =
             t(socket, 100, 0xFFFF, <<65_536::32-little>> <> str("9P2000.u"))
  end
end
