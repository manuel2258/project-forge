defmodule Forge.Pages.Outside do
  @moduledoc """
  A viewer's toggle for one page: its presence means the page may reach outside addresses for that
  person alone (`docs/design/pages.md` § Serving a page's files). It outlives every version.
  """

  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id
  schema "page_outside" do
    belongs_to :user, Forge.Accounts.User, primary_key: true
    belongs_to :page, Forge.Pages.Page, primary_key: true

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
