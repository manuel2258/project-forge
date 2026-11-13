defmodule ForgeWeb.NotFoundTest do
  @moduledoc """
  The not-found page (`docs/design/ui.md` § Not found, `20c`): in the frame for a signed-in
  person, naming what was asked for with the two places worth going — and, for a project the
  viewer is not a member of, exactly the page a project that does not exist gets
  (`docs/design/identity.md` § Projects and members).
  """

  use ForgeWeb.ConnCase, async: true

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures

  setup %{conn: conn} do
    project = project_fixture()
    member = member_fixture(project)
    ticket_fixture(%{project: project, number: 7})
    %{conn: conn, project: project, member: member}
  end

  # A page that raised for a row it could not find: the endpoint renders the page and re-raises.
  defp miss(conn, path) do
    {404, _headers, body} = assert_error_sent(404, fn -> get(conn, path) end)
    LazyHTML.from_document(body)
  end

  # An address no route matches: rendered the same, and not raised.
  defp no_route(conn, path),
    do: conn |> get(path) |> html_response(404) |> LazyHTML.from_document()

  defp text(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.text() |> squish()
  defp squish(text), do: text |> String.split() |> Enum.join(" ")
  defp hrefs(doc), do: doc |> LazyHTML.query("#not-found-places a") |> LazyHTML.attribute("href")

  test "a member's missing ticket is named, with the range and the project to open", %{
    conn: conn,
    project: project,
    member: member
  } do
    doc = conn |> log_in_user(member) |> miss("/tickets/#{project.name}/99")

    assert text(doc, "#not-found-headline") == "#{project.name} has no ticket #99."
    assert text(doc, "#not-found-reasons") =~ "#{project.name}'s tickets run up to #7."
    assert hrefs(doc) == ["/projects/#{project.name}", "/"]

    # The frame stays: the top bar with its queue button, titled for what was missed.
    assert LazyHTML.query(doc, "#frame #top-bar") |> Enum.count() == 1
    assert LazyHTML.query(doc, "#top-bar a[href='/']") |> Enum.count() >= 1
    assert text(doc, "#title-row .frame-subline") == "#{project.name}#99"
  end

  # The guard: a non-member is told nothing a member is — not the range, not that the ticket is
  # there — and gets word for word what a project that does not exist gets.
  test "a non-member gets the same miss as a project that does not exist", %{
    conn: conn,
    project: project
  } do
    outsider = conn |> log_in_user(user_fixture())

    theirs = miss(outsider, "/tickets/#{project.name}/7")
    absent = miss(outsider, "/tickets/nosuch/7")

    assert text(theirs, "#not-found-headline") == "There is no project #{project.name}."
    refute text(theirs, "#not-found") =~ "#7"
    refute text(theirs, "#not-found") =~ "run up to"

    assert String.replace(text(theirs, "#not-found"), project.name, "nosuch") ==
             text(absent, "#not-found")

    assert hrefs(theirs) == hrefs(absent)
    assert LazyHTML.query(theirs, "#top-bar .ui-top-context") |> Enum.count() == 0

    # And the whole response, not only the part read above: the title, the title row and every
    # byte of the frame, once the name asked for is the same and the per-request CSRF token is
    # set aside.
    body = fn path ->
      {404, _headers, body} = assert_error_sent(404, fn -> get(outsider, path) end)
      Regex.replace(~r/<meta name="csrf-token" content="[^"]*"/, body, "")
    end

    assert String.replace(body.("/tickets/#{project.name}/7"), project.name, "nosuch") ==
             body.("/tickets/nosuch/7")
  end

  test "a page that raises for a project it cannot see renders the same page", %{
    conn: conn,
    project: project
  } do
    doc = conn |> log_in_user(user_fixture()) |> miss("/projects/#{project.name}")
    assert text(doc, "#not-found-headline") == "There is no project #{project.name}."
  end

  test "the removed board and review pages land here, and say where they went", %{
    conn: conn,
    project: project,
    member: member
  } do
    conn = log_in_user(conn, member)

    board = no_route(conn, "/board")
    assert text(board, "#not-found-headline") == "There is no board any more."
    assert hrefs(board) == ["/projects", "/"]

    review = no_route(conn, "/tickets/#{project.name}/7/review")
    assert text(review, "#not-found-headline") == "#{project.name}#7 has no review page."
    assert hrefs(review) == ["/tickets/#{project.name}/7?tab=changes", "/"]
  end

  test "signed out, it is the sign-in screens' page and tells nothing", %{project: project} do
    doc = no_route(build_conn(), "/no/such/page")

    assert LazyHTML.query(doc, "#sign-in #not-found") |> Enum.count() == 1
    assert LazyHTML.query(doc, "#frame") |> Enum.count() == 0
    assert hrefs(doc) == []
    refute LazyHTML.to_html(doc) =~ project.name
  end

  # Signed in by the remember-me cookie alone — the browser has dropped the session cookie — is
  # signed in here as on every other page: the cookie is read by `ForgeWeb.UserAuth` itself, not
  # by a second reading of the session that knows only one of the two (r2 L5).
  test "a remember-me cookie alone is signed in here too", %{conn: conn, member: member} do
    signed =
      conn
      |> Map.replace!(:secret_key_base, ForgeWeb.Endpoint.config(:secret_key_base))
      |> Plug.Test.init_test_session(%{})
      |> fetch_cookies()
      |> ForgeWeb.UserAuth.log_in_user(member, %{"remember_me" => "true"})

    %{value: cookie} = signed.resp_cookies["_forge_web_user_remember_me"]

    doc =
      build_conn()
      |> put_req_cookie("_forge_web_user_remember_me", cookie)
      |> no_route("/no/such/page")

    assert LazyHTML.query(doc, "#frame #top-bar") |> Enum.count() == 1
    assert LazyHTML.query(doc, "#sign-in") |> Enum.count() == 0
  end

  test "a pending account is not drawn the frame", %{project: project} do
    doc = build_conn() |> log_in_user(pending_user_fixture()) |> no_route("/no/such/page")

    assert LazyHTML.query(doc, "#frame") |> Enum.count() == 0
    refute LazyHTML.to_html(doc) =~ project.name
  end

  test "a template rendered alone is its status line" do
    assert Phoenix.Template.render_to_string(ForgeWeb.ErrorHTML, "500", "html", []) ==
             "Internal Server Error"
  end
end
