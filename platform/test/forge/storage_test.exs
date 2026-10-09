defmodule Forge.StorageTest do
  # Not async: every test here points the store at its own directory, and the store is
  # chosen by application environment, which is global.
  use ExUnit.Case, async: false

  alias Forge.Storage
  alias Forge.Storage.Key

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "#{System.pid()}-forge-store-test-#{System.unique_integer([:positive])}"
      )

    previous = Application.get_env(:forge, Storage, [])
    Application.put_env(:forge, Storage, Keyword.put(previous, :dir, dir))

    on_exit(fn ->
      Application.put_env(:forge, Storage, previous)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  describe "keys" do
    test "are built, not written by hand" do
      assert Key.job("a1b2", "transcript-1.jsonl") == "job/a1b2/transcript-1.jsonl"
      assert Key.seed("sample", "2026-09-12") == "seed/sample/2026-09-12"
      assert Key.artifact("sha256:beef") == "artifact/beef"
    end

    test "reject traversal, absolutes, uppercase and single segments" do
      for key <- [
            "job/../etc/passwd",
            "/job/x",
            "job//x",
            "Job/x",
            "job/x/",
            "artifact",
            "..",
            "job/x\n/y",
            "job/x/y\n"
          ] do
        assert {:error, :invalid_key} = Key.validate(key), "expected #{inspect(key)} to fail"
      end

      assert {:ok, "job/x/transcript-1.jsonl"} = Key.validate("job/x/transcript-1.jsonl")
    end

    # Ownership is decided on the key the store would take, not on the string: `..` is not under
    # the job, and neither is a sibling whose id merely starts the same.
    test "a job's own keys are its, and nothing that only reads like one" do
      assert Key.job?("job/a1/log-1.txt", "a1")
      assert Key.job?("job/a1/out-x/1", "a1")
      refute Key.job?("job/a1/../b2/log-1.txt", "a1")
      refute Key.job?("job/a10/log-1.txt", "a1")
      refute Key.job?("job/a1", "a1")
      refute Key.job?(nil, "a1")
    end

    test "are checked before any implementation sees them" do
      assert {:error, :invalid_key} = Storage.put("job/../escape", "x")
      assert {:error, :invalid_key} = Storage.get("job/../escape")
      assert {:error, :invalid_key} = Storage.read_range("job/../escape", 0, 1)
    end
  end

  describe "the local implementation" do
    test "round-trips bytes and reports size and hash" do
      assert {:ok, %{size: 5, hash: hash}} = Storage.put("job/j1/out.txt", "hello")
      assert hash == Storage.hash("hello")
      assert {:ok, "hello"} = Storage.get("job/j1/out.txt")
      assert {:ok, %{size: 5, hash: ^hash}} = Storage.stat("job/j1/out.txt")
    end

    test "takes a file and gives one back, without holding it", %{dir: dir} do
      source = Path.join(dir, "source.bin")
      File.mkdir_p!(dir)
      File.write!(source, :crypto.strong_rand_bytes(64))

      assert {:ok, %{size: 64, hash: hash}} = Storage.put("seed/sample/s1", {:file, source})

      destination = Path.join(dir, "fetched.bin")
      assert {:ok, %{size: 64, hash: ^hash}} = Storage.fetch("seed/sample/s1", destination)
      assert File.read!(destination) == File.read!(source)
    end

    test "refuses to overwrite a blob" do
      assert {:ok, _info} = Storage.put("job/j1/out.txt", "first")
      assert {:error, :exists} = Storage.put("job/j1/out.txt", "second")
      assert {:ok, "first"} = Storage.get("job/j1/out.txt")
    end

    # The size is the whole object's, and a range is cut at its end rather than refused.
    test "reads a range, and says how big the whole is" do
      assert {:ok, _info} = Storage.put("job/j1/log.txt", "0123456789")

      assert {:ok, %{size: 10, bytes: "234"}} = Storage.read_range("job/j1/log.txt", 2, 3)
      assert {:ok, %{size: 10, bytes: "89"}} = Storage.read_range("job/j1/log.txt", 8, 5)
      assert {:ok, %{size: 10, bytes: ""}} = Storage.read_range("job/j1/log.txt", 10, 5)
      assert {:ok, %{size: 10, bytes: ""}} = Storage.read_range("job/j1/log.txt", 0, 0)
    end

    test "says not_found rather than raising" do
      assert {:error, :not_found} = Storage.get("job/j1/missing.txt")
      assert {:error, :not_found} = Storage.stat("job/j1/missing.txt")
      assert {:error, :not_found} = Storage.read_range("job/j1/missing.txt", 0, 1)

      assert {:error, :not_found} =
               Storage.fetch(
                 "job/j1/missing.txt",
                 Path.join(System.tmp_dir!(), "#{System.pid()}-nope")
               )
    end

    test "leaves nothing behind on delete, and does not mind deleting twice" do
      assert {:ok, _info} = Storage.put("job/j1/out.txt", "hello")
      assert :ok = Storage.delete("job/j1/out.txt")
      assert :ok = Storage.delete("job/j1/out.txt")
      assert {:error, :not_found} = Storage.get("job/j1/out.txt")
    end

    test "writes are atomic: no partial object is left where a key will be", %{dir: dir} do
      assert {:ok, _info} = Storage.put("job/j1/out.txt", "hello")
      assert File.ls!(Path.join([dir, "job", "j1"])) == ["out.txt"]
    end
  end

  describe "uris" do
    test "carry the key, and only for the store's own scheme" do
      assert Storage.uri("job/j1/out.txt") == "store:job/j1/out.txt"
      assert {:ok, "job/j1/out.txt"} = Storage.key_from_uri("store:job/j1/out.txt")
      assert :error = Storage.key_from_uri("file:///tmp/out.txt")
      assert :error = Storage.key_from_uri("git:abc123")
      assert :error = Storage.key_from_uri("store:job/../escape")
    end
  end
end
