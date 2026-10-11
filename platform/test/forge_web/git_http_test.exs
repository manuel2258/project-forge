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

      # What git says when challenged with prompts off depends on its version: git 2.55, the
      # devshell's, says it could not get a password, where older ones said they could not read a
      # username. A 403 or a 404 says neither, so each still means the challenge was there.
      assert out =~ "Authentication failed" or out =~ "could not read Username" or
               out =~ "unable to get password from user"
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

    # The hook is the enforcement point, so it must hold without the token's own validation in
    # front of it: `ticket/[0-9]*` as a glob is a digit followed by anything.
    test "a ticket branch is a number and nothing after it", %{project: project} do
      {:ok, token, _row} = Tokens.issue(project, ref: "refs/heads/ticket/1", write: true)
      dir = clone!(project, token, "ticket/1")
      commit!(dir, "work.txt", "done")

      # Anything after the number, wherever it is — not only at the end.
      for bad <- ["ticket/1abc", "ticket/1a2", "ticket/1/2"] do
        {:ok, wild, wild_row} = Tokens.issue(project, ref: "refs/heads/ticket/1", write: true)
        Repo.update!(Ecto.Changeset.change(wild_row, ref: "refs/heads/" <> bad))

        assert {out, code} = push(dir, project, wild, "HEAD:refs/heads/" <> bad)
        assert code != 0, bad
        assert out =~ "branches are ticket/<number>", bad
      end
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

  # Mirrored over the platform's own git endpoint rather than to a path on disk: a local path
  # exercised neither the transport, the credential, nor `receive-pack` on the far side, and a
  # local path is now refused anyway.
  describe "the mirrors" do
    setup %{project: project, bare: bare} do
      # An admin of the project under test, because `register_owned!/1` does not hand its owner
      # back and `put_mirror/5` needs a named actor.
      owner = Forge.AccountsFixtures.user_fixture()
      join!(project, owner, :admin)

      # Two rules have to agree for an authenticated mirror to work at all: the hook derives its
      # credential directory from its own working directory, and `Forge.Git.Credentials.path/2`
      # derives the filename from `project.name`. Both hold by construction for a project
      # registered the normal way, at `<repos_dir>/<name>.git` — but `bare` here is
      # `seeded_repo/1`'s fixture, always named `project.git` under a `System.tmp_dir/0` path
      # that is not inside any configured `repos_dir`. So this setup gives the project under
      # test the address a normal registration would have, rather than working around the
      # absence of one — `repos_dir` is pointed at `node_repos_dir/0`'s own unique, self-cleaning
      # directory (already under `System.tmp_dir/0`, so the rename below is not cross-device;
      # unique so an interrupted run never leaves a stale `<name>.git` for the next run's
      # `File.rename!` to collide with) and the repository is moved to
      # `<repos_dir>/<project.name>.git`.
      jobs_config = Application.get_env(:forge, Forge.Jobs)

      Application.put_env(
        :forge,
        Forge.Jobs,
        Keyword.put(jobs_config, :repos_dir, node_repos_dir())
      )

      # Captured now, while the override above is live: `Credentials.dir/0` reads
      # `Projects.repos_dir/0` when called, and an `on_exit` that restored the config first and
      # read it after would compute the *original* `repos_dir` — deleting an empty directory
      # nobody used while leaving the real credential files, mode 0600 and holding live git
      # tokens, behind in the shared `mirror-credentials` directory forever.
      credentials_dir = Forge.Git.Credentials.dir()

      on_exit(fn ->
        Application.put_env(:forge, Forge.Jobs, jobs_config)
        File.rm_rf(credentials_dir)
      end)

      real_bare = Path.join(Forge.Projects.repos_dir(), project.name <> ".git")
      File.mkdir_p!(Path.dirname(real_bare))
      File.rename!(bare, real_bare)
      bare = real_bare

      {:ok, project} =
        project
        |> Forge.Projects.Project.changeset(%{repo_path: bare})
        |> Forge.Repo.update()

      # A clone of `bare`'s own current state, not an independently seeded repository: the
      # mirror push below is fast-forward only on both ends, and two unrelated histories are
      # never a fast-forward of one another.
      destination_bare = mirror_target(bare)

      {:ok, destination} =
        register_owned!(%{
          name: "destination#{System.unique_integer([:positive])}",
          repo_path: destination_bare,
          default_branch: "main"
        })

      # The default-branch write token is the shape only an operator can mint, and it is what
      # `pre-receive` on the far side accepts as authority over `main`.
      {:ok, token, _row} = Tokens.issue(destination, ref: "refs/heads/main", write: true)

      %{
        owner: owner,
        project: project,
        bare: bare,
        destination: destination,
        destination_bare: destination_bare,
        mirror_url: platform_git_url(destination.name),
        mirror_token: token
      }
    end

    # The platform's own merge: a local push into the bare repository, the one path that runs the
    # repository's own hooks. `Git.run/3` merges stderr unless told otherwise, so the hook's
    # `forge: ` lines come back in `out`.
    defp mirror_push(project, bare) do
      {:ok, token, _row} = Tokens.issue(project, ref: "refs/heads/ticket/1", write: true)
      dir = clone!(project, token, "ticket/1")
      commit!(dir, "work.txt", "done")

      {:ok, out} =
        Git.run(dir, ["push", "--quiet", bare, "HEAD:refs/heads/main"],
          env: [{"FORGE_INTERNAL", "1"}]
        )

      out
    end

    test "a push reaches the mirror, and only the refs it is configured for", %{
      project: project,
      bare: bare,
      destination: destination,
      mirror_url: url,
      mirror_token: token,
      owner: owner
    } do
      :ok = Projects.put_mirror(project, owner, "backup", url, user: "forge", token: token)

      out = mirror_push(project, bare)

      assert out =~ "forge: mirrored refs/heads/main to backup"
      assert {:ok, _sha} = Git.resolve(Projects.repo_path(destination), "refs/heads/main")
    end

    test "a ticket branch is not mirrored, because the glob does not name it", %{
      project: project,
      bare: bare,
      destination: destination,
      mirror_url: url,
      mirror_token: token,
      owner: owner
    } do
      :ok = Projects.put_mirror(project, owner, "backup", url, user: "forge", token: token)

      mirror_push(project, bare)

      assert {:error, {:unknown_ref, _}} =
               Git.resolve(Projects.repo_path(destination), "refs/heads/ticket/1")
    end

    test "two mirrors both receive, and one failing does not stop the other", %{
      project: project,
      bare: bare,
      destination: destination,
      mirror_url: url,
      mirror_token: token,
      owner: owner
    } do
      # "bad" configured first, deliberately: `git config --get-regexp` walks the config file in
      # write order, so this is what actually proves the loop does not stop at the first failure
      # — putting the failing mirror last would still pass even if it did.
      :ok = Projects.put_mirror(project, owner, "bad", platform_git_url("nope"), [])
      :ok = Projects.put_mirror(project, owner, "good", url, user: "forge", token: token)

      out = mirror_push(project, bare)

      assert out =~ "forge: mirrored refs/heads/main to good"
      assert out =~ "forge: mirror to bad FAILED"
      assert {:ok, _sha} = Git.resolve(Projects.repo_path(destination), "refs/heads/main")
    end

    test "a failing mirror records why, and the push stands", %{
      project: project,
      bare: bare,
      owner: owner
    } do
      :ok = Projects.put_mirror(project, owner, "bad", platform_git_url("nope"), [])

      out = mirror_push(project, bare)

      assert out =~ "the push itself stands"
      assert [%{name: "bad", last_status: "failed"} = mirror] = Projects.list_mirrors(project)
      assert mirror.last_error =~ "not found"
      assert mirror.last_ok_at == nil
      assert {:ok, _sha} = Git.resolve(Projects.repo_path(project), "refs/heads/main")
    end

    test "a succeeding mirror records when it last worked", %{
      project: project,
      bare: bare,
      mirror_url: url,
      mirror_token: token,
      owner: owner
    } do
      :ok = Projects.put_mirror(project, owner, "backup", url, user: "forge", token: token)

      mirror_push(project, bare)

      assert [%{last_status: "ok", last_ok_at: at, last_error: nil}] =
               Projects.list_mirrors(project)

      assert at =~ ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/
    end

    # Neither `mirror_push/2` (merges stdout and stderr, per `Git.run/3`'s default) nor even
    # `Git.run/3` with `stderr: :separate` can tell the two apart here: git's own client relays a
    # hook's messages as "remote: " lines on the *client's* stderr regardless of which fd the
    # hook wrote to, and the CGI wrapper's own `err_path` never receives hook output at all (see
    # the comment on "a CGI-mediated push..." below). Neither push path can observe the hook's fd
    # choice, so this runs the installed hook script directly, the way `receive-pack` runs it,
    # with its own stdout and stderr captured into separate files — the one way to actually see
    # it.
    test "the success line is on stderr, not stdout", %{
      project: project,
      bare: bare,
      mirror_url: url,
      mirror_token: token,
      owner: owner
    } do
      :ok = Projects.put_mirror(project, owner, "backup", url, user: "forge", token: token)

      hook = Path.join(Projects.repo_path(project), "hooks/post-receive")
      {:ok, main} = Git.resolve(bare, "refs/heads/main")

      in_path = Path.join(tmp_dir("hook-in"), "stdin")
      out_path = Path.join(tmp_dir("hook-out"), "stdout")
      err_path = Path.join(tmp_dir("hook-err"), "stderr")
      File.write!(in_path, "#{String.duplicate("0", 40)} #{main} refs/heads/main\n")

      {_out, 0} =
        System.cmd(
          "sh",
          ["-c", ~s(exec "#{hook}" <"#{in_path}" >"#{out_path}" 2>"#{err_path}")],
          cd: bare
        )

      assert File.read!(out_path) == ""
      assert File.read!(err_path) =~ "forge: mirrored refs/heads/main to backup"
    end

    # The hook is the second enforcement point, and this is the case that needs it: config
    # written by something other than `Forge.Projects`.
    test "a URL the rules refuse is never pushed to, however it got into the config", %{
      project: project,
      bare: bare
    } do
      repo = Projects.repo_path(project)
      # A path unique to this test, not a fixed name two tests (or another user on the machine)
      # could share: a leftover from an interrupted run would otherwise make the assertion below
      # pass, or fail, for a reason that has nothing to do with this push.
      target = Path.join(tmp_dir("pwned"), "pwned")
      :ok = Hooks.put_mirror(repo, "evil", "ext::sh -c 'touch #{target}'", [])

      out = mirror_push(project, bare)

      refute File.exists?(target)
      assert out =~ "forge: mirror evil is not an http(s) URL"
      assert [%{name: "evil", last_status: "failed"}] = Projects.list_mirrors(project)
    end

    # Not covered by the `ext::` case above: `allowed/1`'s option-like guard and its `::`
    # transport-helper guard are two different case arms, and a mutation of one does not move
    # the other. `--end-of-options` in the push itself is the second line of defense for exactly
    # this shape — this mirror would be refused before either mattered, but the URL is chosen so
    # that removing *only* the option-like guard would hand git something that looks like a flag.
    test "an option-like URL is refused too, not handed to git as an argument", %{
      project: project,
      bare: bare
    } do
      repo = Projects.repo_path(project)
      target = Path.join(tmp_dir("pwned"), "pwned")
      :ok = Hooks.put_mirror(repo, "opt", "--upload-pack=touch #{target}", [])

      out = mirror_push(project, bare)

      refute File.exists?(target)
      assert out =~ "forge: mirror opt is not an http(s) URL"
      assert [%{name: "opt", last_status: "failed"}] = Projects.list_mirrors(project)
    end

    test "a local path is never pushed to either", %{project: project, bare: bare} do
      repo = Projects.repo_path(project)
      elsewhere = Path.join(tmp_dir("elsewhere"), "elsewhere.git")
      :ok = Git.init_bare(elsewhere)
      :ok = Hooks.put_mirror(repo, "local", elsewhere, [])

      mirror_push(project, bare)

      assert {:error, {:unknown_ref, _}} = Git.resolve(elsewhere, "refs/heads/main")
    end

    # The brief for this task asserts a `git.hook.said` *event* here: `Forge.Git.Http.report/3`
    # is documented (`docs/design/git-hosting.md` § What the mirrors say about themselves) as
    # turning a hook's `forge: ` lines into that event, reading them from the CGI wrapper's
    # captured stderr (`err_path`). It does not, for any push: `git http-backend` relays a
    # hook's stderr to the *client* over the smart-HTTP protocol's own sideband — the "remote: "
    # lines a git client prints — and that relay is embedded in the CGI's stdout (the response
    # body), never written to the CGI's own stderr. `err_path` is empty after every push,
    # verified by instrumenting `report/3` directly against this exact scenario, so no
    # `git.hook.said` event is created today — not for a mirror, and not for the ticket-branch
    # rewrite notice the same design section already claims one for. This is a real,
    # pre-existing gap, not something this task's file list (the hook and this test) can fix —
    # doing so needs `report/3` to parse the pkt-line/side-band-64k response body instead, which
    # is a change to `Forge.Git.Http`. Flagged in the task-4 report rather than silently
    # asserted here. What *is* true, and what this asserts instead, is the half that survives
    # the CGI boundary: the client still sees the hook's line.
    test "a CGI-mediated push still relays the hook's report to the client", %{
      project: project,
      mirror_url: url,
      mirror_token: token,
      owner: owner
    } do
      :ok = Projects.put_mirror(project, owner, "backup", url, user: "forge", token: token)

      {:ok, main_token, _row} = Tokens.issue(project, ref: "refs/heads/main", write: true)
      dir = clone!(project, main_token, "main")
      commit!(dir, "work.txt", "done")

      assert {out, 0} = push(dir, project, main_token, "HEAD:refs/heads/main")
      assert out =~ "forge: mirrored refs/heads/main to backup"
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
