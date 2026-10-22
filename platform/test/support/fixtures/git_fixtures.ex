defmodule Forge.GitFixtures do
  @moduledoc "A bare repository seeded with a `.forge/` directory, for tests that need git."

  alias Forge.Git

  @workflow Path.expand("../../../../core/test/fixtures/workflow_example.yml", __DIR__)

  @doc """
  A fresh temporary directory, removed when the test process exits.

  Named by the OS process as well as `System.unique_integer/1`, which is unique only within one
  BEAM: suites run side by side from sibling worktrees share the system temp directory, and two
  of them made — and removed — each other's directories.
  """
  def tmp_dir(label) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "#{System.pid()}-forge-#{label}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  @doc """
  A fresh repositories directory with a parent of its own, for a test that points `repos_dir` at
  it.

  Not `node_repos_dir()`: `Forge.Git.Credentials.dir/0` is a *sibling* of `repos_dir`, so a
  repositories directory placed directly in the system temp directory puts every such test
  file's mirror credentials in one shared `<tmp>/mirror-credentials` — which each of them removes
  in its own `on_exit`. Nothing collides within a run, because the files that do this are all
  `async: false` and ExUnit runs sync modules one at a time; two runs on one machine, or two
  users sharing a box, are what this closes. The parent gives the credentials directory the same
  isolation the repositories already had.
  """
  def node_repos_dir do
    dir = Path.join(tmp_dir("node"), "repos")
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  A bare repository whose `main` starts exactly where `source`'s does, and nothing else: a
  mirror destination in an end-to-end mirror test.

  A mirror push is fast-forward only, on both ends — the far side's own `pre-receive` enforces it
  too — so the destination needs a common ancestor with whatever `source` is about to push.
  `seeded_repo/1` gives two independently-called destinations a common ancestor only by accident:
  its root commit carries no explicit `GIT_AUTHOR_DATE`, so two calls collide only when they land
  in the same wall-clock second. Copying `main` alone, rather than `git clone --bare`'s every
  branch, is deliberate too: `ForgeWeb.GitHttpTest`'s `source` already has a `ticket/1` branch by
  the time it calls this, and its test proving a ticket branch does *not* reach the mirror would
  fail outright — not pass for the wrong reason — against a destination that already carries one
  from the clone, never having exercised the mirror at all. Returns the new bare path.
  """
  def mirror_target(source) do
    dest = Path.join(tmp_dir("mirror-target"), "target.git")
    :ok = Git.init_bare(dest)
    {:ok, _out} = Git.run(source, ["push", "--quiet", dest, "refs/heads/main:refs/heads/main"])
    dest
  end

  @doc """
  The platform's own git URL for `repo` as this test run serves it. Built from the endpoint's
  configured port rather than written out, so a run on another `PORT` — two suites side by side
  on one machine — reaches its own server and not the other's.
  """
  def platform_git_url(repo) do
    "http://127.0.0.1:#{ForgeWeb.Endpoint.config(:http)[:port]}/git/#{repo}.git"
  end

  @doc """
  A bare repository whose `main` holds `.forge/workflow.yml` (the grammar example), the four
  prompts it names, and a README. Returns the bare path.

  `files` overrides or adds paths; a path mapped to `nil` is left out of the commit, which is
  how to seed a repository that is pushed but missing something.
  """
  def seeded_repo(files \\ %{}) do
    bare = Path.join(tmp_dir("bare"), "project.git")
    work = tmp_dir("work")
    :ok = Git.init_bare(bare)

    files =
      Map.merge(
        %{
          "README.md" => "# Game\n",
          ".forge/workflow.yml" => File.read!(@workflow),
          ".forge/agents/refine.md" => "Refine the ticket into a crisp problem statement.\n",
          ".forge/agents/plan.md" => "Write a plan.\n",
          ".forge/agents/implement.md" => "Implement the plan.\n",
          ".forge/agents/verify.md" => "Verify the implementation.\n"
        },
        files
      )

    files
    |> Enum.reject(fn {_path, content} -> is_nil(content) end)
    |> Enum.each(fn {path, content} ->
      full = Path.join(work, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end)

    git!(work, ["init", "-q", "-b", "main"])
    git!(work, ["add", "."])

    git!(work, [
      "-c",
      "user.name=seed",
      "-c",
      "user.email=seed@forge",
      "commit",
      "-q",
      "-m",
      "seed"
    ])

    git!(work, ["push", "-q", bare, "main"])
    bare
  end

  @doc """
  Commits `content` at `path` on a ticket's branch, over the platform's own git endpoint, the
  way a job does — clone, commit, push, all with a write token scoped to that branch. Returns
  the sha the branch now points at.

  A plain git client rather than `ForgeWorker.Checkout`: since milestone 3 the platform does
  not compile the worker in, so its tests cannot borrow the worker's git any more than its code
  can. The token rides in the URL, which is the form `Forge.Git.Url.with_token/2` exists for.
  """
  def commit_over_http(project, branch, path, content, message \\ nil) do
    dir = Path.join(tmp_dir("client"), "clone")

    {:ok, token, _row} =
      Forge.Git.Tokens.issue(project, ref: "refs/heads/" <> branch, write: true)

    url = Forge.Git.Url.with_token(project, token)

    git!(Path.dirname(dir), ["clone", "--quiet", "--branch", branch, url, dir])
    File.mkdir_p!(Path.dirname(Path.join(dir, path)))
    File.write!(Path.join(dir, path), content <> "\n")
    git!(dir, ["add", path])

    git!(dir, [
      "-c",
      "user.name=job",
      "-c",
      "user.email=job@forge",
      "commit",
      "-q",
      "-m",
      message || content
    ])

    git!(dir, ["push", "--quiet", "--force", url, "HEAD:refs/heads/" <> branch])

    {:ok, sha} = Git.resolve(Forge.Projects.repo_path(project), "refs/heads/" <> branch)
    sha
  end

  @doc """
  Commits `files` (`%{path => content}`) to the project's default branch and returns the new head.
  Stands in for the platform's own merge, the only writer the repository lets onto that branch,
  which is why the push says it is one.
  """
  def commit_to_default(project, files),
    do: commit_to(Forge.Projects.repo_path(project), project.default_branch, files, "fix")

  @doc """
  Commits `files` (`%{path => content}`) onto `branch` of the repository at `repo`, pushed as the
  platform pushes — past the hooks that keep everyone else off a protected branch — and returns
  the new head. A path mapped to `nil` is removed.
  """
  def commit_to(repo, branch, files, message \\ "change") do
    work = Path.join(tmp_dir("commit"), "work")
    git!(Path.dirname(work), ["clone", "-q", "--branch", branch, repo, work])

    for {path, content} <- files do
      full = Path.join(work, path)

      if is_nil(content) do
        File.rm!(full)
      else
        File.mkdir_p!(Path.dirname(full))
        File.write!(full, content)
      end
    end

    git!(work, ["add", "-A"])
    git!(work, ["-c", "user.name=t", "-c", "user.email=t@forge", "commit", "-q", "-m", message])

    {_out, 0} =
      System.cmd("git", ["push", "-q", "origin", "HEAD:refs/heads/" <> branch],
        cd: work,
        env: [{"FORGE_INTERNAL", "1"}],
        stderr_to_stdout: true
      )

    {:ok, head} = Git.resolve(repo, "refs/heads/" <> branch)
    head
  end

  @doc """
  A workflow whose merging state sends a conflict to `integrating`
  (`docs/design/workflow-grammar-v1.md` § Merging). `:b` sends an integration straight back to the
  merge and `:a` back to a person who approves it again, `:reviewed` through a job reading the
  changeset before that person, and `:human` makes the target a human state that sends the
  ticket back to implementing; `:plain` is one from before `on_conflict` existed, with an edge
  the engine takes into the merge by itself beside the person's approval. Its integrating and
  reviewing states' prompt is `agents/integrate.md`, which `seeded_repo/1` does not write.
  """
  def conflict_workflow(route) do
    {conflict, integrating, back, engine} =
      case route do
        :plain ->
          {"", "", "", "  - { from: implementing, to: merged, when: engine_merges }\n"}

        :human ->
          {"    on_conflict: integrating\n", "  integrating: {}\n",
           "  - { from: integrating, to: implementing }\n", ""}

        :reviewed ->
          {"    on_conflict: integrating\n",
           """
             integrating:
               prompt: agents/integrate.md
               inputs: [changeset]
               produces: [changeset]
               budget: { turns: 10, cost: 1.00 }
             reviewing:
               prompt: agents/integrate.md
               inputs: [changeset]
               produces: [review.md]
               budget: { turns: 10, cost: 1.00 }
           """,
           "  - { from: integrating, to: reviewing }\n  - { from: reviewing, to: review_ready }\n",
           ""}

        route ->
          to = if route == :a, do: "review_ready", else: "merged"

          {"    on_conflict: integrating\n",
           """
             integrating:
               prompt: agents/integrate.md
               inputs: [changeset]
               produces: [changeset]
               budget: { turns: 10, cost: 1.00 }
           """, "  - { from: integrating, to: #{to} }\n", ""}
      end

    """
    version: 1
    initial: implementing
    states:
      implementing:
        prompt: agents/implement.md
        produces: [implementation.md, changeset]
        outcomes: [done, engine_merges]
        budget: { turns: 10, cost: 1.00 }
      review_ready: {}
      merged:
        on_enter: merge
    #{conflict}#{integrating}transitions:
      - { from: implementing, to: review_ready }
      - { from: review_ready, to: merged, approve: [changeset] }
    #{back}#{engine}limits:
      ticket_cost: 25.00
    """
  end

  @doc """
  Every file under the bare repository at `repo`, by path and content hash.

  What a write of *any* kind changes, and what `for-each-ref` cannot see: a page that wrote a
  file into a bare repository left every ref exactly where it had been, so the test that was
  supposed to hold "browsing never writes" walked straight past it.
  """
  def tree_of(repo) do
    repo
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{Path.relative_to(&1, repo), :crypto.hash(:sha256, File.read!(&1))})
  end

  @doc """
  `count` commits on `branch` of the bare repository at `repo`, numbered `commit 1` upwards and
  pushed once, returning the branch's new head.

  One clone and one push for all of them: a test that needs thirty-one commits to reach a page
  boundary is the only reason this exists, and a clone per commit was most of two test files'
  runtime. `FORGE_INTERNAL` is set for the same reason `commit_to/4` sets it — the branch may be
  the project's default, which `pre-receive` lets only the platform write.
  """
  def seed_commits(repo, branch, count) do
    work = Path.join(tmp_dir("history"), "work")
    {:ok, _out} = Git.run(tmp_dir("history-parent"), ["clone", "-q", "-b", branch, repo, work])

    for n <- 1..count do
      File.write!(Path.join(work, "n.txt"), "#{n}\n")
      {:ok, _out} = Git.run(work, ["add", "n.txt"])

      {:ok, _out} =
        Git.run(work, [
          "-c",
          "user.name=t",
          "-c",
          "user.email=t@forge",
          "commit",
          "-q",
          "-m",
          "commit #{n}"
        ])
    end

    {:ok, _out} =
      Git.run(work, ["push", "-q", "origin", "HEAD:refs/heads/" <> branch],
        env: [{"FORGE_INTERNAL", "1"}]
      )

    {:ok, head} = Git.resolve(repo, "refs/heads/" <> branch)
    head
  end

  @doc """
  A commit on top of `parent`, made in a scratch clone and fetched into the bare repository
  without moving any ref: something for `race/2` to move the default branch to.
  """
  def commit_beside(bare, parent, path, content) do
    dir = Path.join(tmp_dir("merge-beside"), "work")
    {:ok, _out} = Git.run(tmp_dir("merge-beside-parent"), ["clone", "--quiet", bare, dir])

    for args <- [
          ["checkout", "--quiet", "--detach", parent],
          ["config", "user.name", "elsewhere"],
          ["config", "user.email", "elsewhere@forge"]
        ],
        do: {:ok, _out} = Git.run(dir, args)

    File.write!(Path.join(dir, path), content <> "\n")
    {:ok, _out} = Git.run(dir, ["add", path])
    {:ok, _out} = Git.run(dir, ["commit", "--quiet", "-m", content])
    {:ok, sha} = Git.resolve(dir, "HEAD")
    {:ok, _out} = Git.run(bare, ["fetch", "--quiet", dir, "HEAD"])
    sha
  end

  @doc """
  Wraps the repository's `pre-receive`. On the n-th push it moves the default branch to the n-th
  of `moves`, if there is one, and then hands over to the real hook — or, with `refuse: true`,
  refuses without moving anything. Returns a function counting the pushes it saw.

  The move has to leave git's quarantine to be allowed at all: a hook may not update a ref
  while the pushed objects are still quarantined, which is the rule that makes this window
  otherwise impossible to reach from inside the push. It is how a merge is made to lose the race
  `docs/design/git-hosting.md` § Where it runs, and what a conflict does describes.
  """
  def race(bare, opts) do
    dir = tmp_dir("merge-race")
    count = Path.join(dir, "pushes")
    moves = Path.join(dir, "moves")
    File.write!(moves, Enum.map_join(Keyword.get(opts, :moves, []), &(&1 <> "\n")))

    hook = Path.join([bare, "hooks", "pre-receive"])
    File.rename!(hook, hook <> ".real")

    finish =
      if Keyword.get(opts, :refuse, false),
        do: ~s(echo "forge: refused by the test" >&2; exit 1),
        else: ~s(exec "$0.real")

    File.write!(hook, """
    #!/usr/bin/env bash
    set -eu
    n=$(( $(cat "#{count}" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "#{count}"
    target=$(sed -n "${n}p" "#{moves}")
    if [ -n "$target" ]; then
      env -u GIT_QUARANTINE_PATH git update-ref refs/heads/main "$target"
    fi
    #{finish}
    """)

    File.chmod!(hook, 0o755)

    fn ->
      case File.read(count) do
        {:ok, n} -> n |> String.trim() |> String.to_integer()
        {:error, :enoent} -> 0
      end
    end
  end

  @doc """
  Runs git in `dir` as a job's own client would — the name says whose client, because this module
  has a `git!/2` of its own and `GitHttpTest` a `git/3` — an identity of its own, no signing, no terminal
  — and hands back `{output, status}` rather than raising, for a test about what git *refuses*.

  **No `FORGE_INTERNAL`**, which is what makes it usable for a test of the hook's branch
  discipline: `MergeFixtures`'s own git sets it, bypassing the guard such a test exists to prove
  (`docs/design/git-hosting.md` § The per-job token).
  """
  def job_git(dir, args) do
    System.cmd(
      "git",
      ["-c", "user.name=job", "-c", "user.email=job@forge", "-c", "commit.gpgsign=false" | args],
      cd: dir,
      stderr_to_stdout: true,
      env: [{"GIT_TERMINAL_PROMPT", "0"}]
    )
  end

  defp git!(dir, args) do
    {:ok, _} = Git.run(dir, args)
  end
end
