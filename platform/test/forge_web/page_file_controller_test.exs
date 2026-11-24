defmodule ForgeWeb.PageFileControllerTest do
  @moduledoc """
  A page's own files, for the sandboxed frame (`docs/design/pages.md` § Serving a page's files).

  The headers are the page's whole defence — `sandbox allow-scripts` and no outside address unless
  the viewer switched it on — so each has a test that fails without it, and the reach is asked again
  on every request.
  """

  use ForgeWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Forge.ForgeFixtures
  import ForgeWeb.PageDoorFixtures

  alias Forge.Accounts.User
  alias Forge.{Pages, Repo}
  alias Forge.Projects.Member

  @salt "forge page"

  setup do
    original = Application.get_env(:forge, Forge.Storage, [])

    dir =
      Path.join(
        System.tmp_dir!(),
        "#{System.pid()}-page-files-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:forge, Forge.Storage, Keyword.put(original, :dir, dir))

    on_exit(fn ->
      Application.put_env(:forge, Forge.Storage, original)
      File.rm_rf!(dir)
    end)

    project = project_fixture()
    ticket = ticket_fixture(%{project: project, number: 1})
    viewer = member_fixture(project, :member)

    {page, version} =
      published!({:ticket, ticket.id}, "form", %{
        "index.html" => ~s(<script src="app.js"></script>),
        "app.js" => "console.log(1)",
        "clip.webm" => "0123456789abcdefghij"
      })

    %{project: project, ticket: ticket, viewer: viewer, page: page, version: version}
  end

  defp token(user, page, version),
    do: ForgeWeb.PageToken.sign(user.id, page.id, version.version)

  defp fetch(conn, token, file \\ "index.html"),
    do: get(conn, "/page-files/#{token}/#{file}")

  defp csp(conn), do: conn |> get_resp_header("content-security-policy") |> hd()

  describe "what is sent" do
    test "the page's files, with the type their extension says", ctx do
      %{conn: conn, viewer: viewer, page: page, version: version} = ctx
      token = token(viewer, page, version)

      html = fetch(conn, token)
      assert response(html, 200) =~ "app.js"
      assert [type] = get_resp_header(html, "content-type")
      assert type =~ "text/html"

      js = fetch(conn, token, "app.js")
      assert response(js, 200) == "console.log(1)"
      assert [type] = get_resp_header(js, "content-type")
      assert type =~ "javascript"

      assert [video] = get_resp_header(fetch(conn, token, "clip.webm"), "content-type")
      assert video =~ "video/webm"
    end

    test "sandboxed, never with its own origin, and nothing leaves in a referrer", ctx do
      %{conn: conn, viewer: viewer, page: page, version: version} = ctx
      sent = fetch(conn, token(viewer, page, version))
      csp = csp(sent)

      assert csp =~ "sandbox allow-scripts"
      refute csp =~ "allow-same-origin"
      assert csp =~ "form-action 'none'"
      assert csp =~ "base-uri 'none'"
      # `'self'` as well as the configured URL: a forge reached at another address must still be
      # able to frame its own pages.
      assert csp =~ "frame-ancestors 'self' #{ForgeWeb.Endpoint.url()}"
      assert get_resp_header(sent, "referrer-policy") == ["no-referrer"]
      assert get_resp_header(sent, "x-content-type-options") == ["nosniff"]
    end

    test "no cookie is set and none is needed", ctx do
      %{conn: conn, viewer: viewer, page: page, version: version} = ctx
      sent = fetch(conn, token(viewer, page, version))
      assert get_resp_header(sent, "set-cookie") == []
    end

    test "with nothing switched on a page reaches only itself", ctx do
      %{conn: conn, viewer: viewer, page: page, version: version} = ctx
      csp = conn |> fetch(token(viewer, page, version)) |> csp()
      origin = ForgeWeb.Endpoint.url()
      # The address the request itself came to is allowed beside the configured one.
      asked = "#{conn.scheme}://#{conn.host}:#{conn.port}"
      sources = origin <> " " <> asked

      for directive <- [
            "default-src",
            "script-src",
            "style-src",
            "img-src",
            "media-src",
            "font-src",
            "connect-src"
          ] do
        [_, allowed] = Regex.run(~r/#{directive} ([^;]*)/, csp)
        assert allowed =~ "'self' #{sources}", directive
        # Nothing but `'self'`, the endpoint's own origin and the keywords: no wildcard, no scheme
        # that stands for a whole class of addresses, no other host.
        rest =
          allowed
          |> String.replace(origin, "")
          |> String.replace(asked, "")
          |> String.replace("'self'", "")

        refute rest =~ "*", directive
        refute rest =~ "http", directive
        refute rest =~ "ws:", directive
      end

      assert csp =~ "img-src 'self' #{sources} data: blob:"
      assert csp =~ "media-src 'self' #{sources} data: blob:"
      assert csp =~ "script-src 'self' #{sources} 'unsafe-inline' 'unsafe-eval'"
    end

    test "the viewer's own toggle allows any address, and only for them", ctx do
      %{conn: conn, viewer: viewer, page: page, version: version, project: project} = ctx
      other = member_fixture(project, :member)
      {:ok, true} = Pages.set_outside(viewer.id, page, true)

      on = csp(fetch(conn, token(viewer, page, version)))
      assert on =~ "default-src * data: blob:"
      refute String.replace(on, ~r/frame-ancestors[^;]*/, "") =~ "'self'"
      assert on =~ "sandbox allow-scripts"
      refute on =~ "allow-same-origin"

      off = csp(fetch(conn, token(other, page, version)))
      assert off =~ "'self'"
      refute off =~ "default-src *"

      {:ok, false} = Pages.set_outside(viewer.id, page, false)
      assert csp(fetch(conn, token(viewer, page, version))) =~ "'self'"
    end

    test "the toggle outlives a new version, and a token for the old one still shows the old files",
         ctx do
      %{conn: conn, viewer: viewer, page: page, version: v1, ticket: ticket} = ctx
      {:ok, true} = Pages.set_outside(viewer.id, page, true)
      {_page, v2} = published!({:ticket, ticket.id}, "form", %{"index.html" => "second"})

      assert v2.version == 2
      assert response(fetch(conn, token(viewer, page, v2)), 200) == "second"
      assert csp(fetch(conn, token(viewer, page, v2))) =~ "default-src *"
      assert response(fetch(conn, token(viewer, page, v1)), 200) =~ "app.js"
    end

    test "forge-page.js is the platform's, whatever the page holds", ctx do
      %{conn: conn, viewer: viewer, ticket: ticket} = ctx

      {page, version} =
        published!({:ticket, ticket.id}, "tricky", %{
          "index.html" => "x",
          "forge-page.js" => "EVIL"
        })

      sent = fetch(conn, token(viewer, page, version), "forge-page.js")
      body = response(sent, 200)
      refute body == "EVIL"
      assert body =~ "forge"
      assert [type] = get_resp_header(sent, "content-type")
      assert type =~ "javascript"
      assert csp(sent) =~ "sandbox allow-scripts"
    end

    test "a name the version does not hold is a 404, with the same headers", ctx do
      %{conn: conn, viewer: viewer, page: page, version: version} = ctx
      sent = fetch(conn, token(viewer, page, version), "missing.png")

      assert response(sent, 404)
      assert csp(sent) =~ "sandbox allow-scripts"
      assert get_resp_header(sent, "referrer-policy") == ["no-referrer"]
    end
  end

  describe "who is asking" do
    test "a token that is forged, for another purpose or expired gets nothing", ctx do
      %{conn: conn, viewer: viewer, page: page, version: version} = ctx
      payload = %{user: viewer.id, page: page.id, version: version.version}
      old = System.system_time(:second) - 2 * 24 * 60 * 60

      for bad <- [
            "garbage",
            token(viewer, page, version) <> "x",
            Phoenix.Token.sign(ForgeWeb.Endpoint, "something else", payload),
            Phoenix.Token.sign(ForgeWeb.Endpoint, @salt, payload, signed_at: old),
            Phoenix.Token.sign(ForgeWeb.Endpoint, @salt, "not a map")
          ] do
        sent = fetch(conn, bad)
        assert response(sent, 404)
        assert csp(sent) =~ "sandbox allow-scripts"
      end
    end

    test "a token for a version the page does not have gets nothing", ctx do
      %{conn: conn, viewer: viewer, page: page} = ctx
      sent = fetch(conn, ForgeWeb.PageToken.sign(viewer.id, page.id, 99))
      assert response(sent, 404)
    end

    test "a member who is removed loses the files at once, on the token they had", ctx do
      %{conn: conn, viewer: viewer, page: page, version: version} = ctx
      token = token(viewer, page, version)
      assert response(fetch(conn, token), 200)

      Repo.delete_all(from(m in Member, where: m.user_id == ^viewer.id))

      assert response(fetch(conn, token), 404)
      assert response(fetch(conn, token, "app.js"), 404)
    end

    test "a suspended account loses them too", ctx do
      %{conn: conn, viewer: viewer, page: page, version: version} = ctx
      token = token(viewer, page, version)
      assert response(fetch(conn, token), 200)

      Repo.update_all(from(u in User, where: u.id == ^viewer.id),
        set: [suspended_at: DateTime.utc_now(:second)]
      )

      assert response(fetch(conn, token), 404)
    end

    test "a member of another project is not let in by a token minted for this page", ctx do
      %{conn: conn, page: page, version: version} = ctx
      stranger = member_fixture(project_fixture(), :member)

      assert response(fetch(conn, token(stranger, page, version)), 404)
    end
  end

  describe "Range" do
    test "an answer of 206 with the bytes and where they sit", ctx do
      %{conn: conn, viewer: viewer, page: page, version: version} = ctx
      token = token(viewer, page, version)
      ranged = fn range -> conn |> put_req_header("range", range) |> fetch(token, "clip.webm") end

      sent = ranged.("bytes=2-5")
      assert response(sent, 206) == "2345"
      assert get_resp_header(sent, "content-range") == ["bytes 2-5/20"]
      assert get_resp_header(sent, "accept-ranges") == ["bytes"]

      assert response(ranged.("bytes=15-"), 206) == "fghij"
      assert response(ranged.("bytes=-3"), 206) == "hij"
      assert response(ranged.("bytes=10-999"), 206) == "abcdefghij"
    end

    test "a range past the end is a 416 that says how long the file is", ctx do
      %{conn: conn, viewer: viewer, page: page, version: version} = ctx

      sent =
        conn
        |> put_req_header("range", "bytes=99-")
        |> fetch(token(viewer, page, version), "clip.webm")

      assert response(sent, 416)
      assert get_resp_header(sent, "content-range") == ["bytes */20"]
    end

    test "no range, or one it does not understand, is the whole file", ctx do
      %{conn: conn, viewer: viewer, page: page, version: version} = ctx
      token = token(viewer, page, version)

      assert response(fetch(conn, token, "clip.webm"), 200) == "0123456789abcdefghij"

      for odd <- ["items=0-3", "bytes=0-3,5-6", "bytes=abc", "bytes=-"] do
        sent = conn |> put_req_header("range", odd) |> fetch(token, "clip.webm")
        assert response(sent, 200) == "0123456789abcdefghij", odd
      end
    end

    test "an open-ended range gets at most 8 MiB, and says how much", ctx do
      %{conn: conn, viewer: viewer, ticket: ticket} = ctx
      big = :binary.copy("v", 9 * 1024 * 1024)

      {page, version} =
        published!({:ticket, ticket.id}, "video", %{"index.html" => "x", "big.mp4" => big})

      token = token(viewer, page, version)

      sent = conn |> put_req_header("range", "bytes=0-") |> fetch(token, "big.mp4")
      assert byte_size(response(sent, 206)) == 8 * 1024 * 1024
      assert get_resp_header(sent, "content-range") == ["bytes 0-8388607/#{byte_size(big)}"]

      tail = conn |> put_req_header("range", "bytes=8388608-") |> fetch(token, "big.mp4")
      assert byte_size(response(tail, 206)) == 1024 * 1024
      assert get_resp_header(tail, "content-range") == ["bytes 8388608-9437183/9437184"]
    end

    test "a large file with no range is sent whole, and nothing is left behind", ctx do
      %{conn: conn, viewer: viewer, ticket: ticket} = ctx
      big = :binary.copy("v", 9 * 1024 * 1024)

      {page, version} =
        published!({:ticket, ticket.id}, "video", %{"index.html" => "x", "big.mp4" => big})

      assert byte_size(response(fetch(conn, token(viewer, page, version), "big.mp4"), 200)) ==
               byte_size(big)
    end
  end
end
