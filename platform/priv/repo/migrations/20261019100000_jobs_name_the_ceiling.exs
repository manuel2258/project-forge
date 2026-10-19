defmodule Forge.Repo.Migrations.JobsNameTheCeiling do
  @moduledoc """
  Which ceiling stopped a job that ended `budget_exhausted`: its turn ceiling, its cost ceiling
  or the driver's wall clock (`docs/design/capacity.md` § Four exhaustions, three treatments).

  On the row because the job row is where a person reads how a job ended, and until now the
  distinction lived only inside the free text of a `job.finished` event — "ran out of money" and
  "ran out of turns" want different responses, and neither was legible without opening the log.
  Null for every other job, and for every job recorded before the column existed.
  """

  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :exhausted, :string
    end
  end
end
