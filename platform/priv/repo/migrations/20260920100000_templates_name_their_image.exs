defmodule Forge.Repo.Migrations.TemplatesNameTheirImage do
  @moduledoc """
  A template names the image its machines boot, beside the size they are.

  It was node configuration — one `FORGE_HETZNER_IMAGE` for the whole node — which is wrong for
  the same reason one `machine_size` was: two templates may want different images, and an
  operator rolling a new one wants both to exist while they move over. Opaque above the driver,
  exactly like `size`: the platform stores what `images/1` gave it and never reads it.

  Nullable, and null means *whatever the node is configured with*. That is what keeps every
  template made before this column from stopping being able to create.
  """

  use Ecto.Migration

  def change do
    alter table(:worker_templates) do
      add :image, :string
    end
  end
end
