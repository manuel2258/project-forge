defmodule Forge.Git.UrlTest do
  @moduledoc """
  Two clients at two addresses.

  The operator's clone URL was the worker's for a while: `Url.for/1` fell back to `platform_url`,
  which on the local-VM provider is `http://10.0.2.2:4000` — QEMU's user-mode gateway, routable
  only from inside a guest. The project page showed it, and a clone from the operator's own
  machine hung until it timed out.
  """

  use Forge.DataCase, async: false

  alias Forge.Git.Url

  setup do
    previous = Application.get_env(:forge, Forge.Jobs, [])
    on_exit(fn -> Application.put_env(:forge, Forge.Jobs, previous) end)
    :ok
  end

  defp configure(opts) do
    current = Application.get_env(:forge, Forge.Jobs, [])
    Application.put_env(:forge, Forge.Jobs, Keyword.merge(current, opts))
  end

  defp project, do: %Forge.Projects.Project{name: "game"}

  test "the operator's URL is the endpoint they are already talking to" do
    configure(platform_url: "http://10.0.2.2:4000", git_base_url: nil)

    # Not 10.0.2.2: that address exists only inside a worker VM.
    assert Url.for(project()) == ForgeWeb.Endpoint.url() <> "/git/game.git"
    refute Url.for(project()) =~ "10.0.2.2"
  end

  # `bin/forge eval 'Forge.Release.git_token("game")'` is the command `docs/deploy.md` § First
  # run gives an operator on a fresh deployment, and `eval` starts the repo and nothing else.
  # `Endpoint.url/0` reads a persistent term written when the endpoint *starts*, so asking it
  # there raised "could not find persistent term for endpoint" — the URL is built from the
  # configuration instead, which is the same source with no started process behind it.
  #
  # Driven by changing the configuration under a *running* endpoint: the persistent term keeps
  # the value it was started with, so an implementation that asked the endpoint returns the old
  # host and this fails.
  test "the URL comes from configuration, not from a started endpoint" do
    configure(platform_url: nil, git_base_url: nil)
    previous = Application.get_env(:forge, ForgeWeb.Endpoint, [])

    on_exit(fn -> Application.put_env(:forge, ForgeWeb.Endpoint, previous) end)

    Application.put_env(
      :forge,
      ForgeWeb.Endpoint,
      Keyword.put(previous, :url, host: "forge.example.org", scheme: "https", port: 443)
    )

    assert Url.for(project()) == "https://forge.example.org/git/game.git"

    # A port that is the scheme's own is not written down, which is what the URLs looked like
    # before and what a client expects.
    refute Url.for(project()) =~ ":443"
  end

  test "the worker's URL is the address it is told to dial" do
    configure(platform_url: "http://10.0.2.2:4000", git_base_url: nil)

    assert Url.for_worker(project()) == "http://10.0.2.2:4000/git/game.git"
  end

  test "git_base_url overrides both, which is what a proxy in front means" do
    configure(platform_url: "http://10.0.2.2:4000", git_base_url: "https://forge.example.org/")

    assert Url.for(project()) == "https://forge.example.org/git/game.git"
    assert Url.for_worker(project()) == "https://forge.example.org/git/game.git"
  end

  test "with no configuration at all both fall back to the endpoint" do
    configure(platform_url: nil, git_base_url: nil)

    assert Url.for(project()) == ForgeWeb.Endpoint.url() <> "/git/game.git"
    assert Url.for_worker(project()) == ForgeWeb.Endpoint.url() <> "/git/game.git"
  end

  test "a token goes in the operator's URL, because a person is the one pasting it" do
    configure(platform_url: "http://10.0.2.2:4000", git_base_url: nil)

    url = Url.with_token(project(), "s3cret")

    assert url =~ "forge:s3cret@"
    refute url =~ "10.0.2.2"
  end
end
