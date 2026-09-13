defmodule Forge.Repo.Migrations.JobsOrderedBelowTheSecond do
  use Ecto.Migration

  # Jobs are read back in the order they were created — the ticket timeline is ordered by time
  # rather than by topology, and it chunks consecutive jobs into one visit to a state. At second
  # precision two jobs of one ticket can share a timestamp, and the order then comes back however
  # the planner felt, so a revisit could be drawn before the visit it followed. Sub-second
  # timestamps make the order the record rather than a coincidence.
  def up do
    alter table(:jobs) do
      modify :inserted_at, :utc_datetime_usec
      modify :updated_at, :utc_datetime_usec
    end
  end

  def down do
    alter table(:jobs) do
      modify :inserted_at, :utc_datetime
      modify :updated_at, :utc_datetime
    end
  end
end
