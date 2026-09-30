defmodule ForgeWorker.Job.WorkspaceUserTest.Recording do
  @moduledoc """
  `Slice.Direct`, telling the test each time the tree is handed over and each git command run as
  the job's user — in order, which is the whole of what is being checked. The test's pid rides in
  the owner, so tests can run side by side.
  """

  @behaviour ForgeWorker.Slice

  @impl ForgeWorker.Slice
  defdelegate prepare(opts), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate wrap(executable, args, context), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate cleanup(context), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  def enter(_job_id), do: {:ok, %{test: self()}}

  @impl ForgeWorker.Slice
  def own(%{test: test}, paths) do
    send(test, {:own, paths})
    :ok
  end

  @impl ForgeWorker.Slice
  def run_as(%{test: test}, executable, args) do
    send(test, {:as, git_command(args)})
    {executable, args}
  end

  @impl ForgeWorker.Slice
  def leave(%{test: test}, paths) do
    send(test, {:leave, paths})
    :ok
  end

  # The subcommand, past the credential helper's `-c` pairs `Checkout` puts in front of it.
  defp git_command(["-c", _setting | rest]), do: git_command(rest)
  defp git_command([command | _rest]), do: command
  @impl ForgeWorker.Slice
  defdelegate memory(context), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate ended(context, output), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate probe(), to: ForgeWorker.Slice.Direct
end

defmodule ForgeWorker.Job.WorkspaceUserTest do
  @moduledoc """
  **Every git command in a job's tree runs as the job's user, and the tree is the user's before
  the first one** (`docs/design/worker-tier.md` § The job slice). A repository's hooks and
  configuration are programs the job could have written; git run as root runs them as root.

  Who the user is, is the slice's: here a recording one, which runs git as the test does and
  says in what order things happened. That the real one runs git as a real user — and a hook the
  job planted with it — is `ForgeWorker.JobUserTest`'s, which needs root.
  """

  use ExUnit.Case, async: true

  import ForgeWorker.Fixtures

  alias ForgeWorker.Job.Workspace
  alias ForgeWorker.Job.WorkspaceUserTest.Recording

  setup do
    origin = Path.join(tmp_dir("origin"), "project.git")
    work = tmp_dir("work")
    git!(nil, ["init", "--bare", "--quiet", origin])
    git!(nil, ["clone", "--quiet", origin, work])
    git!(work, ["config", "user.name", "seed"])
    git!(work, ["config", "user.email", "seed@forge"])
    File.write!(Path.join(work, "README.md"), "# Game\n")
    git!(work, ["add", "."])
    git!(work, ["commit", "--quiet", "-m", "seed"])
    git!(work, ["push", "--quiet", "origin", "HEAD:refs/heads/ticket/1"])

    %{origin: origin, root: tmp_dir("root"), user: {Recording, %{test: self()}}}
  end

  defp assignment(origin) do
    %{
      "job_id" => uuid(),
      "spec" => %{"state" => "planning", "attempt" => 1},
      "git" => %{"url" => origin, "branch" => "ticket/1", "base" => nil}
    }
  end

  # What the slice was told, oldest first.
  defp told(acc \\ []) do
    receive do
      {kind, _detail} = message when kind in [:own, :as, :leave] -> told([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp git!(dir, args) do
    args = if dir, do: ["-C", dir | args], else: args
    {out, 0} = System.cmd("git", args, stderr_to_stdout: true)
    out
  end

  # The clone is the worker's own — into a directory nothing has touched — and the only one.
  test "a clone is the worker's, and the tree is the user's the moment it exists", context do
    job = assignment(context.origin)

    assert {:ok, dir} = Workspace.prepare(job, context.root, context.user)

    assert told() == [{:own, [dir]}]
  end

  # A template's `.git` is the last job's: a `post-checkout` in it would run at this `checkout`.
  test "a ticket's template is the user's before any git runs in it", context do
    first = assignment(context.origin)
    {:ok, dir} = Workspace.prepare(first, context.root, context.user)
    :ok = Workspace.promote(first, context.root, dir)
    :ok = Workspace.discard(first, context.root)
    told()

    second = assignment(context.origin)
    assert {:ok, dir} = Workspace.prepare(second, context.root, context.user)

    assert [{:own, [^dir]} | commands] = told()
    assert commands != []
    assert Enum.all?(commands, &match?({:as, _command}, &1))
    assert {:as, "checkout"} in commands
  end

  # A tree an earlier attempt left carries whatever that attempt wrote into its `.git`.
  test "a tree left by an earlier attempt is the user's before any git runs in it", context do
    job = assignment(context.origin)
    {:ok, dir} = Workspace.prepare(job, context.root, context.user)
    told()

    assert {:ok, ^dir} = Workspace.prepare(job, context.root, context.user)

    assert [{:own, [^dir]} | commands] = told()
    assert {:as, "fetch"} in commands
    assert Enum.all?(commands, &match?({:as, _command}, &1))
  end

  test "the commit, the push and the head are the user's", context do
    job = assignment(context.origin)
    {:ok, dir} = Workspace.prepare(job, context.root, context.user)
    File.write!(Path.join(dir, "PLAN.md"), "the plan\n")
    told()

    assert {:ok, _head} = Workspace.commit_and_push(job, dir, "planning: attempt 1", context.user)

    commands = told()
    assert Enum.all?(commands, &match?({:as, _command}, &1))

    for command <- ["reset", "add", "commit", "push", "rev-parse"],
        do: assert({:as, command} in commands, "#{command} was not run as the user")
  end

  test "the head alone is read as the user", context do
    job = assignment(context.origin)
    {:ok, dir} = Workspace.prepare(job, context.root, context.user)
    told()

    assert {:ok, _head} = Workspace.head(dir, context.user)
    assert told() == [{:as, "rev-parse"}]
  end
end
