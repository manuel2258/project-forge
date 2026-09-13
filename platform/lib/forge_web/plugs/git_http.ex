defmodule ForgeWeb.Plugs.GitHttp do
  @moduledoc """
  The platform's git endpoint, served from the endpoint rather than the router.

  It takes HTTP Basic with a per-job token — not the operator session and not the API bearer — so
  neither router pipeline fits it, and its request body is a packfile that has to reach
  `git http-backend` unread, which is not what a pipeline ending in `Plug.Parsers` is for.
  Mounted above `Plug.Parsers`, `Plug.MethodOverride`, `Plug.Head` and `Plug.Session`, so the git
  scope gets no cookie, no CSRF and no method override: all meaningless to git, and all surface.

  Exactly four requests answer. Everything else is 404, the dumb protocol included: walking loose
  objects under `/objects/` names no service, and so bypasses the one place capability is checked.
  See `docs/design/git-hosting.md`.
  """

  import Plug.Conn

  alias Forge.Git.{Http, Tokens}
  alias Forge.Projects

  @behaviour Plug

  @impl true
  def init(opts), do: Keyword.get(opts, :at, "git") |> String.trim_leading("/")

  @impl true
  def call(%Plug.Conn{path_info: [prefix | rest]} = conn, prefix), do: dispatch(conn, rest)
  def call(conn, _prefix), do: conn

  defp dispatch(conn, [repo | tail]) do
    with {:ok, name} <- project_name(repo),
         {:ok, service} <- service(conn, tail),
         project when not is_nil(project) <- Projects.by_name(name) do
      authorise(conn, project, tail, service)
    else
      _other -> halt(send_resp(conn, 404, "forge: no such repository\n"))
    end
  end

  defp dispatch(conn, _tail), do: halt(send_resp(conn, 404, "forge: no such repository\n"))

  defp project_name(repo) do
    case String.split(repo, ".git") do
      [name, ""] when name != "" -> {:ok, name}
      _other -> :error
    end
  end

  # The advertisement names the service it is advertising for; the RPC is the path itself.
  defp service(%Plug.Conn{method: "GET"} = conn, ["info", "refs"]) do
    case Plug.Conn.Query.decode(conn.query_string)["service"] do
      "git-upload-pack" -> {:ok, :read}
      "git-receive-pack" -> {:ok, :write}
      _other -> :error
    end
  end

  defp service(%Plug.Conn{method: "POST"}, ["git-upload-pack"]), do: {:ok, :read}
  defp service(%Plug.Conn{method: "POST"}, ["git-receive-pack"]), do: {:ok, :write}
  defp service(_conn, _tail), do: :error

  defp authorise(conn, project, tail, service) do
    case Tokens.authorise(secret(conn), project, service) do
      {:ok, token} -> halt(Http.serve(conn, project, tail, token))
      :error -> unauthorised(conn)
    end
  end

  # The username is ignored, so `http://forge:TOKEN@host/git/x.git` works with no credential
  # helper. A valid but under-powered token fails exactly as an unknown one does: a caller learns
  # only that this credential does not work here.
  defp secret(conn) do
    case Plug.BasicAuth.parse_basic_auth(conn) do
      {_user, secret} -> secret
      :error -> nil
    end
  end

  # git retries with credentials only when it is told how; without the header it gives up.
  defp unauthorised(conn) do
    conn
    |> put_resp_header("www-authenticate", ~s|Basic realm="forge"|)
    |> send_resp(401, "forge: this repository needs a token\n")
    |> halt()
  end
end
