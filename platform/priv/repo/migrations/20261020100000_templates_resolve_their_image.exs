defmodule Forge.Repo.Migrations.TemplatesResolveTheirImage do
  @moduledoc """
  The concrete snapshot a template is currently made from
  (`docs/design/provisioning.md` § Where a machine comes from).

  A template's `image` may now hold the literal `latest` instead of a snapshot id, and then the
  snapshot a machine comes from is whichever one the account's catalogue marks current at the
  moment of creation. `resolved_image` is that concrete id: the same value as `image` for a
  template naming one, and the last resolution's answer for a template naming `latest`.

  **Backfilled, and that is not optional.** Every row that exists names a concrete snapshot —
  `latest` does not exist before this — and `Forge.Workers` reads `resolved_image` to decide what
  to send the driver and what to write on the machine's row. Left null, every template saved
  before this migration would have made a machine from no image at all: refused by Hetzner, and
  on the local driver a machine booted from the host's default instead of the image the operator
  chose. A column the running code reads is a column that has to be true for the rows already
  there.
  """

  use Ecto.Migration

  def change do
    alter table(:worker_templates) do
      add :resolved_image, :string
    end

    execute "UPDATE worker_templates SET resolved_image = image",
            "SELECT 1"
  end
end
