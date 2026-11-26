defmodule ForgeWeb.TicketTextLiveTest do
  @moduledoc """
  The ticket's text on Steps (`docs/design/ui.md` § Steps, § Documents; ticket 80): the latest
  `ticket` version drawn as Markdown, resolved in the ticket's own scope, whole, with single
  newlines kept and its files from the same version. What a browser does with the cut is
  `Forge.Look.BrowserTest`'s; this is what the server sends.
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.GitFixtures

  alias Forge.{Attachments, Operator, Projects, Tickets}

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, project} =
      Projects.register(
        %{name: "txt-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
        user
      )

    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

    %{project: project}
  end

  defp batch(project, user, names) do
    uploads =
      for name <- names do
        path = Path.join(tmp_dir("src"), "#{System.unique_integer([:positive])}")
        File.write!(path, "bytes")
        {:ok, upload} = Attachments.stage(project, user, {:file, path}, name)
        %{id: upload.id, name: name}
      end

    %Attachments.Batch{uploads: uploads}
  end

  defp admit!(project, user, body, files \\ []) do
    {:ok, ticket} =
      Operator.admit(project, user, %{
        title: "Bug",
        body: body,
        on_hold: false,
        attachments: batch(project, user, files)
      })

    Tickets.get!(ticket.id)
  end

  defp steps(conn, project, ticket) do
    {:ok, view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=steps")
    {view, html}
  end

  describe "the text, as Markdown" do
    test "draws a list and a heading and no source", %{conn: conn, project: project, user: user} do
      ticket = admit!(project, user, "## Steps\n\n- one\n- two\n")
      {view, html} = steps(conn, project, ticket)

      assert has_element?(view, "#ticket-text .doc li", "one")
      assert has_element?(view, "#ticket-text .doc h2", "Steps")
      refute html =~ "- one"
    end

    test "draws an attached picture from the ticket's own scope", %{
      conn: conn,
      project: project,
      user: user
    } do
      ticket = admit!(project, user, "![the shot](attachments/shot.png)", ["shot.png"])
      {view, _html} = steps(conn, project, ticket)

      src = "/tickets/#{project.name}/#{ticket.number}/artifacts/attachments%2Fshot.png/1"
      assert has_element?(view, ~s(#ticket-text img[src="#{src}"][loading=lazy]))
    end

    test "never draws a remote, data, protocol-relative or app path as a picture, nor markup", %{
      conn: conn,
      project: project,
      user: user
    } do
      body = """
      <script>alert(1)</script>

      ![a](https://evil.example/a.png)

      ![b](//evil.example/b.png)

      ![c](data:image/png;base64,AAAA)

      ![d](/oidc/x)
      """

      ticket = admit!(project, user, body)
      {view, html} = steps(conn, project, ticket)

      refute has_element?(view, "#ticket-text img")
      assert has_element?(view, "#ticket-text .ref-note")
      refute html =~ "<script>alert(1)"
      refute html =~ ~s(src="https://evil.example)
      refute html =~ ~s(src="//evil.example)
      refute html =~ ~s(src="data:)
    end

    test "resolves another ticket of the same project by archive/<n>/", %{
      conn: conn,
      project: project,
      user: user
    } do
      other = admit!(project, user, "x", ["x.png"])
      ticket = admit!(project, user, "![x](archive/#{other.number}/attachments/x.png)")
      {view, _html} = steps(conn, project, ticket)

      src = "/tickets/#{project.name}/#{other.number}/artifacts/attachments%2Fx.png/1"
      assert has_element?(view, ~s(#ticket-text img[src="#{src}"]))
    end

    test "is drawn as Docs draws the same row", %{conn: conn, project: project, user: user} do
      ticket = admit!(project, user, "Some *text*\nover two lines\n\n- a\n- b", ["a.png"])
      {steps, _html} = steps(conn, project, ticket)
      {:ok, docs, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=docs")

      inner = fn view, selector ->
        view |> element(selector) |> render() |> Floki.parse_fragment!() |> Floki.raw_html()
      end

      assert inner.(steps, "#ticket-text .doc") == inner.(docs, "#doc-ticket .doc")
    end
  end

  describe "which version" do
    test "is the latest, with the files that came with that version", %{
      conn: conn,
      project: project,
      user: user
    } do
      ticket = admit!(project, user, "First text", ["a.png"])

      {:ok, _} =
        Operator.edit(ticket, user, "ticket", "# Bug\n\nSecond text", nil,
          attachments: batch(project, user, ["b.png"])
        )

      {view, html} = steps(conn, project, ticket)

      assert has_element?(view, "#ticket-text", "Second text")
      refute html =~ "First text"
      assert has_element?(view, "#steps [data-attached]", "b.png")
      refute has_element?(view, "#steps [data-attached]", "a.png")

      # Docs names the files of the same version for its `ticket` row.
      {:ok, docs, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=docs")
      assert has_element?(docs, "#doc-ticket [data-attached]", "b.png")
      refute has_element?(docs, "#doc-ticket [data-attached]", "a.png")
    end

    test "a new version written while the page is open is drawn", %{
      conn: conn,
      project: project,
      user: user
    } do
      ticket = admit!(project, user, "First text")
      {view, _html} = steps(conn, project, ticket)
      assert has_element?(view, "#ticket-text", "First text")

      {:ok, _} = Operator.edit(ticket, user, "ticket", "# Bug\n\nSecond text")
      # A write is told to the page by the ticket's topic.
      assert render(view) =~ "Second text"
    end
  end

  describe "the whole text" do
    test "keeps its title line, which is the page's heading as well", %{
      conn: conn,
      project: project,
      user: user
    } do
      ticket = admit!(project, user, "Body here.")
      {view, _html} = steps(conn, project, ticket)

      assert has_element?(view, "#ticket-text h1", "Bug")
      assert has_element?(view, "#ticket-text", "Body here.")
    end

    test "with no body is drawn as no text, and its files are still named", %{
      conn: conn,
      project: project,
      user: user
    } do
      ticket = admit!(project, user, "", ["a.png"])
      {view, _html} = steps(conn, project, ticket)

      refute has_element?(view, "#ticket-text")
      assert has_element?(view, "#steps [data-attached]", "a.png")
    end

    test "that is only front matter is drawn as no text", %{
      conn: conn,
      project: project,
      user: user
    } do
      ticket = admit!(project, user, "Some text")
      {:ok, _} = Operator.edit(ticket, user, "ticket", "---\nx: 1\n---\n")
      {view, _html} = steps(conn, project, ticket)

      refute has_element?(view, "#ticket-text")
    end

    test "with a second heading is not title-only", %{conn: conn, project: project, user: user} do
      ticket = admit!(project, user, "# Another\n")
      {view, _html} = steps(conn, project, ticket)
      assert has_element?(view, "#ticket-text h1", "Another")
    end

    test "keeps a single newline as a break, here and on Docs, and no other document does", %{
      conn: conn,
      project: project,
      user: user
    } do
      ticket = admit!(project, user, "first line\nsecond line")
      {:ok, _} = Operator.edit(ticket, user, "refinement.md", "one\ntwo")

      {view, _html} = steps(conn, project, ticket)
      assert render(element(view, "#ticket-text .doc.msg p")) =~ "first line\nsecond line"

      {:ok, docs, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=docs")
      assert has_element?(docs, "#doc-ticket .doc.msg")
      assert has_element?(docs, ~s(section[id="doc-refinement.md"] .doc))
      refute has_element?(docs, ~s(section[id="doc-refinement.md"] .msg))
    end
  end

  describe "the cut" do
    test "is the browser's: the server draws it cut, with the hook, and never open or long", %{
      conn: conn,
      project: project,
      user: user
    } do
      ticket = admit!(project, user, String.duplicate("a line\n\n", 40))
      {view, html} = steps(conn, project, ticket)

      assert has_element?(view, "#ticket-text[phx-hook]")
      assert html =~ "Show the whole text"
      assert html =~ "Show less"
      refute has_element?(view, "#ticket-text[data-open]")
      refute has_element?(view, "#ticket-text[data-long]")
    end
  end
end
