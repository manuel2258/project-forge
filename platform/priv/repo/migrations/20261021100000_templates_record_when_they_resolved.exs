defmodule Forge.Repo.Migrations.TemplatesRecordWhenTheyResolved do
  @moduledoc """
  When a template on the mark last asked the provider what `latest` points at
  (`docs/design/provisioning.md` § Where a machine comes from).

  **What bounds the cost of a job nothing marked is new enough for.** Such a job waits rather
  than sticking its ticket, so it is offered again every scheduling pass, and resolving on each
  one sent a listing request per pass per waiting job — 1800 an hour at the default two seconds,
  against a Hetzner account whose published limit is 3600, and the 429 would come back as the
  template's own failure and disable it.

  Null for every row that exists and for every template naming a snapshot, which never resolves:
  null reads as *never asked*, so the first attempt asks.
  """

  use Ecto.Migration

  def change do
    alter table(:worker_templates) do
      add :resolved_at, :utc_datetime
    end
  end
end
