defmodule ForgeWeb.ForgePageLiveTest do
  @moduledoc """
  A page an agent wrote, inside forge's own bar (`docs/design/ui.md` § Pages, `docs/design/pages.md`
  § What a person's page does).

  What is asserted here is what the server decides: who reaches a page, what the frame is given,
  how the person's writes are taken, deduplicated and refused, and what is told to the frame of
  other people's changes and of a ticket that closes. The sandbox itself, and a hostile page's
  attempts, are the browser's and are tried there (`test/forge/look/sandbox_pages_browser_test.exs`).
  """

  use ForgeWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Forge.ForgeFixtures
  import Phoenix.LiveViewTest
  import ForgeWeb.PageDoorFixtures

  alias Forge.{Pages, Repo}
  alias ForgeWeb.{PageLive, PageToken}

  setup :register_and_log_in_user

  setup %{user: user} do
    original = Application.get_env(:forge, Forge.Storage, [])

    dir =
      Path.join(
        System.tmp_dir!(),
        "#{System.pid()}-page-live-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:forge, Forge.Storage, Keyword.put(original, :dir, dir))
    limits = Application.get_env(:forge, Forge.Pages, [])

    on_exit(fn ->
      Application.put_env(:forge, Forge.Storage, original)
      Application.put_env(:forge, Forge.Pages, limits)
      File.rm_rf!(dir)
    end)

    project = project_fixture() |> join!(user)
    ticket = ticket_fixture(%{project: project, number: 1})
    {page, version} = published!({:ticket, ticket.id}, "form")

    %{
      project: project,
      ticket: ticket,
      page: page,
      version: version,
      stranger: Forge.AccountsFixtures.user_fixture()
    }
  end

  defp page_path(project, ticket, name \\ "form"),
    do: "/tickets/#{project.name}/#{ticket.number}/pages/#{name}"

  defp batch(view, seq, ops, client \\ "c1"),
    do: render_hook(view, "page:batch", %{"client" => client, "seq" => seq, "ops" => ops})

  defp set(key, value), do: %{"op" => "set", "key" => key, "value" => value}

  describe "the frame and its bar" do
    test "the page opens in a sandboxed frame under a signed path, and says who wrote it", ctx do
      %{conn: conn, user: user, project: project, ticket: ticket, page: page} = ctx
      job = job_fixture(%{ticket: ticket, state: "implementing"})
      Repo.insert!(%Pages.Version{page_id: page.id, version: 2, files: %{}, job_id: job.id})

      {:ok, view, html} = live(conn, page_path(project, ticket))

      assert has_element?(view, "#page-name[title=form]", "form")
      assert html =~ "written by an agent in implementing · v2"

      # The one attribute that keeps a page's script out of forge's session: never `allow-same-origin`.
      assert has_element?(view, ~s(iframe#page-frame[sandbox="allow-scripts"]))

      assert has_element?(
               view,
               ~s(iframe#page-frame[referrerpolicy="no-referrer"][allowfullscreen])
             )

      refute html =~ "allow-same-origin"

      [src] = html |> Floki.parse_document!() |> Floki.attribute("iframe#page-frame", "src")
      assert ["", "page-files", token, "index.html"] = String.split(src, "/")
      assert {:ok, %{user: user_id, page: page_id, version: 2}} = PageToken.verify(token)
      assert {user_id, page_id} == {user.id, page.id}
    end

    test "the save state is drawn by the hook in an element the server never patches", ctx do
      {:ok, view, _html} = live(ctx.conn, page_path(ctx.project, ctx.ticket))

      assert has_element?(view, ~s(#page-save[phx-update=ignore][data-page-save]), "saved")
      assert has_element?(view, ~s(#page-frame-box[phx-update=ignore] iframe))
      assert has_element?(view, ~s(#page-view[phx-hook=PageFrame]))
    end

    test "a project chat's page says it was written in a chat, and a long name is cut with its title",
         %{conn: conn, project: project} do
      chat = chat_fixture(%{project: project})
      name = String.duplicate("long-", 30) <> "name"
      {page, _version} = published!({:chat, chat.id}, name)
      Repo.insert!(%Pages.Version{page_id: page.id, version: 2, files: %{}, job_id: chat.id})

      {:ok, view, html} = live(conn, "/chats/#{chat.id}/pages/#{name}")

      assert has_element?(view, ~s(#page-name[title="#{name}"]))
      assert html =~ "written in a chat · v2"
      assert has_element?(view, ~s(a.pg-back[href="/chats/#{chat.id}"]))
    end

    test "a page's name is text, never markup", %{conn: conn, project: project, ticket: ticket} do
      hostile = "<img src=x onerror=alert(1)>"
      published!({:ticket, ticket.id}, hostile)

      {:ok, view, html} =
        live(conn, page_path(project, ticket, URI.encode(hostile, &URI.char_unreserved?/1)))

      refute html =~ "<img src=x"
      assert has_element?(view, "#page-name", hostile)
    end
  end

  describe "who reaches a page" do
    test "a page of another project, a page with no version and one that does not exist are not found",
         %{conn: conn, project: project, ticket: ticket} do
      other = project_fixture()
      other_ticket = ticket_fixture(%{project: other, number: 1})
      published!({:ticket, other_ticket.id}, "form")

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, page_path(other, other_ticket))
      end

      {:ok, _page} = Pages.ensure({:ticket, ticket.id}, "unpublished")

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, page_path(project, ticket, "unpublished"))
      end

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, page_path(project, ticket, "nothing"))
      end
    end

    test "a ticket chat opens its ticket's page", %{conn: conn, project: project, ticket: ticket} do
      chat = chat_fixture(%{project: project, ticket_id: ticket.id})
      assert {:ok, view, _html} = live(conn, "/chats/#{chat.id}/pages/form")
      assert has_element?(view, "#page-name", "form")
    end
  end

  describe "what the frame asks" do
    test "hello says who is viewing and whether the page is read only", ctx do
      {:ok, view, _html} = live(ctx.conn, page_path(ctx.project, ctx.ticket))

      render_hook(view, "page:hello", %{})
      assert_reply(view, %{viewer: viewer, readOnly: false, reason: nil})
      assert viewer == ctx.user.email
    end

    test "get and all read the store of this page, and no other", ctx do
      {:ok, other} = Pages.ensure({:ticket, ctx.ticket.id}, "other")
      {:ok, _} = Pages.put(ctx.page, "name", "Ada", {:user, ctx.user.id})
      {:ok, _} = Pages.put(other, "name", "Grace", {:user, ctx.user.id})

      {:ok, view, _html} = live(ctx.conn, page_path(ctx.project, ctx.ticket))

      render_hook(view, "page:get", %{"key" => "name"})
      assert_reply(view, %{value: "Ada", counter: counter})
      assert is_integer(counter)

      render_hook(view, "page:get", %{"key" => "absent"})
      assert_reply(view, %{value: nil, counter: nil})

      render_hook(view, "page:all", %{})
      assert_reply(view, %{entries: %{"name" => %{value: "Ada"}} = entries})
      assert map_size(entries) == 1
    end

    test "a batch is saved as the viewer, and a value is never drawn", ctx do
      {:ok, view, _html} = live(ctx.conn, page_path(ctx.project, ctx.ticket))

      html = batch(view, 1, [set("hero", "<b>Ada</b>"), set("n", 3)])
      assert_reply(view, %{results: [%{ok: true, counter: c1}, %{ok: true, counter: c2}]})
      assert c2 > c1

      entry = Pages.entry(ctx.page, "hero")
      assert entry.value == "<b>Ada</b>"
      assert entry.user_id == ctx.user.id
      refute html =~ "<b>Ada</b>"
      refute render(view) =~ "Ada"
    end

    test "a batch sent again is acknowledged and not applied twice", ctx do
      {:ok, view, _html} = live(ctx.conn, page_path(ctx.project, ctx.ticket))

      batch(view, 1, [set("k", "mine")])
      assert_reply(view, %{results: [%{ok: true}]})

      # Somebody else writes while the reply was lost; the rejoin sends the same batch again.
      {:ok, _} = Pages.put(ctx.page, "k", "theirs", {:user, ctx.stranger.id}, counter: :any)

      batch(view, 1, [set("k", "mine")])
      assert_reply(view, %{duplicate: true})
      assert Pages.entry(ctx.page, "k").value == "theirs"

      # Another client's batch of the same number is its own, and a later number is new.
      batch(view, 1, [set("k", "other client")], "c2")
      assert_reply(view, %{results: [%{ok: true}]})
      batch(view, 2, [set("k", "later")])
      assert_reply(view, %{results: [%{ok: true}]})
      assert Pages.entry(ctx.page, "k").value == "later"
    end

    test "a delete removes the key, and deleting an absent one is not an error", ctx do
      {:ok, _} = Pages.put(ctx.page, "gone", 1, {:user, ctx.user.id})
      {:ok, view, _html} = live(ctx.conn, page_path(ctx.project, ctx.ticket))

      batch(view, 1, [%{"op" => "delete", "key" => "gone"}, %{"op" => "delete", "key" => "never"}])

      assert_reply(view, %{results: [%{ok: true}, %{ok: true}]})
      assert Pages.entry(ctx.page, "gone") == nil
    end

    test "a refused write says why, and the rest of the batch is still taken", ctx do
      Application.put_env(
        :forge,
        Forge.Pages,
        Keyword.put(Application.get_env(:forge, Forge.Pages, []), :value_bytes, 10)
      )

      {:ok, view, _html} = live(ctx.conn, page_path(ctx.project, ctx.ticket))

      batch(view, 1, [set("big", String.duplicate("x", 50)), set("small", "ok")])

      assert_reply(view, %{
        results: [%{ok: false, reason: "limit reached", limit: "value: 10 at most"}, %{ok: true}]
      })

      assert Pages.entry(ctx.page, "big") == nil
      assert Pages.entry(ctx.page, "small").value == "ok"
    end

    test "an operation that is not one is refused and does not crash the page", ctx do
      {:ok, view, _html} = live(ctx.conn, page_path(ctx.project, ctx.ticket))

      batch(view, 1, [%{"op" => "drop", "key" => "x"}, %{"op" => "set"}, "nonsense", set("ok", 1)])

      assert_reply(view, %{
        results: [%{ok: false}, %{ok: false}, %{ok: false}, %{ok: true}]
      })

      assert Process.alive?(view.pid)
      render_hook(view, "page:batch", %{"nonsense" => true})
      assert_reply(view, %{results: []})
    end

    test "a member who has been removed since the page opened writes nothing", ctx do
      {:ok, view, _html} = live(ctx.conn, page_path(ctx.project, ctx.ticket))
      Repo.delete_all(from(m in Forge.Projects.Member, where: m.user_id == ^ctx.user.id))

      batch(view, 1, [set("k", "v")])
      assert_reply(view, %{results: [%{ok: false}]})
      assert Pages.entry(ctx.page, "k") == nil
    end
  end

  describe "what the frame is told" do
    test "another writer's change reaches it, with a delete as one", ctx do
      {:ok, view, _html} = live(ctx.conn, page_path(ctx.project, ctx.ticket))
      other = ctx.stranger.id

      {:ok, _} = Pages.put(ctx.page, "k", %{"a" => 1}, {:user, other})

      assert_push_event(view, "page:changed", %{
        key: "k",
        value: %{"a" => 1},
        deleted: false,
        counter: c
      })

      {:ok, _} = Pages.delete(ctx.page, "k", {:user, other})
      assert_push_event(view, "page:changed", %{key: "k", deleted: true, counter: c2})
      assert c2 > c
    end

    test "the viewer's own write is not told back to the frame that made it, a second tab's is",
         ctx do
      {:ok, view, _html} = live(ctx.conn, page_path(ctx.project, ctx.ticket))

      batch(view, 1, [set("mine", 1)])
      assert_reply(view, %{results: [%{ok: true}]})
      render(view)
      refute_push_event(view, "page:changed", %{key: "mine"}, 50)

      # The same person, elsewhere: this view did not make it, so its frame is told.
      {:ok, _} = Pages.put(ctx.page, "mine", 2, {:user, ctx.user.id})
      assert_push_event(view, "page:changed", %{key: "mine", value: 2})
    end

    test "a change to another page is not told", ctx do
      {:ok, other} = Pages.ensure({:ticket, ctx.ticket.id}, "other")
      {:ok, view, _html} = live(ctx.conn, page_path(ctx.project, ctx.ticket))

      {:ok, _} = Pages.put(other, "k", 1, {:user, ctx.stranger.id})
      render(view)
      refute_push_event(view, "page:changed", %{key: "k"}, 50)
    end

    test "a newer version is offered in the bar and nothing reloads under the person", ctx do
      {:ok, view, _html} = live(ctx.conn, page_path(ctx.project, ctx.ticket))
      refute has_element?(view, "#page-newer")

      Repo.insert!(%Pages.Version{page_id: ctx.page.id, version: 2, files: %{}})

      Phoenix.PubSub.broadcast(
        Forge.PubSub,
        Pages.topic(ctx.page.id),
        {:page_published, ctx.page.id, 2}
      )

      assert render(view) =~ "newer version · reload"
      assert has_element?(view, ~s(#page-newer[href="#{page_path(ctx.project, ctx.ticket)}"]))
      assert has_element?(view, ~s(iframe#page-frame))
    end
  end

  describe "a page that is read only" do
    test "a done ticket's page says why, tells the script, and refuses a save", ctx do
      ctx.ticket |> Ecto.Changeset.change(status: :done) |> Repo.update!()
      {:ok, view, html} = live(ctx.conn, page_path(ctx.project, ctx.ticket))

      assert html =~ "read only · the ticket is done"

      render_hook(view, "page:hello", %{})
      assert_reply(view, %{readOnly: true, reason: "the ticket is done"})

      batch(view, 1, [set("k", "v")])
      assert_reply(view, %{results: [%{ok: false, reason: "read only: the ticket is done"}]})
      assert Pages.entry(ctx.page, "k") == nil
    end

    test "a ticket that closes while the page is open, and one a jump reopens, are told", ctx do
      {:ok, view, html} = live(ctx.conn, page_path(ctx.project, ctx.ticket))
      refute html =~ "read only"

      ctx.ticket |> Ecto.Changeset.change(status: :cancelled) |> Repo.update!()
      send(view.pid, {:ticket_changed, ctx.ticket.id})

      assert_push_event(view, "page:readonly", %{
        readOnly: true,
        reason: "the ticket was cancelled"
      })

      assert render(view) =~ "read only · the ticket was cancelled"

      ctx.ticket |> Repo.reload!() |> Ecto.Changeset.change(status: :active) |> Repo.update!()
      send(view.pid, {:ticket_changed, ctx.ticket.id})
      assert_push_event(view, "page:readonly", %{readOnly: false})
      refute render(view) =~ "read only"
    end

    test "another ticket's change is not even read", ctx do
      {:ok, view, _html} = live(ctx.conn, page_path(ctx.project, ctx.ticket))

      ctx.ticket |> Ecto.Changeset.change(status: :cancelled) |> Repo.update!()
      send(view.pid, {:ticket_changed, Ecto.UUID.generate()})
      render(view)
      refute_push_event(view, "page:readonly", %{}, 50)
    end

    test "an ended project chat's page is read only", %{conn: conn, project: project} do
      chat = chat_fixture(%{project: project})
      published!({:chat, chat.id}, "notes")

      Repo.insert!(%Forge.Events.Event{
        actor: %{"kind" => "system", "id" => nil},
        type: "chat.ended",
        payload: %{"reason" => "closed"},
        job_id: chat.id,
        project_id: chat.project_id
      })

      assert Forge.Conversations.ended?(chat.id)
      {:ok, _view, html} = live(conn, "/chats/#{chat.id}/pages/notes")
      assert html =~ "read only · the chat has ended"
    end
  end

  describe "the frame's signed address" do
    test "is signed again for a reload, never reused", ctx do
      {:ok, view, _html} = live(ctx.conn, page_path(ctx.project, ctx.ticket))

      send(view.pid, :refresh_frame)
      assert_push_event(view, "page:refresh", %{src: first})
      assert signed_for?(first, ctx)

      # A token carries when it was signed, so each is a new address and none is the one before
      # (the rendered one cannot be compared: the client keeps the frame's first markup).
      Process.sleep(20)
      send(view.pid, :refresh_frame)
      assert_push_event(view, "page:refresh", %{src: second})
      assert signed_for?(second, ctx)
      refute second == first

      # A token signed for another viewer or another version is not this page's.
      stranger = Forge.AccountsFixtures.user_fixture()
      other = ForgeWeb.PageToken.sign(stranger.id, ctx.page.id, ctx.version.version)
      refute signed_for?("/page-files/#{other}/index.html", ctx)
    end

    test "is asked for by the view itself, well inside the token's life", ctx do
      assert PageLive.refresh_ms() < ForgeWeb.PageToken.max_age() * 1000

      original = Application.get_env(:forge, :page_refresh_ms)
      Application.put_env(:forge, :page_refresh_ms, 30)

      on_exit(fn ->
        if original,
          do: Application.put_env(:forge, :page_refresh_ms, original),
          else: Application.delete_env(:forge, :page_refresh_ms)
      end)

      {:ok, view, _html} = live(ctx.conn, page_path(ctx.project, ctx.ticket))
      assert_push_event(view, "page:refresh", %{src: src}, 2_000)
      assert signed_for?(src, ctx)
    end
  end

  # The address names the viewer, the page and the version the view is on.
  defp signed_for?("/page-files/" <> rest, ctx) do
    [token, "index.html"] = String.split(rest, "/", parts: 2)
    expected = %{user: ctx.user.id, page: ctx.page.id, version: ctx.version.version}
    ForgeWeb.PageToken.verify(token) == {:ok, expected}
  end

  describe "outside addresses" do
    test "start off, switch on for the viewer alone, and tell the frame to load again", ctx do
      {:ok, view, _html} = live(ctx.conn, page_path(ctx.project, ctx.ticket))
      assert has_element?(view, ~s(#page-outside[aria-pressed=false]), "off")

      Process.sleep(20)
      view |> element("#page-outside") |> render_click()

      assert_push_event(view, "page:reload", %{src: src})
      assert signed_for?(src, ctx)
      assert has_element?(view, ~s(#page-outside[aria-pressed=true]), "on")
      assert Pages.outside?(ctx.user.id, ctx.page.id)

      # Another viewer of the same page starts with it off.
      other = Forge.AccountsFixtures.user_fixture()
      join!(ctx.project, other)
      refute Pages.outside?(other.id, ctx.page.id)

      {:ok, other_view, _html} =
        live(log_in_user(build_conn(), other), page_path(ctx.project, ctx.ticket))

      assert has_element?(other_view, ~s(#page-outside[aria-pressed=false]))

      Process.sleep(20)
      view |> element("#page-outside") |> render_click()
      assert_push_event(view, "page:reload", %{src: again})
      refute again == src
      refute Pages.outside?(ctx.user.id, ctx.page.id)
    end
  end
end
