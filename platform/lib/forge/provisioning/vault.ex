defmodule Forge.Provisioning.Vault do
  @moduledoc """
  Encrypts at rest the secrets the platform has to read back: a provider credential's, an inference
  credential's (`Forge.Credentials.Credential`) and a project secret's (`Forge.Secrets.Secret`),
  each table under a label of its own.

  A provider credential has to be *recoverable* — the platform makes an API call with it —
  which is what separates it from every other secret in this repository. A worker token and a
  user's password are hashed, because nothing ever needs them back; a Hetzner token that could
  not be read back would be a Hetzner token that could not create a machine.

  `Plug.Crypto.MessageEncryptor` rather than a dependency: it is XChaCha20-Poly1305
  authenticated encryption, it is already in the tree behind Phoenix, and the alternative was
  adding a library to do what one is already doing. The key is derived from the endpoint's
  `secret_key_base` with a salt of this module's own, so it is not the key that signs cookies
  even though it comes from the same root.

  **Rotating `secret_key_base` makes every stored credential unreadable**, and there is no
  migration path here that would not mean holding both keys. A credential that cannot be
  decrypted is reported as one rather than crashing, so the page says which row is affected and
  the operator re-enters it — which is a minute's work and the honest cost of not building key
  rotation for a single-node platform.
  """

  alias Plug.Crypto.{KeyGenerator, MessageEncryptor}

  @salt "forge provider credential"
  @aad "forge/provisioning/v1"

  @doc """
  Encrypts a map of secret fields. The shape inside is the driver's business, not ours.

  `label` is the associated data, and it is what keeps one table's secrets out of another's: an
  inference credential and a project secret are each sealed under their own, so a provider
  token's ciphertext pasted into either column does not open, and no other pairing does either.
  """
  @spec seal(map(), String.t()) :: String.t()
  def seal(secret, label \\ @aad) when is_map(secret) do
    MessageEncryptor.encrypt(Jason.encode!(secret), label, key(), "unused")
  end

  @doc """
  Reads a sealed secret back.

  `:error` covers every way this fails — a rotated key, a truncated column, a row written by
  another node — because none of them is separately actionable and all of them mean the same
  thing to the caller: this credential cannot be used and the operator has to say it again.
  """
  @spec open(String.t() | nil, String.t()) :: {:ok, map()} | :error
  def open(sealed, label \\ @aad)
  def open(nil, _label), do: :error

  def open(sealed, label) when is_binary(sealed) do
    with {:ok, json} <- MessageEncryptor.decrypt(sealed, label, key(), "unused"),
         {:ok, secret} when is_map(secret) <- Jason.decode(json) do
      {:ok, secret}
    else
      _other -> :error
    end
  end

  defp key do
    KeyGenerator.generate(secret_key_base(), @salt, length: 32)
  end

  defp secret_key_base do
    Application.get_env(:forge, ForgeWeb.Endpoint, [])[:secret_key_base] ||
      raise "no secret_key_base configured; provider credentials cannot be stored without one"
  end
end
