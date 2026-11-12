defmodule Forge.ChangelogAddTest do
  @moduledoc """
  `bin/changelog-add`, which `publishing` and the `release` skill use to file a release's section
  (`docs/design/changelog.md` § Writing a section). It is shell, so it is run as the release runs
  it, over files of its own.
  """

  use ExUnit.Case, async: true

  import Forge.GitFixtures, only: [tmp_dir: 1]

  @script Path.expand("../../../bin/changelog-add", __DIR__)

  @changelog "# Title\n\npreamble\n\n## 0.2.0\n\n- **may adopt** — a\n\n## 0.1.5\n\nNothing for projects in this release.\n"
  @section "## 0.3.0\n\n- **must change** — b\n"

  setup do
    dir = tmp_dir("changelog-add")
    File.write!(Path.join(dir, "changelog.md"), @changelog)
    File.write!(Path.join(dir, "VERSION"), "0.3.0\n")
    File.write!(Path.join(dir, "section.md"), @section)
    %{dir: dir}
  end

  defp run(dir, file \\ "section.md") do
    System.cmd(@script, [Path.join(dir, file)],
      env: [
        {"CHANGELOG", Path.join(dir, "changelog.md")},
        {"VERSION_FILE", Path.join(dir, "VERSION")}
      ],
      stderr_to_stdout: true
    )
  end

  defp changelog(dir), do: File.read!(Path.join(dir, "changelog.md"))

  test "files the section above the newest, byte for byte, and leaves the preamble", %{dir: dir} do
    assert {_out, 0} = run(dir)

    assert changelog(dir) ==
             "# Title\n\npreamble\n\n" <>
               @section <> "\n" <> String.replace(@changelog, ~r/\A.*?(?=## 0\.2\.0)/s, "")

    assert Forge.Changelog.releases(changelog(dir)) == ["0.3.0", "0.2.0", "0.1.5"]
  end

  test "the same section again is a no-op", %{dir: dir} do
    {_out, 0} = run(dir)
    once = changelog(dir)

    assert {out, 0} = run(dir)
    assert out =~ "already in the changelog"
    assert changelog(dir) == once
  end

  test "a different section under the same heading is refused and nothing changes", %{dir: dir} do
    {_out, 0} = run(dir)
    once = changelog(dir)
    File.write!(Path.join(dir, "other.md"), "## 0.3.0\n\n- **may adopt** — something else\n")

    assert {out, 1} = run(dir, "other.md")
    assert out =~ "different section"
    assert changelog(dir) == once
  end

  # The heading is matched whole: a section headed `## 0.3.01` or `## 0.3.0-rc` is another
  # release's and would otherwise be filed under 0.3.0.
  test "a first line that only starts like the version is refused", %{dir: dir} do
    for heading <- ["## 0.3.01", "## 0.3.0-rc1", "## 0.3.0 "] do
      File.write!(
        Path.join(dir, "near.md"),
        heading <> "\n\nNothing for projects in this release.\n"
      )

      assert {_out, 1} = run(dir, "near.md")
    end

    assert changelog(dir) == @changelog
  end

  # The section already there is found by its whole heading too: one for `0.3.0-rc1` is not it.
  test "a section whose heading only starts like this one is not mistaken for it", %{dir: dir} do
    File.write!(
      Path.join(dir, "changelog.md"),
      "# T\n\n## 0.3.0-rc1\n\n- **may adopt** — early\n\n## 0.2.0\n\nNothing for projects in this release.\n"
    )

    assert {_out, 0} = run(dir)
    assert Forge.Changelog.releases(changelog(dir)) == ["0.3.0", "0.2.0"]
    assert changelog(dir) =~ "## 0.3.0-rc1"
  end

  test "a section for another release than VERSION is refused", %{dir: dir} do
    File.write!(Path.join(dir, "wrong.md"), "## 0.4.0\n\nNothing for projects in this release.\n")

    assert {out, 1} = run(dir, "wrong.md")
    assert out =~ "not '## 0.3.0'"
    assert changelog(dir) == @changelog
  end
end
