defmodule Forge.Look.Guard do
  @moduledoc """
  The app's own check that a request comes from the browser a look started
  (`docs/design/look.md` § Security).

  A look serves made-up data on a loopback port, and another process on the machine can connect
  to a loopback port as easily as the browser can. So the app asks: with a token configured, every
  request — a page, a LiveView socket, the worker and git endpoints — must carry it in the
  `_forge_look` cookie, or it gets a bare 403. The token is made per run from
  `:crypto.strong_rand_bytes/1`, lives in the application environment, and is never put on a
  command line or printed.

  **It runs before socket dispatch.** `Phoenix.Endpoint` adds `socket_dispatch` among the plugs
  ahead of the endpoint's own, so a `plug` of the endpoint's own would run after a socket had already been upgraded. The
  endpoint registers this module's `__before_compile__` *after* `use Phoenix.Endpoint`, which
  wraps the generated `call/2`. Test only (`ForgeWeb.Endpoint`); with no token configured it
  passes everything, so the suite and a release are unaffected.

  The network namespace `bin/look` runs in is the stronger lock — chromedriver listens
  unauthenticated and launches any binary it is told to, which this cannot guard — and this is
  the lock on what the app serves, which holds where there is no namespace.
  """

  @cookie "_forge_look"

  @doc "The cookie the browser must carry."
  def cookie, do: @cookie

  @doc "A fresh token, 256 bits, URL-safe."
  @spec generate() :: String.t()
  def generate, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc "Require `token` from now on, or nothing at all with `nil`."
  @spec put_token(String.t() | nil) :: :ok
  def put_token(token), do: Application.put_env(:forge, __MODULE__, token: token)

  @doc "Whether `conn` may be served."
  @spec allowed?(Plug.Conn.t()) :: boolean
  def allowed?(conn) do
    case Application.get_env(:forge, __MODULE__, [])[:token] do
      nil ->
        true

      token ->
        given = Plug.Conn.fetch_cookies(conn).req_cookies[@cookie]
        is_binary(given) and Plug.Crypto.secure_compare(given, token)
    end
  end

  @doc """
  Answer a refused request: a 403 with one word and nothing of the app.

  The word is not decoration: Chromium replaces an empty error response with an error page of an
  origin of its own, where no cookie can be set, and the look's browser has to set one on this
  very answer.
  """
  @spec refuse(Plug.Conn.t()) :: Plug.Conn.t()
  # `halt` is an equivalent mutant: a conn that is already sent is not dispatched any further, so
  # nothing can observe it missing. It stays as the statement of intent.
  def refuse(conn), do: conn |> Plug.Conn.send_resp(403, "forbidden") |> Plug.Conn.halt()

  defmacro __before_compile__(_env) do
    quote do
      defoverridable call: 2

      def call(conn, opts) do
        if Forge.Look.Guard.allowed?(conn),
          do: super(conn, opts),
          else: Forge.Look.Guard.refuse(conn)
      end
    end
  end
end
