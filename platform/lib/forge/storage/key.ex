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
