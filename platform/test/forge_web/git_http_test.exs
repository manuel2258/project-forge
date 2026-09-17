defmodule ForgeWeb.GitHttpTest do
  @moduledoc """
  The git endpoint, exercised with a real git client against a real socket.

  A `Plug.Test` conn cannot prove this: what is being tested is that `git` itself negotiates,
  authenticates and is refused by the repository's own hooks. The endpoint serves during test for
  this reason, and these run `async: false` so the sandbox connection is shared with the request
  process.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures

  import Forge.GitFixtures

  alias Forge.Git
  alias Forge.Git.{Hooks, Tokens, Url}
  alias Forge.Projects

  setup do
    bare = seeded_repo()
    name = "demo#{System.unique_integer([:positive])}"

    {:ok, project} =
      register_owned!(%{name: name, repo_path: bare, default_branch: "main"})

    {:ok, main} = Git.resolve(bare, "refs/heads/main")
    :ok = Git.create_branch(bare, "ticket/1", main)
    :ok = Git.create_branch(bare, "ticket/2", main)

    %{project: project, bare: bare, main: main}
  end

  describe "fetching" do
    test "a token clones the repository", %{project: project} do
      {:ok, token, _row} = Tokens.issue(project, ref: "refs/heads/ticket/1", write: true)
      dir = clone!(project, token)

      assert File.read!(Path.join(dir, "README.md")) == "# Game\n"
    end

    test "no credential is answered with a challenge git can act on", %{project: project} do
      {out, code} = git(tmp_dir("anon"), ["clone", "--quiet", Url.for(project), "clone"])

      assert code != 0
      assert out =~ "Authentication failed" or out =~ "could not read Username"
    end

    test "an unknown, a revoked and an expired token are all refused", %{project: project} do
      {:ok, revoked, row} = Tokens.issue(project, ref: "refs/heads/ticket/1", write: true)
      Repo.update!(Ecto.Changeset.change(row, revoked_at: DateTime.utc_now(:second)))

      {:ok, expired, row} = Tokens.issue(project, ref: "refs/heads/ticket/1", write: true)

      Repo.update!(
        Ecto.Changeset.change(row,
          expires_at: DateTime.add(DateTime.utc_now(:second), -60, :second)
        )
      )

      for token <- ["not-a-token", revoked, expired] do
        {_out, code} = clone(project, token)
        assert code != 0
      end
    end

    test "a token for another project is refused", %{project: project} do
      other_bare = seeded_repo()
      name = "other#{System.unique_integer([:positive])}"

      {:ok, other} =
        register_owned!(%{name: name, repo_path: other_bare, default_branch: "main"})

      {:ok, token, _row} = Tokens.issue(other, ref: "refs/heads/ticket/1", write: true)

      {_out, code} = clone(project, token)
      assert code != 0
    end

    test "the dumb protocol is not served", %{project: project} do
      {:ok, token, _row} = Tokens.issue(project, ref: "refs/heads/ticket/1", write: true)
      url = Url.with_token(project, token)

      for path <- ["/objects/info/packs", "/HEAD", "/info/refs"] do
        {out, _code} = curl(url <> path)
        assert out =~ "no such repository"
      end
    end
  end

  describe "pushing" do
    test "the credential's own branch is accepted", %{project: project, bare: bare} do
      {:ok, token, _row} = Tokens.issue(project, ref: "refs/heads/ticket/1", write: true)
      dir = clone!(project, token, "ticket/1")
      sha = commit!(dir, "work.txt", "done")

      assert {_out, 0} = push(dir, project, token, "HEAD:refs/heads/ticket/1")
      assert {:ok, ^sha} = Git.resolve(bare, "refs/heads/ticket/1")
    end

    test "another ticket's branch is refused", %{project: project, bare: bare} do
      {:ok, token, _row} = Tokens.issue(project, ref: "refs/heads/ticket/1", write: true)
      dir = clone!(project, token, "ticket/1")
      commit!(dir, "work.txt", "done")
      {:ok, before} = Git.resolve(bare, "refs/heads/ticket/2")

      assert {out, code} = push(dir, project, token, "HEAD:refs/heads/ticket/2")
      assert code != 0
      assert out =~ "this credential may write refs/heads/ticket/1 only"
      assert {:ok, ^before} = Git.resolve(bare, "refs/heads/ticket/2")
    end

    test "the default branch is refused to a job's credential, however it is scoped", %{
      project: project,
      bare: bare,
      main: main
    } do
      {:ok, token, _row} = Tokens.issue(project, ref: "refs/heads/ticket/1", write: true)
      dir = clone!(project, token, "ticket/1")
      commit!(dir, "work.txt", "done")

      assert {out, code} = push(dir, project, token, "HEAD:refs/heads/main")
      assert code != 0
      assert out =~ "main is written by the platform's merge, or by a credential minted for it"
      assert {:ok, ^main} = Git.resolve(bare, "refs/heads/main")
    end

    test "a credential minted for the default branch may write it", %{
      project: project,
      bare: bare
    } do
      {:ok, token, _row} = Tokens.issue(project, ref: Tokens.default_ref(project), write: true)
      dir = clone!(project, token, "main")
      sha = commit!(dir, ".forge/workflow.yml", "states: {}")

      assert {_out, 0} = push(dir, project, token, "HEAD:refs/heads/main")
      assert {:ok, ^sha} = Git.resolve(bare, "refs/heads/main")
    end

    # The clause the operator's token shares with the platform's own merge. A token that could
    # rewrite the default branch would be able to orphan an approved changeset, which is the one
    # thing `refs/forge/approved/<n>` exists to make impossible.
    test "the default branch stays fast-forward, for a minted credential too", %{
      project: project,
      bare: bare
    } do
      {:ok, token, _row} = Tokens.issue(project, ref: Tokens.default_ref(project), write: true)
      dir = clone!(project, token, "main")
      commit!(dir, "work.txt", "first")
      assert {_out, 0} = push(dir, project, token, "HEAD:refs/heads/main")
      {:ok, pushed} = Git.resolve(bare, "refs/heads/main")

      {:ok, _out} = Git.run(dir, ["reset", "--quiet", "--hard", "HEAD~1"])
      commit!(dir, "work.txt", "rewritten")

      assert {out, code} = force_push(dir, project, token, "HEAD:refs/heads/main")
      assert code != 0
      assert out =~ "main must be fast-forward"
      assert {:ok, ^pushed} = Git.resolve(bare, "refs/heads/main")
    end

    # The scope check and the naming rule are separate clauses, and a default-branch credential
    # passes neither for someone else's branch.
    test "a default-branch credential reaches nothing else", %{project: project, bare: bare} do
      {:ok, token, _row} = Tokens.issue(project, ref: Tokens.default_ref(project), write: true)
      dir = clone!(project, token, "main")
      commit!(dir, "work.txt", "done")
      {:ok, before} = Git.resolve(bare, "refs/heads/ticket/1")

      assert {out, code} = push(dir, project, token, "HEAD:refs/heads/ticket/1")
      assert code != 0
      assert out =~ "this credential may write refs/heads/main only"
      assert {:ok, ^before} = Git.resolve(bare, "refs/heads/ticket/1")
    end

    test "a branch that is not a ticket's is refused", %{project: project} do
      {:ok, token, _row} = Tokens.issue(project, ref: "refs/heads/ticket/1", write: true)
      dir = clone!(project, token, "ticket/1")
      commit!(dir, "work.txt", "done")

      # The token's own ref passes the scope check; the naming rule is what refuses it.
      {:ok, wild, wild_row} = Tokens.issue(project, ref: "refs/heads/ticket/1", write: true)
      Repo.update!(Ecto.Changeset.change(wild_row, ref: "refs/heads/wildcat"))

      assert {out, code} = push(dir, project, wild, "HEAD:refs/heads/wildcat")
      assert code != 0
      assert out =~ "branches are ticket/<number>"
    end

    test "a ref is never deleted", %{project: project, bare: bare} do
      {:ok, token, _row} = Tokens.issue(project, ref: "refs/heads/ticket/1", write: true)
      dir = clone!(project, token, "ticket/1")

      assert {out, code} = push(dir, project, token, ":refs/heads/ticket/1")
      assert code != 0
      assert out =~ "refs are never deleted here"
      assert {:ok, _sha} = Git.resolve(bare, "refs/heads/ticket/1")
    end

    test "a read token cannot push", %{project: project} do
      {:ok, token, _row} = Tokens.issue(project)
      {:ok, write, _row} = Tokens.issue(project, ref: "refs/heads/ticket/1", write: true)
      dir = clone!(project, write, "ticket/1")
      commit!(dir, "work.txt", "done")

      {_out, code} = push(dir, project, token, "HEAD:refs/heads/ticket/1")
      assert code != 0
    end

    test "a rewrite of the ticket branch is allowed and said out loud", %{project: project} do
      {:ok, token, _row} = Tokens.issue(project, ref: "refs/heads/ticket/1", write: true)
      dir = clone!(project, token, "ticket/1")
      commit!(dir, "work.txt", "first")
      assert {_out, 0} = push(dir, project, token, "HEAD:refs/heads/ticket/1")

      {:ok, _out} = Git.run(dir, ["reset", "--quiet", "--hard", "HEAD~1"])
      commit!(dir, "work.txt", "squashed")

      assert {out, 0} = force_push(dir, project, token, "HEAD:refs/heads/ticket/1")
      assert out =~ "was rewritten (non-fast-forward)"
    end
  end

  describe "the mirror" do
    test "a push reaches the mirror, and only the refs it is configured for", %{
      project: project,
      bare: bare,
      main: main
    } do
      mirror = Path.join(tmp_dir("mirror"), "mirror.git")
      :ok = Git.init_bare(mirror)
      :ok = Projects.set_mirror(project, mirror)

      {:ok, token, _row} = Tokens.issue(project, ref: "refs/heads/ticket/1", write: true)
      dir = clone!(project, token, "ticket/1")
      commit!(dir, "work.txt", "done")
      assert {_out, 0} = push(dir, project, token, "HEAD:refs/heads/ticket/1")

      # The default is the default branch alone: a ticket's scratch history is not published.
      assert {:error, {:unknown_ref, _}} = Git.resolve(mirror, "refs/heads/ticket/1")
      assert {:error, {:unknown_ref, _}} = Git.resolve(mirror, "refs/heads/main")

      # What the platform's merge does: a local push into the bare repository, which is the one
      # path that runs the repository's own hooks — so the mirror is the same code that guards
      # the branch discipline, rather than a second implementation beside it.
      {:ok, out} =
        Git.run(dir, ["push", "--quiet", bare, "HEAD:refs/heads/main"],
          env: [{"FORGE_INTERNAL", "1"}]
        )

      assert out =~ "mirrored refs/heads/main to #{mirror}"
      {:ok, head} = Git.resolve(bare, "refs/heads/main")
      assert head != main
      assert {:ok, ^head} = Git.resolve(mirror, "refs/heads/main")
    end

    test "a mirror that cannot be reached does not fail the push", %{project: project, bare: bare} do
      :ok = Projects.set_mirror(project, "/nowhere/at/all.git", "refs/heads/*")

      {:ok, token, _row} = Tokens.issue(project, ref: "refs/heads/ticket/1", write: true)
      dir = clone!(project, token, "ticket/1")
      sha = commit!(dir, "work.txt", "done")

      assert {out, 0} = push(dir, project, token, "HEAD:refs/heads/ticket/1")
      assert out =~ "mirror to /nowhere/at/all.git FAILED"
      assert {:ok, ^sha} = Git.resolve(bare, "refs/heads/ticket/1")
    end

    test "the mirror is repository configuration, not a column", %{project: project} do
      refute Projects.mirror(project)
      :ok = Projects.set_mirror(project, "/tmp/somewhere.git")
      assert Projects.mirror(project) == "/tmp/somewhere.git"
      assert Hooks.mirror(Projects.repo_path(project)) == "/tmp/somewhere.git"
      :ok = Projects.set_mirror(project, nil)
      refute Projects.mirror(project)
    end
  end

  describe "the environment the CGI hands to a hook" do
    # System.cmd/3 merges :env with the BEAM's own environment rather than replacing it, and
    # FORGE_INTERNAL is what pre-receive accepts as authority over the default branch. If the
    # platform is holding it for its own merge when a request arrives, it must not reach the
    # child. This is the highest-consequence line in the endpoint.
    test "FORGE_INTERNAL never leaks from the platform's environment", %{
      project: project,
      bare: bare,
      main: main
    } do
      System.put_env("FORGE_INTERNAL", "1")
      on_exit(fn -> System.delete_env("FORGE_INTERNAL") end)

      {:ok, token, _row} = Tokens.issue(project, ref: "refs/heads/ticket/1", write: true)
      dir = clone!(project, token, "ticket/1")
      commit!(dir, "work.txt", "done")

      assert {out, code} = push(dir, project, token, "HEAD:refs/heads/main")
      assert code != 0
      assert out =~ "main is written by the platform's merge, or by a credential minted for it"
      assert {:ok, ^main} = Git.resolve(bare, "refs/heads/main")
    end
  end

  describe "what the CGI said" do
    # A git client decides from the status line and nothing else: a fetch that reads 200 is a
    # fetch that succeeded, whatever the body turns out to be. `git http-backend` writes its own
    # `Status:` header into the CGI response and the endpoint has to carry it through — losing it
    # turns every failure into a success carrying a truncated or empty packfile, which the client
    # then reports as a corrupt repository rather than as the refusal it was.
    #
    # The failure used here is a project whose rows exist and whose bytes do not, because that is
    # the one the CGI answers itself rather than the plug in front of it. The plug's own 404s are
    # sent by `send_resp` and never go near this.
    test "a failure keeps the status git http-backend gave it", %{project: project} do
      {:ok, token, _row} = Tokens.issue(project)
      advertisement = Url.with_token(project, token) <> "/info/refs?service=git-upload-pack"

      assert status(advertisement) == 200

      File.rm_rf!(Projects.repo_path(project))

      assert status(advertisement) == 404
    end
  end

  # -- helpers ---------------------------------------------------------------------------------

  defp clone!(project, token, branch \\ "main") do
    parent = tmp_dir("clone")
    dir = Path.join(parent, "clone")

    assert {_out, 0} =
             git(parent, [
               "clone",
               "--quiet",
               "--branch",
               branch,
               Url.with_token(project, token),
               dir
             ])

    {:ok, _out} = Git.run(dir, ["config", "user.name", "test"])
    {:ok, _out} = Git.run(dir, ["config", "user.email", "test@forge"])
    dir
  end

  defp clone(project, token) do
    parent = tmp_dir("clone")
    git(parent, ["clone", "--quiet", Url.with_token(project, token), Path.join(parent, "clone")])
  end

  defp commit!(dir, path, content) do
    File.write!(Path.join(dir, path), content <> "\n")
    {:ok, _out} = Git.run(dir, ["add", path])
    {:ok, _out} = Git.run(dir, ["commit", "--quiet", "-m", content])
    {:ok, sha} = Git.run(dir, ["rev-parse", "HEAD"])
    String.trim(sha)
  end

  # Always through an explicit URL carrying the token under test, never through `origin`: the
  # clone's origin embeds whatever token cloned it, which would quietly push as a different
  # credential than the one the test names.
  defp push(dir, project, token, refspec) do
    git(dir, ["push", "--quiet", Url.with_token(project, token), refspec])
  end

  defp force_push(dir, project, token, refspec) do
    git(dir, ["push", "--quiet", "--force", Url.with_token(project, token), refspec])
  end

  defp curl(url) do
    System.cmd("curl", ["-sS", "--fail-with-body", url], stderr_to_stdout: true)
  end

  # The status line alone, discarding the body: what a git client reads first.
  defp status(url) do
    {code, 0} = System.cmd("curl", ["-sS", "-o", "/dev/null", "-w", "%{http_code}", url])
    String.to_integer(code)
  end

  defp git(dir, args, env \\ []) do
    System.cmd("git", args,
      cd: dir,
      stderr_to_stdout: true,
      env: [{"GIT_TERMINAL_PROMPT", "0"} | env]
    )
  end
end
