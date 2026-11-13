defmodule Forge.Tickets.View do
  @moduledoc """
  When one person last opened one ticket's page: the row *since you last looked* compares
  against (`Forge.Tickets.Views`). Per person and ticket, unique on the pair.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "ticket_views" do
    field :viewed_at, :utc_datetime_usec

    belongs_to :user, Forge.Accounts.User
    belongs_to :ticket, Forge.Tickets.Ticket
  end
end
