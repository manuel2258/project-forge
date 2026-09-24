defmodule Forge.Accounts.Identity do
  @moduledoc """
  An account at an external issuer, and the user it is.

  The key is `(issuer, subject)` and never the address — `docs/design/identity.md`
  § Identity is `(issuer, subject)`, never email. `email` here is what the issuer claimed at the
  last login, kept so the accounts page can show where a user came from; nothing resolves by it.

  A user has zero or more of these and at most one password.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "identities" do
    field :issuer, :string
    field :subject, :string
    field :email, :string
    field :last_login_at, :utc_datetime

    belongs_to :user, Forge.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc "The pair, the address claimed with it, and when it last logged in."
  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:user_id, :issuer, :subject, :email, :last_login_at])
    # **Equivalent mutants, both of them.** Removing `validate_required/2` changes no observable
    # behaviour: all three columns are `null: false` in the migration and every caller supplies
    # all three, so the only difference is a `Postgrex.Error` where a changeset error would have
    # been. Narrowing `unique_constraint/2` to `[:subject]` changes only which constraint name is
    # inferred, and that matters solely on the concurrent-insert path both callers already guard
    # with a `get_by`.
    #
    # They stay because they say what the row means and give the changeset the right errors when
    # something does race. Do not write tests for them: a test that passes against the broken
    # code claims cover it does not give.
    |> validate_required([:user_id, :issuer, :subject])
    |> unique_constraint([:issuer, :subject])
    |> foreign_key_constraint(:user_id)
  end
end
