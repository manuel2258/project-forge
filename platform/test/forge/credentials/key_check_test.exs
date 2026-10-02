defmodule Forge.Credentials.KeyCheckTest do
  @moduledoc """
  `docs/deploy.md` § Secrets file: a node whose `SECRET_KEY_BASE` opens none of the credentials it
  holds refuses to start, and one that opens any of them starts. A changed key is simulated the
  only way that does not need a second node: a secret sealed exactly as the platform seals it, but
  under another key.
  """

  use Forge.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Forge.ForgeFixtures

  alias Forge.Credentials.KeyCheck
  alias Forge.Provisioning
  alias Plug.Crypto.MessageEncryptor

  setup do
    %{user: Forge.AccountsFixtures.user_fixture()}
  end

  # What `Forge.Provisioning.Vault.seal/2` makes, with a key this node does not have.
  defp sealed_elsewhere(label) do
    other = :crypto.strong_rand_bytes(32)
    MessageEncryptor.encrypt(Jason.encode!(%{"token" => "t"}), label, other, "unused")
  end

  defp unreadable_inference(user) do
    user
    |> credential_fixture()
    |> Ecto.Changeset.change(secret: sealed_elsewhere("forge/credentials/v1"))
    |> Repo.update!()
  end

  defp provider_credential(user, secret) do
    {:ok, credential} =
      Provisioning.create_credential(user, %{
        name: "acct-#{System.unique_integer([:positive])}",
        provider: "fake",
        secret: %{"token" => "abc"}
      })

    if secret,
      do: credential |> Ecto.Changeset.change(secret: secret) |> Repo.update!(),
      else: credential
  end

  test "a node with no credentials has nothing to check" do
    assert KeyCheck.check(false) == :ok
  end

  test "a key that opens the credentials starts", %{user: user} do
    credential_fixture(user)
    provider_credential(user, nil)

    assert KeyCheck.check(false) == :ok
  end

  test "a key that opens none of them refuses, and says what to do", %{user: user} do
    unreadable_inference(user)
    provider_credential(user, sealed_elsewhere("forge/provisioning/v1"))

    assert {:error, message} = KeyCheck.check(false)
    assert message =~ "SECRET_KEY_BASE opens none of the 2 stored credentials"
    assert message =~ "FORGE_ACCEPT_NEW_SECRET_KEY_BASE=1"
  end

  # One row that does not open is a row to re-enter; only none opening is a changed key.
  test "one that opens is enough", %{user: user} do
    unreadable_inference(user)
    provider_credential(user, nil)

    assert KeyCheck.check(false) == :ok
  end

  # The common case: one user's credential damaged, another's fine, in the same table. Newest
  # first, the damaged one is the first the check opens.
  test "one that opens is enough within one table", %{user: user} do
    credential_fixture(user)
    unreadable = unreadable_inference(user)

    Repo.update_all(
      from(c in Forge.Credentials.Credential, where: c.id == ^unreadable.id),
      set: [inserted_at: DateTime.add(DateTime.utc_now(:second), 3600)]
    )

    assert KeyCheck.check(false) == :ok
  end

  # A revoked credential's secret is overwritten with nothing: there is nothing sealed to open,
  # and it says nothing about the key.
  test "a revoked credential is not in the sample", %{user: user} do
    credential = credential_fixture(user)
    {:ok, _revoked} = Forge.Credentials.revoke(user, credential.id)

    assert KeyCheck.check(false) == :ok
  end

  # Each table is opened its own way: a provider credential's ciphertext does not open as an
  # inference credential, so a check that read both alike would refuse a good key.
  test "an inference credential alone is opened as one", %{user: user} do
    credential_fixture(user)
    assert KeyCheck.check(false) == :ok
  end

  test "a provider credential alone is opened as one", %{user: user} do
    provider_credential(user, nil)
    assert KeyCheck.check(false) == :ok
  end

  # A credential is added again rather than changed, so after a rotation the one that opens is the
  # newest; behind twenty dead ones a sample in physical order left it out and kept refusing.
  test "the newest credential is always in the sample", %{user: user} do
    dead = for _ <- 1..21, do: unreadable_inference(user)
    an_hour_ago = DateTime.add(DateTime.utc_now(:second), -3600)

    Repo.update_all(
      from(c in Forge.Credentials.Credential, where: c.id in ^Enum.map(dead, & &1.id)),
      set: [inserted_at: an_hour_ago]
    )

    credential_fixture(user)

    assert KeyCheck.check(false) == :ok
  end

  test "a rotation made on purpose starts anyway", %{user: user} do
    unreadable_inference(user)
    assert KeyCheck.check(true) == :ok
  end

  test "the rotation is accepted from the node's config", %{user: user} do
    unreadable_inference(user)
    configured = Application.get_env(:forge, KeyCheck, [])
    on_exit(fn -> Application.put_env(:forge, KeyCheck, configured) end)

    Application.put_env(:forge, KeyCheck, accept: true)
    assert KeyCheck.check() == :ok

    Application.put_env(:forge, KeyCheck, accept: false)
    assert {:error, _message} = KeyCheck.check()
  end

  test "as the application starts, a good key leaves nothing running and a bad one stops it",
       %{user: user} do
    assert KeyCheck.start_link() == :ignore

    unreadable_inference(user)
    assert {:error, {:secret_key_base, message}} = KeyCheck.start_link()
    assert message =~ "SECRET_KEY_BASE"
  end
end
