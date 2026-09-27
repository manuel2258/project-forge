defmodule Forge.Storage.Key do
  @moduledoc """
  Storage keys: `<prefix>/<rest>`, built here and opaque everywhere else. Nothing parses a
  key to recover a job id; the database already knows. See `docs/design/storage.md`.
  """

  @max_bytes 512
  @segment ~r/^[a-z0-9][a-z0-9._-]*$/

  @doc "A per-job blob: transcripts and anything else tied to one run."
  @spec job(String.t(), String.t()) :: String.t()
  def job(job_id, name), do: "job/#{job_id}/#{name}"

  @doc """
  A short random suffix for a key minted per assignment: a resumed run's transcript, a command's
  log, a run's groups of files each get their own, and the store refuses to overwrite a key.
  Lower case, so it reads as one in a listing.
  """
  @spec nonce() :: String.t()
  def nonce,
    do: :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false) |> String.downcase()

  @doc """
  Whether `key` is one of `job_id`'s own — what a worker reports for a job is recorded only if so.
  Validated first, as the store validates it, so `job/<id>/../<other>` is not under `job/<id>/`
  as a string and somewhere else as a key.
  """
  @spec job?(term(), String.t()) :: boolean()
  def job?(key, job_id),
    do: match?({:ok, _key}, validate(key)) and String.starts_with?(key, job(job_id, ""))

  @doc """
  A prefix under a job's own keys, ending in `/`, for a token that may `put` beneath it: a run's
  groups of files (`docs/design/storage.md` § Keys).
  """
  @spec job_prefix(String.t(), String.t()) :: String.t()
  def job_prefix(job_id, name), do: "job/#{job_id}/#{name}/"

  @doc "A worker seed. `seed_id` identifies the contents, not the time it was made."
  @spec seed(String.t(), String.t()) :: String.t()
  def seed(project, seed_id), do: "seed/#{project}/#{seed_id}"

  @doc "A content-addressed blob not tied to one job. `hash` is `sha256:<hex>`."
  @spec artifact(String.t()) :: String.t()
  def artifact("sha256:" <> hex), do: "artifact/#{hex}"

  @doc """
  Checks a key before it reaches an implementation, so no implementation has to. Lowercase
  segments, no traversal, no leading or trailing slash, at most #{@max_bytes} bytes.
  """
  @spec validate(term()) :: {:ok, String.t()} | {:error, :invalid_key}
  def validate(key) when is_binary(key) do
    segments = String.split(key, "/")

    if byte_size(key) <= @max_bytes and length(segments) >= 2 and
         Enum.all?(segments, &Regex.match?(@segment, &1)) do
      {:ok, key}
    else
      {:error, :invalid_key}
    end
  end

  def validate(_key), do: {:error, :invalid_key}
end
