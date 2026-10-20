defmodule ForgeWeb.DiffTest do
  @moduledoc """
  The bound on a rendered change, and the short sha beside it.

  `ForgeWeb.Diff`'s own doc puts the first in bold — "**A diff is bounded.** Past a size it is not
  rendered inline: a page nobody can read is not a review" — and it is one boolean, built from two
  limits that are almost never crossed together. A change is either a handful of edited files or a
  generated sprawl of small ones, so a test with one ordinary diff and one enormous one cannot
  tell `and` from `or`: each of those crosses both limits or neither. The two limits are therefore
  crossed one at a time here.

  Both surfaces that show a change use this, so the bound is a property of the product and not of
  either page: `docs/design/ui.md` § Semantics that must not be lost.
  """

  use ExUnit.Case, async: true

  import Forge.GitFixtures
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Forge.Git
  alias ForgeWeb.Diff

  # A repository with one commit of `files` on top of a one-file root, and the two shas between
  # which that is the whole change.
  defp change(files) do
    work = tmp_dir("diff-work")

    git!(work, ["init", "-q", "-b", "main"])
    commit!(work, %{"README.md" => "# Base\n"})
    {:ok, base} = Git.run(work, ["rev-parse", "HEAD"])

    commit!(work, files)
    {:ok, head} = Git.run(work, ["rev-parse", "HEAD"])

    {work, String.trim(base), String.trim(head)}
  end

  defp commit!(work, files) do
    Enum.each(files, fn {path, content} ->
      File.mkdir_p!(Path.dirname(Path.join(work, path)))
      File.write!(Path.join(work, path), content)
    end)

    git!(work, ["add", "."])
    git!(work, ["-c", "user.name=t", "-c", "user.email=t@forge", "commit", "-q", "-m", "change"])
  end

  defp git!(dir, args), do: {:ok, _out} = Git.run(dir, args)

  test "an ordinary change is rendered inline" do
    {repo, base, head} = change(%{"score.ex" => "def persist, do: :ok\n"})

    diff = Diff.build(repo, base, head)

    assert diff.inline
    assert diff.files == [{"score.ex", 1, 0}]
    assert diff.added == 1
  end

  # Under the byte limit and over the file limit. Every file here is two lines, so a bound that
  # only looked at bytes would call this readable.
  test "too many files is too much to read, however small they are" do
    files = Map.new(1..61, &{"generated/f#{&1}.ex", "# #{&1}\n"})
    {repo, base, head} = change(files)

    diff = Diff.build(repo, base, head)

    assert length(diff.files) == 61
    assert diff.bytes < 512 * 1024
    refute diff.inline
    # The table still names every file, and no row expands to a patch.
    assert diff |> Diff.files() |> length() == 61
    assert diff |> Diff.files() |> Enum.all?(&is_nil(&1.lines))
  end

  # The third way a patch is too much for the page, and the one that is not about size. git
  # diffs a file it calls binary as a single line, but a file that is merely not UTF-8 — one
  # latin-1 byte in an otherwise ordinary source file — it diffs in full, and those bytes then
  # go into the page. On a GET that is a 200 whose body is not valid UTF-8; through the socket
  # it is `Jason.EncodeError` raised inside the socket's own process, which takes every
  # LiveView on that connection with it.
  test "a patch that is not valid UTF-8 is not drawn, however small it is" do
    {repo, base, head} = change(%{"latin1.ex" => "def caf" <> <<0xE9>> <> ", do: :ok\n"})

    diff = Diff.build(repo, base, head)

    assert diff.files == [{"latin1.ex", 1, 0}]
    assert diff.bytes < 512 * 1024
    refute diff.text
    refute diff.inline
    # The map of the change survives; only the patch gives way.
    assert [%{path: "latin1.ex", lines: nil}] = Diff.files(diff)

    drawn = render_component(&Diff.section/1, diff: diff)
    assert String.valid?(drawn)
    assert drawn =~ "not valid UTF-8"
    assert drawn =~ "latin1.ex"
  end

  # And the other way round: one file, well under the file limit, whose patch is past the byte
  # limit. A bound that only counted files would put six hundred kilobytes on the page.
  test "one enormous file is too much to read, however few there are" do
    {repo, base, head} =
      change(%{"dump.sql" => String.duplicate("insert into scores;\n", 30_000)})

    diff = Diff.build(repo, base, head)

    assert length(diff.files) == 1
    assert diff.bytes > 512 * 1024
    refute diff.inline
    assert [%{path: "dump.sql", lines: nil}] = Diff.files(diff)
  end

  # Each row of the Changes table expands to its own patch. With a space in a path the
  # `diff --git` header has more than one reading, and keying by it put `a b/c`'s patch under
  # `c b/a b/c` — on the tab that carries the changeset approval. A path git has to quote, and
  # one outside ASCII, are read back to the name `--numstat` gives the row.
  test "every file's row carries its own patch, whatever its path" do
    {repo, base, head} =
      change(%{
        "a b/c" => "benign\n",
        "c b/a b/c" => "evil\n",
        "résumé.md" => "cv\n",
        ~s(we"ird.md) => "odd\n"
      })

    rows = repo |> Diff.build(base, head) |> Diff.files() |> Map.new(&{&1.path, &1.lines})

    assert Map.keys(rows) |> Enum.sort() ==
             Enum.sort(["a b/c", "c b/a b/c", "résumé.md", ~s(we"ird.md)])

    assert {:line, "+benign"} in rows["a b/c"]
    assert {:line, "+evil"} in rows["c b/a b/c"]
    refute {:line, "+evil"} in rows["a b/c"]
    assert {:line, "+cv"} in rows["résumé.md"]
    assert {:line, "+odd"} in rows[~s(we"ird.md)]
  end

  # A file the change deletes has no new side; its row is keyed by the old one.
  test "a deleted file's row carries its patch" do
    work = tmp_dir("diff-delete")
    git!(work, ["init", "-q", "-b", "main"])
    commit!(work, %{"gone.ex" => "bye\n"})
    {:ok, base} = Git.run(work, ["rev-parse", "HEAD"])
    git!(work, ["rm", "-q", "gone.ex"])
    git!(work, ["-c", "user.name=t", "-c", "user.email=t@forge", "commit", "-q", "-m", "rm"])
    {:ok, head} = Git.run(work, ["rev-parse", "HEAD"])

    [row] = work |> Diff.build(String.trim(base), String.trim(head)) |> Diff.files()

    assert row.path == "gone.ex"
    assert {:line, "-bye"} in row.lines
  end

  # A binary file has no patch to key: its row is named and does not expand, and the rows
  # beside it still do.
  test "a binary file's row is named and does not expand" do
    {repo, base, head} = change(%{"logo.png" => <<0, 1, 2, 0, 255>>, "a.ex" => "a\n"})

    rows = repo |> Diff.build(base, head) |> Diff.files() |> Map.new(&{&1.path, &1})

    assert %{lines: nil, hunks: []} = rows["logo.png"]
    assert {:line, "+a"} in rows["a.ex"].lines
  end

  test "a quoted path is read back to the name it quotes" do
    assert Git.unquote_path(~s("we\\"ird.md")) == ~s(we"ird.md)
    assert Git.unquote_path(~s("tab\\there")) == "tab\there"
    assert Git.unquote_path(~s("r\\303\\251sum\\303\\251.md")) == "résumé.md"
    assert Git.unquote_path("plain name") == "plain name"
  end

  # The sentence that replaces the patch names the two commits, and names them at the length a
  # person can carry to a terminal. Its own `@doc` says twelve characters; a full forty-character
  # sha in running text is a wall, and is what the short form exists to avoid.
  test "a short sha is twelve characters of the real one" do
    sha = String.duplicate("ab", 20)

    assert String.length(Diff.short(sha)) == 12
    assert String.starts_with?(sha, Diff.short(sha))
    assert Diff.short(nil) == "—"
  end
end
