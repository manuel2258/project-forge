defmodule Forge.GitLfsTest do
  @moduledoc """
  The object store beside a repository, and the pointer reader the pages use
  (`docs/design/git-hosting.md` § Git LFS).
  """

  use ExUnit.Case, async: true

  import Forge.LfsFixtures

  alias Forge.Git.Lfs
  alias Forge.Git.Lfs.Pointer
  alias Forge.GitFixtures

  setup do
    repo = Path.join(GitFixtures.tmp_dir("lfs-store"), "r.git")
    File.mkdir_p!(repo)
    %{repo: repo}
  end

  # A reader that hands out `chunks` one by one, calling `spy` before each.
  defp reader(spy \\ fn _n -> :ok end) do
    fn
      {[], n} ->
        {:eof, {[], n}}

      {[chunk | rest], n} ->
        spy.(n)
        {:ok, chunk, {rest, n + 1}}
    end
  end

  describe "path/2" do
    test "is the layout git lfs uses, and refuses anything but 64 lowercase hex", %{repo: repo} do
      oid = oid("x")
      assert {:ok, path} = Lfs.path(repo, oid)

      assert path ==
               Path.join([
                 repo,
                 "lfs",
                 "objects",
                 String.slice(oid, 0, 2),
                 String.slice(oid, 2, 2),
                 oid
               ])

      for bad <- [
            oid <> "\n",
            "",
            "..",
            String.upcase(oid),
            String.slice(oid, 1, 63),
            oid <> "0",
            "../" <> oid,
            nil,
            5
          ] do
        assert Lfs.path(repo, bad) == :error
        refute Lfs.held?(repo, bad)
      end
    end
  end

  describe "touch/2" do
    test "restarts the clock of an object that is there", %{repo: repo} do
      oid = store!(repo, "held")
      {:ok, path} = Lfs.path(repo, oid)
      File.touch!(path, 1_000_000)

      assert :ok = Lfs.touch(repo, oid)
      assert_in_delta File.stat!(path, time: :posix).mtime, System.os_time(:second), 5
    end

    test "never makes an object of one that is gone", %{repo: repo} do
      oid = oid("deleted between a batch's look and its touch")
      # Its directories are there, as they are once any object of the same prefix was held.
      File.mkdir_p!(Path.dirname(elem(Lfs.path(repo, oid), 1)))

      assert :ok = Lfs.touch(repo, oid)
      refute Lfs.held?(repo, oid)
      refute File.exists?(elem(Lfs.path(repo, oid), 1))
      assert :ok = Lfs.touch(repo, "../nope")
    end
  end

  describe "put/5" do
    test "keeps an object whose bytes hash to its oid and match its size", %{repo: repo} do
      oid = oid("hello world")

      assert {:ok, {[], 2}} = Lfs.put(repo, oid, 11, reader(), {["hello ", "world"], 0})

      assert File.read!(elem(Lfs.path(repo, oid), 1)) == "hello world"
      assert Lfs.size(repo, oid) == 11
      assert File.ls!(Lfs.incoming_dir(repo)) == []
    end

    test "refuses the wrong hash, a short body and a long one, and keeps nothing", %{repo: repo} do
      oid = oid("hello world")

      assert {{:error, :hash}, _} =
               Lfs.put(repo, oid, 11, reader(), {["HELLO WORLD"], 0})

      assert {{:error, :size}, _} = Lfs.put(repo, oid, 11, reader(), {["hello"], 0})

      assert {{:error, :size}, _} =
               Lfs.put(repo, oid, 11, reader(), {["hello world!"], 0})

      assert {{:error, :size}, _} =
               Lfs.put(
                 repo,
                 oid,
                 11,
                 reader(),
                 {["hello ", "world", "!"], 0}
               )

      assert {{:error, :bad_oid}, _} = Lfs.put(repo, "../x", 1, reader(), {[], 0})

      refute Lfs.held?(repo, oid)
      assert File.ls!(Lfs.incoming_dir(repo)) == []
    end

    test "stops asking for more once the body has outrun its size", %{repo: repo} do
      oid = oid("aaaa")

      # The third chunk is never asked for: the second already passes the four bytes declared.
      spy = fn
        2 -> flunk("a body past its size was read on")
        _n -> :ok
      end

      chunks = ["aaa", "aaa", "aaa"]
      assert {{:error, :size}, _} = Lfs.put(repo, oid, 4, reader(spy), {chunks, 0})
      assert File.ls!(Lfs.incoming_dir(repo)) == []
    end

    test "a reader that fails partway leaves nothing", %{repo: repo} do
      oid = oid("hello world")

      failing = fn
        {0, nil} -> {:ok, "hello ", {1, nil}}
        {1, nil} -> {:error, :closed, {1, nil}}
      end

      assert {{:error, {:read, :closed}}, _} = Lfs.put(repo, oid, 11, failing, {0, nil})
      refute Lfs.held?(repo, oid)
      assert File.ls!(Lfs.incoming_dir(repo)) == []
    end

    test "a reader that raises leaves nothing either", %{repo: repo} do
      oid = oid("hello world")

      raising = fn
        0 -> {:ok, "hello ", 1}
        1 -> raise "boom"
      end

      assert_raise RuntimeError, "boom", fn -> Lfs.put(repo, oid, 11, raising, 0) end
      refute Lfs.held?(repo, oid)
      assert File.ls!(Lfs.incoming_dir(repo)) == []
    end

    test "is written to disk as it arrives, not held and written at the end", %{repo: repo} do
      oid = oid("aaaabbbbcccc")
      chunks = ["aaaa", "bbbb", "cccc"]
      dir = Lfs.incoming_dir(repo)

      # Before the second chunk is asked for, the first is already in the file; before the third,
      # the first two are. A put that buffered everything and wrote it at the end sees none.
      spy = fn
        0 ->
          :ok

        n ->
          assert [file] = File.ls!(dir)
          assert File.stat!(Path.join(dir, file)).size == n * 4
      end

      assert {:ok, _} = Lfs.put(repo, oid, 12, reader(spy), {chunks, 0})
    end

    test "two uploads of one object at once leave one correct copy", %{repo: repo} do
      content = String.duplicate("x", 200_000)
      oid = oid(content)
      chunks = for <<chunk::binary-size(50_000) <- content>>, do: chunk

      results =
        1..8
        |> Task.async_stream(fn _n ->
          Lfs.put(repo, oid, byte_size(content), reader(), {chunks, 0})
        end)
        |> Enum.map(fn {:ok, {result, _state}} -> result end)

      assert Enum.all?(results, &(&1 == :ok))
      assert File.read!(elem(Lfs.path(repo, oid), 1)) == content
      assert Lfs.objects(repo) == [oid]
      assert File.ls!(Lfs.incoming_dir(repo)) == []
    end

    test "an empty object is an object", %{repo: repo} do
      assert {:ok, _} = Lfs.put(repo, oid(""), 0, reader(), {[], 0})
      assert Lfs.held?(repo, oid(""))
    end
  end

  describe "with_lock/3" do
    test "an exclusive lock waits for a shared one, and the lock ends with the function", %{
      repo: repo
    } do
      parent = self()

      holder =
        Task.async(fn ->
          Lfs.with_lock(repo, :shared, fn ->
            send(parent, :held)
            receive do: (:release -> :released)
          end)
        end)

      # The first `flock` has to start, which a busy machine takes its time over.
      assert_receive :held, 5_000

      # Another shared lock is granted at once; an exclusive one is not.
      assert Lfs.with_lock(repo, :shared, fn -> :also end) == :also

      waiting = Task.async(fn -> Lfs.with_lock(repo, :exclusive, fn -> :exclusive end) end)
      assert Task.yield(waiting, 400) == nil

      send(holder.pid, :release)
      assert Task.await(holder) == :released
      assert Task.await(waiting) == :exclusive
      assert Lfs.with_lock(repo, :exclusive, fn -> :again end) == :again
    end
  end

  describe "Pointer.parse/1 agrees with git lfs" do
    @oid String.duplicate("a", 64)
    @v1 "version https://git-lfs.github.com/spec/v1\n"

    # Every row is also put to `git lfs pointer --check`, the oracle, and the two must agree.
    for {name, text, parses} <- [
          {"valid", @v1 <> "oid sha256:#{@oid}\nsize 12\n", true},
          {"no trailing newline", @v1 <> "oid sha256:#{@oid}\nsize 12", true},
          {"keys out of order", @v1 <> "size 12\noid sha256:#{@oid}\n", false},
          {"an extra key after the size", @v1 <> "oid sha256:#{@oid}\nsize 12\nfoo bar\n", false},
          {"an ext line before the oid",
           @v1 <> "ext-0-a sha256:#{@oid}\noid sha256:#{@oid}\nsize 12\n", true},
          {"the hawser alias",
           "version https://hawser.github.com/spec/v1\noid sha256:#{@oid}\nsize 12\n", true},
          {"another version",
           "version https://git-lfs.github.com/spec/v2\noid sha256:#{@oid}\nsize 12\n", false},
          {"an upper-case oid", @v1 <> "oid sha256:#{String.upcase(@oid)}\nsize 12\n", false},
          {"a short oid", @v1 <> "oid sha256:#{String.slice(@oid, 1, 63)}\nsize 12\n", false},
          {"another algorithm", @v1 <> "oid sha1:#{@oid}\nsize 12\n", false},
          {"a negative size", @v1 <> "oid sha256:#{@oid}\nsize -1\n", false},
          {"a size that is not a number", @v1 <> "oid sha256:#{@oid}\nsize 12abc\n", false},
          {"a size past 64 bits", @v1 <> "oid sha256:#{@oid}\nsize 9223372036854775808\n", false},
          {"no size", @v1 <> "oid sha256:#{@oid}\n", false},
          {"no oid", @v1 <> "size 12\n", false},
          {"a repeated oid", @v1 <> "oid sha256:#{@oid}\noid sha256:#{@oid}\nsize 12\n", false},
          {"carriage returns",
           String.replace(@v1 <> "oid sha256:#{@oid}\nsize 12\n", "\n", "\r\n"), true},
          {"a blank line between", @v1 <> "oid sha256:#{@oid}\n\nsize 12\n", true},
          {"plain text", "just some text\n", false}
        ] do
      test "#{name}" do
        text = unquote(text)
        assert match?({:ok, _}, Pointer.parse(text)) == unquote(parses)
        assert oracle(text) == unquote(parses)
      end
    end

    test "the size and oid it reads, and the 1024-byte cut" do
      assert {:ok, %{oid: @oid, size: 12}} = Pointer.parse(@v1 <> "oid sha256:#{@oid}\nsize 12\n")

      # Under 1024 bytes, however it is padded; at 1024 it is a file.
      padded = fn n ->
        @v1 <>
          "ext-0-a sha256:#{@oid}\n" <>
          String.duplicate("\n", n) <> "oid sha256:#{@oid}\nsize 12\n"
      end

      text = padded.(1023 - byte_size(padded.(0)))
      assert byte_size(text) == 1023
      assert {:ok, _} = Pointer.parse(text)
      assert Pointer.parse(text <> "\n") == :error
      assert Pointer.parse(<<0, 255, 1>>) == :error
      assert Pointer.parse(nil) == :error
    end

    defp oracle(text) do
      file = Path.join(GitFixtures.tmp_dir("pointer"), "f")
      File.write!(file, text)

      {_out, status} =
        Forge.Git.spawn_cmd("git", ["lfs", "pointer", "--check", "--file=" <> file],
          stderr_to_stdout: true
        )

      status == 0
    end
  end
end
