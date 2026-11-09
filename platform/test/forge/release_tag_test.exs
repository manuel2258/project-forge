defmodule Forge.ReleaseTagTest do
  @moduledoc """
  The tag of a release and the hooks that admit it (`docs/design/ticket-types.md` § The record, the
  tag, the history; `docs/design/git-hosting.md` § `pre-receive`, § `post-receive`): real bare
  repositories, the real hooks, nothing stubbed.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.Git
  alias Forge.Git.Hooks
  alias Forge.ReleaseRecords.Tag

  setup do
    bare = seeded_repo()

    {:ok, project} =
      register_owned!(%{
        name: "tag#{System.unique_integer([:positive])}",
        repo_path: bare,
        default_branch: "main"
      })

    repo = Forge.Projects.repo_path(project)
    {:ok, head} = Git.resolve(repo, "refs/heads/main")
    %{project: project, repo: repo, head: head}
  end

  defp tag_ref(repo, name),
    do: Git.run(repo, ["rev-parse", "--verify", "--quiet", "refs/tags/" <> name])

  describe "Tag.make/4" do
    test "makes an annotated tag on the commit, by the platform, carrying the notes", ctx do
      assert {:tagged, "v0.18.0"} =
               Tag.make(ctx.project, "0.18.0", ctx.head, "# Notes\n\nWhat changed.\n")

      assert {:ok, "tag\n"} = Git.run(ctx.repo, ["cat-file", "-t", "refs/tags/v0.18.0"])
      assert {:ok, head} = Git.run(ctx.repo, ["rev-parse", "refs/tags/v0.18.0^{commit}"])
      assert String.trim(head) == ctx.head

      assert {:ok, out} = Git.run(ctx.repo, ["cat-file", "tag", "refs/tags/v0.18.0"])
      assert out =~ ~r/^tagger forge <forge@localhost> \d+ \+0000$/m
      assert out =~ "\n\n# Notes\n\nWhat changed.\n"
      refute out =~ "BEGIN PGP"
    end

    test "a leading v is dropped from the version before the tag is named", ctx do
      assert Tag.name("0.18.0") == "v0.18.0"
      assert Tag.name("v0.18.0") == "v0.18.0"
      # Only the leading one: a v inside a pre-release is part of it.
      assert Tag.name("1.0.0-dev") == "v1.0.0-dev"
      assert Tag.name("v1.0.0-dev") == "v1.0.0-dev"
      assert {:tagged, "v0.18.0"} = Tag.make(ctx.project, "v0.18.0", ctx.head, nil)
      assert {:ok, _} = tag_ref(ctx.repo, "v0.18.0")
    end

    test "without notes the message is the tag's name, and blank notes are none", ctx do
      assert {:tagged, "v1.0.0"} = Tag.make(ctx.project, "1.0.0", ctx.head, "  \n")
      assert {:ok, out} = Git.run(ctx.repo, ["cat-file", "tag", "refs/tags/v1.0.0"])
      assert out =~ "\n\nv1.0.0\n"
    end

    test "a tag already on the same commit counts as made", ctx do
      assert {:tagged, "v1.0.0"} = Tag.make(ctx.project, "1.0.0", ctx.head, nil)
      {:ok, before} = tag_ref(ctx.repo, "v1.0.0")
      assert {:tagged, "v1.0.0"} = Tag.make(ctx.project, "1.0.0", ctx.head, "other notes")
      assert {:ok, ^before} = tag_ref(ctx.repo, "v1.0.0")
    end

    test "a name pointing at another commit is reported and never moved", ctx do
      assert {:tagged, _} = Tag.make(ctx.project, "1.0.0", ctx.head, nil)
      {:ok, before} = tag_ref(ctx.repo, "v1.0.0")
      later = commit_to_default(ctx.project, %{"a.txt" => "a\n"})

      assert {:taken, "v1.0.0", other} = Tag.make(ctx.project, "1.0.0", later, nil)
      assert other == ctx.head
      assert {:ok, ^before} = tag_ref(ctx.repo, "v1.0.0")
    end

    test "a commit outside the default branch's history is refused by the hook, and says so",
         ctx do
      {:ok, _} = Git.run(ctx.repo, ["update-ref", "refs/heads/ticket/7", ctx.head])
      stray = commit_to(ctx.repo, "ticket/7", %{"b.txt" => "b\n"})

      assert {:failed, "v2.0.0", reason} = Tag.make(ctx.project, "2.0.0", stray, nil)
      assert reason =~ "git refused the tag"
      assert reason =~ "history of main"
      assert {:error, _} = tag_ref(ctx.repo, "v2.0.0")
    end

    # A concurrent conclusion may make the tag between our read and our push; the push is then
    # refused and the answer is read again. The hook stands in for that other writer: it makes the
    # ref, then refuses.
    defp racing_hook(ctx, target) do
      hook = Path.join([ctx.repo, "hooks", "pre-receive"])
      original = File.read!(hook)

      File.write!(hook, """
      #!/usr/bin/env bash
      while read -r old new ref; do
        case "$ref" in
          refs/tags/*)
            env -u GIT_QUARANTINE_PATH git update-ref "$ref" "$(env -u GIT_QUARANTINE_PATH git rev-parse #{target})"
            echo "forge: lost the race" >&2
            exit 1
            ;;
        esac
      done
      exit 0
      """)

      on_exit(fn -> File.write!(hook, original) end)
    end

    test "a push refused because the tag was just made reads as made, or as taken", ctx do
      older = ctx.head
      later = commit_to_default(ctx.project, %{"a.txt" => "a\n"})
      racing_hook(ctx, "refs/heads/main")

      assert {:tagged, "v9.0.0"} = Tag.make(ctx.project, "9.0.0", later, nil)
      assert {:taken, "v9.1.0", ^later} = Tag.make(ctx.project, "9.1.0", older, nil)
    end

    test "a version git cannot name a tag after fails in words", ctx do
      assert {:failed, "v1.0.0-a..b", reason} = Tag.make(ctx.project, "1.0.0-a..b", ctx.head, nil)
      assert reason =~ "not one git accepts"
    end
  end

  describe "pre-receive" do
    defp push(repo, refspec, internal \\ true) do
      env = if internal, do: [{"FORGE_INTERNAL", "1"}], else: []

      System.cmd("git", ["push", "--quiet", ".", refspec],
        cd: repo,
        env: env,
        stderr_to_stdout: true
      )
    end

    test "admits a lightweight tag on a default-branch commit from the platform only", ctx do
      assert {out, 1} = push(ctx.repo, "#{ctx.head}:refs/tags/v1", false)
      assert out =~ "tags are made by the platform"
      assert {:error, _} = tag_ref(ctx.repo, "v1")

      assert {_, 0} = push(ctx.repo, "#{ctx.head}:refs/tags/v1")
      assert {:ok, _} = tag_ref(ctx.repo, "v1")
    end

    test "never moves or deletes a tag, even for the platform", ctx do
      assert {_, 0} = push(ctx.repo, "#{ctx.head}:refs/tags/v1")
      later = commit_to_default(ctx.project, %{"a.txt" => "a\n"})

      assert {out, 1} = push(ctx.repo, "+#{later}:refs/tags/v1")
      assert out =~ "never moved"
      assert {out, 1} = push(ctx.repo, ":refs/tags/v1")
      assert out =~ "never deleted"
      assert {:ok, tag} = tag_ref(ctx.repo, "v1")
      assert String.trim(tag) == ctx.head
    end

    test "refuses a tag on a commit that is not in the default branch's history", ctx do
      {:ok, _} = Git.run(ctx.repo, ["update-ref", "refs/heads/ticket/7", ctx.head])
      stray = commit_to(ctx.repo, "ticket/7", %{"b.txt" => "b\n"})

      assert {out, 1} = push(ctx.repo, "#{stray}:refs/tags/v1")
      assert out =~ "history of main"
      assert {:error, _} = tag_ref(ctx.repo, "v1")
    end

    test "refuses a tag object that peels to something that is not a commit", ctx do
      {:ok, tree} = Git.run(ctx.repo, ["rev-parse", "#{ctx.head}^{tree}"])
      assert {out, 1} = push(ctx.repo, "#{String.trim(tree)}:refs/tags/v1")
      assert out =~ "history of main"
    end

    test "a branch is still a branch: other refs are not opened up", ctx do
      assert {out, 1} = push(ctx.repo, "#{ctx.head}:refs/notes/x")
      assert out =~ "only branches"
    end
  end

  describe "post-receive" do
    # A mirror at a URL nothing answers: whether it was attempted is `lastStatus`, which the hook
    # writes after every attempt and only after one.
    @dead "http://127.0.0.1:1/never.git"

    defp status(repo, name) do
      repo |> Hooks.list_mirrors() |> Enum.find(&(&1.name == name)) |> Map.fetch!(:last_status)
    end

    test "a mirror with no pattern receives the default branch and release tags only", ctx do
      :ok = Hooks.put_mirror(ctx.repo, "off-site", @dead, [])

      {:ok, _} = Git.run(ctx.repo, ["update-ref", "refs/heads/ticket/7", ctx.head])
      assert {_, 0} = push(ctx.repo, "#{ctx.head}:refs/heads/ticket/8")
      assert status(ctx.repo, "off-site") == nil

      assert {_, 0} = push(ctx.repo, "#{ctx.head}:refs/tags/release-candidate")
      assert status(ctx.repo, "off-site") == nil

      assert {:tagged, _} = Tag.make(ctx.project, "1.0.0", ctx.head, nil)
      assert status(ctx.repo, "off-site") == "failed"
    end

    test "a mirror with a pattern of its own receives exactly what it matches", ctx do
      :ok = Hooks.put_mirror(ctx.repo, "branches", @dead, refs: "refs/heads/main")
      :ok = Hooks.put_mirror(ctx.repo, "tags", @dead, refs: "refs/tags/*")

      assert {:tagged, _} = Tag.make(ctx.project, "1.0.0", ctx.head, nil)

      assert status(ctx.repo, "branches") == nil
      assert status(ctx.repo, "tags") == "failed"
    end

    test "a failing mirror leaves the tag made", ctx do
      :ok = Hooks.put_mirror(ctx.repo, "off-site", @dead, [])

      assert {:tagged, "v1.0.0"} = Tag.make(ctx.project, "1.0.0", ctx.head, nil)
      assert status(ctx.repo, "off-site") == "failed"
      assert {:ok, _} = tag_ref(ctx.repo, "v1.0.0")
    end
  end
end
