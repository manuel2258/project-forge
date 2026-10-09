defmodule ForgeCore.Job.Credential do
  @moduledoc """
  A job's inference credential on its way to the worker that runs the job.

  `docs/design/credentials.md` § Delivery to the machine. The platform seals the secret for one
  worker and one job; the worker opens it when it spawns the harness, and at no point before. So
  the assignment map, the channel message, the frame on the wire and every process that holds
  them carry ciphertext — which is what keeps the secret out of a crash report or a log line that
  prints any of them.

  **One implementation for both ends**, because two implementations of a cipher that have to
  agree are two places for them to disagree. This module is pure: no process, no configuration.

  - **The key is the worker's token.** The platform keeps the SHA-256 of a worker's token and the
    worker holds the token, so both can compute `token_hash/1`; the key is an HMAC of it under a
    label of this module's own.
  - **AES-256-GCM**, with a random nonce per seal.
  - **The job id is the associated data**, so a sealed credential opens only for the job it was
    sealed for and cannot be replayed into another.

  What it buys is logs and crash reports, not a layer against the database: whoever can read
  `workers.token_hash` and a captured assignment can open it.

  **A seal has a purpose**, and the purpose is part of the associated data: a job's credential and
  its project secrets (`docs/design/secrets.md` § Delivery) are sealed under the same key for the
  same job, and without it each would open in the other's place. The credential's associated data
  is the job id alone, as it was before secrets existed, so a protocol 4 worker still opens it;
  the secrets' is the job id behind a prefix of their own.
  """

  @label "forge job credential v1"
  @cipher :aes_256_gcm
  @nonce_bytes 12
  @tag_bytes 16

  @doc """
  The digest of a worker's token, in the form the platform stores it: SHA-256 of the raw bytes,
  lower-case hex. The token a worker is given is those bytes, URL-safe base64 without padding.
  """
  @spec token_hash(String.t()) :: {:ok, String.t()} | :error
  def token_hash(token) when is_binary(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, raw} -> {:ok, Base.encode16(:crypto.hash(:sha256, raw), case: :lower)}
      :error -> :error
    end
  end

  def token_hash(_token), do: :error

  @typedoc "What a seal is for: a job's inference credential, or its project secrets."
  @type purpose :: :credential | :secrets

  @doc """
  Seals `secret` for the worker whose token hashes to `token_hash`, for `job_id` only, and for
  `purpose` only — the credential when none is named.
  """
  @spec seal(String.t(), String.t(), String.t(), purpose()) :: String.t()
  def seal(secret, token_hash, job_id, purpose \\ :credential)
      when is_binary(secret) and is_binary(token_hash) and is_binary(job_id) do
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        @cipher,
        key(token_hash),
        nonce,
        secret,
        aad(purpose, job_id),
        true
      )

    Base.url_encode64(nonce <> tag <> ciphertext, padding: false)
  end

  @doc """
  Opens what `seal/3` made, or `:error` — for another worker's key, another job's id, a byte
  changed, or anything that is not a sealed credential at all. None of those is separately
  actionable, and all of them mean the harness runs without a credential and says so.
  """
  @spec open(String.t() | nil, String.t() | nil, String.t() | nil, purpose()) ::
          {:ok, String.t()} | :error
  def open(sealed, token_hash, job_id, purpose \\ :credential)

  def open(sealed, token_hash, job_id, purpose)
      when is_binary(sealed) and is_binary(token_hash) and is_binary(job_id) do
    with {:ok,
          <<nonce::binary-size(@nonce_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>>} <-
           Base.url_decode64(sealed, padding: false),
         secret when is_binary(secret) <-
           :crypto.crypto_one_time_aead(
             @cipher,
             key(token_hash),
             nonce,
             ciphertext,
             aad(purpose, job_id),
             tag,
             false
           ) do
      {:ok, secret}
    else
      _other -> :error
    end
  end

  def open(_sealed, _token_hash, _job_id, _purpose), do: :error

  defp key(token_hash), do: :crypto.mac(:hmac, :sha256, token_hash, @label)

  # The credential's is the job id alone, which every worker since credentials has opened; any
  # other purpose's carries its name, so no two purposes share associated data for one job.
  defp aad(:credential, job_id), do: job_id
  defp aad(:secrets, job_id), do: "secrets:" <> job_id
end
