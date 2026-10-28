defmodule Forge.Actor do
  @moduledoc """
  Who did a thing, as the contexts below `Forge.Operator` take it.

  A person is `{:user, id}` and a project token using the API is `{:api, id, name}`; the engine
  itself is `:system`. The name is carried so an event or a version can say who without a lookup,
  and so a token that has since been revoked reads the same.

  Callers that only ever had a person used to pass a bare user id (or `nil` for nobody), and the
  engine's entry points still accept that shape: `of/1` is the one place it is turned into an actor.
  """

  alias Forge.Accounts.User
  alias Forge.Git.Token

  @type t :: :system | {:user, String.t()} | {:api, String.t(), String.t()}

  @doc "The actor for a user, a token, an id or nobody."
  @spec of(User.t() | Token.t() | String.t() | nil | t()) :: t()
  def of(nil), do: :system
  def of(:system), do: :system
  def of(id) when is_binary(id), do: {:user, id}
  def of({:user, id} = actor) when is_binary(id), do: actor
  def of({:api, id, name} = actor) when is_binary(id) and is_binary(name), do: actor
  def of(%User{id: id}), do: {:user, id}
  def of(%Token{id: id, name: name}), do: {:api, id, name}

  @doc """
  The two columns an answer, an approval or a proposal decision names its author in: exactly one of
  them is set, and the database says so too.
  """
  @spec columns(t() | String.t()) :: %{user_id: String.t() | nil, token_id: String.t() | nil}
  def columns(who) do
    case of(who) do
      {:user, id} -> %{user_id: id, token_id: nil}
      {:api, id, _name} -> %{user_id: nil, token_id: id}
    end
  end

  @doc "The user behind an actor, or nil when it is not a person."
  @spec user_id(t() | String.t() | nil) :: String.t() | nil
  def user_id(who) do
    case of(who) do
      {:user, id} -> id
      _other -> nil
    end
  end

  @doc """
  Refuses a changeset in which a person and a token both wrote a row, or neither did. The database
  says the same (`num_nonnulls(user_id, token_id) = 1`), because a changeset is not the only writer.
  """
  @spec validate_one_author(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_one_author(changeset) do
    import Ecto.Changeset

    if is_nil(get_field(changeset, :user_id)) == is_nil(get_field(changeset, :token_id)),
      do: add_error(changeset, :user_id, "exactly one of a user and a token wrote this"),
      else: changeset
  end
end
