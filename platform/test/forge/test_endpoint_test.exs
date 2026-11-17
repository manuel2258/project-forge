defmodule Forge.TestEndpointTest do
  @moduledoc """
  The suite serves on a port the kernel picks, so that two suites on one machine cannot collide
  on a name (`Forge.TestEndpoint`). Everything that builds a URL to the endpoint has to agree on
  the number, and the number has to be one something answers on.
  """

  use Forge.DataCase, async: false

  alias Forge.Git.Url
  alias Forge.TestEndpoint

  setup do
    previous = Application.get_env(:forge, Forge.Jobs, [])
    Application.put_env(:forge, Forge.Jobs, Keyword.merge(previous, git_base_url: nil))
    on_exit(fn -> Application.put_env(:forge, Forge.Jobs, previous) end)
    :ok
  end

  test "the port is a real one that no configuration names" do
    port = TestEndpoint.port()

    assert port > 0
    # Not a number written down anywhere: that is what the suite was changed from.
    refute port == 4002
    assert Application.get_env(:forge, ForgeWeb.Endpoint)[:http][:port] == port
  end

  test "every reader of the address says the bound port" do
    port = TestEndpoint.port()
    project = %Forge.Projects.Project{name: "game"}

    assert ForgeWeb.Endpoint.config(:http)[:port] == port
    assert URI.parse(ForgeWeb.Endpoint.url()).port == port
    assert URI.parse(Url.for(project)).port == port
    assert URI.parse(Forge.GitFixtures.platform_git_url("game")).port == port
  end

  test "the endpoint answers on the URL it says it has" do
    # `Endpoint.url/0` and not `base_url/1`, which asks the listener and would pass unpublished.
    url = String.replace(ForgeWeb.Endpoint.url(), "localhost", "127.0.0.1")
    response = Req.get!(url <> "/", retry: false, redirect: false)

    # Whatever the page says: a listener that was not there would have refused the connection.
    assert response.status in 200..399
  end
end
