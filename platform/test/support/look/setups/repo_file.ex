defmodule Forge.Look.Setups.RepoFile do
  @moduledoc """
  A project whose repository holds files to open on the repository page: an Elixir module, a
  Markdown note, a shell script known only by its shebang, and a file in no language with markup
  in it — highlighted, highlighted, highlighted and plain (`ForgeWeb.Highlight`). Users: `member`
  (a project admin). Paths: `files` (the page's file tree).
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures

  @files %{
    "lib/game/scores.ex" => """
    defmodule Game.Scores do
      @moduledoc "The high score table, kept across restarts."

      # The ten best, highest first; ties go to whoever set theirs first.
      @limit 10

      def top(scores, limit \\\\ @limit) when is_list(scores) do
        scores
        |> Enum.sort_by(&{-&1.points, &1.set_at})
        |> Enum.take(limit)
      end

      def put(%{name: name} = score, table), do: Map.put(table, name, %{score | points: 0})
    end
    """,
    "NOTES.md" => """
    # Scores

    The table survives a restart: `Game.Scores.top/1` reads it back.

    - [x] ten rows
    - [ ] a weekly tab
    """,
    "bin/reset" => """
    #!/usr/bin/env bash
    set -euo pipefail
    # Clears the table; asks first.
    read -r -p "Clear all scores? " answer
    [ "$answer" = "y" ] && rm -f "${SCORES_FILE:-scores.db}"
    """,
    "notes.unknown" => """
    Plain text in no language this platform highlights.
    </span><script>alert(1)</script> stays text.
    """
  }

  @impl true
  def build do
    member = user_fixture()
    {:ok, project} = Forge.Projects.register_named("look-repo", "main", member)

    Forge.ProjectFixtures.commit_files!(Forge.Projects.repo_path(project), "main", @files,
      message: "Keep the score table"
    )

    %{
      users: %{"member" => member},
      paths: %{"files" => "/projects/#{project.name}/repo?tab=files"}
    }
  end
end
