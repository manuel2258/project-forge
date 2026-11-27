defmodule ForgeWorker.ExploreTest do
  @moduledoc """
  Looking into a ticket's command copy on this machine (`ForgeWorker.Explore`,
  `docs/design/worker-tier.md` § Looking into a copy): over a real kept copy, with the guards the
  refinement's security criteria (34 and 35) name aimed at: the ticket's own copy only, no path out
  of it, and a link never followed.

  Not async: the platform's address and the Req plug are the node's.
  """

  use ExUnit.Case, async: false

  import ForgeWorker.Fixtures, only: [tmp_dir: 1, uuid: 0]

  alias ForgeWorker.Explore
  alias ForgeWorker.Job.CommandCopy

  @ticket "5f0a6d1e-0000-4000-8000-0000000000b1"
  @limit 1024 * 1024

  setup do
    root = tmp_dir("explore-root")
    tree = tmp_dir("explore-tree")
    job = uuid()

    File.write!(Path.join(tree, "a.txt"), "hello\n")
    File.write!(Path.join(tree, "bin.dat"), <<1, 2, 0, 3>>)
    File.write!(Path.join(tree, "big.txt"), String.duplicate("x", @limit + 10))
    File.write!(Path.join(tree, "cut.txt"), String.duplicate("a", @limit - 1) <> "é" <> "tail")
    File.write!(Path.join(tree, <<"bad", 255, ".txt">>), "odd name")
    File.mkdir_p!(Path.join(tree, "dir1"))
    for n <- 1..3, do: File.write!(Path.join(tree, "dir1/f#{n}"), "f#{n}")
    File.mkdir_p!(Path.join(tree, "dir2"))
    File.mkdir_p!(Path.join(tree, "many"))

    for n <- 0..249,
        do: File.write!(Path.join(tree, "many/f#{String.pad_leading("#{n}", 3, "0")}"), "")

    File.ln_s!("/etc/passwd", Path.join(tree, "l"))
    File.ln_s!("/etc", Path.join(tree, "link-to-etc"))
    File.ln_s!("dir1", Path.join(tree, "link-to-dir1"))

    key = %{ticket: @ticket, epoch: 0}

    {:ok, _size, _folders} =
      CommandCopy.keep(root, key, tree, %{"job_id" => job, "command" => "test", "commit" => "c"})

    %{root: root, job: job, key: key}
  end

  # The answer to one request: its last reply, and the ones before it.
  defp ask(context, op, path, extra \\ %{}) do
    test = self()

    payload =
      Map.merge(
        %{
          "ref" => "r1",
          "op" => op,
          "ticket" => Map.get(extra, "ticket", @ticket),
          "copy" => Map.get(extra, "copy", context.job),
          "path_b64" => if(is_binary(path), do: Base.encode64(path), else: path)
        },
        extra
      )

    :ok = Explore.run(payload, context.root, fn reply -> send(test, {:reply, reply}) end)
    replies(context, [])
  end

  defp replies(context, acc) do
    receive do
      {:reply, reply} -> replies(context, [reply | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp answer(context, op, path, extra \\ %{}) do
    assert [%{"ref" => "r1"} = reply] = ask(context, op, path, extra)
    reply
  end

  describe "which copy" do
    test "is the ticket's own, found by the ticket's id and the job that kept it", context do
      assert %{"ok" => %{"entries" => _}} = answer(context, "list", "")
    end

    test "is not another ticket's, nor a job that did not keep this one, nor an id that is not one",
         context do
      other = "5f0a6d1e-0000-4000-8000-0000000000b2"

      for extra <- [
            %{"ticket" => other},
            %{"copy" => uuid()},
            %{"ticket" => "../#{@ticket}"},
            %{"copy" => "../../etc"},
            %{"ticket" => nil},
            %{"copy" => 7}
          ] do
        assert %{"error" => "no_copy"} = answer(context, "list", "", extra), inspect(extra)
      end
    end

    test "is held from the moment it is opened", context do
      refute CommandCopy.held?(context.root, @ticket, context.job)
      answer(context, "list", "")
      assert CommandCopy.held?(context.root, @ticket, context.job)
    end

    test "is still answered after a keep moved it aside", context do
      answer(context, "list", "")
      new = uuid()
      tree = tmp_dir("explore-new")
      File.write!(Path.join(tree, "new.txt"), "new")

      {:ok, _size, _folders} =
        CommandCopy.keep(context.root, context.key, tree, %{"job_id" => new, "commit" => "c"})

      assert %{"ok" => %{"entries" => [%{"kind" => "file"}]}} =
               answer(context, "list", "", %{"copy" => new})

      assert %{"ok" => %{"entries" => entries}} = answer(context, "list", "")
      assert length(entries) == 11
    end
  end

  describe "which path" do
    test "is refused when it leaves the copy, before anything is looked at", context do
      for path <- ["..", "../x", "dir1/../../x", "/etc/passwd", "a//b", ".", "dir1/", <<"a", 0>>] do
        assert %{"error" => "path_refused"} = answer(context, "file", path), inspect(path)
      end

      assert %{"error" => "path_refused"} = answer(context, "list", nil)
    end

    test "is refused when a link is on the way, whatever is on the other side of it", context do
      assert %{"error" => "path_refused"} = answer(context, "file", "link-to-etc/passwd")
      assert %{"error" => "not_a_folder"} = answer(context, "list", "link-to-etc")
      assert %{"error" => "path_refused"} = answer(context, "list", "link-to-dir1/f1")
      assert %{"error" => "path_refused"} = answer(context, "hash", "link-to-etc/passwd")
    end

    test "is not found when it is not there, or a file is on the way", context do
      assert %{"error" => "path_not_found"} = answer(context, "file", "nothing")
      assert %{"error" => "path_not_found"} = answer(context, "file", "a.txt/more")
      assert %{"error" => "path_not_found"} = answer(context, "list", "dir1/nothing")
    end
  end

  describe "list" do
    test "is folders first and then the rest, each by name, with what each is", context do
      assert %{"ok" => %{"entries" => entries, "total" => total, "offset" => 0}} =
               answer(context, "list", "")

      assert total == 11
      names = Enum.map(entries, &Base.decode64!(&1["name_b64"]))

      assert names == [
               "dir1",
               "dir2",
               "many",
               "a.txt",
               <<"bad", 255, ".txt">>,
               "big.txt",
               "bin.dat",
               "cut.txt",
               "l",
               "link-to-dir1",
               "link-to-etc"
             ]

      by_name = Map.new(entries, &{Base.decode64!(&1["name_b64"]), &1})
      assert %{"kind" => "dir", "entries" => 3} = by_name["dir1"]
      assert %{"kind" => "dir", "entries" => 0} = by_name["dir2"]
      assert %{"kind" => "dir", "entries" => 250} = by_name["many"]
      assert %{"kind" => "file", "size" => 6, "mtime" => mtime} = by_name["a.txt"]
      assert is_integer(mtime)
      refute Map.has_key?(by_name["a.txt"], "entries")
    end

    test "carries a link's target as text and does not follow it", context do
      assert %{"ok" => %{"entries" => entries}} = answer(context, "list", "")
      by_name = Map.new(entries, &{Base.decode64!(&1["name_b64"]), &1})

      assert %{"kind" => "link", "target_b64" => etc} = by_name["link-to-etc"]
      assert Base.decode64!(etc) == "/etc"
      assert Base.decode64!(by_name["l"]["target_b64"]) == "/etc/passwd"
      refute Map.has_key?(by_name["link-to-etc"], "entries")
      refute Map.has_key?(by_name["l"], "size")
    end

    test "names a file that is not text in base64, and lists it", context do
      assert %{"ok" => %{"entries" => entries}} = answer(context, "list", "")
      assert Enum.any?(entries, &(Base.decode64!(&1["name_b64"]) == <<"bad", 255, ".txt">>))
    end

    test "is two hundred entries at a time, from the offset asked", context do
      assert %{"ok" => %{"entries" => first, "total" => 250, "offset" => 0}} =
               answer(context, "list", "many")

      assert length(first) == 200

      assert %{"ok" => %{"entries" => rest, "offset" => 200}} =
               answer(context, "list", "many", %{"offset" => 200})

      assert length(rest) == 50
      assert Base.decode64!(hd(rest)["name_b64"]) == "f200"
    end

    test "is for a folder only", context do
      assert %{"error" => "not_a_folder"} = answer(context, "list", "a.txt")
      assert %{"error" => "not_a_folder"} = answer(context, "list", "l")
    end

    test "lists a folder inside the copy by its path", context do
      assert %{"ok" => %{"entries" => entries}} = answer(context, "list", "dir1")
      assert Enum.map(entries, &Base.decode64!(&1["name_b64"])) == ["f1", "f2", "f3"]
    end
  end

  describe "file" do
    test "gives a text file's facts and its content", context do
      assert %{
               "ok" => %{
                 "kind" => "file",
                 "size" => 6,
                 "text" => true,
                 "truncated" => false,
                 "content_b64" => content
               }
             } = answer(context, "file", "a.txt")

      assert Base.decode64!(content) == "hello\n"
    end

    test "gives a file that is not text its facts and no content", context do
      assert %{"ok" => %{"kind" => "file", "size" => 4, "text" => false} = ok} =
               answer(context, "file", "bin.dat")

      refute Map.has_key?(ok, "content_b64")
    end

    test "gives the first mebibyte of a longer file and says so", context do
      assert %{"ok" => %{"text" => true, "truncated" => true, "size" => size} = ok} =
               answer(context, "file", "big.txt")

      assert size == @limit + 10
      assert byte_size(Base.decode64!(ok["content_b64"])) == @limit
    end

    test "is still text when the mebibyte ends inside a character", context do
      assert %{"ok" => %{"text" => true, "truncated" => true} = ok} =
               answer(context, "file", "cut.txt")

      assert byte_size(Base.decode64!(ok["content_b64"])) == @limit
    end

    test "gives a link its target and never its target's content", context do
      assert %{"ok" => %{"kind" => "link", "text" => false, "target_b64" => target} = ok} =
               answer(context, "file", "l")

      assert Base.decode64!(target) == "/etc/passwd"
      refute Map.has_key?(ok, "content_b64")
      refute Map.has_key?(ok, "size")
    end

    test "gives a folder its entry count", context do
      assert %{"ok" => %{"kind" => "dir", "entries" => 3}} = answer(context, "file", "dir1")
    end

    test "is text only by the bytes: a NUL, or invalid UTF-8 in the middle, is not text" do
      assert Explore.text?("plain", false)
      refute Explore.text?(<<"a", 0, "b">>, false)
      refute Explore.text?(<<"a", 255, "b">>, false)
      refute Explore.text?(<<"a", 255>>, true)
      assert Explore.text?(<<"a", 195>>, true)
      refute Explore.text?(<<"a", 195>>, false)
    end
  end

  describe "hash" do
    test "is the file's SHA-256, and its size", context do
      expected = :sha256 |> :crypto.hash("hello\n") |> Base.encode16(case: :lower)
      assert %{"ok" => %{"sha256" => ^expected, "size" => 6}} = answer(context, "hash", "a.txt")
    end

    test "is for a regular file only", context do
      for path <- ["dir1", "l", ""] do
        assert %{"error" => "not_a_file"} = answer(context, "hash", path), path
      end
    end

    test "says how far it has got while it reads", context do
      Application.put_env(:forge_worker, :explore_progress_ms, 0)
      on_exit(fn -> Application.delete_env(:forge_worker, :explore_progress_ms) end)

      replies = ask(context, "hash", "big.txt")

      assert [%{"progress" => %{"done" => done, "total" => total}} | _] = replies
      assert total == @limit + 10
      assert done > 0
      assert %{"ok" => %{"sha256" => _}} = List.last(replies)
      assert Enum.all?(replies, &(&1["ref"] == "r1"))
    end
  end

  describe "download" do
    setup do
      Application.put_env(:forge_worker, :platform_url, "http://platform.test")
      test = self()

      Application.put_env(:forge_worker, :req_options,
        plug: fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn, length: 100_000_000)

          send(test, {
            :posted,
            conn.request_path,
            Plug.Conn.get_req_header(conn, "authorization"),
            Map.new(conn.req_headers),
            body
          })

          Plug.Conn.send_resp(conn, 200, "")
        end
      )

      on_exit(fn ->
        Application.delete_env(:forge_worker, :platform_url)
        Application.delete_env(:forge_worker, :req_options)
      end)
    end

    defp download(context, path) do
      extra = %{"stream" => "stream-abcdef12", "secret" => "s3cret"}
      reply = answer(context, "download", path, extra)
      assert_received {:posted, request_path, auth, headers, body}
      {reply, request_path, auth, headers, body}
    end

    defp tar_listing(body) do
      file = Path.join(tmp_dir("explore-tar"), "out.tar")
      File.write!(file, body)
      {out, 0} = System.cmd("tar", ["-tvf", file], stderr_to_stdout: true)
      out
    end

    test "sends a file as itself, with the secret as a bearer, to the stream's door", context do
      {reply, path, auth, headers, body} = download(context, "a.txt")

      assert %{"ok" => %{"bytes" => 6}} = reply
      assert path == "/worker-streams/stream-abcdef12"
      assert auth == ["Bearer s3cret"]
      assert headers["x-forge-kind"] == "file"
      assert Base.decode64!(headers["x-forge-name-b64"]) == "a.txt"
      assert body == "hello\n"
    end

    test "sends a folder as a tar named from the copy's root", context do
      {reply, _path, _auth, headers, body} = download(context, "dir1")

      assert %{"ok" => %{"bytes" => bytes}} = reply
      assert bytes == byte_size(body)
      assert headers["x-forge-kind"] == "tar"
      listing = tar_listing(body)
      assert listing =~ "dir1/f1"
      refute listing =~ "a.txt"
    end

    test "sends the whole copy as a tar with a link as a link, never as what it points at",
         context do
      {_reply, _path, _auth, headers, body} = download(context, "")

      assert headers["x-forge-kind"] == "tar"
      listing = tar_listing(body)
      assert listing =~ "a.txt"
      assert listing =~ "dir1/f3"
      assert listing =~ ~r/link-to-etc -> \/etc/
      refute listing =~ "link-to-etc/"
    end

    test "renews the hold on the copy", context do
      answer(context, "list", "")

      File.touch!(
        CommandCopy.hold_path(context.root, @ticket, context.job),
        System.os_time(:second) - 5_000
      )

      refute CommandCopy.held?(context.root, @ticket, context.job)
      {_reply, _path, _auth, _headers, _body} = download(context, "a.txt")
      assert CommandCopy.held?(context.root, @ticket, context.job)
    end

    test "is refused for a path out of the copy, and sends nothing", context do
      extra = %{"stream" => "stream-abcdef12", "secret" => "s3cret"}

      assert %{"error" => "path_refused"} =
               answer(context, "download", "link-to-etc/passwd", extra)

      refute_received {:posted, _path, _auth, _headers, _body}
    end

    test "needs a stream and a secret, and a stream id that is only what an id is", context do
      assert %{"error" => "failed"} = answer(context, "download", "a.txt")

      for stream <- ["../x", "a b", "short"] do
        extra = %{"stream" => stream, "secret" => "s"}
        assert %{"error" => "failed"} = answer(context, "download", "a.txt", extra), stream
      end

      refute_received {:posted, _path, _auth, _headers, _body}
    end

    test "is an error when the platform refuses the stream", context do
      Application.put_env(:forge_worker, :req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 403, "no") end
      )

      extra = %{"stream" => "stream-abcdef12", "secret" => "wrong"}
      assert %{"error" => "failed"} = answer(context, "download", "a.txt", extra)
    end
  end

  test "a request with no ref is not answered, and one that is not an op is" do
    test = self()
    reply = fn message -> send(test, {:reply, message}) end

    assert :ok = Explore.run(%{"op" => "list"}, "/nonexistent", reply)
    assert :ok = Explore.run("nonsense", "/nonexistent", reply)
    refute_received {:reply, _message}

    assert :ok = Explore.run(%{"ref" => "r", "op" => "delete"}, "/nonexistent", reply)
    assert_received {:reply, %{"ref" => "r", "error" => "failed"}}
  end
end
