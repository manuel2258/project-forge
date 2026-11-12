defmodule Forge.ForgeReleaseTest do
  @moduledoc """
  What a project records as its forge release, and how the platform judges it
  (`docs/design/changelog.md` § The one list). The rule is run over lists of its own; the reading
  is run against a real repository.
  """

  use ExUnit.Case, async: true

  import Forge.GitFixtures

  alias Forge.{ForgeRelease, Git}

  @releases ["0.1.1", "0.17.0", "0.18.0", "0.19.0"]
  @running "0.19.0"

  defp status(read), do: ForgeRelease.status(read, @releases, @running)

  describe "status/3" do
    test "no file is not recorded" do
      assert status(:none) == :not_recorded
    end

    test "the running release is current" do
      assert status({:ok, "0.19.0\n"}) == :current
    end

    test "an older release in the list is behind, with the list's own spelling" do
      assert status({:ok, "0.17.0\n"}) == {:behind, "0.17.0"}
      assert status({:ok, "  0.18.0  \n"}) == {:behind, "0.18.0"}
    end

    test "the baseline is a release, and behind" do
      assert status({:ok, "0.1.1\n"}) == {:behind, "0.1.1"}
    end

    test "a release above the running one is newer, though no list can hold it" do
      assert status({:ok, "0.25.0\n"}) == {:newer, "0.25.0"}
      # numerically, not as text: "0.100.0" sorts below "0.19.0" as a string
      assert status({:ok, "0.100.0\n"}) == {:newer, "0.100.0"}
    end

    test "a well formed number with no section is not a release" do
      assert status({:ok, "0.12.9\n"}) == {:not_release, "0.12.9"}
    end

    test "anything else is not a release, and is quoted" do
      assert status({:ok, "v0.17.0\n"}) == {:not_release, "v0.17.0"}
      assert status({:ok, ""}) == {:not_release, ""}
      assert status({:ok, "0.17\n"}) == {:not_release, "0.17"}
      assert status({:ok, "0.17.0-rc1\n"}) == {:not_release, "0.17.0-rc1"}
      assert status({:ok, "<b>x</b>\n"}) == {:not_release, "<b>x</b>"}
    end

    test "a file over the bound is not a release and quotes nothing" do
      assert status(:too_large) == {:not_release, :too_large}
    end

    test "the quote is cut after 40 characters, and 40 are shown whole" do
      forty = String.duplicate("é", 40)

      assert status({:ok, forty}) == {:not_release, forty}
      assert status({:ok, forty <> "x"}) == {:not_release, forty <> "…"}
    end

    test "the quote collapses control characters, replaces bad UTF-8 and is cut short" do
      assert {:not_release, quoted} = status({:ok, "a\nb\r\n\tc\e[0m"})
      assert quoted == "a b c [0m"

      assert {:not_release, quoted} = status({:ok, <<"x", 0xFF, "y">>})
      assert String.valid?(quoted)

      assert {:not_release, quoted} = status({:ok, String.duplicate("é", 60)})
      assert quoted == String.duplicate("é", 40) <> "…"
    end

    test "the defaults are the changelog's own list and the running release" do
      assert ForgeRelease.status({:ok, Forge.Changelog.running() <> "\n"}) == :current
      assert ForgeRelease.status({:ok, "0.1.1\n"}) == {:behind, "0.1.1"}
    end
  end

  describe "read/2" do
    setup do
      repo = seeded_repo(%{".forge/forge-release" => "0.17.0\n", "VERSION" => "0.19.0\n"})
      {:ok, sha} = Git.resolve(repo, "main")
      %{repo: repo, sha: sha, scratch: tmp_dir("fr")}
    end

    # A branch off `sha` with `setup` run in a worktree of it, committed; the new head.
    defp commit_on(repo, scratch, sha, name, setup) do
      :ok = Git.create_branch(repo, name, sha)
      worktree = Path.join(scratch, name)
      :ok = Git.worktree_add(repo, worktree, name)
      setup.(worktree)
      {:ok, _} = Git.run(worktree, ["add", "-A"])

      {:ok, _} =
        Git.run(worktree, [
          "-c",
          "user.name=t",
          "-c",
          "user.email=t@forge",
          "commit",
          "-q",
          "-m",
          name
        ])

      {:ok, head} = Git.resolve(repo, name)
      head
    end

    test "reads the file at the commit it is given", %{repo: repo, sha: sha, scratch: scratch} do
      assert ForgeRelease.read(repo, sha) == {:ok, "0.17.0\n"}

      later =
        commit_on(repo, scratch, sha, "later", fn dir ->
          File.write!(Path.join(dir, ".forge/forge-release"), "0.19.0\n")
        end)

      assert ForgeRelease.read(repo, later) == {:ok, "0.19.0\n"}
      # the sha passed in is the one read: a later commit is not seen
      assert ForgeRelease.read(repo, sha) == {:ok, "0.17.0\n"}
    end

    test "no file is none", %{repo: repo, sha: sha, scratch: scratch} do
      head =
        commit_on(repo, scratch, sha, "gone", fn dir ->
          File.rm!(Path.join(dir, ".forge/forge-release"))
        end)

      assert ForgeRelease.read(repo, head) == :none
    end

    test "64 bytes are read and 65 are refused unread", %{repo: repo, sha: sha, scratch: scratch} do
      at = String.duplicate("1", 64)
      over = String.duplicate("1", 65)

      head64 =
        commit_on(repo, scratch, sha, "b64", fn dir ->
          File.write!(Path.join(dir, ".forge/forge-release"), at)
        end)

      head65 =
        commit_on(repo, scratch, sha, "b65", fn dir ->
          File.write!(Path.join(dir, ".forge/forge-release"), over)
        end)

      assert ForgeRelease.read(repo, head64) == {:ok, at}
      assert ForgeRelease.read(repo, head65) == :too_large
    end

    # **The guard that a symlink is not followed.** Following `../VERSION` would read `0.19.0`,
    # the running release, and the project would be current. Git's object store holds the link's
    # target as the blob's content, so it reads as that path, which is not a release.
    test "a committed symlink reads as its target, never what it points at", %{
      repo: repo,
      sha: sha,
      scratch: scratch
    } do
      head =
        commit_on(repo, scratch, sha, "link", fn dir ->
          File.rm!(Path.join(dir, ".forge/forge-release"))
          File.ln_s!("../VERSION", Path.join(dir, ".forge/forge-release"))
        end)

      assert ForgeRelease.read(repo, head) == {:ok, "../VERSION"}

      assert ForgeRelease.status({:ok, "../VERSION"}, @releases, @running) ==
               {:not_release, "../VERSION"}
    end

    test "a directory at the path is none", %{repo: repo, sha: sha, scratch: scratch} do
      head =
        commit_on(repo, scratch, sha, "dir", fn dir ->
          File.rm!(Path.join(dir, ".forge/forge-release"))
          File.mkdir_p!(Path.join(dir, ".forge/forge-release"))
          File.write!(Path.join(dir, ".forge/forge-release/x"), "0.19.0\n")
        end)

      assert ForgeRelease.read(repo, head) == :none
    end

    test "a submodule entry at the path is none", %{repo: repo, sha: sha, scratch: scratch} do
      head =
        commit_on(repo, scratch, sha, "gitlink", fn dir ->
          File.rm!(Path.join(dir, ".forge/forge-release"))

          {:ok, _} =
            Git.run(dir, [
              "update-index",
              "--add",
              "--cacheinfo",
              "160000,#{sha},.forge/forge-release"
            ])
        end)

      assert ForgeRelease.read(repo, head) == :none
    end
  end

  test "path/0 is where the platform's instructions to agents say the file is" do
    for doc <- [ForgeCore.Workflow.platform_overview(), ForgeCore.Prompt.chat_preamble()] do
      assert doc =~ ForgeRelease.path()
    end

    assert ForgeCore.Workflow.platform_overview() =~ "changelog.md"
  end
end
