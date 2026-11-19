defmodule ForgeWeb.SchedulesLiveTest do
  @moduledoc """
  Schedules where a person meets them (`docs/design/ui.md` § Workflow, § The queue,
  `docs/design/schedules.md`): the block under each type on the project's Workflow view, the
  switch an admin has and a member does not, the confirmation, a refusal drawn on its row, the
  queue item and its dismissal, and what a ticket a schedule admitted says of itself.
  """

  use ForgeWeb.ConnCase, async: false

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.GitFixtures
  import Phoenix.LiveViewTest

  alias Forge.{Projects, Schedules, Tickets}
  alias Forge.Schedules.Schedule

  # The id a row is drawn with: a hash of its type and name (`SchedulesView.anchor/2`).
  @weekly ForgeWeb.SchedulesView.anchor(nil, "weekly-cleanup")

  @workflow Path.expand("../../../../core/test/fixtures/workflow_example.yml", __DIR__)

  # A title and a body that hold markup, and a name and a cron line long enough to need to wrap.
  @hostile """
  schedules:
    - name: weekly-cleanup
      cron: "0 6 * * MON"
      title: Weekly <b>cleanup</b>
      body: "Tidy <script>alert(1)</script> up."
    - name: a-name-that-goes-on-and-on-and-on-and-on-and-on-and-on-and-on-and-on-and-on-and-on
      cron: "*/15 0,6,12,18 1-7,15,20-25 JAN,MAR,MAY,JUL,SEP,NOV 1-5"
      title: A title that is long enough that it would run off the side of a phone if it could
      body: Long.
  """

  setup :register_and_log_in_user

  setup %{user: user} do
    repos = node_repos_dir()
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :repos_dir, repos))
    on_exit(fn -> Application.put_env(:forge, Forge.Jobs, original) end)

    {:ok, project} =
      Projects.register(
        %{
          name: "sch-#{System.unique_integer([:positive])}",
          repo_path:
            seeded_repo(%{".forge/workflow.yml" => File.read!(@workflow) <> "\n" <> @hostile})
        },
        user
      )

    %{project: project}
  end

  defp open(conn, project, query \\ []) do
    live(conn, ~p"/projects/#{project.name}?#{[view: "workflow"] ++ query}")
  end

  defp member_conn(project) do
    member = user_fixture()
    join!(project, member, :member)
    {log_in_user(Phoenix.ConnTest.build_conn(), member), member}
  end

  defp row(project, name \\ "weekly-cleanup"), do: Schedules.get(project, nil, name)

  describe "the block" do
    test "lists each schedule with its cron line, in words, its title and its next time", %{
      conn: conn,
      project: project
    } do
      {:ok, view, html} = open(conn, project)

      assert has_element?(view, "##{@weekly}")
      assert has_element?(view, "##{@weekly} .schedule-cron", "0 6 * * MON")
      assert html =~ "every Monday at 06:00 UTC"
      assert has_element?(view, "##{@weekly} time[datetime]")
      assert has_element?(view, "##{@weekly} .schedule-state", "off")
    end

    test "markup in a title or a body is text", %{conn: conn, project: project} do
      {:ok, view, html} = open(conn, project)

      assert html =~ "Weekly &lt;b&gt;cleanup&lt;/b&gt;"
      refute html =~ "<b>cleanup</b>"
      refute html =~ "<script>alert(1)</script>"

      assert render(element(view, "##{@weekly} .schedule-body-text")) =~
               "&lt;script&gt;"
    end

    test "a long name and a long cron line wrap and are not cut", %{conn: conn, project: project} do
      {:ok, _view, html} = open(conn, project)
      assert html =~ "a-name-that-goes-on-and-on-and-on"
      assert html =~ "*/15 0,6,12,18 1-7,15,20-25 JAN,MAR,MAY,JUL,SEP,NOV 1-5"
    end

    test "says who switched it on and when, and links the last ticket", %{
      conn: conn,
      project: project,
      user: user
    } do
      {:ok, row} = Schedules.switch_on(project, user, nil, "weekly-cleanup")
      [{_, {:admitted, ticket}}] = Schedules.tick(DateTime.add(row.fires_after, 8 * 86_400))

      {:ok, view, _html} = open(conn, project)

      assert has_element?(view, "##{@weekly} .schedule-state", "on")

      assert has_element?(
               view,
               "##{@weekly} .schedule-by",
               "Switched on by #{user.email}"
             )

      assert has_element?(
               view,
               ~s(##{@weekly} .schedule-last a[href="/tickets/#{project.name}/#{ticket.number}"])
             )
    end

    test "draws a problem in the warning tone", %{conn: conn, project: project, user: user} do
      {:ok, row} = Schedules.switch_on(project, user, nil, "weekly-cleanup")
      commit_to_default(project, %{".forge/workflow.yml" => "version: 1\nstates: [\n"})
      Schedules.tick(DateTime.add(row.fires_after, 8 * 86_400))

      {:ok, view, _html} = open(conn, project)

      assert has_element?(view, "##{@weekly}-problem.ui-notice--warning")

      assert has_element?(
               view,
               "##{@weekly}-problem",
               "Could not admit its ticket"
             )

      # The file does not parse, so the schedules that are on are listed by name, with the reason.
      assert has_element?(view, "##{@weekly}")
      assert render(view) =~ "does not parse"
    end
  end

  describe "a type with no schedule" do
    test "says how one is added, and the release says nothing of it", %{user: user, conn: conn} do
      plain = File.read!(@workflow)

      {:ok, project} =
        Projects.register(
          %{
            name: "typed-#{System.unique_integer([:positive])}",
            repo_path:
              seeded_repo(%{
                ".forge/workflow.yml" => nil,
                ".forge/workflows/chore.yml" => plain,
                ".forge/workflows/plain.yml" => plain,
                ".forge/workflows/ship.yml" => "release: true\n" <> plain
              })
          },
          user
        )

      {:ok, view, _html} = open(conn, project, type: "chore")
      assert has_element?(view, "#schedules-chore .schedules-hint", "schedules:")
      assert has_element?(view, "#schedules-chore .schedules-hint", ".forge/workflows/chore.yml")
      refute has_element?(view, "#schedules-ship")

      # `type=` is how an alert's link opens the view on the type holding its schedule.
      assert has_element?(view, "#type-chore:not([hidden])")
      {:ok, view, _html} = open(conn, project, type: "plain")
      assert has_element?(view, "#type-plain:not([hidden])")
      assert has_element?(view, "#type-chore[hidden]")
    end
  end

  describe "the switch" do
    test "an admin switches a schedule on, after the confirmation says what it will do", %{
      conn: conn,
      project: project,
      user: user
    } do
      {:ok, view, _html} = open(conn, project)

      assert has_element?(view, "##{@weekly}-on-ask")
      sentence = render(element(view, "##{@weekly}-on-confirm"))
      assert sentence =~ "every Monday at 06:00 UTC"
      assert sentence =~ "in your name"
      assert sentence =~ "Weekly &lt;b&gt;cleanup&lt;/b&gt;"

      view |> element("##{@weekly}-on") |> render_click()

      assert row(project).enabled_by_id == user.id
      assert has_element?(view, "##{@weekly} .schedule-state", "on")
      refute has_element?(view, "##{@weekly}-on")
    end

    test "switching off asks nothing", %{conn: conn, project: project, user: user} do
      {:ok, _} = Schedules.switch_on(project, user, nil, "weekly-cleanup")
      {:ok, view, _html} = open(conn, project)

      refute has_element?(view, "##{@weekly}-off-confirm")
      view |> element("##{@weekly}-off") |> render_click()
      refute Schedule.on?(row(project))
    end

    test "a member sees the state and no switch", %{project: project} do
      {conn, _member} = member_conn(project)
      {:ok, view, _html} = open(conn, project)

      assert has_element?(view, "##{@weekly}")
      refute has_element?(view, "##{@weekly}-on-ask")
      refute has_element?(view, "##{@weekly} .schedule-controls")
    end

    test "a member's switch-off pushed by hand changes nothing either", %{
      project: project,
      user: user
    } do
      {:ok, _} = Schedules.switch_on(project, user, nil, "weekly-cleanup")
      {conn, _member} = member_conn(project)
      {:ok, view, _html} = open(conn, project)

      render_hook(view, "schedule:off", %{"name" => "weekly-cleanup"})

      assert Schedule.on?(row(project))
      assert has_element?(view, "##{@weekly}-refused", "Only a project admin")
    end

    test "a member's event pushed by hand changes nothing, and says why on the row", %{
      project: project
    } do
      {conn, _member} = member_conn(project)
      {:ok, view, _html} = open(conn, project)

      render_hook(view, "schedule:on", %{"name" => "weekly-cleanup"})

      assert row(project) == nil

      assert has_element?(
               view,
               "##{@weekly}-refused",
               "Only a project admin"
             )
    end

    test "a schedule that left the file meanwhile is refused where it was pressed", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = open(conn, project)
      commit_to_default(project, %{".forge/workflow.yml" => File.read!(@workflow)})

      view |> element("##{@weekly}-on") |> render_click()

      assert row(project) == nil

      assert has_element?(
               view,
               "##{@weekly}-refused",
               "no longer in its file"
             )
    end

    test "a refusal for a schedule that is not drawn does not break the page", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = open(conn, project)
      render_hook(view, "schedule:on", %{"name" => "nope"})
      assert render(view) =~ "every Monday"
      render_hook(view, "schedule:off", %{})
    end
  end

  describe "an alert in the queue" do
    setup %{project: project, user: user} do
      {:ok, row} = Schedules.switch_on(project, user, nil, "weekly-cleanup")
      commit_to_default(project, %{".forge/workflow.yml" => "version: 1\nstates: [\n"})
      Schedules.tick(DateTime.add(row.fires_after, 8 * 86_400))
      %{row: row}
    end

    test "is an item with the sentence, Dismiss, and the way to the schedule", %{
      conn: conn,
      project: project
    } do
      {:ok, view, html} = live(conn, ~p"/")

      assert has_element?(view, "#queue-item", "weekly-cleanup")
      assert html =~ "could not admit its ticket"
      assert html =~ "schedule failed"
      assert has_element?(view, "#queue-schedule-dismiss")

      assert has_element?(
               view,
               ~s(#queue-schedule-open[href="/projects/#{project.name}?view=workflow##{@weekly}"])
             )
    end

    test "Dismiss clears the item and keeps the problem on the schedule", %{
      conn: conn,
      project: project,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#queue-schedule-dismiss") |> render_click()

      assert row(project).alerted_at == nil
      assert row(project).problem != nil
      assert Forge.Queue.items(user) == []
    end

    test "a member of another project cannot dismiss it by an id off the wire", %{
      project: project
    } do
      stranger = user_fixture()
      conn = log_in_user(Phoenix.ConnTest.build_conn(), stranger)
      {:ok, view, _html} = live(conn, ~p"/")

      render_hook(view, "schedule:dismiss", %{"id" => row(project).id})
      assert row(project).alerted_at != nil
      render_hook(view, "schedule:dismiss", %{"id" => "not-an-id"})
    end
  end

  describe "a ticket a schedule admitted" do
    test "says which schedule, when it was due and in whose name, and is drawn as any ticket's",
         %{
           conn: conn,
           project: project,
           user: user
         } do
      {:ok, row} = Schedules.switch_on(project, user, nil, "weekly-cleanup")
      [{_, {:admitted, ticket}}] = Schedules.tick(DateTime.add(row.fires_after, 8 * 86_400))

      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")

      assert has_element?(view, "#ticket-scheduled", "weekly-cleanup")
      assert has_element?(view, "#ticket-scheduled", "in #{user.email}'s name")
      due = ticket.title |> String.split(" · ") |> List.last()
      assert has_element?(view, "#ticket-scheduled", "due #{due}")

      # And its Activity says it too, under *On the ticket*, with the admin it was made in the name of.
      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=activity")
      assert has_element?(view, "#ticket-events", "admitted by the schedule weekly-cleanup, due ")
      assert has_element?(view, "#ticket-events", user.email)

      by_hand = Forge.Tickets.admit(project, %{title: "By hand"}, {:user, user.id})
      {:ok, hand} = by_hand
      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{hand.number}")
      refute has_element?(view, "#ticket-scheduled")

      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{hand.number}?tab=activity")
      refute has_element?(view, "#ticket-events", "admitted")

      assert Tickets.get!(ticket.id).title =~ "Weekly <b>cleanup</b> · "
    end
  end

  describe "a row's id" do
    test "is a hash: unique per type and name, and safe in a selector whatever the name holds" do
      pairs = [{nil, "weekly.cleanup"}, {"a", "b-c"}, {"a-b", "c"}, {nil, "a.b"}, {"a.b", "c"}]
      ids = for {type, name} <- pairs, do: ForgeWeb.SchedulesView.anchor(type, name)

      assert Enum.uniq(ids) == ids
      for id <- ids, do: assert(id =~ ~r/\Aschedule-[0-9a-f]{12}\z/)
    end

    test "a schedule named with a dot is switched on from the page", %{conn: conn, user: user} do
      dotted = """
      schedules:
        - name: weekly.cleanup
          cron: "0 6 * * MON"
          title: Dotted
          body: Tidy.
      """

      {:ok, project} =
        Projects.register(
          %{
            name: "dot-#{System.unique_integer([:positive])}",
            repo_path:
              seeded_repo(%{".forge/workflow.yml" => File.read!(@workflow) <> "\n" <> dotted})
          },
          user
        )

      id = ForgeWeb.SchedulesView.anchor(nil, "weekly.cleanup")
      {:ok, view, _html} = open(conn, project)

      # The confirmation opens its panel with `#<id>-ask`, so each id must be one a selector reads.
      for suffix <- ["-on-ask", "-on-confirm", "-on"],
          do: assert(has_element?(view, "##{id}#{suffix}"))

      view |> element("##{id}-on") |> render_click()
      assert Schedule.on?(Schedules.get(project, nil, "weekly.cleanup"))
    end
  end

  describe "a layout that cannot be read" do
    test "lists the schedules that are on, by name, and an admin may switch one off", %{
      conn: conn,
      project: project,
      user: user
    } do
      {:ok, _} = Schedules.switch_on(project, user, nil, "weekly-cleanup")

      commit_to_default(project, %{
        ".forge/workflows/chore.yml" => File.read!(@workflow)
      })

      {:ok, view, html} = open(conn, project)

      assert html =~ "cannot take a ticket"
      assert has_element?(view, "##{@weekly}")
      assert has_element?(view, "##{@weekly} .schedule-state", "on")
      refute has_element?(view, "##{ForgeWeb.SchedulesView.anchor(nil, "hostile")}")
      assert render(view) =~ "workflow cannot be read"

      view |> element("##{@weekly}-off") |> render_click()
      refute Schedule.on?(row(project))
    end

    test "a member sees the listing and no switch", %{project: project, user: user} do
      {:ok, _} = Schedules.switch_on(project, user, nil, "weekly-cleanup")
      commit_to_default(project, %{".forge/workflows/chore.yml" => File.read!(@workflow)})
      {conn, _member} = member_conn(project)

      {:ok, view, _html} = open(conn, project)

      assert has_element?(view, "##{@weekly} .schedule-state", "on")
      refute has_element?(view, "##{@weekly}-off")
      refute has_element?(view, "##{@weekly} .schedule-controls")
    end

    test "does not list a schedule that is off, though an alert on it is open", %{
      project: project,
      user: user,
      conn: conn
    } do
      {:ok, _} = Schedules.switch_on(project, user, nil, "weekly-cleanup")
      other = user_fixture()
      join!(project, other, :admin)
      {:ok, _} = Projects.put_member(project, user, :member, other)
      assert row(project).alerted_at != nil

      commit_to_default(project, %{".forge/workflows/chore.yml" => File.read!(@workflow)})
      other_conn = log_in_user(Phoenix.ConnTest.build_conn(), other)
      {:ok, view, html} = open(other_conn, project)

      assert html =~ "cannot take a ticket"
      refute has_element?(view, "##{@weekly}")
      _ = conn
    end
  end
end
