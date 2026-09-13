defmodule Forge.Git.Url do
  @moduledoc """
  Where a client reaches a project's repository.

  Configured rather than derived wherever the platform sits behind something that rewrites the
  host — `FORGE_GIT_BASE_URL` — and taken from the endpoint otherwise, which is right on the one
  machine the PoC runs on.
  """

  alias Forge.Projects.Project

  @doc "The clone URL for `project`, with no credential in it."
  @spec for(Project.t()) :: String.t()
  def for(%Project{name: name}), do: base() <> "/git/" <> name <> ".git"

  @doc "The same URL carrying `token` as the password, for a client with no credential helper."
  @spec with_token(Project.t(), String.t()) :: String.t()
  def with_token(%Project{} = project, token) do
    uri = project |> __MODULE__.for() |> URI.parse()
    URI.to_string(%{uri | userinfo: "forge:" <> token})
  end

  defp base do
    case Forge.Jobs.config(:git_base_url, nil) do
      nil -> ForgeWeb.Endpoint.url()
      url -> String.trim_trailing(url, "/")
    end
  end
end
