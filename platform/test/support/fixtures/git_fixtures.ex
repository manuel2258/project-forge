defmodule Forge.GitFixtures do
  @moduledoc "A bare repository seeded with a `.forge/` directory, for tests that need git."

  alias Forge.Git

  @workflow Path.expand("../../../../core/test/fixtures/workflow_example.yml", __DIR__)

  @doc "A fresh temporary directory, removed when the test process exits."
  def tmp_dir(label) do
    dir = Path.join(System.tmp_dir!(), "forge-#{label}-#{System.unique_integer([:positive])}")
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

  defp git!(dir, args) do
    {:ok, _} = Git.run(dir, args)
  end
end
