defmodule Forge.Projects.Mirror do
  @moduledoc """
  What a mirror is allowed to be. `docs/design/git-hosting.md` § What a mirror URL may be.

  A mirror URL is attacker-adjacent input: a project admin sets it from the UI and it becomes an
  argument to `git push` on the platform's own machine. So this is an allowlist of two schemes
  rather than a denylist of the transports anybody thought of, and it is checked here *and* again
  in the hook — a config file is editable by anything that can reach the disk, and a guard must
  use the same model as the operation it guards.
  """

  @name ~r/\A[a-z0-9-]+\z/

  @doc "Whether `name` can be half of a `forge.mirror.<name>.url` key without ambiguity."
  @spec validate_name(term()) :: :ok | {:error, :invalid_name}
  def validate_name(name) when is_binary(name) do
    if Regex.match?(@name, name), do: :ok, else: {:error, :invalid_name}
  end

  def validate_name(_other), do: {:error, :invalid_name}

  @doc "Whether `url` is one of the two transports a mirror may use."
  @spec validate_url(term()) ::
          :ok
          | {:error, :option_like | :transport_helper | :scheme | :credentials_in_url | :no_host}
  def validate_url(url) when is_binary(url) do
    cond do
      String.starts_with?(url, "-") -> {:error, :option_like}
      String.contains?(url, "::") -> {:error, :transport_helper}
      not String.starts_with?(url, ["https://", "http://"]) -> {:error, :scheme}
      URI.parse(url).userinfo != nil -> {:error, :credentials_in_url}
      URI.parse(url).host in [nil, ""] -> {:error, :no_host}
      true -> :ok
    end
  end

  def validate_url(_other), do: {:error, :scheme}
end
