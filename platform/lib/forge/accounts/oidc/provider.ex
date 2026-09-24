defmodule Forge.Accounts.Oidc.Provider do
  @moduledoc """
  One configured issuer.

  `id` is the URL segment and the stable handle; `name` is what the login page calls it. Renaming
  a provider is a display change — `issuer` is half of every identity's key, so changing *that*
  makes every account behind it a new one, which is a thing to do on purpose or not at all.

  `id_token_alg` is the algorithm the issuer signs its ID tokens with. `assent` compares the
  token's `alg` header against one expected value and refuses anything else, so this being a
  constant meant an issuer on `ES256` could not be used at all — and said so only as the same
  "could not be completed" an unreachable issuer gets. Per provider, because the algorithm is
  the issuer's choice and a node may have two.
  """

  # A configured secret should not be printable by accident. `Forge.Accounts.Oidc.describe_error/1`
  # is what keeps it out of the one place it was actually reachable — the login failure log — and
  # this is the backstop for every other `inspect/1`: a crash report naming this struct in a
  # process state, a `dbg`, an exception in a LiveView that holds one.
  @derive {Inspect, except: [:client_secret]}

  @enforce_keys [:id, :name, :issuer, :client_id, :client_secret]
  defstruct [
    :id,
    :name,
    :issuer,
    :client_id,
    :client_secret,
    scope: "email profile",
    id_token_alg: "RS256"
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          issuer: String.t(),
          client_id: String.t(),
          client_secret: String.t(),
          scope: String.t(),
          id_token_alg: String.t()
        }
end
