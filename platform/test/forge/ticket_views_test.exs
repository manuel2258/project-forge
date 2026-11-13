defmodule Forge.TicketViewsTest do
  @moduledoc """
  *Since you last looked* (`Forge.Tickets.Views`, `docs/design/ui.md` § The end of the pass, and
  *All*): a look is per person and ticket, a page compares against the previous one, and a page
  that refused its reader records nothing.
  """

  use ForgeWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Phoenix.LiveViewTest

  alias Forge.{Events, Repo}
  alias Forge.Tickets.{View, Views}

  setup do
    project = project_fixture()
    %{project: project, ticket: ticket_fixture(%{project: project})}
  end

  defp views(ticket), do: Repo.all(from v in View, where: v.ticket_id == ^ticket.id)

  # Backdates a look, so "before" and "after" are seconds apart rather than microseconds.
  defp looked!(user, ticket, at) do
    Repo.update_all(
      from(v in View, where: v.user_id == ^user.id and v.ticket_id == ^ticket.id),
      set: [viewed_at: at]
    )
  end

  describe "touch/2" do
    # The previous look, not this one: a page that compared against the row it had just written
    # would find nothing new, ever.
    test "returns the previous look, and records this one", %{ticket: ticket} do
      user = user_fixture()

      assert Views.touch(user, ticket) == nil
      earlier = DateTime.add(DateTime.utc_now(), -3600)
      looked!(user, ticket, earlier)

      assert Views.touch(user, ticket) == earlier
      assert [%{viewed_at: now}] = views(ticket)
      assert DateTime.diff(DateTime.utc_now(), now) < 5
    end

    # Per person: the conflict target is the pair, so another person's look is another row.
    test "another person's look never moves mine", %{ticket: ticket} do
      me = user_fixture()
      other = user_fixture()

      Views.touch(me, ticket)
      earlier = DateTime.add(DateTime.utc_now(), -3600)
      looked!(me, ticket, earlier)

      assert Views.touch(other, ticket) == nil
      assert Views.since(me, [ticket.id]) == %{ticket.id => earlier}
      assert length(views(ticket)) == 2
    end
  end

  test "since/2 reads only the person's own looks, only of the tickets asked", %{
    project: project,
    ticket: ticket
  } do
    me = user_fixture()
    other = user_fixture()
    elsewhere = ticket_fixture(%{project: project})

    Views.touch(other, ticket)
    Views.touch(me, elsewhere)

    assert Views.since(me, [ticket.id]) == %{}
    assert Map.keys(Views.since(me, [ticket.id, elsewhere.id])) == [elsewhere.id]
  end

  describe "events_since/3" do
    # Inserted with its time, since the log is append-only and a recorded event cannot be moved.
    defp event!(ticket, type, payload, ago) do
      Repo.insert!(%Events.Event{
        ticket_id: ticket.id,
        project_id: ticket.project_id,
        actor: %{"kind" => "system", "id" => nil},
        type: type,
        payload: payload,
        inserted_at: DateTime.add(DateTime.utc_now(:second), -ago)
      })
    end

    test "lists what happened after the look, oldest first, and only the listed kinds", %{
      ticket: ticket
    } do
      before = event!(ticket, "transition.taken", %{"from" => "a", "to" => "b"}, 7200)
      first = event!(ticket, "transition.taken", %{"from" => "b", "to" => "c"}, 1800)
      second = event!(ticket, "ticket.stuck", %{"reason" => "it ran out of turns"}, 600)
      _harness = event!(ticket, "job.harness.text", %{"text" => "thinking"}, 300)

      look = DateTime.add(DateTime.utc_now(), -3600)

      assert Enum.map(Views.events_since(ticket.id, look, 10), & &1.seq) == [
               first.seq,
               second.seq
             ]

      # Never looked: the newest, all of them new — still only the listed kinds, and bounded.
      assert Enum.map(Views.events_since(ticket.id, nil, 2), & &1.seq) == [first.seq, second.seq]
      assert before.seq in Enum.map(Views.events_since(ticket.id, nil, 10), & &1.seq)
    end

    # One ticket's, never another's — of this project or any other.
    test "lists only the ticket's own", %{ticket: ticket} do
      mine = event!(ticket, "ticket.stuck", %{"reason" => "mine"}, 600)
      neighbour = ticket_fixture(%{project: Forge.Projects.get!(ticket.project_id)})
      event!(neighbour, "ticket.stuck", %{"reason" => "next door"}, 600)
      event!(ticket_fixture(), "ticket.stuck", %{"reason" => "elsewhere"}, 600)

      look = DateTime.add(DateTime.utc_now(), -3600)

      for at <- [look, nil],
          do: assert(Enum.map(Views.events_since(ticket.id, at, 10), & &1.seq) == [mine.seq])
    end

    # Whole seconds against a look that is not: an event in the look's own second is new.
    test "counts an event in the same second as the look as after it", %{ticket: ticket} do
      second = DateTime.add(DateTime.utc_now(:second), -600)
      look = %{second | microsecond: {500_000, 6}}

      same =
        Repo.insert!(%Events.Event{
          ticket_id: ticket.id,
          project_id: ticket.project_id,
          actor: %{"kind" => "system", "id" => nil},
          type: "ticket.stuck",
          payload: %{"reason" => "same second"},
          inserted_at: second
        })

      assert Enum.map(Views.events_since(ticket.id, look, 10), & &1.seq) == [same.seq]
    end
  end

  describe "the ticket's page records a look" do
    setup %{project: project} do
      %{member: member_fixture(project, :member)}
    end

    test "after the membership check, keeping the previous one", %{
      conn: conn,
      project: project,
      ticket: ticket,
      member: member
    } do
      conn = log_in_user(conn, member)
      {:ok, _view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
      assert [%{user_id: user_id}] = views(ticket)
      assert user_id == member.id

      earlier = DateTime.add(DateTime.utc_now(), -3600)
      looked!(member, ticket, earlier)

      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
      assert :sys.get_state(view.pid).socket.assigns.since == earlier
    end

    # The check refuses the page; the look must not be recorded before it does. The dead render
    # refuses an outsider before any socket connects, so the connected mount is reached the way a
    # crafted client reaches it: rendered while a member, joined after the membership is gone.
    test "never for a reader the page refused", %{
      conn: conn,
      project: project,
      ticket: ticket,
      member: member
    } do
      conn = conn |> log_in_user(member) |> get(~p"/tickets/#{project.name}/#{ticket.number}")
      assert html_response(conn, 200)

      Repo.delete_all(
        from m in Forge.Projects.Member,
          where: m.project_id == ^project.id and m.user_id == ^member.id
      )

      Process.flag(:trap_exit, true)
      assert {%{status: 404}, _call} = catch_exit(live(conn))

      assert views(ticket) == []
    end
  end
end
