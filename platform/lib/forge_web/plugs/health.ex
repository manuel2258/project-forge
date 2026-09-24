defmodule ForgeWeb.Plugs.Health do
  @moduledoc """
  Liveness, and deliberately nothing more.

  A container runtime and a proxy both want one address that says *this process is answering*,
  and `docs/deploy.md` § In a container is why it exists here: without it the only probe left is
  one against something else — the deployment that prompted this was checking Postgres and
  calling it the platform.

  **It does not touch the database and does not say what it is.** Readiness — is Postgres
  reachable, are migrations done — is a different question with a different failure, and an
  unauthenticated endpoint that answers it hands a stranger the shape of the node; so does a
  version. What comes back is `ok`, to anyone, and the whole of what it proves is that the
  endpoint is up.

  Forwarded from the router, piped through nothing, so a probe carries no session and no CSRF.
  It is mounted there rather than on the endpoint for one reason: `AuthorizationInventoryTest`
  enumerates `Router.__routes__/0`, and an endpoint plug is a way in that test cannot see —
  which for the one route reachable with no credential at all is exactly backwards.

  Being a `forward` target, it is the end of the line: nothing runs after it, so it answers
  everything under `/health` itself rather than falling through to a router that will not see it
  again.

  Excluded from `force_ssl` in `config/prod.exs`: a probe on the container's own address has no
  proxy in front of it to put `x-forwarded-proto` there, and a 301 is not an answer a runtime
  reads as healthy.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  # `path_info` and not `request_path`: under a `forward` the first is what is left after the
  # mount point, so this is *exactly* `/health` and not everything beginning with it.
  @impl true
  def call(%Plug.Conn{path_info: [], method: method} = conn, _opts)
      when method in ["GET", "HEAD"] do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "ok\n")
    |> halt()
  end

  # A probe with a body is not a probe, and neither is one addressed to a deeper path.
  def call(conn, _opts), do: conn |> send_resp(404, "not found\n") |> halt()
end
