defmodule ForgeWeb.DeviceController do
  @moduledoc """
  What a phone's installed forge asks of the platform (`docs/design/ui.md` § The installed app):
  the service worker's script, the page it falls back to when the server cannot be reached, and
  the one read it makes about its own person.

  `service_worker/2` and `offline/2` run in the `:device` pipeline, which has no session, so what
  the device stores of them holds nothing of anybody's. `waiting/2` is the exception, and answers
  only the signed-in, approved person about themselves.
  """
  use ForgeWeb, :controller

  alias Forge.Accounts.{Scope, User}
  alias Forge.Push

  @source Path.join(__DIR__, "device/sw.js")
  @external_resource @source
  @source_text File.read!(@source)

  # What the worker precaches, besides the offline page, to draw it: the stylesheet and the two
  # fonts the stylesheet names (`assets/css/tokens.css`). Each is the address the page links, so in
  # production the digested one.
  @files [
    "/assets/css/app.css",
    "/fonts/instrument-sans-var.woff2",
    "/fonts/jetbrains-mono-var.woff2"
  ]

  @doc """
  The service worker: a few constants in front of the source — this release's version, the offline
  page's address and the exact files to precache, as JSON — so every release serves a script that
  differs from the last, which is what makes a browser install it. `no-cache`, so a browser always
  asks.
  """
  def service_worker(conn, _params) do
    constants = %{
      version: Forge.Changelog.running(),
      offline: offline_path(),
      precache: precache()
    }

    conn
    |> put_resp_content_type("text/javascript")
    |> put_resp_header("cache-control", "no-cache")
    |> send_resp(200, "const FORGE = " <> Jason.encode!(constants) <> ";\n" <> @source_text)
  end

  @doc "Every address the worker keeps on the device: the offline page and what it draws with."
  @spec precache() :: [String.t()]
  def precache, do: [offline_path() | Enum.map(@files, &ForgeWeb.Endpoint.static_path/1)]

  defp offline_path, do: ~p"/offline"

  @doc """
  The offline page: forge's own, with nothing of the person's on it, drawn the same for anybody.
  `no-cache`, so the copy the worker keeps is the release's own.
  """
  def offline(conn, _params) do
    # The pipeline has no `accepts`: the worker's own fetch of this page asks for anything.
    conn
    |> put_format("html")
    |> put_resp_header("cache-control", "no-cache")
    |> render(:offline, layout: false)
  end

  @doc """
  What this device needs to tidy its notifications and set its badge: the queue button's `count`
  and the `tags` of what waits (`Forge.Push.state/1`), for the signed-in, approved person and
  nobody else. Anything else — signed out, pending, suspended, a project token with no session —
  is a 401 with no body, never a redirect, which a fetch would follow into a page. `no-store`.
  """
  def waiting(conn, _params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    # `User.active?/1` is what refuses a pending account. For a suspended one it is an equivalent
    # mutant: suspension drops the account's sessions (`Accounts.suspend_user/2`), so such a request
    # arrives with no user and is refused below whatever this asks.
    case conn.assigns[:current_scope] do
      %Scope{user: %User{} = user} ->
        if User.active?(user), do: json(conn, Push.state(user)), else: send_resp(conn, 401, "")

      _ ->
        send_resp(conn, 401, "")
    end
  end
end
