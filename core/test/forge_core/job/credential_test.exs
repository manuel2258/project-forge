defmodule ForgeCore.Job.CredentialTest do
  @moduledoc """
  The seal a job's credential travels under (`docs/design/credentials.md` § Delivery to the
  machine). Each refusal below is a way the secret could otherwise reach the wrong process.
  """

  use ExUnit.Case, async: true

  alias ForgeCore.Job.Credential

  @secret "sk-ant-oat01-the-job's-own"

  # A worker's token as the platform mints it: 32 random bytes, URL-safe base64, no padding.
  defp token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp hash(token) do
    {:ok, hash} = Credential.token_hash(token)
    hash
  end

  test "what is sealed for a worker and a job opens there, and nowhere near the plaintext" do
    token = token()
    sealed = Credential.seal(@secret, hash(token), "job-1")

    refute sealed =~ @secret
    assert Credential.open(sealed, hash(token), "job-1") == {:ok, @secret}
  end

  # The digest the platform stores for a token, computed the way the platform computes it: the
  # worker has only the token, and the two must agree or no credential ever opens.
  test "the token's digest is the platform's: SHA-256 of the raw bytes, lower-case hex" do
    raw = :crypto.strong_rand_bytes(32)
    token = Base.url_encode64(raw, padding: false)

    assert Credential.token_hash(token) ==
             {:ok, Base.encode16(:crypto.hash(:sha256, raw), case: :lower)}

    assert Credential.token_hash("not base64 !") == :error
    assert Credential.token_hash(nil) == :error
  end

  test "another worker's key opens nothing" do
    sealed = Credential.seal(@secret, hash(token()), "job-1")
    assert Credential.open(sealed, hash(token()), "job-1") == :error
  end

  # The associated data: a credential handed to one job cannot be carried into another.
  test "another job's id opens nothing" do
    token = token()
    sealed = Credential.seal(@secret, hash(token), "job-1")
    assert Credential.open(sealed, hash(token), "job-2") == :error
  end

  test "a changed byte, a truncation, or something that was never sealed opens nothing" do
    token = token()
    sealed = Credential.seal(@secret, hash(token), "job-1")
    {:ok, raw} = Base.url_decode64(sealed, padding: false)
    <<head::binary-size(20), byte, rest::binary>> = raw
    flipped = Base.url_encode64(head <> <<Bitwise.bxor(byte, 1)>> <> rest, padding: false)

    assert Credential.open(flipped, hash(token), "job-1") == :error
    assert Credential.open(binary_part(sealed, 0, 10), hash(token), "job-1") == :error
    assert Credential.open("not sealed at all", hash(token), "job-1") == :error
    assert Credential.open(nil, hash(token), "job-1") == :error
    assert Credential.open(sealed, nil, "job-1") == :error
  end

  # A random nonce per seal: two seals of one secret for one job do not match, so a captured
  # ciphertext says nothing about whether a later job got the same credential.
  test "sealing twice gives two different ciphertexts" do
    token = token()

    refute Credential.seal(@secret, hash(token), "job-1") ==
             Credential.seal(@secret, hash(token), "job-1")
  end
end
