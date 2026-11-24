defmodule Forge.Pages.Entry do
  @moduledoc """
  One key of a page's store: its JSON value, who last wrote it (exactly one of a person, a job and
  a token), when, and the page-wide counter of that write (`docs/design/pages.md` § The store). A delete removes the row.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "page_entries" do
    field :key, :string
    field :value, Forge.Pages.Value
    field :counter, :integer
    field :size, :integer
    field :written_at, :utc_datetime_usec

    belongs_to :page, Forge.Pages.Page
    belongs_to :user, Forge.Accounts.User
    belongs_to :job, Forge.Jobs.Job
    belongs_to :token, Forge.Git.Token
  end

  @type t :: %__MODULE__{}
end
