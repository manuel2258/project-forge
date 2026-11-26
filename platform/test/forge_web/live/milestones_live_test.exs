defmodule ForgeWeb.MilestonesLiveTest do
  @moduledoc """
  The Milestones view, the Tickets list's *On hold* and the ticket page's band
  (`docs/design/ui.md` § Milestones): what a member does there, what is refused and where it is
  said, and that what a person wrote is shown as text.
  """

  use ForgeWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Forge.GitFixtures

  alias Forge.{Engine, Milestones, Operator, Projects, Repo, Tickets}

  setup :register_and_log_in_user

  setup %{user: user} do
    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

    {:ok, project} =
      Projects.register(
        %{name: "ml-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
        user
      )

    %{project: project}
  end

  defp held!(project, user, title \\ "An idea", opts \\ []) do
    {:ok, ticket} =
      Operator.admit(project, user, Map.merge(%{title: title, on_hold: true}, Map.new(opts)))

    ticket
  end

  defp create_milestone!(project, user, name) do
    {:ok, milestone} = Operator.create_milestone(project, user, %{name: name})
    milestone
  end

  defp view_url(project), do: ~p"/projects/#{project.name}?view=milestones"

  describe "the view" do
    test "a project with no milestones says what one is for and offers to create one", ctx do
      %{conn: conn, project: project, user: user} = ctx
      held!(project, user, "Loose idea")
      {:ok, view, _html} = live(conn, view_url(project))

      assert has_element?(view, "#milestones-none", "named goal")
      assert has_element?(view, "#milestone-create")
      assert has_element?(view, "#ms-rows-none", "Loose idea")

      view |> form("#milestone-create", %{"name" => "0.4 saves"}) |> render_submit()

      assert has_element?(view, "article.ms-card .ms-name", "0.4 saves")
      refute has_element?(view, "#milestones-none")
      assert has_element?(view, "#milestones-no-current", "Make current")
    end

    test "marking one current puts it first and says which", ctx do
      %{conn: conn, project: project, user: user} = ctx
      {:ok, _a} = Operator.create_milestone(project, user, %{name: "Alpha"})
      {:ok, b} = Operator.create_milestone(project, user, %{name: "Beta"})
      {:ok, view, _html} = live(conn, view_url(project))

      render_click(view, "milestones:current", %{"id" => b.id})

      assert [{_, _, [first | _]} | _] =
               view |> render() |> Floki.parse_document!() |> Floki.find("article.ms-card")

      assert Floki.text(first) =~ "Beta"
      assert has_element?(view, "#ms-#{b.id} .ms-mark", "current")
      refute has_element?(view, "#milestones-no-current")

      render_click(view, "milestones:current", %{"id" => ""})
      assert Milestones.current(project.id) == nil
    end

    test "a ticket on hold has Release on its row, which releases it", ctx do
      %{conn: conn, project: project, user: user} = ctx
      {:ok, m} = Operator.create_milestone(project, user, %{name: "Goal"})
      ticket = held!(project, user, "Top of the list", milestone_id: m.id)
      {:ok, view, _html} = live(conn, view_url(project))

      assert has_element?(view, "#ms-rows-#{m.id}-#{ticket.number} .ms-flag--held", "on hold")

      assert has_element?(
               view,
               "#ms-rows-#{m.id}-#{ticket.number}",
               "starts refining when released"
             )

      view |> element("#ms-rows-#{m.id}-#{ticket.number} button", "Release") |> render_click()

      refute Tickets.get!(ticket.id).held_at
      refute has_element?(view, "#ms-rows-#{m.id}-#{ticket.number} .ms-flag--held")
      assert [%{state: "refining"}] = Forge.Jobs.for_ticket(ticket.id)
    end

    test "a taken-over ticket says so, and its button is Hand back, which hands it back", ctx do
      %{conn: conn, project: project, user: user} = ctx
      {:ok, m} = Operator.create_milestone(project, user, %{name: "Goal"})
      ticket = held!(project, user, "By hand", milestone_id: m.id)
      {:ok, _} = Operator.take_over(ticket, user)
      {:ok, view, _html} = live(conn, view_url(project))
      row = "#ms-rows-#{m.id}-#{ticket.number}"

      assert view |> element(row) |> render() =~ "taken over · #{user.email}"
      refute has_element?(view, row <> " button", "Release")

      view |> element(row <> " button", "Hand back") |> render_click()

      back = Tickets.get!(ticket.id)
      refute back.held_at
      refute back.takeover_id
      assert [%{state: "refining"}] = Forge.Jobs.for_ticket(ticket.id)
    end

    test "a refused release is said on its row, and nothing else moves", ctx do
      %{conn: conn, project: project, user: user} = ctx
      ticket = held!(project, user, "Raced")
      other = held!(project, user, "Bystander")
      {:ok, view, _html} = live(conn, view_url(project))

      # Someone else released it first: this page's Release is stale.
      {:ok, _} = Operator.release(ticket, user)

      # What a stale page sends: the button is gone from the live one, which saw the release.
      render_click(view, "milestones:release", %{"ticket" => ticket.id})

      assert has_element?(view, "#ms-row-refusal-#{ticket.id}", "not on hold")
      refute has_element?(view, "#ms-row-refusal-#{other.id}")
      assert Tickets.get!(other.id).held_at
    end

    test "buttons and a drag order a list the same way, and a no-op moves nothing", ctx do
      %{conn: conn, project: project, user: user} = ctx
      [a, b, c] = for t <- ~w(A B C), do: held!(project, user, t)
      {:ok, view, _html} = live(conn, view_url(project))

      order = fn ->
        project.id |> Milestones.overview() |> Map.fetch!(:unplaced) |> Enum.map(& &1.id)
      end

      render_click(view, "milestones:ticket_move", %{"ticket" => c.id, "to" => "top"})
      assert order.() == [c.id, a.id, b.id]

      render_click(view, "milestones:ticket_move", %{"ticket" => c.id, "to" => "down"})
      assert order.() == [a.id, c.id, b.id]

      render_hook(view, "milestones:drag", %{"ticket" => b.id, "before" => a.id})
      assert order.() == [b.id, a.id, c.id]
      assert_reply(view, %{restore: false})

      render_hook(view, "milestones:drag", %{"ticket" => b.id, "before" => nil})
      assert order.() == [a.id, c.id, b.id]
      assert_reply(view, %{restore: false})

      # A drag that changes nothing is put back too: the last row dropped at the bottom, and a
      # row dropped above the one already below it.
      render_hook(view, "milestones:drag", %{"ticket" => b.id, "before" => nil})
      assert_reply(view, %{restore: true})
      render_hook(view, "milestones:drag", %{"ticket" => a.id, "before" => c.id})
      assert_reply(view, %{restore: true})
      assert order.() == [a.id, c.id, b.id]

      # Refused, the order the browser drew is put back: the reply says so.
      render_hook(view, "milestones:drag", %{"ticket" => b.id, "before" => Ecto.UUID.generate()})
      assert_reply(view, %{restore: true})
      assert order.() == [a.id, c.id, b.id]

      # The first row's *up* is a move that changes nothing: no event.
      before = length(Forge.Events.for_ticket(a.id))
      render_click(view, "milestones:ticket_move", %{"ticket" => a.id, "to" => "up"})
      assert length(Forge.Events.for_ticket(a.id)) == before
      assert has_element?(view, "#ms-rows-none-#{a.number} button[disabled]")
    end

    test "a ticket of another project named by id is refused and moved nowhere", ctx do
      %{conn: conn, project: project, user: user} = ctx
      other_owner = Forge.AccountsFixtures.user_fixture()

      {:ok, other} =
        Projects.register(
          %{name: "oth-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
          other_owner
        )

      foreign = held!(other, other_owner, "Theirs")
      mine = held!(project, user, "Mine")
      {:ok, view, _html} = live(conn, view_url(project))
      before = Repo.get!(Forge.Tickets.Ticket, foreign.id)

      for {event, params} <- [
            {"milestones:ticket_move", %{"ticket" => foreign.id, "to" => "top"}},
            {"milestones:release", %{"ticket" => foreign.id}},
            {"milestones:place", %{"ticket" => foreign.id, "milestone" => ""}},
            {"milestones:drag", %{"ticket" => foreign.id, "before" => mine.id}}
          ] do
        render_click(view, event, params)
      end

      assert Repo.get!(Forge.Tickets.Ticket, foreign.id) == before
      assert Tickets.get!(foreign.id).held_at

      # A milestone of another project, named by id, is no milestone here either.
      {:ok, theirs} = Milestones.create(other, %{name: "Theirs"}, {:user, other_owner.id})
      render_click(view, "milestones:close", %{"id" => theirs.id})
      render_click(view, "milestones:current", %{"id" => theirs.id})
      assert Repo.get!(Milestones.Milestone, theirs.id).closed_at == nil
      refute render(view) =~ "Theirs"
    end

    test "a ticket of a project the person is also in is not this page's to move", ctx do
      %{conn: conn, project: project, user: user} = ctx

      {:ok, other} =
        Projects.register(
          %{name: "both-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
          user
        )

      elsewhere = held!(other, user, "In the other project")
      {:ok, view, _html} = live(conn, view_url(project))
      before = Repo.get!(Forge.Tickets.Ticket, elsewhere.id)

      render_click(view, "milestones:release", %{"ticket" => elsewhere.id})
      render_click(view, "milestones:ticket_move", %{"ticket" => elsewhere.id, "to" => "top"})
      render_change(view, "milestones:place", %{"ticket" => elsewhere.id, "milestone" => ""})

      assert Repo.get!(Forge.Tickets.Ticket, elsewhere.id) == before
      assert Tickets.get!(elsewhere.id).held_at
    end

    test "Move to puts a ticket in a milestone, or in none", ctx do
      %{conn: conn, project: project, user: user} = ctx
      {:ok, m} = Operator.create_milestone(project, user, %{name: "Goal"})
      t = held!(project, user, "Wanderer")
      {:ok, view, _html} = live(conn, view_url(project))

      render_change(view, "milestones:place", %{"ticket" => t.id, "milestone" => m.id})
      assert Repo.get!(Forge.Tickets.Ticket, t.id).milestone_id == m.id
      assert has_element?(view, "#ms-rows-#{m.id}-#{t.number}")

      render_change(view, "milestones:place", %{"ticket" => t.id, "milestone" => ""})
      assert Repo.get!(Forge.Tickets.Ticket, t.id).milestone_id == nil
    end

    test "close folds a milestone away with its open tickets moved out; reopen brings it back",
         ctx do
      %{conn: conn, project: project, user: user} = ctx
      {:ok, m} = Operator.create_milestone(project, user, %{name: "Short lived"})
      t = held!(project, user, "Orphaned", milestone_id: m.id)
      {:ok, view, _html} = live(conn, view_url(project))

      render_click(view, "milestones:close", %{"id" => m.id})
      assert has_element?(view, "#ms-closed-#{m.id}", "Short lived")
      assert has_element?(view, "#ms-rows-none-#{t.number}", "Orphaned")
      refute has_element?(view, "article#ms-#{m.id}")

      render_click(view, "milestones:reopen", %{"id" => m.id})
      assert has_element?(view, "article#ms-#{m.id}")
      refute has_element?(view, "#ms-closed")
    end

    test "milestones are renamed and ordered from the page", ctx do
      %{conn: conn, project: project, user: user} = ctx
      {:ok, a} = Operator.create_milestone(project, user, %{name: "Alpha"})
      {:ok, b} = Operator.create_milestone(project, user, %{name: "Beta"})
      {:ok, view, _html} = live(conn, view_url(project))

      view
      |> form("#ms-edit-#{a.id}", %{"name" => "Alpha 2", "description" => "Why it matters"})
      |> render_submit()

      assert has_element?(view, "#ms-#{a.id} .ms-name", "Alpha 2")
      assert has_element?(view, "#ms-#{a.id} .ms-description", "Why it matters")

      render_click(view, "milestones:move", %{"id" => b.id, "to" => "top"})
      assert Enum.map(Milestones.list(project.id), & &1.id) == [b.id, a.id]
    end

    # The current milestone is drawn first and takes no part in the order; the others are ordered
    # among themselves by the same three buttons and by a drag, whatever the stored order is.
    test "milestones are ordered by buttons and by a drag, the current one pinned first", ctx do
      %{conn: conn, project: project, user: user} = ctx
      {:ok, a} = Operator.create_milestone(project, user, %{name: "Alpha"})
      {:ok, b} = Operator.create_milestone(project, user, %{name: "Beta"})
      {:ok, c} = Operator.create_milestone(project, user, %{name: "Gamma"})
      {:ok, _} = Operator.set_current_milestone(project, user, b.id)
      {:ok, view, _html} = live(conn, view_url(project))

      drawn = fn ->
        view
        |> render()
        |> Floki.parse_document!()
        |> Floki.find("#ms-list > article")
        |> Enum.map(&(&1 |> Floki.attribute("data-id") |> hd()))
      end

      assert drawn.() == [b.id, a.id, c.id]

      # The current one has nowhere to go; the first of the others cannot go up or to the top,
      # and the last cannot go down.
      for {m, to} <- [{b, "top"}, {b, "up"}, {b, "down"}, {a, "top"}, {a, "up"}, {c, "down"}] do
        assert has_element?(view, ~s(#ms-#{m.id} button[phx-value-to="#{to}"][disabled]))
      end

      assert has_element?(view, ~s{#ms-#{c.id} button[phx-value-to="top"]:not([disabled])})
      refute has_element?(view, "#ms-#{b.id} .ms-handle")

      render_click(view, "milestones:move", %{"id" => c.id, "to" => "top"})
      assert drawn.() == [b.id, c.id, a.id]

      render_click(view, "milestones:move", %{"id" => c.id, "to" => "down"})
      assert drawn.() == [b.id, a.id, c.id]

      render_click(view, "milestones:move", %{"id" => c.id, "to" => "up"})
      assert drawn.() == [b.id, c.id, a.id]

      # A drag above the current milestone lands first among the rest; one that changes nothing is
      # told to put the order back, and so is one that is refused.
      render_hook(view, "milestones:drag_milestone", %{"milestone" => a.id, "before" => b.id})
      assert drawn.() == [b.id, a.id, c.id]
      assert_reply(view, %{restore: false})

      render_hook(view, "milestones:drag_milestone", %{"milestone" => a.id, "before" => b.id})
      assert_reply(view, %{restore: true})

      render_hook(view, "milestones:drag_milestone", %{"milestone" => a.id, "before" => nil})
      assert drawn.() == [b.id, c.id, a.id]
      assert_reply(view, %{restore: false})

      render_hook(view, "milestones:drag_milestone", %{
        "milestone" => a.id,
        "before" => Ecto.UUID.generate()
      })

      assert_reply(view, %{restore: true})
      assert has_element?(view, "#ms-refusal-#{a.id}")
      assert drawn.() == [b.id, c.id, a.id]

      # The pinned one is not moved by a crafted event either.
      render_hook(view, "milestones:drag_milestone", %{"milestone" => b.id, "before" => nil})
      assert_reply(view, %{restore: true})
      assert drawn.() == [b.id, c.id, a.id]
    end

    # With three that can move, the first has no *up* and the last no *down*, and a drag that
    # changes nothing is put back.
    test "milestone moves that change nothing change nothing, and a drag of one is put back",
         ctx do
      %{conn: conn, project: project, user: user} = ctx

      [w, x, y, z] =
        for name <- ~w(Wren Xenon Yarrow Zinc) do
          {:ok, m} = Operator.create_milestone(project, user, %{name: name})
          m
        end

      {:ok, _} = Operator.set_current_milestone(project, user, y.id)
      {:ok, view, _html} = live(conn, view_url(project))

      stored = fn -> Enum.map(Milestones.list(project.id), & &1.id) end
      assert stored.() == [w.id, x.id, y.id, z.id]

      # Each on its own, so that one that moves something is not put right by the next.
      for {id, to} <- [{w.id, "up"}, {z.id, "down"}, {w.id, "top"}, {z.id, "bottom"}] do
        render_click(view, "milestones:move", %{"id" => id, "to" => to})
        assert stored.() == [w.id, x.id, y.id, z.id]
      end

      for {id, before} <- [{z.id, nil}, {w.id, x.id}, {w.id, y.id}, {x.id, z.id}] do
        render_hook(view, "milestones:drag_milestone", %{"milestone" => id, "before" => before})
        assert_reply(view, %{restore: true})
      end

      assert stored.() == [w.id, x.id, y.id, z.id]

      # And the moves that do something still do it: the last up, the first down, to the bottom.
      render_click(view, "milestones:move", %{"id" => z.id, "to" => "up"})
      assert stored.() == [w.id, z.id, x.id, y.id]
      render_click(view, "milestones:move", %{"id" => w.id, "to" => "down"})
      assert stored.() == [z.id, w.id, x.id, y.id]
      render_click(view, "milestones:move", %{"id" => z.id, "to" => "bottom"})
      assert stored.() == [w.id, x.id, y.id, z.id]
    end

    # Stored places are not dense (a merged ticket keeps its own), so a real move can rewrite the
    # moved ticket to the place it had; it is still a move, and the browser keeps its order.
    test "a drag that moves a ticket is kept when places have gaps", ctx do
      %{conn: conn, project: project, user: user} = ctx
      [first, a, b] = for t <- ~w(First A B), do: held!(project, user, t)
      Forge.TicketFixtures.merged!(first, 0)
      {:ok, view, _html} = live(conn, view_url(project))

      order = fn ->
        project.id |> Milestones.overview() |> Map.fetch!(:unplaced) |> Enum.map(& &1.id)
      end

      assert order.() == [a.id, b.id]
      assert Tickets.get!(a.id).position == 2

      render_hook(view, "milestones:drag", %{"ticket" => a.id, "before" => nil})
      assert order.() == [b.id, a.id]
      assert_reply(view, %{restore: false})
    end

    # A ticket's order inside a milestone is a list of its own: a real drag there is kept, and one
    # that changes nothing is put back, as for the tickets in no milestone.
    test "a drag inside a milestone's list is kept, and one that changes nothing is put back",
         ctx do
      %{conn: conn, project: project, user: user} = ctx
      {:ok, m} = Operator.create_milestone(project, user, %{name: "Goal"})
      [a, b, c] = for t <- ~w(A B C), do: held!(project, user, t, milestone_id: m.id)
      {:ok, view, _html} = live(conn, view_url(project))

      order = fn ->
        entry = Enum.find(Milestones.overview(project.id).milestones, &(&1.milestone.id == m.id))
        Enum.map(entry.open, & &1.id)
      end

      assert order.() == [a.id, b.id, c.id]

      render_hook(view, "milestones:drag", %{"ticket" => c.id, "before" => a.id})
      assert order.() == [c.id, a.id, b.id]
      assert_reply(view, %{restore: false})

      render_hook(view, "milestones:drag", %{"ticket" => c.id, "before" => a.id})
      assert order.() == [c.id, a.id, b.id]
      assert_reply(view, %{restore: true})
    end

    # *Down* on the last of the others is nothing, even when the current milestone is stored after
    # it: a crafted event must not move the card past it, where the buttons are disabled.
    test "down on the last card changes nothing when the current one is stored last", ctx do
      %{conn: conn, project: project, user: user} = ctx
      [w, z, y] = for n <- ~w(Wren Zinc Yarrow), do: create_milestone!(project, user, n)
      {:ok, _} = Operator.set_current_milestone(project, user, y.id)
      {:ok, view, _html} = live(conn, view_url(project))

      stored = fn -> Enum.map(Milestones.list(project.id), & &1.id) end
      assert stored.() == [w.id, z.id, y.id]

      render_click(view, "milestones:move", %{"id" => z.id, "to" => "down"})
      assert stored.() == [w.id, z.id, y.id]
    end

    test "a project whose milestones are all closed says what one is for and offers reopening",
         ctx do
      %{conn: conn, project: project, user: user} = ctx
      {:ok, m} = Operator.create_milestone(project, user, %{name: "Done with"})
      {:ok, _} = Operator.close_milestone(project, user, m.id)
      {:ok, view, _html} = live(conn, view_url(project))

      assert has_element?(view, "#milestones-none", "named goal")
      assert has_element?(view, "#milestones-none", "Every milestone here is closed")
      assert has_element?(view, "#ms-closed-#{m.id}", "Done with")
    end

    test "an over-long name is refused at the field with the limit said; markup is text", ctx do
      %{conn: conn, project: project} = ctx
      {:ok, view, _html} = live(conn, view_url(project))

      view
      |> form("#milestone-create", %{"name" => String.duplicate("n", 81)})
      |> render_submit()

      assert has_element?(view, "#milestones-refusal", "80")
      assert Milestones.list(project.id) == []

      view
      |> form("#milestone-create", %{"name" => "<b>bold</b> <script>x</script>"})
      |> render_submit()

      html = render(view)
      assert html =~ "&lt;b&gt;bold&lt;/b&gt;"
      refute html =~ "<b>bold</b>"
      refute html =~ "<script>x</script>"
    end

    test "a second session sees a milestone made in the first, and a ticket moved", ctx do
      %{conn: conn, project: project, user: user} = ctx
      {:ok, one, _} = live(conn, view_url(project))
      {:ok, two, _} = live(conn, view_url(project))

      {:ok, m} = Operator.create_milestone(project, user, %{name: "Seen by both"})
      assert render(one) =~ "Seen by both"
      assert render(two) =~ "Seen by both"

      t = held!(project, user, "Placed live")
      {:ok, _} = Operator.set_milestone(t, user, m.id)
      assert has_element?(two, "#ms-rows-#{m.id}-#{t.number}", "Placed live")
    end

    test "another project's milestone changes do no work on this page", ctx do
      %{conn: conn, project: project} = ctx
      other_owner = Forge.AccountsFixtures.user_fixture()

      {:ok, other} =
        Projects.register(
          %{name: "oth-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
          other_owner
        )

      {:ok, view, _html} = live(conn, view_url(project))
      {:ok, _} = Milestones.create(other, %{name: "Not here"}, {:user, other_owner.id})
      refute render(view) =~ "Not here"
    end

    test "a milestone of two hundred tickets is drawn whole", ctx do
      %{conn: conn, project: project, user: user} = ctx
      {:ok, m} = Operator.create_milestone(project, user, %{name: "Everything"})

      for n <- 1..200,
          do:
            Forge.ForgeFixtures.ticket_fixture(%{project: project, title: "T#{n}"})
            |> then(&Milestones.set_ticket_milestone(&1, m.id, :system))

      {:ok, view, _html} = live(conn, view_url(project))

      assert view
             |> render()
             |> Floki.parse_document!()
             |> Floki.find("#ms-rows-#{m.id} > li")
             |> length() == 200
    end
  end

  describe "the Tickets list" do
    test "a ticket on hold is below the rest and counted in On hold", ctx do
      %{conn: conn, project: project, user: user} = ctx
      {:ok, started} = Operator.admit(project, user, %{title: "In flight", on_hold: false})
      held = held!(project, user, "Parked idea")
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      assert has_element?(view, "#tickets-rest-#{started.number}")
      assert has_element?(view, "#tickets-held-#{held.number}", "on hold")
      refute has_element?(view, "#tickets-rest-#{held.number}")
      assert has_element?(view, "#ticket-filter", "On hold")
      assert render(view) =~ "ticket-row--held"

      view |> element("#ticket-filter button", "On hold") |> render_click()
      assert has_element?(view, "#tickets-held-#{held.number}")
      refute has_element?(view, "#tickets-rest-#{started.number}")
    end

    test "rows name their milestone", ctx do
      %{conn: conn, project: project, user: user} = ctx
      {:ok, m} = Operator.create_milestone(project, user, %{name: "0.4 saves"})
      t = held!(project, user, "Placed", milestone_id: m.id)
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")
      assert has_element?(view, "#tickets-held-#{t.number} .ticket-milestone", "0.4 saves")
    end

    test "the map draws a ticket on hold as on hold", ctx do
      %{conn: conn, project: project, user: user} = ctx
      held!(project, user)
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}?view=workflow")
      assert render(view) =~ "wf-map-dot--held"
      assert has_element?(view, ".workflow-legend", "on hold")
    end
  end

  describe "the ticket page" do
    test "a ticket on hold says so with Release, and Hold puts a ticket on hold", ctx do
      %{conn: conn, project: project, user: user} = ctx
      {:ok, ticket} = Operator.admit(project, user, %{title: "Live one", on_hold: false})
      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")

      refute has_element?(view, "#hold-band")
      view |> element("#hold-ticket") |> render_click()

      assert has_element?(view, "#hold-band", "On hold")
      assert has_element?(view, "#hold-waits", "when released")
      assert has_element?(view, "#top-bar .ui-top-sub", "on hold")
      refute has_element?(view, "#hold-band .ui-btn--accent")

      view |> element("#release-ticket") |> render_click()
      refute has_element?(view, "#hold-band")
      refute Tickets.get!(ticket.id).held_at
    end

    test "a refused Release is said in the band, and the ticket stays on hold", ctx do
      %{conn: conn, project: project, user: user} = ctx
      ticket = held!(project, user)
      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")

      # The type's file is gone from the default branch: the refresh cannot be made.
      commit_to_default(project, %{".forge/workflow.yml" => nil})

      view |> element("#release-ticket") |> render_click()

      assert has_element?(view, "#hold-refusal", "not on the default branch any more")
      assert has_element?(view, "#hold-band")
      assert Tickets.get!(ticket.id).held_at
    end

    test "Stop now is offered only while a run of its state is going", ctx do
      %{conn: conn, project: project, user: user} = ctx
      {:ok, ticket} = Operator.admit(project, user, %{title: "Running", on_hold: false})
      {:ok, held} = Engine.hold(ticket, {:user, user.id})
      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
      refute has_element?(view, "#stop-now-ask")

      [job] = Forge.Jobs.for_ticket(ticket.id)
      job |> Forge.Jobs.Job.progress_changeset(%{status: :running}) |> Repo.update!()
      notify!(held)

      assert has_element?(view, "#stop-now-ask")
    end

    test "the title is edited by a member, and a release's is not", ctx do
      %{conn: conn, project: project, user: user} = ctx
      ticket = held!(project, user, "Old title")
      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")

      view |> form("#retitle-form", %{"title" => "New title"}) |> render_submit()
      assert Tickets.get!(ticket.id).title == "New title"

      {:ok, release} = Operator.admit(project, user, %{title: "0.9.0", on_hold: true})

      Repo.update_all(from(t in Tickets.Ticket, where: t.id == ^release.id),
        set: [workflow: Map.put(release.workflow, "release", true)]
      )

      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{release.number}")
      refute has_element?(view, "#retitle-form")
      assert has_element?(view, "#retitle-why", "version")
    end

    test "the milestone select puts the ticket in a milestone", ctx do
      %{conn: conn, project: project, user: user} = ctx
      {:ok, m} = Operator.create_milestone(project, user, %{name: "Goal"})
      ticket = held!(project, user)
      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")

      render_change(view, "set-milestone", %{"ticket" => ticket.id, "milestone" => m.id})
      assert Tickets.get!(ticket.id).milestone_id == m.id
    end
  end

  describe "admitting" do
    test "the form is one split button: Start now is its face, the others are in its menu", ctx do
      %{conn: conn, project: project, user: user} = ctx
      {:ok, m} = Operator.create_milestone(project, user, %{name: "Goal"})
      {:ok, view, _html} = live(conn, ~p"/tickets/new?project=#{project.name}")

      # `docs/design/ui.md` § Creating things: the face is *Start now*, and the menu holds *Put on
      # hold* and *Outside work*. Enter in a box still starts nothing, as below.
      assert has_element?(view, "#admit-face", "Start now")
      assert has_element?(view, "#admit-hold", "Put on hold")
      assert has_element?(view, "#admit-outside", "Outside work")
      refute has_element?(view, "#ticket-form button.ui-btn--primary")

      # Enter in a box clicks the form's first submit button, and the browser sends that button's
      # name and value. It is the hidden one, which sends neither choice, and not Start now.
      [first_button | _] =
        view
        |> element("#ticket-form")
        |> render()
        |> Floki.parse_fragment!()
        |> Floki.find("button[type=submit]")

      assert Floki.attribute(first_button, "name") == ["on_hold"]
      assert Floki.attribute(first_button, "value") == [""]

      render_submit(view, "create", %{
        "ticket" => %{"project" => project.name, "title" => "x", "body" => ""},
        "on_hold" => ""
      })

      assert Tickets.list(project) == []

      assert view |> element("#ticket-new-error") |> render() =~
               "choose whether to start it now or put it on hold"

      render_submit(view, "create", %{
        "ticket" => %{
          "project" => project.name,
          "title" => "Held",
          "body" => "",
          "milestone_id" => m.id
        },
        "on_hold" => "true"
      })

      assert [%{held_at: held_at, milestone_id: milestone_id}] = Tickets.list(project)
      assert held_at
      assert milestone_id == m.id
    end

    test "a proposal is admitted on hold or started, into a milestone", ctx do
      %{conn: conn, project: project, user: user} = ctx
      {:ok, m} = Operator.create_milestone(project, user, %{name: "Goal"})

      job =
        Forge.ForgeFixtures.job_fixture(%{
          ticket: Forge.ForgeFixtures.ticket_fixture(%{project: project})
        })

      version = Forge.ForgeFixtures.proposal_fixture(%{job: job, file: "a.md", title: "Idea one"})

      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.name}?view=proposals&read=#{version.id}")

      assert has_element?(view, "#proposal-admit-hold", "Put on hold")
      assert has_element?(view, "#proposal-admit-face", "Start now")
      refute has_element?(view, "#proposal-admit-outside")

      # Neither pressed: nothing is admitted.
      render_submit(view, "decide_proposal", %{"version_id" => version.id})
      assert Forge.Proposals.decision(version.id) == nil

      render_submit(view, "decide_proposal", %{
        "version_id" => version.id,
        "admit" => "hold",
        "milestone_id" => m.id
      })

      assert %{ticket_id: ticket_id} = Forge.Proposals.decision(version.id)
      ticket = Tickets.get!(ticket_id)
      assert ticket.held_at
      assert ticket.milestone_id == m.id
    end
  end

  defp notify!(ticket), do: Forge.Events.notify(ticket.id)
end
