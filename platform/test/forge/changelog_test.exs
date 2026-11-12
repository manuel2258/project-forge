defmodule Forge.ChangelogTest do
  @moduledoc """
  The changelog forge hands to every project (`docs/design/changelog.md`). The file is the
  release's to write, and the second test is the gate that no release reaches `main` without it.
  """

  use ExUnit.Case, async: true

  alias Forge.Changelog

  # Every release from 0.2.0, the first with a section, to 0.19.0, the last this ticket wrote. A
  # later release adds its own and is checked by the "newest section" test, not by this list.
  @backfilled ~w(0.2.0 0.2.1 0.3.0 0.4.0 0.5.0 0.6.0 0.7.0 0.8.0 0.8.1 0.9.0 0.9.1 0.10.0 0.11.0
                 0.12.0 0.12.1 0.12.2 0.13.0 0.14.0 0.15.0 0.16.0 0.17.0 0.18.0 0.19.0)

  defp version_key(version), do: version |> String.split(".") |> Enum.map(&String.to_integer/1)

  test "the shipped file has a section for every release from 0.2.0, and none for the baseline" do
    sections = Changelog.releases(Changelog.text())

    assert @backfilled -- sections == []
    refute "0.1.1" in sections
    assert Changelog.releases() == ["0.1.1" | sections]
  end

  # **The guard.** `VERSION` is bumped by a release, and the release writes its section in the same
  # commit (`bin/changelog-add`); a bump with no section leaves the newest section behind, which is
  # what this fails on. It is also what makes "the release the node runs" and "the newest section"
  # one fact for the agent, who can only see the latter.
  test "the newest section is the release the platform runs" do
    assert hd(Changelog.releases(Changelog.text())) == Changelog.running()
  end

  test "headings are unique and strictly descending, so newest first" do
    sections = Changelog.releases(Changelog.text())

    assert sections == Enum.uniq(sections)
    assert sections == Enum.sort_by(sections, &version_key/1, :desc)
  end

  test "every section has a body" do
    bodies =
      Changelog.text()
      |> String.split(~r/^## \d+\.\d+\.\d+$/m)
      |> tl()

    assert length(bodies) == length(Changelog.releases(Changelog.text()))
    assert Enum.all?(bodies, &(String.trim(&1) != ""))
  end

  test "every entry says what it is, and an empty section says so in the one sentence" do
    for body <- String.split(Changelog.text(), ~r/^## \d+\.\d+\.\d+$/m) |> tl() do
      body = String.trim(body)

      assert body == "Nothing for projects in this release." or
               String.starts_with?(body, "- **must change**") or
               String.starts_with?(body, "- **may adopt**")
    end
  end

  describe "releases/1" do
    test "reads the `## N.N.N` headings in file order" do
      assert Changelog.releases("# T\n\n## 1.2.0\n\nx\n\n## 1.1.0\n\ny\n") == ["1.2.0", "1.1.0"]
    end

    test "ignores a heading inside a fenced block, a deeper heading and the preamble" do
      text = """
      # Title

      A preamble that mentions ## 9.9.9 in passing.

      ## 1.2.0

      ```yaml
      ## 9.9.9
      a: 1
      ```

      ### 8.8.8

      ## 1.1.0
      """

      assert Changelog.releases(text) == ["1.2.0", "1.1.0"]
    end

    test "an indented fence and a tilde fence hide a heading too" do
      text = "## 1.0.0\n\n  ```yaml\n## 9.9.9\n  ```\n\n~~~\n## 8.8.8\n~~~\n"

      assert Changelog.releases(text) == ["1.0.0"]
    end

    # What counts as a release heading is exactly `## N.N.N` and nothing after it: this list is the
    # one both the page and the agent judge a recorded value by.
    test "a heading is `## N.N.N` alone: text after it, a missing space or a fourth part are not" do
      text = "## 1.2.3 notes\n##1.2.3\n## 1.2.3.4\n## 1.2\n## 1.2.3-rc1\n## 2.0.0  \n"

      assert Changelog.releases(text) == ["2.0.0"]
    end

    test "a fence that closes lets the next heading count again" do
      assert Changelog.releases("```\n## 1.0.0\n```\n## 2.0.0\n") == ["2.0.0"]
    end
  end
end
