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
  `seeded_repo/1` gives two calls with the same `files` the same root commit, since it builds each
  once and copies it, but two with different `files` none; and before it did that, only by accident:
  its root commit carries no explicit `GIT_AUTHOR_DATE`, so two calls collided only when they landed
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
  bound port (`Forge.TestEndpoint`), which the kernel picks for each run, so two suites side by
  side on one machine reach their own servers and not each other's.
  """
  def platform_git_url(repo) do
    "http://127.0.0.1:#{Forge.TestEndpoint.port()}/git/#{repo}.git"
  end

  @doc """
  A bare repository whose `main` holds `.forge/workflow.yml` (the grammar example), the four
  prompts it names, and a README. Returns the bare path.

  `files` overrides or adds paths; a path mapped to `nil` is left out of the commit, which is
  how to seed a repository that is pushed but missing something.

  **Made once per distinct `files` in a run, and copied** (`seed_template/1`): it was `git init`,
  `add`, `commit` and `push` for every one of its 140-odd call sites' tests. An early run (the suite
  on two cores beside another job's load, `git` replaced by a script that timed it) made 69 000 git
  calls taking 304 s of process wall time, 140 s of them `init`, `add`, `commit` and `push`, of which
  this is one of several callers; the saving was not measured on its own. At 1cec7c8 a gate run
  started 89,516 git processes, 448 CPU-seconds of git's own, counted by a `git` first on `PATH`;
  one partition of three (the second, 1931 tests, no coverage) started 42,335 by git's own trace2
  `start` events, and 29,750 after ticket 68 (`docs/design/git-hosting.md` § What a question costs).
  The copy is a repository
  of its own, which no test shares with another — and the same commit, so two calls with the same
  `files` now always have a common root (`mirror_target/1`).
  """
  def seeded_repo(files \\ %{}) do
    bare = Path.join(tmp_dir("bare"), "project.git")
    File.cp_r!(seed_template(seed_files(files)), bare)
    bare
  end

  defp seed_files(files) do
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
  end

  # The cache is a directory of this VM's own (`System.pid/0` in its name, as `tmp_dir/1`'s are:
  # suites and partitions side by side share the system temporary directory), removed when the
  # suite ends (`drop_seed_cache/0`, from `test_helper.exs`). A template is built beside its
  # final name and renamed into it, so a copy never sees half of one; `:global.trans/2` makes two
  # async tests that want the same one build it once.
  defp seed_template(files) do
    key = :sha256 |> :crypto.hash(:erlang.term_to_binary(files)) |> Base.encode16(case: :lower)
    template = Path.join(seed_cache(), key)

    :global.trans({{__MODULE__, key}, self()}, fn ->
      unless File.dir?(template) do
        building = template <> ".building"
        File.rm_rf!(building)
        build_seed(files, building)
        File.rename!(building, template)
      end
    end)

    template
  end

  defp seed_cache do
    dir = Path.join(System.tmp_dir!(), "#{System.pid()}-forge-seed-cache")
    File.mkdir_p!(dir)
    dir
  end

  @doc "Removes what `seeded_repo/1` kept for the run. Called once, when the suite is over."
  def drop_seed_cache, do: File.rm_rf!(seed_cache())

  defp build_seed(files, bare) do
    work = Path.join(Path.dirname(bare), Path.basename(bare) <> "-work")
    File.mkdir_p!(work)
    :ok = Git.init_bare(bare)

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
    File.rm_rf!(work)
  end

  @doc """
  Commits `content` and a newline at `path` on `branch` of the project's repository, with `message`
  (else the content), and returns the sha the branch now points at. Made by git's plumbing in the
  bare repository: no token, no clone, no push through the platform's endpoint and no hooks.

  **It replaced `commit_over_http/5`, which did what a job does** — a clone, a commit and a push over
  the endpoint with a write token scoped to the branch. That is 6 git processes against 39 (counted
  by git's trace2 `start` events), the push running both hooks (ticket 68), for tests whose subject is what happens to a branch with a
  commit on it: a merge, the queue, a page. A test of the token, of the branch discipline, of a hook
  or of the endpoint pushes the way a job does (`ForgeWeb.GitHttpTest`'s own helpers), because that
  is its subject.
  """
  def commit_file_on_branch(project, branch, path, content, message \\ nil) do
    Forge.ProjectFixtures.commit_files!(
      Forge.Projects.repo_path(project),
      branch,
      %{path => content <> "\n"},
      message: message || default_message(content),
      author: "job"
    )
  end

  # The content as the message, as the push over HTTP made it, unless git would take it for
  # something else: a message that is not text (a PNG's bytes, a file in latin-1) is a warning and a
  # spoilt sha for `commit-tree`, which `git commit` merely warned about.
  defp default_message(content), do: if(String.printable?(content), do: content, else: "change")

  @doc """
  Commits `files` (`%{path => content}`) to the project's default branch and returns the new head.
  Stands in for the platform's own merge, the only writer the repository lets onto that branch,
  which is why the push says it is one.
  """
  def commit_to_default(project, files),
    do: commit_to(Forge.Projects.repo_path(project), project.default_branch, files, "fix")

  @doc """
  Commits `files` (`%{path => content}`) onto `branch` of the repository at `repo` and returns the
  new head. A path mapped to `nil` is removed.

  **By git's plumbing in the bare repository, not a clone and a push past the hooks** (ticket 68):
  it is what the platform's own merge does to the default branch, which the hooks otherwise keep
  everyone off, and what no test of it needs the hooks for. That is 6 git processes against 18
  (counted by trace2). A test of what the hooks do pushes for itself.
  """
  def commit_to(repo, branch, files, message \\ "change") do
    Forge.ProjectFixtures.commit_files!(repo, branch, files, message: message, author: "t")
  end

  @doc """
  `commit_to/4` the way a job pushes: a clone, a commit and a push as the platform pushes — past the
  hooks that keep everyone else off a protected branch, but through them: `pre-receive` judges it and
  `post-receive` mirrors it. For a test of what a hook does with a push, which `commit_to/4`'s
  plumbing does not run. Raises (`MatchError`) when a hook refuses.
  """
  def push_commit_to(repo, branch, files, message \\ "change") do
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
      Forge.Git.spawn_cmd("git", ["push", "-q", "origin", "HEAD:refs/heads/" <> branch],
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
               budget: { turns: 10, tokens: 200k }
             reviewing:
               prompt: agents/integrate.md
               inputs: [changeset]
               produces: [review.md]
               budget: { turns: 10, tokens: 200k }
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
               budget: { turns: 10, tokens: 200k }
           """, "  - { from: integrating, to: #{to} }\n", ""}
      end

    """
    version: 1
    initial: implementing
    states:
      implementing:
        prompt: agents/implement.md
        produces: [implementation.md, changeset, commit-message]
        outcomes: [done, engine_merges]
        budget: { turns: 10, tokens: 200k }
      review_ready: {}
      merged:
        on_enter: merge
    #{conflict}#{integrating}transitions:
      - { from: implementing, to: review_ready }
      - { from: review_ready, to: merged, approve: [changeset] }
    #{back}#{engine}limits:
      ticket_tokens: 5M
    """
  end

  @doc """
  A workflow with an update step between implementing and review: implementing → refresh (the step)
  → review_ready, a conflict going to `resolving`, which may give up to a person who sends it round
  again through the step (`docs/design/workflow-grammar-v1.md` § Bringing the branch up to date).
  `after: "merged"` leads the step into the merge, `conflict: false` names no conflict state and
  `max: n` bounds the step's edge and `queue: true` queues it into the merge. Its prompts are `agents/integrate.md` and `agents/implement.md`.
  """
  def update_workflow(opts \\ []) do
    # `job: true`: the step's edge leads into a job that reads the changeset, so what the job is
    # made on (its pin, its base) is visible in the job's own inputs.
    {after_step, building, building_edge} =
      if opts[:job] do
        {"building",
         """
           building:
             prompt: agents/implement.md
             inputs: [changeset]
             produces: [notes.md]
             budget: { turns: 10, tokens: 200k }
         """, "  - { from: building, to: review_ready }\n"}
      else
        {Keyword.get(opts, :after, "review_ready"), "", ""}
      end

    max = if opts[:max], do: ", max: #{opts[:max]}", else: ""
    queue = if opts[:queue], do: ", queue: true", else: ""

    {conflict, states, edges} =
      if Keyword.get(opts, :conflict, true) do
        {"    on_conflict: resolving\n",
         """
           resolving:
             prompt: agents/integrate.md
             inputs: [changeset]
             produces: [integration.md, changeset]
             outcomes: [done, gave_up]
             budget: { turns: 10, tokens: 200k }
           asking: {}
         """,
         """
           - { from: resolving, to: review_ready }
           - { from: resolving, to: asking, when: gave_up }
           - { from: asking, to: refresh }
         """}
      else
        {"", "", ""}
      end

    """
    version: 1
    initial: implementing
    states:
      implementing:
        prompt: agents/implement.md
        produces: [implementation.md, changeset, commit-message]
        budget: { turns: 10, tokens: 200k }
      refresh:
        on_enter: update
    #{conflict}#{states}#{building}  review_ready: {}
      merged:
        on_enter: merge
    transitions:
      - { from: implementing, to: refresh }
      - { from: refresh, to: #{after_step}#{max}#{queue} }
    #{edges}#{building_edge}  - { from: review_ready, to: merged, approve: [changeset] }
    limits:
      ticket_tokens: 5M
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
  Wraps the repository's `pre-receive`. On the n-th push it moves `ref` (the default branch unless
  `ref: "refs/heads/ticket/3"` says otherwise) to the n-th of `moves`, if there is one, and then
  hands over to the real hook — or, with `refuse: true`, refuses without moving anything. Returns a
  function counting the pushes it saw.

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

    ref = Keyword.get(opts, :ref, "refs/heads/main")
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
      env -u GIT_QUARANTINE_PATH git update-ref #{ref} "$target"
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
    Forge.Git.spawn_cmd(
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
