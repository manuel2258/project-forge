defmodule ForgeWeb.DocsPagesTest do
  @moduledoc """
  Where a page is drawn outside its own screen (`docs/design/ui.md` § Docs, § The ticket): one row
  under *Produced*, its files none, its earlier versions as downloads, its name text and cut; the
  count of the Docs tab; a chat's Docs; and *Open `<name>` ›* where a human state names one.
  """

  use ForgeWeb.ConnCase, async: false

  import Forge.ForgeFixtures, only: [job_fixture: 1, chat_fixture: 1, ticket_fixture: 1]
  import Forge.GitFixtures
  import ForgeWeb.PageDoorFixtures
  import Phoenix.LiveViewTest

  alias Forge.{Artifacts, Pages, Projects, Repo, Tickets}
  alias ForgeWeb.{PageViews, TicketViews}

  setup :register_and_log_in_user

  setup %{user: user} do
    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

    {:ok, project} =
      Projects.register(
        %{name: "pd-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
        user
      )

    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    %{project: project, ticket: ticket}
  end

  defp docs_path(project, ticket), do: "/tickets/#{project.name}/#{ticket.number}?tab=docs"

  defp page_path(project, ticket, name),
    do: "/tickets/#{project.name}/#{ticket.number}/pages/#{name}"

  describe "Docs" do
    test "a page is one row under Produced, and its files are none", ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx

      {:ok, _} =
        Artifacts.record_version(ticket.id, "plan.md", :document, :system, %{content: "# Plan\n"})

      {page, _v1} =
        published!({:ticket, ticket.id}, "form", %{"index.html" => "<p>1</p>", "app.js" => "1"})

      job = job_fixture(%{ticket: Tickets.get!(ticket.id), state: "implementing"})

      {:ok, v2} =
        Artifacts.record_version(
          {:ticket, ticket.id},
          "form/index.html",
          :blob,
          {:job, job.id},
          %{blob_uri: "store:x/y", content_hash: "sha256:" <> String.duplicate("1", 64)}
        )

      Repo.insert!(%Pages.Version{
        page_id: page.id,
        version: 2,
        job_id: job.id,
        files: %{"index.html" => v2.id}
      })

      {:ok, view, _html} = live(conn, docs_path(project, ticket))

      # The row: the page's tile, its name cut with the whole of it in the title, who wrote it and
      # which version, opening the page — a link, so a full page load.
      assert has_element?(view, ~s(#docs section[id="doc-form"] [data-file-type="page"]))
      assert has_element?(view, ~s(#docs section[id="doc-form"] .work-doc-name-cut[title="form"]))

      assert has_element?(
               view,
               ~s(#docs section[id="doc-form"] a[href="#{page_path(project, ticket, "form")}"]),
               "v2"
             )

      assert has_element?(view, ~s(#docs section[id="doc-form"]), "agent · implementing")
      assert has_element?(view, ~s(#docs #docs-produced section[id="doc-form"]))

      # Its files are not rows, and not in the count of the tab.
      refute has_element?(view, ~s(#docs section[id="doc-form/index.html"]))
      refute has_element?(view, ~s(#docs section[id="doc-form/app.js"]))
      assert has_element?(view, ~s(#docs section[id="doc-plan.md"]))

      # An earlier version folds under the row as a link that downloads its file.
      assert has_element?(
               view,
               ~s(#docs section[id="doc-form"] .work-doc-earlier[href$="/artifacts/form%2Findex.html/1"])
             )
    end

    test "an earlier version lists its other files as downloads, each as the version it holds",
         ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx

      {page, v1} =
        published!({:ticket, ticket.id}, "gallery", %{
          "index.html" => "<p>1</p>",
          "app.js" => "one"
        })

      {:ok, html2} =
        Artifacts.record_version(
          {:ticket, ticket.id},
          "gallery/index.html",
          :blob,
          {:user, Ecto.UUID.generate()},
          %{blob_uri: "store:x/z", content_hash: "sha256:" <> String.duplicate("2", 64)}
        )

      # The second version changed `index.html` and kept the first's `app.js`.
      Repo.insert!(%Pages.Version{
        page_id: page.id,
        version: 2,
        files: %{"index.html" => html2.id, "app.js" => v1.files["app.js"]}
      })

      {:ok, view, _html} = live(conn, docs_path(project, ticket))
      row = ~s(#docs section[id="doc-gallery"])

      assert has_element?(
               view,
               ~s(#{row} .work-doc-earlier[href$="/artifacts/gallery%2Findex.html/1"])
             )

      assert has_element?(
               view,
               ~s(#{row} a.work-doc-earlier-file[href$="/artifacts/gallery%2Fapp.js/1"]),
               "app.js"
             )

      # `index.html` is the row's own link, not listed twice.
      refute has_element?(view, ~s(#{row} a.work-doc-earlier-file), "index.html")
    end

    test "the Docs count counts a page once and its files not at all", ctx do
      %{project: project, ticket: ticket} = ctx

      count = fn ->
        project
        |> TicketViews.strip_of(Tickets.get!(ticket.id), nil)
        |> Enum.find(&(&1.key == "docs"))
        |> Map.fetch!(:count)
      end

      {:ok, _} =
        Artifacts.record_version(ticket.id, "plan.md", :document, :system, %{content: "# Plan\n"})

      before = count.()

      published!({:ticket, ticket.id}, "form", %{
        "index.html" => "<p>1</p>",
        "app.js" => "1",
        "clip.webm" => "v"
      })

      assert count.() == before + 1
    end

    test "a page name is text, never markup", %{conn: conn, project: project, ticket: ticket} do
      hostile = "<img src=x onerror=alert(1)>"
      published!({:ticket, ticket.id}, hostile)

      {:ok, view, html} = live(conn, docs_path(project, ticket))

      refute html =~ "<img src=x"
      assert has_element?(view, "#docs .work-doc-name-cut", hostile)
    end

    test "a page with no version has no row", %{conn: conn, project: project, ticket: ticket} do
      {:ok, _page} = Pages.ensure({:ticket, ticket.id}, "unpublished")
      {:ok, view, _html} = live(conn, docs_path(project, ticket))
      refute has_element?(view, ~s(section[id="doc-unpublished"]))
    end

    test "a project chat's Docs has its own pages, and a ticket's are not its", ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx
      chat = chat_fixture(%{project: Projects.get!(project.id)})
      published!({:chat, chat.id}, "notes", %{"index.html" => "<p>n</p>"})
      published!({:ticket, ticket.id}, "form")

      {:ok, view, _html} = live(conn, "/chats/#{chat.id}?tab=docs")

      assert has_element?(
               view,
               ~s(section[id="doc-notes"] a[href="/chats/#{chat.id}/pages/notes"])
             )

      refute has_element?(view, ~s(section[id="doc-form"]))
      refute has_element?(view, ~s(section[id="doc-notes/index.html"]))
    end
  end

  describe "PageViews" do
    test "a file of a page is told from a group's by the pages the scope has", %{ticket: ticket} do
      published!({:ticket, ticket.id}, "form")
      names = PageViews.names({:ticket, ticket.id})

      assert PageViews.member?(names, "form/index.html")
      refute PageViews.member?(names, "package/app.apk")
      refute PageViews.member?(names, "form")
      refute PageViews.member?(names, "formal/index.html")
    end

    test "opens is a link with a version, and none without", %{project: project, ticket: ticket} do
      where = %{project: project, ticket: ticket, chat: nil}
      assert PageViews.opens(where, nil) == nil
      assert PageViews.opens(where, "form") == %{name: "form", href: nil}

      {:ok, _page} = Pages.ensure({:ticket, ticket.id}, "form")
      assert PageViews.opens(where, "form") == %{name: "form", href: nil}

      published!({:ticket, ticket.id}, "form")

      assert PageViews.opens(where, "form") == %{
               name: "form",
               href: page_path(project, ticket, "form")
             }
    end
  end

  # A human state that names a page to open (`docs/design/workflow-grammar-v1.md` § Semantics).
  @opens_workflow """
  version: 1
  initial: drafting
  states:
    drafting:
      prompt: agents/draft.md
      produces: [form@]
      budget: { turns: 10, tokens: 200k }
    filling:
      opens: form
    finished: {}
  transitions:
    - { from: drafting, to: filling }
    - { from: filling, to: finished }
  limits:
    ticket_tokens: 5M
  """

  describe "Open <name> ›" do
    setup %{project: project} do
      {:ok, workflow} = YamlElixir.read_from_string(@opens_workflow)
      ticket = ticket_fixture(%{project: project, workflow: workflow, state: "filling"})
      %{waiting: ticket}
    end

    test "leads the ticket page of a human state that names a page, as a link", ctx do
      %{conn: conn, project: project, waiting: ticket} = ctx
      published!({:ticket, ticket.id}, "form")

      {:ok, view, _html} = live(conn, "/tickets/#{project.name}/#{ticket.number}")

      assert has_element?(
               view,
               ~s(#open-page a#open-page-link[href="#{page_path(project, ticket, "form")}"]),
               "Open form"
             )

      refute has_element?(view, "#open-page-link[disabled]")
    end

    test "says there is no version yet until there is one, and is not a link", ctx do
      %{conn: conn, project: project, waiting: ticket} = ctx

      {:ok, view, _html} = live(conn, "/tickets/#{project.name}/#{ticket.number}")

      assert has_element?(view, "#open-page button#open-page-link[disabled]", "no version yet")
      refute has_element?(view, "#open-page a")
    end

    test "leads the queue item's dock, as a link and not a decision", ctx do
      %{conn: conn, waiting: ticket} = ctx
      published!({:ticket, ticket.id}, "form")

      {:ok, queue, _html} = live(conn, "/")

      assert has_element?(
               queue,
               ~s(#queue-dock a#queue-open-page[href="#{page_path(ctx.project, ticket, "form")}"]),
               "Open form"
             )

      # Not twice: the page that leads is not also one of the others.
      refute has_element?(queue, "#queue-page-0")
    end

    test "is not drawn for a state that names none, nor once the ticket has left the state",
         ctx do
      %{conn: conn, project: project, waiting: ticket} = ctx
      published!({:ticket, ticket.id}, "form")

      {:ok, other} = YamlElixir.read_from_string(@opens_workflow)
      plain = ticket_fixture(%{project: project, workflow: other, state: "drafting"})
      {:ok, view, _html} = live(conn, "/tickets/#{project.name}/#{plain.number}")
      refute has_element?(view, "#open-page")

      ticket |> Ecto.Changeset.change(status: :done) |> Repo.update!()
      {:ok, view, _html} = live(conn, "/tickets/#{project.name}/#{ticket.number}")
      refute has_element?(view, "#open-page")
    end
  end
end
