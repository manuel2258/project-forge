defmodule Forge.Repo.Migrations.JobsCarrySessions do
  @moduledoc """
  The harness session a resume needs, carried between machines
  (`docs/design/claude-code-events.md` § Resume).

  - `jobs.session_blob` is the latest session file the worker uploaded for the job — its store key
    and the Claude Code version that wrote it — so a resume on another machine can put it back.
  - `jobs.resume_from_id` is the previous attempt of the job's state whose session a new attempt
    forks, set when a transition sends the ticket back into a state whose last attempt finished
    with an outcome it declared. Cleared when a resume is refused, so it is tried once.
  """

  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :session_blob, :map
      add :resume_from_id, references(:jobs, type: :binary_id, on_delete: :nilify_all)
    end
  end
end
