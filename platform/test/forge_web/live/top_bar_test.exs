defmodule ForgeWeb.TopBarTest do
  @moduledoc """
  The laptop's top row (`docs/design/ui.md` § Navigation): what it carries beside the nav that no
  page test asks about — the version the node runs, beside the wordmark.
  """

  use ForgeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  test "says the version the node runs, beside the wordmark and outside its link", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    version = String.trim(File.read!(Path.expand("../../../../VERSION", __DIR__)))

    assert view |> element("header #forge-version") |> render() =~ version
    refute has_element?(view, "header a #forge-version")
  end

  test "tells nobody signed out which release is running" do
    {:ok, view, _html} = live(build_conn(), ~p"/users/log-in")

    assert has_element?(view, "header")
    refute has_element?(view, "#forge-version")
  end
end
