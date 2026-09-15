defmodule Forge.Git.Url do
  @moduledoc """
  Where a client reaches a project's repository.

  **There are two clients and they are not at the same address.** A worker dials from inside its
  own machine; an operator clones from wherever they are browsing. On the local-VM provider those
  differ concretely: the worker's platform is `http://10.0.2.2:4000`, QEMU's user-mode gateway,
  which is meaningful only inside the guest and unroutable everywhere else.

  So `for/1` is the operator's URL and `for_worker/1` is the worker's. Handing one the other's is
  not a cosmetic error: a clone that hangs until it times out is what it looks like.

  `FORGE_GIT_BASE_URL` overrides both, for a deployment where something in front rewrites the
  host and the two collapse back into one address.
  """

  alias Forge.Projects.Project

  @doc """
  The clone URL a person uses, with no credential in it.

  The endpoint's own URL, which is what the operator is already talking to — `PHX_HOST` in
  production, so it is the public name and not the container's.
  """
  @spec for(Project.t()) :: String.t()
  def for(%Project{name: name}), do: path(operator_base(), name)

  @doc """
  The clone URL a job is given in its assignment.

  The address the platform already tells a worker to dial, because the worker is on another
  machine and the endpoint's own URL says `localhost`, which to a worker is the worker.
  """
  @spec for_worker(Project.t()) :: String.t()
  def for_worker(%Project{name: name}), do: path(worker_base(), name)

  @doc "The operator's URL carrying `token` as the password, for a client with no credential helper."
  @spec with_token(Project.t(), String.t()) :: String.t()
  def with_token(%Project{} = project, token) do
    uri = project |> __MODULE__.for() |> URI.parse()
    URI.to_string(%{uri | userinfo: "forge:" <> token})
  end

  defp path(base, name), do: base <> "/git/" <> name <> ".git"

  defp operator_base do
    case Forge.Jobs.config(:git_base_url, nil) do
      nil -> endpoint_url()
      url -> trim(url)
    end
  end

  defp worker_base do
    case Forge.Jobs.config(:git_base_url, nil) || Forge.Jobs.config(:platform_url, nil) do
      nil -> endpoint_url()
      url -> trim(url)
    end
  end

  # Built from the endpoint's configuration rather than asked of the endpoint. `Endpoint.url/0`
  # reads a persistent term the endpoint writes when it *starts*, and the commands that most
  # need a clone URL are the ones run without a started endpoint: `bin/forge eval
  # 'Forge.Release.git_token("game")'`, which `docs/deploy.md` § First run tells the operator to
  # run on a fresh deployment. Asking the endpoint there raises "could not find persistent term".
  #
  # The configuration is the same source the endpoint would read, so a started one gets the same
  # answer it always did.
  defp endpoint_url do
    config = Application.get_env(:forge, ForgeWeb.Endpoint, [])
    url = Keyword.get(config, :url, [])

    scheme = url[:scheme] || "http"
    host = url[:host] || "localhost"
    port = url[:port] || config[:http][:port] || 4000

    %URI{scheme: scheme, host: host, port: port}
    |> normalise_port(scheme)
    |> URI.to_string()
    |> trim()
  end

  # A URL says its port only when it is not the scheme's own, which is what `Endpoint.url/0`
  # does and what every one of these URLs was before this.
  defp normalise_port(%URI{port: 443} = uri, "https"), do: %{uri | port: nil}
  defp normalise_port(%URI{port: 80} = uri, "http"), do: %{uri | port: nil}
  defp normalise_port(uri, _scheme), do: uri

  defp trim(url), do: String.trim_trailing(url, "/")
end
