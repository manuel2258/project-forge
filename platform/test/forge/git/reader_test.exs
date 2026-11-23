defmodule Forge.Git.ReaderTest do
  @moduledoc """
  `Forge.Git.Reader`: many reads through one `git cat-file --batch`, where `Git.show/3` starts a
  process for each (ticket 68).
  """

  use ExUnit.Case, async: true

  import Forge.GitFixtures

  alias Forge.Git
  alias Forge.Git.Reader

  @big String.duplicate("0123456789abcdef\n", 20_000)

  setup do
    repo =
      seeded_repo(%{
        "dir/with space/a b.txt" => "spaced\n",
        "big.txt" => @big,
        "empty.txt" => "",
        "binary.bin" => <<0, 1, 2, 255, 10, 10, 0>>
      })

    {:ok, sha} = Git.resolve(repo, "main")
    %{repo: repo, sha: sha}
  end

  test "reads blobs, however they are shaped, one after another on one pipe", %{
    repo: repo,
    sha: sha
  } do
    Reader.with_reader(repo, fn reader ->
      assert Reader.read(reader, sha, "README.md") == {:ok, "# Game\n"}
      assert Reader.read(reader, sha, "dir/with space/a b.txt") == {:ok, "spaced\n"}
      assert Reader.read(reader, sha, "empty.txt") == {:ok, ""}
      assert Reader.read(reader, sha, "binary.bin") == {:ok, <<0, 1, 2, 255, 10, 10, 0>>}
      assert Reader.read(reader, sha, "big.txt") == {:ok, @big}
      # Still in step after the 340 kB answer.
      assert Reader.read(reader, sha, "README.md") == {:ok, "# Game\n"}
    end)
  end

  test "starts one process for all of it", %{repo: repo, sha: sha} do
    test = self()
    id = {__MODULE__, System.unique_integer()}

    :telemetry.attach(
      id,
      [:forge, :git, :spawn],
      fn _event, _measurements, meta, _config ->
        if self() == test, do: send(test, {:spawned, meta.args})
      end,
      nil
    )

    try do
      Reader.with_reader(repo, fn reader ->
        for _read <- 1..20, do: Reader.read(reader, sha, "README.md")
        Reader.exists?(reader, sha, "nope")
      end)
    after
      :telemetry.detach(id)
    end

    assert_received {:spawned, ["cat-file", "--batch"]}
    refute_received {:spawned, _args}
  end

  test "a path that is not there is an error, and the next read still works", %{
    repo: repo,
    sha: sha
  } do
    Reader.with_reader(repo, fn reader ->
      assert Reader.read(reader, sha, "no/such/file") == :error
      assert Reader.read(reader, sha, "no such file") == :error

      # `<sha>:x blob missing` is three words, which is also what an object that is there looks like.
      assert Reader.read(reader, sha, "x blob") == :error
      refute Reader.exists?(reader, sha, "x blob")
      refute Reader.exists?(reader, sha, "no such file")
      assert Reader.read(reader, sha, "README.md") == {:ok, "# Game\n"}
    end)
  end

  test "a commit that is not there is an error", %{repo: repo} do
    Reader.with_reader(repo, fn reader ->
      assert Reader.read(reader, String.duplicate("a", 40), "README.md") == :error
      refute Reader.exists?(reader, String.duplicate("a", 40), "README.md")
    end)
  end

  test "a directory exists and is not read as text", %{repo: repo, sha: sha} do
    Reader.with_reader(repo, fn reader ->
      assert Reader.exists?(reader, sha, "dir")
      assert Reader.read(reader, sha, "dir") == :error
      assert Reader.read(reader, sha, "README.md") == {:ok, "# Game\n"}
    end)
  end

  test "a name with a newline in it is refused rather than asked as two questions", %{
    repo: repo,
    sha: sha
  } do
    Reader.with_reader(repo, fn reader ->
      assert Reader.read(reader, sha, "README.md\n" <> sha <> ":README.md") == :error
      assert Reader.read(reader, sha, "README.md") == {:ok, "# Game\n"}
    end)
  end

  # `"#{sha}:#{nil}"` is `<sha>:`, the root tree, which exists: a path that is not a string must
  # not be asked at all.
  test "a path that is not a string is not asked", %{repo: repo, sha: sha} do
    Reader.with_reader(repo, fn reader ->
      refute Reader.exists?(reader, sha, nil)
      assert Reader.read(reader, sha, nil) == :error
    end)
  end

  # git reads the name as a C string, so what follows a NUL is dropped and `README.md\0junk` would
  # answer as `README.md`.
  test "a name with a NUL in it is refused", %{repo: repo, sha: sha} do
    Reader.with_reader(repo, fn reader ->
      assert Reader.read(reader, sha, "README.md" <> <<0>> <> "junk") == :error
      assert Reader.read(reader, sha, "README.md") == {:ok, "# Game\n"}
    end)
  end

  test "a repository that is not there answers as a missing file would" do
    missing =
      Path.join(System.tmp_dir!(), "forge-reader-no-such-#{System.unique_integer([:positive])}")

    Reader.with_reader(missing, fn reader ->
      assert Reader.read(reader, String.duplicate("a", 40), "README.md") == :error
      refute Reader.exists?(reader, String.duplicate("a", 40), "README.md")
    end)
  end

  test "closing it leaves no process behind", %{repo: repo, sha: sha} do
    port =
      Reader.with_reader(repo, fn %{port: port} = reader ->
        {:ok, _text} = Reader.read(reader, sha, "README.md")
        port
      end)

    assert Port.info(port) == nil
  end
end
