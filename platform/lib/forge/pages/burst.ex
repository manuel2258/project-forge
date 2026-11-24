defmodule Forge.Pages.Burst do
  @moduledoc """
  The audit of a writer's changes to a page, gathered until it stops: written in the transaction of
  each change, so a crash loses none, and closed into one `page.data_changed` event by
  `Forge.Pages.Bursts`. Holds the first fifty key names and a count, never a value.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "page_bursts" do
    field :writer_key, :string
    field :writer, :map
    field :opened_at, :utc_datetime_usec
    field :last_at, :utc_datetime_usec
    field :changes, :integer, default: 0
    field :keys, {:array, :string}, default: []
    field :key_count, :integer, default: 0

    belongs_to :page, Forge.Pages.Page
  end
end
