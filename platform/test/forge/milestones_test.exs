defmodule Forge.MilestonesTest do
  @moduledoc """
  Milestones and the order of the tickets in them (`docs/design/ui.md` § Milestones), and a
  ticket's title: what each write does, what it refuses, that every one is a member's and leaves
  its event.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures
  import Forge.TicketFixtures, only: [merged!: 2]

  alias Forge.{Events, Milestones, Operator, Repo, Tickets}
  alias Forge.Git.Tokens
  alias Forge.Milestones.Milestone

  setup do
    {:ok, project} =
      register_owned!(%{
        name: "ms-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo()
      })

    user = member_fixture(project)
    %{project: project, user: user}
  end

  defp milestone!(project, user, name \\ nil) do
    name = name || "Goal #{System.unique_integer([:positive])}"
    {:ok, m} = Operator.create_milestone(project, user, %{name: name})
    m
  end

  defp ticket!(project, user, opts \\ []) do
    attrs =
      Map.merge(%{title: "T#{System.unique_integer([:positive])}", on_hold: true}, Map.new(opts))

    {:ok, ticket} = Operator.admit(project, user, attrs)
    ticket
  end

  defp numbers(project, milestone_id) do
    overview = Milestones.overview(project.id)

    entries =
      if milestone_id,
        do: Enum.find(overview.milestones, &(&1.milestone.id == milestone_id)).open,
        else: overview.unplaced

    Enum.map(entries, & &1.number)
  end

  defp types(ticket), do: ticket.id |> Events.for_ticket() |> Enum.map(& &1.type)

  describe "a milestone" do
    test "has a name, an optional description, and no date; names are unique, closed ones too",
         %{project: project, user: user} do
      {:ok, m} = Operator.create_milestone(project, user, %{name: "  0.3  ", description: " "})
      assert m.name == "0.3"
      assert m.description == nil

      assert {:error, %Ecto.Changeset{errors: [name: {_, _}]}} =
               Operator.create_milestone(project, user, %{name: "0.3"})

      {:ok, _} = Operator.close_milestone(project, user, m.id)

      assert {:error, %Ecto.Changeset{errors: [name: {_, _}]}} =
               Operator.create_milestone(project, user, %{name: "0.3"})

      assert {:error, %Ecto.Changeset{}} = Operator.create_milestone(project, user, %{name: ""})

      # The limits are said, here, and not only read back from the constant the code uses.
      assert Milestone.name_limit() == 80
      assert Milestone.description_limit() == 2_000

      assert {:ok, _} =
               Operator.create_milestone(project, user, %{name: String.duplicate("n", 80)})

      assert {:ok, _} =
               Operator.create_milestone(project, user, %{
                 name: "d2000",
                 description: String.duplicate("d", 2_000)
               })

      long = String.duplicate("n", Milestone.name_limit() + 1)

      assert {:error, %Ecto.Changeset{errors: [name: {_, opts}]}} =
               Operator.create_milestone(project, user, %{name: long})

      assert opts[:count] == Milestone.name_limit()

      assert {:error, %Ecto.Changeset{errors: [description: _]}} =
               Operator.create_milestone(project, user, %{
                 name: "d",
                 description: String.duplicate("d", Milestone.description_limit() + 1)
               })
    end

    test "a caller cannot reach what is not text: project, current or closed_at", %{
      project: project,
      user: user
    } do
      other = milestone!(project, user)

      {:ok, m} =
        Operator.create_milestone(project, user, %{
          name: "x",
          current: true,
          closed_at: DateTime.utc_now(),
          project_id: Ecto.UUID.generate()
        })

      assert m.project_id == project.id
      refute m.current
      assert m.closed_at == nil
      assert other.id != m.id
    end

    test "at most one is current: marking another unmarks the first; none may be", %{
      project: project,
      user: user
    } do
      a = milestone!(project, user)
      b = milestone!(project, user)

      {:ok, _} = Operator.set_current_milestone(project, user, a.id)
      assert Milestones.current(project.id).id == a.id
      {:ok, _} = Operator.set_current_milestone(project, user, b.id)
      assert Milestones.current(project.id).id == b.id
      refute Repo.get!(Milestone, a.id).current

      {:ok, nil} = Operator.set_current_milestone(project, user, nil)
      assert Milestones.current(project.id) == nil
    end

    test "the database refuses a second current milestone and a closed current one", %{
      project: project,
      user: user
    } do
      a = milestone!(project, user)
      b = milestone!(project, user)
      Repo.update_all(Ecto.Query.from(m in Milestone, where: m.id == ^a.id), set: [current: true])

      assert_raise Postgrex.Error, ~r/milestones_one_current_per_project/, fn ->
        Repo.update_all(Ecto.Query.from(m in Milestone, where: m.id == ^b.id),
          set: [current: true]
        )
      end

      assert_raise Postgrex.Error, ~r/milestones_current_is_open/, fn ->
        Repo.update_all(Ecto.Query.from(m in Milestone, where: m.id == ^a.id),
          set: [closed_at: DateTime.utc_now()]
        )
      end
    end

    test "a closed milestone cannot be marked current, and can be reopened", %{
      project: project,
      user: user
    } do
      m = milestone!(project, user)
      {:ok, _} = Operator.set_current_milestone(project, user, m.id)
      {:ok, closed} = Operator.close_milestone(project, user, m.id)

      assert closed.closed_at
      refute closed.current
      assert {:error, :closed} = Operator.set_current_milestone(project, user, m.id)
      assert {:error, :already_closed} = Operator.close_milestone(project, user, m.id)

      {:ok, reopened} = Operator.reopen_milestone(project, user, m.id)
      assert reopened.closed_at == nil
      assert {:error, :not_closed} = Operator.reopen_milestone(project, user, m.id)
    end

    test "milestones are ordered by a member, closed ones last", %{project: project, user: user} do
      a = milestone!(project, user)
      b = milestone!(project, user)
      c = milestone!(project, user)
      names = fn -> project.id |> Milestones.list() |> Enum.map(& &1.id) end
      assert names.() == [a.id, b.id, c.id]

      {:ok, _} = Operator.move_milestone(project, user, c.id, :top)
      assert names.() == [c.id, a.id, b.id]
      {:ok, _} = Operator.move_milestone(project, user, c.id, {:before, b.id})
      assert names.() == [a.id, c.id, b.id]
      assert {:ok, :unchanged} = Operator.move_milestone(project, user, a.id, :up)

      {:ok, _} = Operator.close_milestone(project, user, c.id)
      assert names.() == [a.id, b.id, c.id]
      assert {:error, :closed} = Operator.move_milestone(project, user, c.id, :top)
    end
  end

  describe "a ticket in a milestone" do
    test "admitted into one, it goes to the bottom of its order; otherwise of the unplaced", %{
      project: project,
      user: user
    } do
      m = milestone!(project, user)
      one = ticket!(project, user, milestone_id: m.id)
      two = ticket!(project, user, milestone_id: m.id)
      loose = ticket!(project, user)
      later = ticket!(project, user)

      assert numbers(project, m.id) == [one.number, two.number]
      assert numbers(project, nil) == [loose.number, later.number]
      assert Repo.get!(Forge.Tickets.Ticket, one.id).milestone_id == m.id
    end

    test "only an open milestone of its own project may be chosen", %{
      project: project,
      user: user
    } do
      {:ok, other} =
        register_owned!(%{
          name: "o-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo()
        })

      foreign = milestone!(other, member_fixture(other))
      closed = milestone!(project, user)
      {:ok, _} = Operator.close_milestone(project, user, closed.id)

      for id <- [foreign.id, closed.id, Ecto.UUID.generate(), "not-an-id"] do
        assert {:error, :milestone} =
                 Operator.admit(project, user, %{title: "x", on_hold: true, milestone_id: id})
      end

      assert Tickets.list(project) == []
    end

    test "moved between milestones and out, it goes to the bottom of each order", %{
      project: project,
      user: user
    } do
      a = milestone!(project, user)
      b = milestone!(project, user)
      t1 = ticket!(project, user, milestone_id: a.id)
      t2 = ticket!(project, user, milestone_id: b.id)

      {:ok, _} = Operator.set_milestone(t1, user, b.id)
      assert numbers(project, b.id) == [t2.number, t1.number]
      assert numbers(project, a.id) == []

      {:ok, _} = Operator.set_milestone(t1, user, nil)
      assert numbers(project, nil) == [t1.number]

      assert {:error, :milestone} = Operator.set_milestone(t1, user, Ecto.UUID.generate())

      assert %{payload: %{"from_name" => from_name, "to_name" => nil}} =
               t1.id
               |> Events.for_ticket()
               |> Enum.filter(&(&1.type == "ticket.milestone_set"))
               |> List.last()

      assert is_binary(from_name)
    end

    test "a merged or cancelled ticket keeps its milestone and cannot be placed", %{
      project: project,
      user: user
    } do
      m = milestone!(project, user)
      t = ticket!(project, user, milestone_id: m.id)
      {:ok, cancelled} = Operator.cancel(t, user)

      assert {:error, {:not_open, :cancelled}} = Operator.set_milestone(cancelled, user, nil)
      assert {:error, {:not_open, :cancelled}} = Operator.move_ticket(cancelled, user, :top)
      assert Repo.get!(Forge.Tickets.Ticket, t.id).milestone_id == m.id
    end

    # Cancelled tickets keep their milestone when it closes, so restoring one afterwards would be
    # an open ticket in a closed milestone, which no list draws.
    test "restoring a ticket whose milestone closed puts it at the bottom of the unplaced", %{
      project: project,
      user: user
    } do
      m = milestone!(project, user)
      other = milestone!(project, user)
      loose = ticket!(project, user)
      t = ticket!(project, user, milestone_id: m.id)
      kept = ticket!(project, user, milestone_id: other.id)
      {:ok, cancelled} = Operator.cancel(t, user)
      {:ok, cancelled_kept} = Operator.cancel(kept, user)
      {:ok, _} = Operator.close_milestone(project, user, m.id)
      assert Repo.get!(Forge.Tickets.Ticket, t.id).milestone_id == m.id

      {:ok, restored} = Operator.restore(cancelled, user)
      assert restored.status == :stuck
      assert Repo.get!(Forge.Tickets.Ticket, t.id).milestone_id == nil
      assert numbers(project, nil) == [loose.number, t.number]
      assert "ticket.milestone_set" in types(t)

      # One whose milestone is still open is where it was.
      {:ok, _} = Operator.restore(cancelled_kept, user)
      assert Repo.get!(Forge.Tickets.Ticket, kept.id).milestone_id == other.id
      assert numbers(project, other.id) == [kept.number]
    end

    test "closing moves the open tickets to the bottom of the unplaced, keeps the merged", %{
      project: project,
      user: user
    } do
      m = milestone!(project, user)
      loose = ticket!(project, user)
      a = ticket!(project, user, milestone_id: m.id)
      b = ticket!(project, user, milestone_id: m.id)
      merged = ticket!(project, user, milestone_id: m.id)
      merged!(merged, 0)

      {:ok, _} = Operator.close_milestone(project, user, m.id)

      assert numbers(project, nil) == [loose.number, a.number, b.number]
      assert Repo.get!(Forge.Tickets.Ticket, merged.id).milestone_id == m.id
      assert Repo.get!(Forge.Tickets.Ticket, a.id).milestone_id == nil

      assert %{payload: %{"moved" => moved}} =
               project.id |> Events.for_project(20) |> Enum.find(&(&1.type == "milestone.closed"))

      assert moved == [a.id, b.id]

      # Reopening brings nothing back.
      {:ok, _} = Operator.reopen_milestone(project, user, m.id)
      assert numbers(project, m.id) == []
    end

    test "progress is merged out of open and merged; cancelled count towards nothing", %{
      project: project,
      user: user
    } do
      m = milestone!(project, user)
      held = ticket!(project, user, milestone_id: m.id)
      _flying = ticket!(project, user, milestone_id: m.id, on_hold: false)
      merged = ticket!(project, user, milestone_id: m.id)
      merged!(merged, 0)
      cancelled = ticket!(project, user, milestone_id: m.id)
      {:ok, _} = Operator.cancel(cancelled, user)
      done_unmerged = ticket!(project, user, milestone_id: m.id)

      Repo.update_all(
        Ecto.Query.from(t in Forge.Tickets.Ticket, where: t.id == ^done_unmerged.id),
        set: [status: :done]
      )

      %{milestones: [entry]} = Milestones.overview(project.id)
      assert entry.progress == %{merged: 1, total: 3, on_hold: 1, in_flight: 1}
      assert held.id in Enum.map(entry.open, & &1.id)
      assert merged.id in Enum.map(entry.merged, & &1.id)
      assert done_unmerged.id in Enum.map(entry.merged, & &1.id)
      refute cancelled.id in Enum.map(entry.merged ++ entry.open, & &1.id)
    end
  end

  describe "order" do
    test "reorder/3 is top, up, down, bottom and before" do
      ids = ~w(a b c d)
      assert {:ok, ~w(c a b d)} = Milestones.reorder(ids, "c", :top)
      assert {:ok, ~w(a c b d)} = Milestones.reorder(ids, "c", :up)
      assert {:ok, ~w(a b d c)} = Milestones.reorder(ids, "c", :down)
      assert {:ok, ~w(a b d c)} = Milestones.reorder(ids, "c", :bottom)
      assert {:ok, ~w(a d b c)} = Milestones.reorder(ids, "d", {:before, "b"})
      assert {:ok, ^ids} = Milestones.reorder(ids, "a", :up)
      assert {:ok, ^ids} = Milestones.reorder(ids, "d", :down)
      assert {:error, :not_in_order} = Milestones.reorder(ids, "z", :top)
      assert {:error, :not_in_order} = Milestones.reorder(ids, "a", {:before, "z"})
      assert {:error, :not_in_order} = Milestones.reorder(ids, "a", :sideways)
    end

    test "a move is relative to the order read under the lock: both moves are kept", %{
      project: project,
      user: user
    } do
      m = milestone!(project, user)
      [t1, t2, t3, t4] = for _ <- 1..4, do: ticket!(project, user, milestone_id: m.id)

      # Two people each saw 1 2 3 4: one sends 4 to the top, the other 3 up one.
      {:ok, _} = Operator.move_ticket(t4, user, :top)
      {:ok, _} = Operator.move_ticket(t3, user, :up)

      assert numbers(project, m.id) == [t4.number, t1.number, t3.number, t2.number]
    end

    test "a move that changes nothing writes nothing and logs nothing", %{
      project: project,
      user: user
    } do
      m = milestone!(project, user)
      first = ticket!(project, user, milestone_id: m.id)
      _second = ticket!(project, user, milestone_id: m.id)

      {:ok, _} = Operator.move_ticket(first, user, :up)
      refute "ticket.moved" in types(first)

      {:ok, _} = Operator.move_ticket(first, user, :down)
      assert "ticket.moved" in types(first)
    end

    test "the unplaced have an order of their own", %{project: project, user: user} do
      a = ticket!(project, user)
      b = ticket!(project, user)
      m = milestone!(project, user)
      _in_goal = ticket!(project, user, milestone_id: m.id)

      {:ok, _} = Operator.move_ticket(b, user, :top)
      assert numbers(project, nil) == [b.number, a.number]
      assert numbers(project, m.id) |> length() == 1
    end
  end

  describe "titles" do
    test "a member retitles a ticket in any status and the event says old and new", %{
      project: project,
      user: user
    } do
      t = ticket!(project, user)
      {:ok, retitled} = Operator.retitle(t, user, "  A better name ")
      assert retitled.title == "A better name"

      {:ok, cancelled} = Operator.cancel(retitled, user)

      assert {:ok, %{title: "Cancelled but named"}} =
               Operator.retitle(cancelled, user, "Cancelled but named")

      assert %{payload: %{"from" => "A better name", "to" => "Cancelled but named"}} =
               t.id
               |> Events.for_ticket()
               |> Enum.filter(&(&1.type == "ticket.retitled"))
               |> List.last()

      assert {:error, :blank} = Operator.retitle(cancelled, user, "   ")
    end

    test "a release's title is never editable, and the refusal says so", %{
      project: project,
      user: user
    } do
      t = ticket!(project, user, on_hold: false)

      Repo.update_all(Ecto.Query.from(x in Forge.Tickets.Ticket, where: x.id == ^t.id),
        set: [workflow: Map.put(t.workflow, "release", true)]
      )

      assert {:error, :release_title} = Operator.retitle(Tickets.get!(t.id), user, "0.9.9")
      assert Tickets.get!(t.id).title == t.title
      assert Forge.Operator.hold(Tickets.get!(t.id), user) |> elem(0) == :ok
    end
  end

  describe "who may" do
    test "every write is a member's: a non-member is forbidden, and a ticket's is no one else's",
         %{project: project, user: user} do
      stranger = Forge.AccountsFixtures.user_fixture()
      m = milestone!(project, user)
      t = ticket!(project, user, milestone_id: m.id)

      attempts = [
        fn -> Operator.hold(t, stranger) end,
        fn -> Operator.release(t, stranger) end,
        fn -> Operator.stop_now(t, stranger) end,
        fn -> Operator.retitle(t, stranger, "x") end,
        fn -> Operator.set_milestone(t, stranger, nil) end,
        fn -> Operator.move_ticket(t, stranger, :top) end,
        fn -> Operator.create_milestone(project, stranger, %{name: "n"}) end,
        fn -> Operator.update_milestone(project, stranger, m.id, %{name: "n"}) end,
        fn -> Operator.set_current_milestone(project, stranger, m.id) end,
        fn -> Operator.close_milestone(project, stranger, m.id) end,
        fn -> Operator.reopen_milestone(project, stranger, m.id) end,
        fn -> Operator.move_milestone(project, stranger, m.id, :top) end,
        fn -> Operator.admit(project, stranger, %{title: "x", on_hold: true}) end
      ]

      for attempt <- attempts, do: assert({:error, :forbidden} = attempt.())
      assert Repo.get!(Milestone, m.id).name == m.name
      assert Tickets.get!(t.id).held_at == t.held_at
    end

    test "a write token may do each, as the API; a read token and a stranger's token may not", %{
      project: project,
      user: user
    } do
      {:ok, other} =
        register_owned!(%{
          name: "o-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo()
        })

      {:ok, _s, write} = Tokens.issue(project, name: "bot", git: :none, api: :write)
      {:ok, _s, read} = Tokens.issue(project, name: "ro", git: :none, api: :read)
      {:ok, _s, foreign} = Tokens.issue(other, name: "f", git: :none, api: :write)
      t = ticket!(project, user, on_hold: false)

      assert {:error, :forbidden} = Operator.hold(t, read)
      assert {:error, :forbidden} = Operator.hold(t, foreign)
      assert {:error, :forbidden} = Operator.create_milestone(project, read, %{name: "n"})

      {:ok, m} = Operator.create_milestone(project, write, %{name: "By api"})
      {:ok, _} = Operator.hold(t, write)
      {:ok, _} = Operator.retitle(t, write, "Retitled")
      {:ok, _} = Operator.set_milestone(t, write, m.id)
      {:ok, _} = Operator.release(Tickets.get!(t.id), write)

      for type <- ["ticket.held", "ticket.released", "ticket.retitled", "ticket.milestone_set"] do
        assert %{actor: %{"kind" => "api", "name" => "bot"}} =
                 t.id |> Events.for_ticket() |> Enum.find(&(&1.type == type))
      end

      assert %{actor: %{"kind" => "api"}} =
               project.id
               |> Events.for_project(20)
               |> Enum.find(&(&1.type == "milestone.created"))
    end

    test "another project's milestone is not found, as one that does not exist", %{
      project: project,
      user: user
    } do
      {:ok, other} =
        register_owned!(%{
          name: "o-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo()
        })

      foreign = milestone!(other, member_fixture(other))
      t = ticket!(project, user)

      assert {:error, :not_found} =
               Operator.update_milestone(project, user, foreign.id, %{name: "x"})

      assert {:error, :not_found} = Operator.set_current_milestone(project, user, foreign.id)
      assert {:error, :not_found} = Operator.close_milestone(project, user, foreign.id)
      assert {:error, :not_found} = Operator.reopen_milestone(project, user, foreign.id)
      assert {:error, :not_found} = Operator.move_milestone(project, user, foreign.id, :top)
      assert {:error, :milestone} = Operator.set_milestone(t, user, foreign.id)
      assert Repo.get!(Milestone, foreign.id).name == foreign.name
    end

    test "every write leaves its event, with the project", %{project: project, user: user} do
      m = milestone!(project, user)
      {:ok, _} = Operator.update_milestone(project, user, m.id, %{name: "Renamed"})
      {:ok, _} = Operator.set_current_milestone(project, user, m.id)
      m2 = milestone!(project, user)
      {:ok, _} = Operator.move_milestone(project, user, m2.id, :top)
      {:ok, _} = Operator.close_milestone(project, user, m.id)
      {:ok, _} = Operator.reopen_milestone(project, user, m.id)

      logged = project.id |> Events.for_project(50) |> Enum.map(& &1.type)

      for type <-
            ~w(milestone.created milestone.updated milestone.current milestone.moved milestone.closed milestone.reopened) do
        assert type in logged, "missing #{type}"
      end

      assert %{payload: %{"from" => %{"name" => _}, "to" => %{"name" => "Renamed"}}} =
               project.id
               |> Events.for_project(50)
               |> Enum.find(&(&1.type == "milestone.updated"))
    end
  end

  describe "the project's pages are told" do
    test "a milestone write broadcasts on that project's topic and no other's", %{
      project: project,
      user: user
    } do
      {:ok, other} =
        register_owned!(%{
          name: "o-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo()
        })

      Events.subscribe_project(project.id)
      milestone!(other, member_fixture(other))
      refute_receive {:project_changed, _}, 100

      milestone!(project, user)
      assert_receive {:project_changed, id}
      assert id == project.id
    end
  end
end
