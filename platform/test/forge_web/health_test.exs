defmodule ForgeWeb.HealthTest do
  @moduledoc """
  The liveness endpoint, and what it deliberately does not do.

  A container runtime reads a 200 as alive and anything else as dead, so what matters is that the
  answer needs no session, no credential and no database — and that it stays a bare `ok`. An
  unauthenticated endpoint that reported the version, or reached Postgres and reported what it
  found, would be handing a stranger the shape of the node one probe at a time.
  """

  use ForgeWeb.ConnCase, async: true

  test "answers 200 to anyone, with no credential", %{conn: conn} do
    conn = get(conn, "/health")

    assert conn.status == 200
    assert conn.resp_body == "ok\n"
  end

  test "a HEAD probe is answered too", %{conn: conn} do
    assert head(conn, "/health").status == 200
  end

  # The mutation this is aimed at is the tempting one: making the probe useful. A version, a
  # commit, a database round trip — each is one line, and each turns an address open to the whole
  # internet into a disclosure. The assertion is on the whole body for that reason.
  test "says nothing but ok", %{conn: conn} do
    body = get(conn, "/health").resp_body

    refute body =~ ~r/\d+\.\d+\.\d+/
    assert body == "ok\n"
  end

  # It is mounted above the router, so nothing it does can reach a route, and a path that merely
  # starts with it is not it.
  test "only that exact path", %{conn: conn} do
    assert get(conn, "/health/deep").status == 404
  end

  # A probe with a body is not a probe. The plug answers reads and lets everything else fall
  # through to the router, which has no such route.
  test "a write is not a liveness check", %{conn: conn} do
    assert post(conn, "/health", %{}).status == 404
  end

  # The moduledoc above and the plug's own both say the probe reaches no database. Nothing
  # asserted it, so `Forge.Repo.query!("SELECT 1")` could be added to the 200 path with the whole
  # suite still green — and the cost of that is a liveness probe that reports the node dead every
  # time Postgres hiccups, which is the opposite of what a container runtime should restart on.
  #
  # Ecto's own telemetry is what can see this; a assertion on the response body cannot.
  test "the probe reaches no database", %{conn: conn} do
    parent = self()
    handler = "health-no-queries-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:forge, :repo, :query],
      # A telemetry handler is node-global and runs in whichever process emitted the event, so
      # without this the queries of every other async test arrive here too. The request under
      # `ConnCase` runs in the test process, so that identity is what distinguishes "this probe
      # queried" from "the suite is busy".
      fn _event, _measurements, _metadata, _config ->
        if self() == parent, do: send(parent, :queried)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert get(conn, "/health").status == 200

    refute_receive :queried, 100
  end
end
