defmodule ForgeWeb.DigestedStaticTest do
  @moduledoc """
  What the endpoint serves at the addresses a release's pages link (`docs/design/ui.md` § The
  installed app, ticket 70). A release runs `mix phx.digest`, so `manifest.webmanifest` is linked as
  `manifest-<md5>.webmanifest?vsn=d`, and `Plug.Static`'s `:only` compares a first segment exactly:
  it answered the plain name and 404'd the one the page links, so Chromium found no manifest and
  forge could not be installed. The test environment digests nothing, so nothing else here reaches
  the digested address: these tests make the digested files with Phoenix's own digester
  (`Forge.DigestedStatic`) and ask the endpoint, not a `Plug.Static` built by hand.
  """

  # Writes to `priv/static`, which the partitions share, under names no other test module writes
  # (`installed_app_test.exs` digests a manifest of other bytes: see `Forge.DigestedStatic`).
  use ForgeWeb.ConnCase, async: false

  @static Application.app_dir(:forge, "priv/static")

  # A file in `priv/static` that is not in `static_paths/0`, a name that starts with a listed one's
  # letters without its dash, and the digested copy of each.
  @unlisted %{
    "secret.json" => ~s({"x":1}),
    "manifesto.txt" => "not the manifest"
  }

  setup_all do
    real = for name <- ~w(favicon.ico manifest.webmanifest robots.txt), do: {name, read!(name)}

    put = Forge.DigestedStatic.put!(Map.new(real) |> Map.merge(@unlisted), manifest: true)

    on_exit(fn ->
      Forge.DigestedStatic.remove!(put)

      # The real files are the checkout's own, shared with every partition: a helper that took
      # them out with its own would pass this module and break the others.
      for {name, _} <- real, do: assert(File.exists?(Path.join(@static, name)), "#{name} is gone")
    end)

    %{latest: put.latest}
  end

  # What the router makes of an address nothing serves: a 404, which a test without the endpoint's
  # error rendering sees as a raise.
  defp status_of(path) do
    get(build_conn(), path).status
  rescue
    Phoenix.Router.NoRouteError -> 404
  end

  defp read!(name), do: File.read!(Path.join(@static, name))

  describe "a digested top-level file" do
    test "the manifest is served at the address a release links, as the manifest", %{
      conn: conn,
      latest: latest
    } do
      digested = latest["manifest.webmanifest"]
      assert digested =~ ~r/^manifest-[0-9a-f]{32}\.webmanifest$/

      conn = get(conn, "/#{digested}?vsn=d")

      assert response(conn, 200) == read!("manifest.webmanifest")
      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "application/manifest+json"
      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
      # a new release changes the address, never the app (criterion 4)
      assert %{"id" => "/"} = Jason.decode!(conn.resp_body)
    end

    test "the favicon is served at the address a release links", %{conn: conn, latest: latest} do
      conn = get(conn, "/#{latest["favicon.ico"]}?vsn=d")

      assert response(conn, 200) == read!("favicon.ico")
      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "image/"
    end

    test "every top-level file the sign-in page links is served at its digested address", %{
      conn: conn,
      latest: latest
    } do
      html = conn |> get(~p"/users/log-in") |> html_response(200)

      hrefs =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("head link[href]")
        |> LazyHTML.attribute("href")

      # A page in the test environment links the plain names; a release links `latest` of each.
      top =
        for href <- hrefs,
            [file] <- [href |> URI.parse() |> Map.fetch!(:path) |> Path.split() |> Enum.drop(1)],
            do: file

      assert "manifest.webmanifest" in top
      assert "favicon.ico" in top

      for file <- top do
        assert digested = latest[file], "#{file} has no digested copy in the test"
        assert response(get(build_conn(), "/#{digested}?vsn=d"), 200) == read!(file)
      end
    end

    test "every file in the one list is served digested, with the rule derived from it", %{
      latest: latest
    } do
      top = for path <- ForgeWeb.static_paths(), Path.extname(path) != "", do: path

      assert Enum.sort(top) == ~w(favicon.ico manifest.webmanifest robots.txt)
      assert ForgeWeb.static_prefixes() |> Enum.sort() == ~w(favicon- manifest- robots-)

      for file <- top do
        assert response(get(build_conn(), "/#{latest[file]}?vsn=d"), 200) == read!(file)
      end
    end
  end

  describe "the plain addresses" do
    test "still answer, for a browser that installed with or cached one", %{conn: conn} do
      assert response(get(conn, "/manifest.webmanifest"), 200) == read!("manifest.webmanifest")
      assert response(get(build_conn(), "/favicon.ico"), 200) == read!("favicon.ico")
    end

    test "a file under a directory is still served, whatever it is called", %{conn: conn} do
      assert response(get(conn, "/images/icon-192.png"), 200) =~ "PNG"
    end
  end

  describe "nothing else in a release's static directory" do
    test "is reachable: not the manifest of digests, not an unlisted file or a lookalike", %{
      latest: latest
    } do
      for path <- [
            "/cache_manifest.json",
            "/secret.json",
            "/#{latest["secret.json"]}",
            "/manifesto.txt",
            "/#{latest["manifesto.txt"]}"
          ] do
        # The files are there, so the 404 is the endpoint's rule and not a file that never arrived.
        assert File.exists?(Path.join(@static, path)), "#{path} was never put in priv/static"
        assert status_of(path) == 404, "#{path} is reachable"
      end
    end

    test "a script the platform renders is still its own", %{conn: conn} do
      conn = get(conn, "/sw.js")

      assert response(conn, 200) =~ "forgeWorker"
      refute "sw.js" in ForgeWeb.static_paths()
    end
  end
end
