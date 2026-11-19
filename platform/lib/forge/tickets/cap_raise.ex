defmodule Forge.Tickets.CapRaise do
  @moduledoc """
  A person raising one ticket's allowance, on the Extend or the Run again form
  (`docs/design/workflow-grammar-v1.md` § Extending a job): who, the cap before and after as the
  numbers they were, and the extension or restart it came with. Insert-only.

  The ticket's `cap_raise` is the sum of what these added, and its allowance is the workflow's
  `limits.ticket_tokens` plus it (`Forge.Spend.ticket_cap/2`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Forge.Actor

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "ticket_cap_raises" do
    field :from_tokens, :integer
    field :to_tokens, :integer

    belongs_to :ticket, Forge.Tickets.Ticket
    belongs_to :user, Forge.Accounts.User
    belongs_to :token, Forge.Git.Token
    belongs_to :extension, Forge.Jobs.Extension
    belongs_to :restart, Forge.Tickets.Restart

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(raise, attrs) do
    raise
    |> cast(attrs, [
      :ticket_id,
      :user_id,
      :token_id,
      :from_tokens,
      :to_tokens,
      :extension_id,
      :restart_id
    ])
    |> validate_required([:ticket_id, :from_tokens, :to_tokens])
    |> Actor.validate_one_author()
    |> validate_one_origin()
    |> validate_raises()
    |> foreign_key_constraint(:ticket_id)
    |> check_constraint(:user_id, name: :ticket_cap_raises_one_author)
    |> check_constraint(:to_tokens, name: :ticket_cap_raises_raises)
    |> check_constraint(:extension_id, name: :ticket_cap_raises_one_origin)
  end

  defp validate_one_origin(changeset) do
    if is_nil(get_field(changeset, :extension_id)) == is_nil(get_field(changeset, :restart_id)),
      do:
        add_error(changeset, :extension_id, "exactly one of an extension and a restart made this"),
      else: changeset
  end

  # Equivalent, for what the engine builds, to the database's own check (`ticket_cap_raises_raises`,
  # and `check_constraint/3` above): a raise is `from + a positive amount`, so no record it makes
  # fails either. The changeset says it first, as a field error and not a constraint one, for a
  # caller that builds one by hand; no test builds one that way.
  defp validate_raises(changeset) do
    from = get_field(changeset, :from_tokens)
    to = get_field(changeset, :to_tokens)

    if is_integer(from) and is_integer(to) and to <= from,
      do: add_error(changeset, :to_tokens, "must be more than the cap it raises"),
      else: changeset
  end
end
