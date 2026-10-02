defmodule Forge.Credentials.KeyCheck do
  @moduledoc """
  Refuses to start a node whose `SECRET_KEY_BASE` opens none of the credentials it holds
  (`docs/deploy.md` § Secrets file).

  Inference credentials and provider credentials are both sealed under a key derived from it
  (`Forge.Provisioning.Vault`), and a changed key is otherwise found piecemeal, long after the
  restart that caused it: no job starts (*credential … cannot be decrypted*), no Hetzner machine
  can be made or destroyed, every session cookie is void, and the store tokens already in workers'
  hands stop working mid-job. So before the endpoint serves anything, a sample of each table's
  sealed secrets is opened — **with each schema's own way of opening them**, the model the platform
  reads them with when it needs them, so this cannot pass on a key the real read would refuse —
  and if there are any and not one opens, the node stops and says why.

  **One that opens is enough.** It proves the key; a single row that does not is a row to enter
  again, which the settings and templates pages already say. Only *none* is a changed key.

  `FORGE_ACCEPT_NEW_SECRET_KEY_BASE=1` (`config :forge, #{inspect(__MODULE__)}, accept: true`)
  starts the node anyway, for a rotation made on purpose. The check then passes on its own once one
  credential has been added again under the new key.
  """

  import Ecto.Query, only: [from: 2]

  alias Forge.Credentials.Credential
  alias Forge.Provisioning
  alias Forge.Repo

  require Logger

  # Enough that one damaged row cannot be the whole sample, few enough to cost nothing at boot.
  @sample 20

  @doc false
  def child_spec(_opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :temporary}

  @doc """
  Runs the check as the application starts: `:ignore` when the key is good, which leaves nothing
  running, and an error that stops the application — and so the release — when it is not.
  """
  @spec start_link() :: :ignore | {:error, {:secret_key_base, String.t()}}
  def start_link do
    case check() do
      :ok ->
        :ignore

      {:error, message} ->
        Logger.error(message)
        {:error, {:secret_key_base, message}}
    end
  end

  @doc "Whether this node's key opens the credentials it holds; `accepted` overrides a refusal."
  @spec check(boolean()) :: :ok | {:error, String.t()}
  def check(accepted \\ accepted?()) do
    sealed = sealed()

    cond do
      sealed == [] ->
        :ok

      Enum.any?(sealed, &opens?/1) ->
        :ok

      accepted ->
        Logger.warning(
          "SECRET_KEY_BASE opens none of the stored credentials; starting anyway because " <>
            "FORGE_ACCEPT_NEW_SECRET_KEY_BASE is set. Add each credential again."
        )

        :ok

      true ->
        {:error,
         "SECRET_KEY_BASE opens none of the #{length(sealed)} stored credentials sampled, so it " <>
           "is not the key they were sealed with. Started like this, no job could run, no " <>
           "machine could be made or destroyed, and every session would be void. Restore the " <>
           "previous SECRET_KEY_BASE; or, if it was changed on purpose, start once with " <>
           "FORGE_ACCEPT_NEW_SECRET_KEY_BASE=1 and add the credentials again."}
    end
  end

  defp accepted?, do: Keyword.get(Application.get_env(:forge, __MODULE__, []), :accept, false)

  # The secret column is not loaded by an ordinary query on `credentials` (`load_in_query: false`),
  # so it is selected by name, and each is paired with its table's own way of opening it. **Newest
  # first**, because a credential cannot be changed in place, only added again: after a rotation
  # the row that opens is the newest, and a sample in physical order could leave it out behind
  # twenty dead ones.
  defp sealed do
    inference =
      Repo.all(
        from c in Credential,
          where: not is_nil(c.secret),
          order_by: [desc: c.inserted_at],
          select: c.secret,
          limit: @sample
      )

    # A provider credential's secret is NOT NULL, and deleting one is how it ends: there is no
    # empty one to leave out.
    provider =
      Repo.all(
        from c in Provisioning.Credential,
          order_by: [desc: c.inserted_at],
          select: c.secret,
          limit: @sample
      )

    Enum.map(inference, &{:inference, &1}) ++ Enum.map(provider, &{:provider, &1})
  end

  defp opens?({:inference, sealed}), do: match?({:ok, _secret}, Credential.open(sealed))

  defp opens?({:provider, sealed}),
    do:
      match?(
        {:ok, _secret},
        Provisioning.Credential.secret(%Provisioning.Credential{secret: sealed})
      )
end
