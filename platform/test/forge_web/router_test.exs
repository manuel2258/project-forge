defmodule ForgeWeb.RouterTest do
  @moduledoc """
  What the router mounts, and — for the developer tools — what it must not.

  `/dev/mailbox` previews every email the node sends, login magic-links included, and
  `/dev/dashboard` exposes processes, ETS and config, both behind no authentication. They exist
  only when `:dev_routes` is on, which is `config/dev.exs` alone: not test, not prod. This pins
  that gate — remove the `if` around the `/dev` scope and these stop being 404.
  """

  use ForgeWeb.ConnCase, async: true

  test "the developer tools are not mounted unless dev_routes is enabled", %{conn: conn} do
    for path <- ["/dev/dashboard", "/dev/mailbox"] do
      assert get(conn, path).status == 404
    end
  end
end
