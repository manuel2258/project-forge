defmodule Forge.ArtifactsExcerptTest do
  @moduledoc """
  A blob read as text a job or a page can hold (`Forge.Artifacts.excerpt/3`): what a state reading
  a command's log is handed, and what the ticket page shows of a failed one. Not async: the store's
  directory is application configuration.
  """

  use Forge.DataCase, async: false

  import Forge.GitFixtures, only: [tmp_dir: 1]

  alias Forge.{Artifacts, Storage}

  setup do
    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)
    :ok
  end

  defp blob(bytes) do
    key = Storage.Key.job(Ecto.UUID.generate(), "log.txt")
    {:ok, _info} = Storage.put(key, bytes)
    %Artifacts.Version{blob_uri: Storage.uri(key)}
  end

  test "a log that fits is handed over whole" do
    assert {:ok, "compiled\nfailed\n"} = Artifacts.excerpt(blob("compiled\nfailed\n"), 8, 8)
    assert {:ok, "0123456789"} = Artifacts.excerpt(blob("0123456789"), 5, 5)
  end

  # A build says what it was doing at the top and why it stopped at the bottom.
  test "a log that does not fit keeps both ends and says how much was cut" do
    assert {:ok, text} =
             Artifacts.excerpt(blob("head-" <> String.duplicate("x", 100) <> "-tail"), 5, 5)

    assert text == "head-\n[… 100 bytes cut, of 110 …]\n-tail"
  end

  # Neither end starts or stops half way through a line, and the count says what really went.
  test "a log with lines is cut between them" do
    log = "first line\nsecond\n" <> String.duplicate("noise\n", 20) <> "last but one\nlast\n"

    assert {:ok, text} = Artifacts.excerpt(blob(log), 14, 12)

    assert text ==
             "first line\n[… #{byte_size(log) - 16} bytes cut, of #{byte_size(log)} …]\nlast\n"
  end

  # A build that fails often ends on one line longer than the tail, and starts on a blank one: a
  # cut to whole lines would leave nothing of either end but the marker, so each is kept as the
  # bytes fall instead.
  test "an end a line cut would leave blank is kept as it falls" do
    log =
      "\n" <>
        String.duplicate("z", 30) <>
        "\n" <> String.duplicate("noise\n", 20) <> String.duplicate("y", 30) <> "\n"

    assert {:ok, text} = Artifacts.excerpt(blob(log), 10, 20)

    assert text ==
             "\n" <>
               String.duplicate("z", 9) <>
               "\n[… #{byte_size(log) - 30} bytes cut, of #{byte_size(log)} …]\n" <>
               String.duplicate("y", 19) <> "\n"
  end

  # Up to the head's last whole line, not its first.
  test "a head of several lines keeps every whole one" do
    log = "one\ntwo\nthree is long\n" <> String.duplicate("noise\n", 20) <> "end\n"

    assert {:ok, "one\ntwo\n[… " <> _rest} = Artifacts.excerpt(blob(log), 10, 4)
  end

  # The ticket page's tail: no head at all, and the tail from a whole line.
  test "a tail alone starts at a line" do
    log = String.duplicate("noise\n", 20) <> "error: no build here\n"

    assert {:ok, "[… 120 bytes cut, of 141 …]\nerror: no build here\n"} =
             Artifacts.excerpt(blob(log), 0, 23)
  end

  # A compiler's bytes are not always UTF-8, and the text is inlined into a spec stored as JSON in
  # Postgres, which takes neither invalid UTF-8 nor NUL.
  test "bytes that are not text become the replacement character" do
    assert {:ok, "a�b�c"} = Artifacts.excerpt(blob(<<"a", 0xFF, "b", 0, "c">>), 8, 8)
  end

  test "a cut through a character does not leave half of it" do
    {:ok, text} = Artifacts.excerpt(blob("é" <> String.duplicate("x", 10) <> "é"), 1, 1)
    assert String.valid?(text)
    assert String.starts_with?(text, "�")
    assert String.ends_with?(text, "�")
  end

  test "a document is its own text" do
    assert {:ok, "# Plan\n"} = Artifacts.excerpt(%Artifacts.Version{content: "# Plan\n"}, 1, 1)
  end

  test "a log the store does not have is not found" do
    version = %Artifacts.Version{blob_uri: Storage.uri("job/#{Ecto.UUID.generate()}/gone.txt")}
    assert {:error, _not_found} = Artifacts.excerpt(version, 8, 8)
  end
end
