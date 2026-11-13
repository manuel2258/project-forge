defmodule Forge.Repo.Migrations.CodexCredentialsAndHolds do
  @moduledoc """
  What a Codex credential records, and what makes a ChatGPT login held by one run at a time
  (`docs/design/codex.md` § Credentials; `docs/design/credentials.md` § Holding a login).

  - `credentials.account_id` and `plan`: what a ChatGPT login names of itself, in the clear —
    neither is a secret, the account is what a returned login is compared against, and the plan is
    display. `expires_on`: the optional date a Codex access token's owner chose, warned about and
    never enforced. `renewed_at`: when a returned login was last accepted.
  - `job_runs.exclusive`: copied from the credential's kind when the run opens. **A hold is a live
    run**, and the partial unique index is what makes two runs unable to hold one login at once
    whatever the order the scheduler asked in: the second insert loses and is answered as held.
  """

  use Ecto.Migration

  def change do
    alter table(:credentials) do
      add :account_id, :string
      add :plan, :string
      add :expires_on, :date
      add :renewed_at, :utc_datetime
    end

    alter table(:job_runs) do
      add :exclusive, :boolean, null: false, default: false
    end

    create unique_index(:job_runs, [:credential_id],
             where: "finished_at IS NULL AND exclusive",
             name: :job_runs_one_live_exclusive_index
           )
  end
end
