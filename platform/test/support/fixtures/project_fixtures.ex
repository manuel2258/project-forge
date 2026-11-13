defmodule Forge.ProjectFixtures do
  @moduledoc """
  Fixtures for the projects page and its look setup (`docs/design/ui.md` § The projects page):
  tickets in the states its row draws (a template it runs on is `Forge.MachinesFixtures`'). Beside
  `Forge.ForgeFixtures`, which the redesign's area slices leave as it is.
  """

  import Forge.ForgeFixtures

  alias Forge.Repo

  @doc """
  An open ticket of `project` numbered `number` in `state`, last changed `ago` seconds before now,
  and `:stuck` when asked: a stuck ticket is an item of its project's queue.
  """
  def ticket_in!(project, number, state, opts \\ []) do
    at = DateTime.add(DateTime.utc_now(:second), -Keyword.get(opts, :ago, 0))

    %{project: project, number: number, state: state, title: "Ticket #{number}"}
    |> ticket_fixture()
    |> Ecto.Changeset.change(
      status: Keyword.get(opts, :status, :active),
      updated_at: at
    )
    |> Repo.update!()
  end

  @doc "`count` jobs of `ticket` on a machine now."
  def jobs_running!(ticket, count) do
    for attempt <- 1..count,
        do: job_fixture(%{ticket: ticket, attempt: attempt, status: :running})
  end

  @doc """
  `files` committed onto `branch` of the bare repository `repo` over what it holds: a scratch
  index read from the branch, the files added by name, `write-tree`, `commit-tree`, `update-ref`.
  Returns the new head. Git's plumbing rather than `Forge.GitFixtures`, which cleans up with
  `ExUnit.Callbacks` that a look's setup has no test to run under.

  Options: `message` (else `look: <paths>`); `author`, a name, written as author and committer
  with `<name>@example.invalid` (else `look`); `days_ago` for both dates (else now); `from`, a
  branch to start `branch` at instead of its own head.
  """
  def commit_files!(repo, branch, files, opts \\ []) do
    work = Path.join(System.tmp_dir!(), "look-commit-#{System.unique_integer([:positive])}")
    index = work <> ".index"
    env = [{"GIT_INDEX_FILE", index} | identity(opts)]
    git = fn args -> git!(repo, work, args, env) end

    try do
      for {path, content} <- files do
        File.mkdir_p!(Path.join(work, Path.dirname(path)))
        File.write!(Path.join(work, path), content)
      end

      parent = git.(["rev-parse", "refs/heads/" <> Keyword.get(opts, :from, branch)])
      git.(["read-tree", parent])
      git.(["add", "--" | Map.keys(files)])
      tree = git.(["write-tree"])
      message = Keyword.get(opts, :message, "look: #{Enum.join(Map.keys(files), ", ")}")
      commit = git.(["commit-tree", tree, "-p", parent, "-m", message])
      git.(["update-ref", "refs/heads/#{branch}", commit])
      commit
    after
      File.rm_rf!(work)
      File.rm_rf!(index)
    end
  end

  # Git reads these over `user.name`/`user.email`, and they set the dates `-c` cannot.
  defp identity(opts) do
    author = Keyword.get(opts, :author, "look")
    email = "#{author}@example.invalid"

    dated =
      case Keyword.fetch(opts, :days_ago) do
        {:ok, days} ->
          date = "#{System.os_time(:second) - days * 86_400} +0000"
          [{"GIT_AUTHOR_DATE", date}, {"GIT_COMMITTER_DATE", date}]

        :error ->
          []
      end

    [
      {"GIT_AUTHOR_NAME", author},
      {"GIT_AUTHOR_EMAIL", email},
      {"GIT_COMMITTER_NAME", author},
      {"GIT_COMMITTER_EMAIL", email}
      | dated
    ]
  end

  defp git!(repo, work, args, env) do
    identity = ~w(-c user.name=look -c user.email=look@example.invalid)
    full = identity ++ ["--git-dir=#{repo}", "--work-tree=#{work}"] ++ args
    {out, 0} = System.cmd("git", full, env: env, cd: work, stderr_to_stdout: true)
    String.trim(out)
  end
end
