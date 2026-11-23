defmodule Forge.GitSpawnTest do
  @moduledoc """
  How many processes the platform starts for git, per operation (ticket 68).

  A time limit in the suite would fail on a busy machine for no reason; the number of processes a
  question takes does not move with the machine. Each limit is what the operation takes after the
  change, with the figure it took at the base commit beside it. `Forge.Git.spawn_cmd/3` and
  `Forge.Git.Reader` announce every spawn as `[:forge, :git, :spawn]`.
  """

  use Forge.DataCase, async: true

  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Git, Projects, Tickets, TicketTypes}

  @event [:forge, :git, :spawn]

  # Runs `fun` and returns `{result, [%{executable:, args:}]}` for the spawns made by this process
  # and the processes it called into.
  defp spawned(fun) do
    test = self()
    id = {__MODULE__, System.unique_integer()}

    :telemetry.attach(
      id,
      @event,
      fn _event, _measurements, meta, _config ->
        callers = Process.get(:"$callers", [])
        if self() == test or test in callers, do: send(test, {:spawned, meta})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain([])}
    after
      :telemetry.detach(id)
    end
  end

  defp drain(acc) do
    receive do
      {:spawned, meta} -> drain([meta | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp project(files \\ %{}) do
    repo = seeded_repo(files)

    {:ok, project} =
      register_owned!(%{name: "spawn-#{System.unique_integer([:positive])}", repo_path: repo})

    project
  end

  defp describe_spawns(spawns),
    do: Enum.map_join(spawns, "\n", &"#{&1.executable} #{Enum.join(&1.args, " ")}")

  # The lower bound of each is not a goal: it says the counter counts. A limit alone passes when
  # nothing is announced at all.
  #
  # Five: the default branch's commit, the one listing of `.forge/`, the reader, the first job's
  # prompt (`Forge.Jobs`' spec) and the ticket's branch.
  test "admitting a ticket starts at most 5 processes (10 at the base commit)" do
    project = project()

    {result, spawns} = spawned(fn -> Tickets.admit(project, %{title: "A ticket"}) end)

    assert {:ok, _ticket} = result
    assert length(spawns) in 3..5, describe_spawns(spawns)
  end

  test "listing the ticket types starts at most 3 processes (8 at the base commit)" do
    project = project()

    {result, spawns} = spawned(fn -> Tickets.types(project) end)

    assert {:ok, %{form: :single}} = result
    assert length(spawns) == 3, describe_spawns(spawns)
  end

  # `config` (the default branch), one `config` read for the mirrors, `symbolic-ref` (HEAD) and
  # the `rev-parse` that finds the default branch there. Seven at the base commit: a `config` read
  # for each of the mirrors' two questions and `Git.ensure_head/2`'s two more (three, on a
  # repository whose branch is not there yet).
  test "registering a repository that has its branch starts at most 4 processes (7 at the base commit)" do
    attrs = %{name: "spawn-#{System.unique_integer([:positive])}", repo_path: seeded_repo()}

    {result, spawns} =
      spawned(fn -> Projects.register(attrs, Forge.AccountsFixtures.user_fixture()) end)

    assert {:ok, _project} = result
    assert length(spawns) in 3..4, describe_spawns(spawns)
  end

  # The same and `init`, then the root commit: `hash-object`, `commit-tree` and `update-ref`. 12
  # at the base commit.
  test "registering a new repository starts at most 8 processes (12 at the base commit)" do
    repo = Path.join(tmp_dir("register"), "fresh.git")
    attrs = %{name: "spawn-#{System.unique_integer([:positive])}", repo_path: repo}

    {result, spawns} =
      spawned(fn -> Projects.register(attrs, Forge.AccountsFixtures.user_fixture()) end)

    assert {:ok, _project} = result
    assert length(spawns) in 6..8, describe_spawns(spawns)
  end

  test "every spawn names its executable by an absolute path" do
    project = project()

    {_result, spawns} =
      spawned(fn ->
        {:ok, _ticket} = Tickets.admit(project, %{title: "A ticket"})
        {:ok, _} = Git.resolve(Projects.repo_path(project), project.default_branch)
        {:ok, _} = Git.run(Projects.repo_path(project), ["log", "-1"], stderr: :separate)
      end)

    assert spawns != []
    assert Enum.all?(spawns, &(Path.type(&1.executable) == :absolute)), describe_spawns(spawns)
  end

  # `stderr: :separate` runs `git` under `sh`, which is a spawn of its own. A bypass of `spawn_cmd/3`
  # there (a bare `System.cmd`) is announced by nobody, so the "all absolute" test above cannot see
  # it: this one asks for the announcement itself.
  test "a run with stderr kept apart announces its sh, by an absolute path" do
    project = project()

    {_result, spawns} =
      spawned(fn ->
        Git.run(Projects.repo_path(project), ["log", "-1"], stderr: :separate)
      end)

    assert [%{executable: sh, args: ["-c" | _]}] = spawns
    assert Path.basename(sh) == "sh"
    assert Path.type(sh) == :absolute
  end

  test "the path of an executable is found once and kept" do
    git = Git.executable("git")

    assert Path.type(git) == :absolute
    assert :persistent_term.get({Git, :executable, "git"}, nil) == git
    assert Git.executable("git") == git
  end

  test "the layout of a repository is one listing, however small its workflow files are" do
    project = project()
    tip = tip(project)

    {result, spawns} = spawned(fn -> TicketTypes.layout(Projects.repo_path(project), tip) end)

    assert {:ok, %{form: :single}} = result
    assert [%{args: ["ls-tree" | _]}] = spawns
  end

  defp tip(project) do
    {:ok, sha} = Git.resolve(Projects.repo_path(project), project.default_branch)
    sha
  end
end
