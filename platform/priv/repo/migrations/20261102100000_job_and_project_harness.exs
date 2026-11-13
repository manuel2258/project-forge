defmodule Forge.Repo.Migrations.JobAndProjectHarness do
  @moduledoc """
  Which harness runs a job, and a model and an effort for each harness
  (`docs/design/codex.md`; `docs/design/workflow-grammar-v1.md` § Harness).

  - `jobs.harness`: set when the job is made — its state's, else its project's, else Claude Code.
    **Backfilled `claude_code` for every workflow job and conversation**, since that is what ran
    them all; null for a command, which has no harness.
  - `projects.harness`: the project's default, `claude_code` — so a project that never names
    another behaves exactly as before.
  - `projects.codex_model` and `projects.codex_effort`: the second harness's dials. The existing
    `model` and `effort` stay, and are Claude Code's.
  """

  use Ecto.Migration

  def up do
    alter table(:jobs) do
      add :harness, :string
    end

    execute "UPDATE jobs SET harness = 'claude_code' WHERE kind <> 'command'"

    alter table(:projects) do
      add :harness, :string, null: false, default: "claude_code"
      add :codex_model, :string
      add :codex_effort, :string
    end
  end

  def down do
    alter table(:projects) do
      remove :codex_effort
      remove :codex_model
      remove :harness
    end

    alter table(:jobs) do
      remove :harness
    end
  end
end
