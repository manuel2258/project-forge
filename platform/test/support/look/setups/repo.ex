defmodule Forge.Look.Setups.Repo do
  @moduledoc """
  A project's repository (`docs/design/ui.md` § The project's repository, `10a`–`10f`): `game`'s
  default branch holds a history by three authors over several weeks, an Elixir module to read, a
  binary image and a 600 KB file too large to draw; two open tickets have branches of their own,
  one in a job step and one in a person's, and one branch is nobody's.

  Users: `member`. Paths: `commits` (`10a`), `files` (`10c`), `file` (`10d`, `10f`), `large`,
  `binary`, `commit` (`10e`, the newest commit on the default branch), `ticket` (a ticket's
  branch). The branch sheet (`10b`) is opened from any of them.

  Commits are written with git's plumbing, each with its own author and date, for the reason
  `Forge.Look.Setups.Decision` gives: a look has no test for `Forge.GitFixtures` to clean up
  under.
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures
  import Forge.ProjectFixtures, only: [commit_files!: 4]

  alias Forge.Look.Setups.Decision
  alias Forge.{Projects, Repo, Tickets}

  @workflow Path.expand("../../../../../core/test/fixtures/workflow_example.yml", __DIR__)
  @external_resource @workflow

  @icon Path.expand("../../../../priv/static/images/icon-192.png", __DIR__)
  @external_resource @icon

  @scores """
  defmodule Game.Scores do
    @moduledoc "The top 100, kept in SQLite."

    import Ecto.Query
    alias Game.{Repo, Score}

    @keep 100

    def top(n \\\\ 10) do
      Repo.all(
        from s in Score,
          order_by: [desc: s.score, asc: s.inserted_at],
          limit: ^n
      )
    end

    def record(name, score) do
      %Score{name: name, score: score}
      |> Repo.insert!()

      trim_to(@keep)
    end

    defp trim_to(keep) do
      # Rows past the keep line, newest last.
      cutoff =
        from s in Score,
          order_by: [desc: s.score, asc: s.inserted_at],
          offset: ^keep,
          select: s.id

      Repo.delete_all(from s in Score, where: s.id in subquery(cutoff))
    end
  end
  """

  # Oldest first: each is `{subject, author, days ago, files}`.
  @history [
    {"First playable build", "you", 34,
     %{
       "mix.exs" => "defmodule Game.MixProject do\n  use Mix.Project\nend\n",
       ".formatter.exs" =>
         "[inputs: [\"{mix,.formatter}.exs\", \"{config,lib,test}/**/*.{ex,exs}\"]]\n",
       "lib/game/application.ex" => "defmodule Game.Application do\n  use Application\nend\n",
       "lib/game/world.ex" => "defmodule Game.World do\n  def new, do: %{}\nend\n"
     }},
    {"Move the asset pipeline into mix tasks", "ana", 22,
     %{
       "config/config.exs" => "import Config\n\nconfig :game, assets: \"priv/static\"\n",
       "assets/atlas.bin" => {:large, 600 * 1024}
     }},
    {"Controller rebinding", "you", 20,
     %{"lib/game/hud.ex" => "defmodule Game.Hud do\n  def bindings, do: %{}\nend\n"}},
    {"Particle pooling", "you", 14,
     %{"lib/game/world.ex" => "defmodule Game.World do\n  def new, do: %{particles: []}\nend\n"}},
    {"Bump the Elixir image to 1.17.3", "jo", 8, %{"mix.lock" => "%{}\n"}},
    {"Crash on an empty player name", "ana", 6,
     %{"test/game/scores_test.exs" => "defmodule Game.ScoresTest do\n  use ExUnit.Case\nend\n"}},
    {"Tilt controls", "you", 4,
     %{"lib/game/hud.ex" => "defmodule Game.Hud do\n  def bindings, do: %{tilt: true}\nend\n"}},
    {"Show the score on the end screen", "you", 2,
     %{
       "lib/game/scores.ex" => @scores,
       "lib/game_web/live/end_live.ex" => "defmodule GameWeb.EndLive do\nend\n",
       "assets/fonts/score.png" => {:file, @icon}
     }}
  ]

  @impl true
  def build do
    member = user_fixture()
    project = Decision.project!("game", File.read!(@workflow), member)
    repo = Projects.repo_path(project)

    head =
      Enum.reduce(@history, nil, fn {subject, author, days, files}, _head ->
        commit!(repo, "main", files, subject, author, days)
      end)

    persist =
      ticket!(project, member, "Persist the high score table", "implementing", [
        {"Keep scores across restarts", "you", 1,
         %{"lib/game/store.ex" => "defmodule S do\nend\n"}}
      ])

    _shape =
      ticket!(project, member, "Shape the leaderboard screen", "review_ready", [])

    commit!(
      repo,
      "experiment/sdf",
      %{"lib/game/sdf.ex" => "defmodule Sdf do\nend\n"},
      "SDF text",
      "jo",
      7,
      from: "main"
    )

    base = "/projects/#{project.name}/repo"

    %{
      users: %{"member" => member},
      paths: %{
        "commits" => base,
        "files" => base <> "?tab=files",
        "file" => base <> "?tab=files&file=lib/game/scores.ex",
        "large" => base <> "?tab=files&file=assets/atlas.bin",
        "binary" => base <> "?tab=files&file=assets/fonts/score.png",
        "commit" => base <> "/commits/" <> head,
        "ticket" => base <> "?branch=" <> URI.encode_www_form(persist.branch)
      }
    }
  end

  # An open ticket of this project, in `state`, with `commits` on its own branch.
  defp ticket!(project, member, title, state, commits) do
    {:ok, ticket} = Tickets.admit(project, %{title: title}, {:user, member.id})
    ticket = Repo.update!(Ecto.Changeset.change(ticket, state: state))
    repo = Projects.repo_path(project)

    for {subject, author, days, files} <- commits,
        do: commit!(repo, ticket.branch, files, subject, author, days)

    ticket
  end

  # `files` committed onto `branch` over what it holds, as `author`, `days` ago — or, with
  # `from:`, onto a new branch started at that one. A file is its content, `{:file, path}` for
  # another file's bytes, or `{:large, bytes}` for that many bytes of filler. Returns the commit.
  defp commit!(repo, branch, files, subject, author, days, opts \\ []) do
    files = Map.new(files, fn {path, content} -> {path, bytes(content)} end)
    opts = [message: subject, author: author, days_ago: days] ++ opts
    commit_files!(repo, branch, files, opts)
  end

  defp bytes({:file, path}), do: File.read!(path)
  defp bytes({:large, size}), do: String.duplicate("forge atlas ", div(size, 12) + 1)
  defp bytes(text), do: text
end
