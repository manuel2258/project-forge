defmodule Forge.Look.Device do
  @moduledoc """
  What the gate's browser test needs to play a phone's installed forge (`docs/design/look.md`
  § What a look cannot show, and the browser test does): chromedriver's own door to the DevTools
  protocol, a script that waits for a promise, and a second listener for the endpoint that can be
  stopped and started again on the same port — which is what the network going away looks like to
  a service worker, and a proxy that cannot reach the platform looks like when it answers 502.

  Test support, compiled with the setups. Nothing here reaches the platform's own listener.
  """

  alias Forge.Look

  # Not `look-test`, which `browser_test.exs` writes and removes: the partitions of the suite run side
  # by side on one `priv/static`, and a directory two files both remove is one a test in the other
  # partition can lose its page from.
  @pages "look-device-test"

  @doc """
  One DevTools command in the browser, through chromedriver (`POST …/goog/cdp/execute`). Raises
  when the browser refuses it.
  """
  @spec cdp(Wallaby.Session.t(), String.t(), map) :: map
  def cdp(session, cmd, params \\ %{}) do
    {:ok, %{"value" => value}} =
      Wallaby.HTTPClient.request(:post, session.session_url <> "/goog/cdp/execute", %{
        cmd: cmd,
        params: params
      })

    value
  end

  @doc "Allows notifications for the app's own origin, as a person who tapped Allow."
  @spec grant_notifications(Wallaby.Session.t(), String.t()) :: map
  def grant_notifications(session, origin),
    do:
      cdp(session, "Browser.grantPermissions", %{permissions: ["notifications"], origin: origin})

  @doc """
  Runs the body of an async function in the page and returns what it returned. A promise cannot
  cross `execute_script`, so the page keeps it in `window.__out` and this polls for it.
  """
  @spec async(Wallaby.Session.t(), String.t()) :: term
  def async(session, body) do
    Look.script(
      session,
      "window.__out = '__pending'; (async () => { #{body} })()" <>
        ".then(v => { window.__out = v }, e => { window.__out = 'ERR ' + (e && e.message) }); return 1"
    )

    until(session, "return window.__out !== '__pending'", "the page's promise to settle")
    Look.script(session, "return window.__out")
  end

  @doc "Waits until `script` returns something truthy, or fails saying `what` never happened."
  @spec until(Wallaby.Session.t(), String.t(), String.t(), integer) :: :ok
  def until(session, script, what, left \\ 8_000) do
    cond do
      Look.script(session, script) -> :ok
      left <= 0 -> ExUnit.Assertions.flunk("never became true: " <> what)
      true -> Process.sleep(50) && until(session, script, what, left - 50)
    end
  end

  @doc """
  A second listener for `ForgeWeb.Endpoint`, on `port` (0 for one the kernel picks). Returns
  `{pid, port, down}`: `down` is a flag that makes the listener answer 502 to everything, as a
  proxy does when it cannot reach the platform. `scripts` maps a path to the JavaScript the listener
  serves there instead of the platform's own file: how a test breaks one page's script without
  touching the built file, which every partition of the suite shares.
  """
  @spec listen(:inet.port_number(), %{optional(String.t()) => String.t()}) ::
          {pid, :inet.port_number(), :atomics.atomics_ref()}
  def listen(port \\ 0, scripts \\ %{}) do
    down = :atomics.new(1, [])

    {:ok, pid} =
      Bandit.start_link(
        plug: {Forge.Look.Gateway, {down, scripts}},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port
      )

    # Not linked to the test: the test stops it itself, and a stop is not a crash.
    Process.unlink(pid)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {pid, port, down}
  end

  @doc "Stops a listener started by `listen/1`: connections to its port are then refused."
  @spec stop(pid) :: :ok
  def stop(pid), do: Supervisor.stop(pid)

  @doc "Makes a listener answer 502 to everything, or stop."
  @spec gateway_down(:atomics.atomics_ref(), boolean) :: :ok
  def gateway_down(down, on?), do: :atomics.put(down, 1, if(on?, do: 1, else: 0))

  @doc """
  Writes a page the app does not have under `priv/static/images/look-device-test/`, served by the
  endpoint's `Plug.Static`, and returns its path. The caller removes the directory.
  """
  @spec page!(String.t(), String.t()) :: String.t()
  def page!(name, html) do
    dir = Path.join(Application.app_dir(:forge, "priv/static/images"), @pages)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name), html)
    "/images/#{@pages}/" <> name
  end

  @doc "Removes what `page!/2` wrote."
  @spec remove_pages() :: :ok
  def remove_pages do
    File.rm_rf!(Path.join(Application.app_dir(:forge, "priv/static/images"), @pages))
    :ok
  end
end
