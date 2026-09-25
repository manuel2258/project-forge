defmodule Forge.Storage.Token do
  @moduledoc """
  Short-lived tokens that let a worker read or write one storage key. The operator never uses
  one: they have a session, and the platform serves their blobs itself. See
  `docs/design/storage.md` § Serving.

  A token is scoped to one key and one verb. A token that said "you may read the store" would
  read every ticket's transcripts, and a worker holding a `put` token for its own job's
  transcript must not be able to replace the seed. It carries no identity: who the worker is
  was settled by the channel before this was minted.
  """

  @salt "forge storage"
  @default_max_age 900

  @type op :: :get | :put

  @doc """
  A token for `op` on `key`, good for the store's configured lifetime.

  **`:outlasting_ms` extends it by that long**, for a token that is minted at the start of
  something and used at its end: a job's transcript is uploaded when the job stops, which may be
  its preparation and then its whole wall clock after assignment, and a token that had lapsed by
  then loses the transcript to `expired_token` (`docs/design/storage.md` § Serving). The
  lifetime is signed into the token, so it is decided once, here, by the caller who knows how
  long the holder may need it; `verify/3` reads it back rather than applying one number to
  every token.
  """
  @spec sign(op(), Forge.Storage.key(), keyword()) :: String.t()
  def sign(op, key, opts \\ []) when op in [:get, :put] do
    max_age = max_age() + div(Keyword.get(opts, :outlasting_ms, 0), 1000)
    Phoenix.Token.sign(ForgeWeb.Endpoint, @salt, %{op: op, key: key}, max_age: max_age)
  end

  @doc """
  The key this token authorises for `op`, if it is still valid. The key travels in the token
  as well as the request path, and the two must agree: a caller cannot present a token for
  one key and ask for another.
  """
  @spec verify(String.t(), op(), Forge.Storage.key()) ::
          :ok | {:error, :invalid | :expired | :wrong_key}
  def verify(token, op, key) when is_binary(token) do
    # No `:max_age` here: the one `sign/3` put in the token governs, and passing one would
    # override it — which is how every token came to die at fifteen minutes whatever it was for.
    case Phoenix.Token.verify(ForgeWeb.Endpoint, @salt, token) do
      {:ok, %{op: ^op, key: ^key}} -> :ok
      {:ok, %{}} -> {:error, :wrong_key}
      {:error, :expired} -> {:error, :expired}
      {:error, _reason} -> {:error, :invalid}
    end
  end

  def verify(_token, _op, _key), do: {:error, :invalid}

  defp max_age, do: Forge.Storage.config(:token_max_age, @default_max_age)
end
