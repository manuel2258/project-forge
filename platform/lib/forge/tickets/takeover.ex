defmodule Forge.Tickets.Takeover do
  @moduledoc """
  A ticket taken over to be worked on outside forge, and handed back (`docs/design/outside-work.md`).
  One row is both halves: the take-over's columns are written when it is made, the hand-back's are
  null while it is open and written once, when the ticket is handed back. A ticket has at most one
  open (`ticket_takeovers_one_open`), and `tickets.takeover_id` names it while it is.

  Who took it over and who handed it back are each a person or a token, as an approval's author is,
  and `via` says through which door: `page`, `api` or `mcp`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @vias ~w(page api mcp)

  # The longest hand-back note, in codepoints. Refused and never cut (`Forge.Operator`).
  @note_limit 2_000

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "ticket_takeovers" do
    field :via, :string
    field :state, :string
    field :head, :string
    field :taken_at, :utc_datetime

    field :back_via, :string
    field :to_state, :string
    field :note, :string
    field :back_head, :string
    field :commits, :map
    field :handed_back_at, :utc_datetime

    belongs_to :ticket, Forge.Tickets.Ticket
    belongs_to :user, Forge.Accounts.User
    belongs_to :token, Forge.Git.Token
    belongs_to :back_user, Forge.Accounts.User
    belongs_to :back_token, Forge.Git.Token
    belongs_to :changeset_version, Forge.Artifacts.Version

    timestamps(type: :utc_datetime)
  end

  @doc "The doors a take-over or hand-back may come through."
  @spec vias() :: [String.t()]
  def vias, do: @vias

  @doc "The longest hand-back note, in codepoints."
  @spec note_limit() :: pos_integer()
  def note_limit, do: @note_limit

  @doc "Changeset for a take-over being made: who, through which door, where the ticket was."
  def take_changeset(takeover, attrs) do
    takeover
    |> cast(attrs, [:ticket_id, :user_id, :token_id, :via, :state, :head, :taken_at])
    |> validate_required([:ticket_id, :via, :state, :taken_at])
    |> validate_inclusion(:via, @vias)
    |> validate_at_most_one(:user_id, :token_id)
    |> foreign_key_constraint(:ticket_id)
    |> unique_constraint(:ticket_id, name: :ticket_takeovers_one_open)
  end

  @doc "Changeset for the hand-back half, written once."
  def back_changeset(takeover, attrs) do
    takeover
    |> cast(attrs, [
      :back_user_id,
      :back_token_id,
      :back_via,
      :to_state,
      :note,
      :back_head,
      :commits,
      :changeset_version_id,
      :handed_back_at
    ])
    |> validate_required([:back_via, :to_state, :handed_back_at])
    |> validate_inclusion(:back_via, @vias)
    |> validate_length(:note, max: @note_limit)
    |> validate_at_most_one(:back_user_id, :back_token_id)
    |> check_constraint(:note, name: :ticket_takeovers_note_limit)
  end

  defp validate_at_most_one(changeset, a, b) do
    if get_field(changeset, a) != nil and get_field(changeset, b) != nil,
      do: add_error(changeset, a, "a person and a token cannot both have done this"),
      else: changeset
  end

  @doc "Whether the take-over is still open."
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{handed_back_at: nil}), do: true
  def open?(%__MODULE__{}), do: false

  @doc """
  Who took it over, as an actor (`Forge.Actor`): the token's name is read from the row when it
  was preloaded, and `nil` for a person or token that has since been deleted.
  """
  @spec taker(t()) :: Forge.Actor.t() | nil
  def taker(%__MODULE__{user_id: id}) when is_binary(id), do: {:user, id}

  def taker(%__MODULE__{token_id: id, token: %Forge.Git.Token{name: name}}) when is_binary(id),
    do: {:api, id, name}

  def taker(%__MODULE__{token_id: id}) when is_binary(id), do: {:api, id, "token"}
  def taker(%__MODULE__{}), do: nil

  @doc "Who handed it back, as `taker/1` reads who took it over."
  @spec returner(t()) :: Forge.Actor.t() | nil
  def returner(%__MODULE__{back_user_id: id}) when is_binary(id), do: {:user, id}

  def returner(%__MODULE__{back_token_id: id, back_token: %Forge.Git.Token{name: name}})
      when is_binary(id),
      do: {:api, id, name}

  def returner(%__MODULE__{back_token_id: id}) when is_binary(id), do: {:api, id, "token"}
  def returner(%__MODULE__{}), do: nil
end
