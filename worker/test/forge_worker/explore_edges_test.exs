defmodule ForgeWorker.ExploreEdgesTest do
  @moduledoc """
  The ends of `ForgeWorker.Explore` that `ExploreTest` does not reach: what is neither a file, a
  folder nor a link, a folder the machine cannot read, a request that is malformed, and a download
  that cannot start, is refused by the platform, or ends badly.

  Not async: the platform's address, the Req plug and `PATH` are the node's.
  """

  use ExUnit.Case, async: false

  import ForgeWorker.Fixtures, only: [tmp_dir: 1, uuid: 0]

  alias ForgeWorker.Explore
  alias ForgeWorker.Job.CommandCopy

  @ticket "5f0a6d1e-0000-4000-8000-0000000000c1"

  setup do
    root = tmp_dir("edges-root")
    tree = tmp_dir("edges-tree")
    job = uuid()

    File.write!(Path.join(tree, "empty.txt"), "")
    File.write!(Path.join(tree, "big.bin"), :binary.copy("0123456789abcdef", 200_000))
    File.write!(Path.join(tree, "secret"), "closed")
    File.mkdir_p!(Path.join(tree, "locked"))
    {_out, 0} = System.cmd("mkfifo", [Path.join(tree, "pipe")])

    key = %{ticket: @ticket, epoch: 0}

    {:ok, _size, _folders} =
      CommandCopy.keep(root, key, tree, %{"job_id" => job, "command" => "test", "commit" => "c"})

    on_exit(fn ->
      Application.delete_env(:forge_worker, :platform_url)
      Application.delete_env(:forge_worker, :req_options)
      Application.delete_env(:forge_worker, :explore_progress_ms)
      Application.delete_env(:forge_worker, :explore_hold_renew_ms)
    end)

    %{root: root, job: job, key: key, copy: CommandCopy.path(root, key)}
  end

  defp root?, do: System.cmd("id", ["-u"]) == {"0\n", 0}

  defp ask(context, op, path, extra) do
    test = self()

    payload =
      Map.merge(
        %{
          "ref" => "r1",
          "op" => op,
          "ticket" => @ticket,
          "copy" => context.job,
          "path_b64" => Base.encode64(path)
        },
        extra
      )

    :ok = Explore.run(payload, context.root, fn reply -> send(test, {:reply, reply}) end)
    replies([])
  end

  defp replies(acc) do
    receive do
      {:reply, reply} -> replies([reply | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp answer(context, op, path, extra \\ %{}) do
    assert [reply] = ask(context, op, path, extra)
    reply
  end

  describe "what is neither a file, a folder nor a link" do
    test "is listed as other, with no size and no count", context do
      assert %{"ok" => %{"entries" => entries}} = answer(context, "list", "")
      pipe = Enum.find(entries, &(Base.decode64!(&1["name_b64"]) == "pipe"))

      assert %{"kind" => "other"} = pipe
      refute Map.has_key?(pipe, "size")
      refute Map.has_key?(pipe, "entries")
      refute Map.has_key?(pipe, "target_b64")
    end

    test "has facts and no content, is not hashed, and is not read", context do
      assert %{"ok" => %{"kind" => "other", "text" => false} = ok} =
               answer(context, "file", "pipe")

      refute Map.has_key?(ok, "content_b64")
      assert %{"error" => "not_a_file"} = answer(context, "hash", "pipe")
    end
  end

  test "an empty file is text with no content", context do
    assert %{"ok" => %{"kind" => "file", "size" => 0, "text" => true, "content_b64" => ""}} =
             answer(context, "file", "empty.txt")

    empty = :sha256 |> :crypto.hash("") |> Base.encode16(case: :lower)
    assert %{"ok" => %{"sha256" => ^empty, "size" => 0}} = answer(context, "hash", "empty.txt")
  end

  test "a folder the machine cannot read is a failure the platform can word, not a crash",
       context do
    if root?() do
      :ok
    else
      File.chmod!(Path.join(context.copy, "locked"), 0o000)
      on_exit(fn -> File.chmod(Path.join(context.copy, "locked"), 0o755) end)

      assert %{"error" => "failed"} = answer(context, "list", "locked")
      assert %{"ok" => %{"kind" => "dir", "entries" => nil}} = answer(context, "file", "locked")
    end
  end

  describe "a request that is malformed" do
    test "has a path that is not base64, or no op, or an op nobody knows", context do
      assert %{"error" => "path_refused"} = answer(context, "list", "", %{"path_b64" => "!!"})
      assert %{"error" => "path_refused"} = answer(context, "list", "", %{"path_b64" => 7})
      assert %{"error" => "failed"} = answer(context, "list", "", %{"op" => nil})
      assert %{"error" => "failed"} = answer(context, "list", "", %{"op" => "delete"})
    end

    test "has an offset that is not a count, which is the first page", context do
      assert %{"ok" => %{"offset" => 0}} = answer(context, "list", "", %{"offset" => -4})
      assert %{"ok" => %{"offset" => 0}} = answer(context, "list", "", %{"offset" => "2"})
    end

    test "that crashes while it is answered is answered `failed`, once", context do
      {:ok, calls} = Agent.start_link(fn -> 0 end)
      test = self()

      reply = fn message ->
        if Agent.get_and_update(calls, &{&1, &1 + 1}) == 0, do: raise("the first send fails")
        send(test, {:reply, message})
      end

      payload = %{
        "ref" => "r9",
        "op" => "list",
        "ticket" => @ticket,
        "copy" => context.job,
        "path_b64" => ""
      }

      assert :ok = Explore.run(payload, context.root, reply)
      assert_received {:reply, %{"ref" => "r9", "error" => "failed"}}
    end
  end

  describe "a download" do
    setup do
      Application.put_env(:forge_worker, :platform_url, "http://platform.test")
      test = self()

      Application.put_env(:forge_worker, :req_options,
        plug: fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn, length: 100_000_000)
          send(test, {:posted, Map.new(conn.req_headers), body})
          Plug.Conn.send_resp(conn, 200, "")
        end
      )

      :ok
    end

    defp stream, do: %{"stream" => "stream-abcdef12", "secret" => "s3cret"}

    test "says how far it has got and how much it sent, and renews the hold as it goes",
         context do
      Application.put_env(:forge_worker, :explore_progress_ms, 0)
      Application.put_env(:forge_worker, :explore_hold_renew_ms, 0)

      replies = ask(context, "download", "big.bin", stream())

      assert %{"ok" => %{"bytes" => 3_200_000}} = List.last(replies)
      progress = for %{"progress" => progress} <- replies, do: progress
      assert progress != []
      assert Enum.all?(progress, &(&1["total"] == nil and &1["done"] > 0))
      assert_received {:posted, %{"x-forge-kind" => "file"}, body}
      assert byte_size(body) == 3_200_000
      assert CommandCopy.held?(context.root, @ticket, context.job)
    end

    test "sends something that is not a file or a folder as a tar of it", context do
      assert %{"ok" => %{"bytes" => bytes}} = answer(context, "download", "pipe", stream())

      assert_received {:posted, %{"x-forge-kind" => "tar"} = headers, body}
      assert Base.decode64!(headers["x-forge-name-b64"]) == "pipe"
      assert bytes == byte_size(body)
    end

    test "is a failure when this machine does not know the platform's address", context do
      Application.delete_env(:forge_worker, :platform_url)

      assert %{"error" => "failed"} = answer(context, "download", "empty.txt", stream())
      refute_received {:posted, _headers, _body}
    end

    test "is a failure when the platform cannot be reached", context do
      Application.delete_env(:forge_worker, :req_options)
      Application.put_env(:forge_worker, :platform_url, "http://127.0.0.1:1")

      assert %{"error" => "failed"} = answer(context, "download", "empty.txt", stream())
    end

    test "is a failure, and sends nothing, when tar cannot be started", context do
      bin = tmp_dir("edges-bin")
      sh = System.find_executable("sh")
      mkfifo = System.find_executable("mkfifo")
      File.ln_s!(sh, Path.join(bin, "sh"))
      File.ln_s!(mkfifo, Path.join(bin, "mkfifo"))

      path = System.get_env("PATH")
      System.put_env("PATH", bin)
      on_exit(fn -> System.put_env("PATH", path) end)

      assert %{"error" => "failed"} = answer(context, "download", "locked", stream())
      refute_received {:posted, _headers, _body}
    end

    test "is not a download that ended when tar failed halfway", context do
      if root?() do
        :ok
      else
        File.chmod!(Path.join(context.copy, "secret"), 0o000)
        on_exit(fn -> File.chmod(Path.join(context.copy, "secret"), 0o644) end)

        assert %{"error" => "failed"} = answer(context, "download", "", stream())
      end
    end
  end
end
