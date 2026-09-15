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
