defmodule Forge.SchedulesTest do
  @moduledoc """
  `Forge.Schedules` (`docs/design/schedules.md`): switching on and off, firing, what a failure
  records, leaving the file, and the queue item that goes with a problem. Time is driven by the
  test: `tick/2` takes the `now` it fires for, always computed from the row's own cursor so that
  nothing here depends on the date the suite runs on.
  """

  use Forge.DataCase, async: false

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Projects, Queue, Schedules, Tickets}
  alias Forge.Push.TestSender
  alias Forge.Schedules.Schedule
  alias ForgeCore.Cron

  @workflow Path.expand("../../../core/test/fixtures/workflow_example.yml", __DIR__)

  # Mondays at 06:00 UTC.
  @weekly """
  schedules:
    - name: weekly-cleanup
      cron: "0 6 * * MON"
      title: Weekly cleanup
      body: |
        Tidy <b>up</b>.
    - name: monthly-deps
      cron: "0 6 1 * *"
      title: Dependencies
      body: Check the dependencies.
  """

  setup do
    TestSender.watch()
    :ok
  end

  defp key(bytes), do: Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false)

  defp subscription(endpoint),
    do: %{"endpoint" => endpoint, "keys" => %{"p256dh" => key(65), "auth" => key(16)}}

  defp workflow(schedules \\ @weekly), do: File.read!(@workflow) <> "\n" <> schedules

  # A project in the single-file form, with `schedules` appended to its workflow, owned by an admin
  # and with a plain member beside them.
  defp project_with(files) do
    owner = user_fixture()
    repo = seeded_repo(files)

    {:ok, project} =
      Projects.register(
        %{name: "sched-#{System.unique_integer([:positive])}", repo_path: repo},
        owner
      )

    member = user_fixture()
    join!(project, member, :member)
    %{project: project, admin: owner, member: member}
  end

  defp single(schedules \\ @weekly),
    do: project_with(%{".forge/workflow.yml" => workflow(schedules)})

  defp typed(files \\ %{}) do
    project_with(
      Map.merge(
        %{
          ".forge/workflow.yml" => nil,
          ".forge/workflows/chore.yml" => workflow(),
          ".forge/workflows/plain.yml" => File.read!(@workflow)
        },
        files
      )
    )
  end

  defp on!(%{project: project, admin: admin}, name \\ "weekly-cleanup", type \\ nil) do
    {:ok, row} = Schedules.switch_on(project, admin, type, name)
    row
  end

  # The time `days` after the row's cursor, which is when the test says it is now.
  defp later(%Schedule{fires_after: at}, days), do: DateTime.add(at, days * 86_400)

  defp row(project, name \\ "weekly-cleanup", type \\ nil), do: Schedules.get(project, type, name)

  defp tickets(project), do: Tickets.all(project)

  defp events(project, type),
    do:
      Repo.all(
        from e in Forge.Events.Event,
          where: e.project_id == ^project.id and e.type == ^type,
          order_by: e.seq
      )

  describe "switching on" do
    test "records who and when, and the time it fires after, and nothing is admitted" do
      ctx = single()
      row = on!(ctx)

      assert row.enabled_by_id == ctx.admin.id
      assert Schedule.on?(row)
      assert row.cron == "0 6 * * MON"
      assert row.fires_after == row.enabled_at
      assert tickets(ctx.project) == []

      assert [%{actor: %{"kind" => "user", "id" => id}, payload: payload}] =
               events(ctx.project, "schedule.switched_on")

      assert id == ctx.admin.id
      assert payload["name"] == "weekly-cleanup" and payload["cron"] == "0 6 * * MON"
    end

    test "is refused for a schedule that is not in the file, writing nothing" do
      ctx = single()

      assert {:error, :schedule_gone} = Schedules.switch_on(ctx.project, ctx.admin, nil, "nope")

      assert {:error, :schedule_gone} =
               Schedules.switch_on(ctx.project, ctx.admin, "chore", "weekly-cleanup")

      assert Schedules.rows(ctx.project) == []
      assert events(ctx.project, "schedule.switched_on") == []
    end

    test "is refused for a file that does not parse, and for a project with no workflow" do
      ctx = single("schedules:\n  - { name: bad, cron: nonsense, title: T, body: B }\n")

      assert {:error, :schedule_unreadable} =
               Schedules.switch_on(ctx.project, ctx.admin, nil, "bad")

      empty = project_with(%{".forge/workflow.yml" => nil})

      assert {:error, :schedule_unreadable} =
               Schedules.switch_on(empty.project, empty.admin, nil, "x")
    end

    test "is refused when it is on already, and keeps the first admin's" do
      ctx = single()
      first = on!(ctx)
      other = user_fixture()
      join!(ctx.project, other, :admin)

      assert {:error, :already_on} =
               Schedules.switch_on(ctx.project, other, nil, "weekly-cleanup")

      assert row(ctx.project).enabled_by_id == ctx.admin.id
      assert row(ctx.project).fires_after == first.fires_after
      assert length(events(ctx.project, "schedule.switched_on")) == 1
    end

    test "another admin may switch it on in their own name after it is off" do
      ctx = single()
      on!(ctx)
      {:ok, _} = Schedules.switch_off(ctx.project, ctx.admin, nil, "weekly-cleanup")
      other = user_fixture()
      join!(ctx.project, other, :admin)

      assert {:ok, row} = Schedules.switch_on(ctx.project, other, nil, "weekly-cleanup")
      assert row.enabled_by_id == other.id
    end
  end

  describe "switching off" do
    test "turns it off, clears its problem, and says who" do
      ctx = single()
      on!(ctx)

      assert {:ok, off} = Schedules.switch_off(ctx.project, ctx.admin, nil, "weekly-cleanup")
      refute Schedule.on?(off)
      assert off.fires_after == nil and off.enabled_at == nil

      assert [%{actor: %{"id" => id}}] = events(ctx.project, "schedule.switched_off")
      assert id == ctx.admin.id
    end

    test "is refused when it is off, or was never on" do
      ctx = single()

      assert {:error, :already_off} =
               Schedules.switch_off(ctx.project, ctx.admin, nil, "weekly-cleanup")

      on!(ctx)
      {:ok, _} = Schedules.switch_off(ctx.project, ctx.admin, nil, "weekly-cleanup")

      assert {:error, :already_off} =
               Schedules.switch_off(ctx.project, ctx.admin, nil, "weekly-cleanup")
    end
  end

  describe "a project nobody switched a schedule on for" do
    test "is never read by the runner" do
      single()
      reads = self()

      assert [] =
               Schedules.tick(DateTime.utc_now(),
                 read: fn _project -> send(reads, :read) && {:error, :none} end
               )

      refute_received :read
    end

    test "is not read once its schedule is off and has no alert either" do
      ctx = single()
      on!(ctx)
      {:ok, _} = Schedules.switch_off(ctx.project, ctx.admin, nil, "weekly-cleanup")
      reads = self()

      assert [] =
               Schedules.tick(DateTime.utc_now(),
                 read: fn _project -> send(reads, :read) && {:error, :none} end
               )

      refute_received :read
    end

    test "one that has a schedule on is read" do
      ctx = single()
      on!(ctx)
      reads = self()

      Schedules.tick(DateTime.utc_now(),
        read: fn _project -> send(reads, :read) && {:error, :none} end
      )

      assert_received :read
    end
  end

  describe "firing" do
    test "admits one ordinary ticket in the admin's name, dated by the time it was due" do
      ctx = single()
      row = on!(ctx)
      now = later(row, 8)
      {:ok, cron} = Cron.parse("0 6 * * MON")
      due = Cron.latest_at_or_before(cron, now)

      assert [{"weekly-cleanup", {:admitted, ticket}}] = Schedules.tick(now)

      assert ticket.title == "Weekly cleanup · #{Date.to_iso8601(DateTime.to_date(due))}"
      assert ticket.body == "Tidy <b>up</b>.\n"
      assert ticket.ticket_type == nil

      reread = row(ctx.project)
      assert reread.fires_after == due
      assert reread.last_ticket_id == ticket.id
      assert reread.problem == nil

      [admitted] = events(ctx.project, "ticket.admitted")
      assert admitted.actor == %{"kind" => "user", "id" => ctx.admin.id}

      assert %{"id" => id, "name" => "weekly-cleanup", "due_at" => due_at, "admin" => email} =
               admitted.payload["schedule"]

      assert id == row.id
      assert due_at == DateTime.to_iso8601(due)
      assert email == ctx.admin.email

      # An ordinary ticket: it pins, has a branch and a first job.
      assert ticket.workflow_commit == ticket.base_commit
      assert Forge.Jobs.for_ticket(ticket.id) != []
    end

    test "the title and body come from the commit the ticket pins" do
      ctx = single()
      row = on!(ctx)

      head =
        commit_to_default(ctx.project, %{
          ".forge/workflow.yml" =>
            workflow(String.replace(@weekly, "Weekly cleanup", "Spring clean"))
        })

      assert [{_, {:admitted, ticket}}] = Schedules.tick(later(row, 8))
      assert ticket.title =~ "Spring clean"
      assert ticket.workflow_commit == head
      assert ticket.base_commit == head
    end

    test "does not fire before it is due, and not for a time already past when it was switched on" do
      ctx = single()
      row = on!(ctx)
      {:ok, cron} = Cron.parse("0 6 * * MON")
      last_before = Cron.latest_at_or_before(cron, row.fires_after)
      assert DateTime.compare(last_before, row.fires_after) != :gt

      assert Schedules.tick(row.fires_after) == []
      assert tickets(ctx.project) == []
    end

    test "a time equal to the one it was switched on at is not after it" do
      ctx = single()
      row = on!(ctx)
      {:ok, cron} = Cron.parse("0 6 * * MON")
      next = Cron.next_after(cron, row.fires_after)

      # Switched on at exactly a due minute: that time is not after it.
      Repo.update_all(from(s in Schedule, where: s.id == ^row.id), set: [fires_after: next])

      assert Schedules.tick(next) == []
      assert tickets(ctx.project) == []
      assert [{_, {:admitted, _}}] = Schedules.tick(DateTime.add(next, 7 * 86_400))
    end

    test "fires although an earlier ticket of it is still open" do
      ctx = single()
      row = on!(ctx)
      assert [{_, {:admitted, first}}] = Schedules.tick(later(row, 8))
      assert first.status == :active

      assert [{_, {:admitted, second}}] = Schedules.tick(later(row, 16))
      assert second.id != first.id
      assert length(tickets(ctx.project)) == 2
    end

    test "times missed while down are made up by one ticket, dated by the latest" do
      ctx = single()
      row = on!(ctx)
      now = later(row, 30)
      {:ok, cron} = Cron.parse("0 6 * * MON")
      latest = Cron.latest_at_or_before(cron, now)

      assert [{_, {:admitted, ticket}}] = Schedules.tick(now)
      assert ticket.title =~ Date.to_iso8601(DateTime.to_date(latest))
      assert length(tickets(ctx.project)) == 1
      assert row(ctx.project).fires_after == latest

      # And it carries on from its next time.
      assert Schedules.tick(DateTime.add(latest, 60)) == []
      assert [{_, {:admitted, _}}] = Schedules.tick(DateTime.add(latest, 8 * 86_400))
    end

    test "a second firing of the same stale row admits nothing" do
      ctx = single()
      row = on!(ctx)
      now = later(row, 8)
      {:ok, cron} = Cron.parse("0 6 * * MON")
      due = Cron.latest_at_or_before(cron, now)

      assert {:admitted, _ticket} = Schedules.fire(ctx.project, row, due, now)
      assert :stale = Schedules.fire(ctx.project, row, due, now)
      assert length(tickets(ctx.project)) == 1
    end

    test "firing a time that is not after the cursor admits nothing, whatever the pass read" do
      ctx = single()
      row = on!(ctx)
      {:ok, cron} = Cron.parse("0 6 * * MON")
      monday = Cron.next_after(cron, row.fires_after)
      Repo.update_all(from(s in Schedule, where: s.id == ^row.id), set: [fires_after: monday])

      assert :not_due = Schedules.fire(ctx.project, row(ctx.project), monday, monday)
      assert tickets(ctx.project) == []
    end

    test "a row switched off between the read and the fire admits nothing" do
      ctx = single()
      row = on!(ctx)
      {:ok, _} = Schedules.switch_off(ctx.project, ctx.admin, nil, "weekly-cleanup")
      now = later(row, 8)
      {:ok, cron} = Cron.parse("0 6 * * MON")

      assert :stale = Schedules.fire(ctx.project, row, Cron.latest_at_or_before(cron, now), now)
      assert tickets(ctx.project) == []
    end

    test "a row switched on again by another admin at the same cursor is not fired from a stale read" do
      ctx = single()
      row = on!(ctx)
      other = user_fixture()
      join!(ctx.project, other, :admin)

      Repo.update_all(from(s in Schedule, where: s.id == ^row.id), set: [enabled_by_id: other.id])

      now = later(row, 8)
      {:ok, cron} = Cron.parse("0 6 * * MON")
      assert :stale = Schedules.fire(ctx.project, row, Cron.latest_at_or_before(cron, now), now)
      assert tickets(ctx.project) == []
    end

    test "a single-file schedule is never fired as the one type a directory implies" do
      # `Tickets.prepare_admission/2` with no type picks the only type of a directory; the schedule
      # was declared in a file that is gone, and must not admit that type's ticket in its place.
      ctx = typed(%{".forge/workflows/plain.yml" => nil})
      now = DateTime.utc_now(:second)

      row =
        Repo.insert!(%Schedule{
          project_id: ctx.project.id,
          ticket_type: nil,
          name: "weekly-cleanup",
          enabled_by_id: ctx.admin.id,
          enabled_at: now,
          fires_after: DateTime.add(now, -9 * 86_400),
          cron: "0 6 * * MON"
        })

      assert :not_due = Schedules.fire(ctx.project, row, now, now)
      assert tickets(ctx.project) == []
    end

    test "the line the file says is kept, so a file that then breaks fails against it" do
      ctx = single()
      row = on!(ctx)

      commit_to_default(ctx.project, %{
        ".forge/workflow.yml" => workflow(String.replace(@weekly, "0 6 * * MON", "0 6 * * 1,2"))
      })

      assert Schedules.tick(row.fires_after) == []
      assert row(ctx.project).cron == "0 6 * * 1,2"
    end

    test "follows the file: an edited cron line is read when it fires" do
      ctx = single()
      row = on!(ctx)

      commit_to_default(ctx.project, %{
        ".forge/workflow.yml" => workflow(String.replace(@weekly, "0 6 * * MON", "0 6 * * *"))
      })

      # Every day now: a firing falls well inside two days, and a Monday-only line might not.
      now = later(row, 2)
      assert [{_, {:admitted, _}}] = Schedules.tick(now)
      assert row(ctx.project).cron == "0 6 * * *"
    end

    test "in a type's file, admits a ticket of that type" do
      ctx = typed()
      row = on!(ctx, "weekly-cleanup", "chore")

      assert [{_, {:admitted, ticket}}] = Schedules.tick(later(row, 8))
      assert ticket.ticket_type == "chore"
      assert row(ctx.project, "weekly-cleanup", "chore").last_ticket_id == ticket.id
    end

    test "never reads one type's schedule from another's file" do
      ctx = typed()
      on!(ctx, "weekly-cleanup", "chore")

      assert {:error, :schedule_gone} =
               Schedules.switch_on(ctx.project, ctx.admin, "plain", "weekly-cleanup")
    end
  end

  describe "a failure to admit" do
    test "admits nothing, records the problem and moves the cursor, and the item is in the queue" do
      ctx = single()
      row = on!(ctx)
      break_file!(ctx)
      now = later(row, 8)
      {:ok, cron} = Cron.parse("0 6 * * MON")
      due = Cron.latest_at_or_before(cron, now)

      assert [{"weekly-cleanup", {:failed, reason}}] = Schedules.tick(now)
      assert reason =~ "does not parse"
      assert tickets(ctx.project) == []

      failed = row(ctx.project)
      assert failed.fires_after == due
      assert failed.problem == reason
      assert failed.problem_kind == :failed
      assert failed.alerted_at != nil
      # The switch is kept: a file that does not parse is not a schedule leaving it.
      assert Schedule.on?(failed)

      assert [%{kind: :schedule, ticket: nil, detail: detail}] = Queue.items(ctx.admin)
      assert detail.name == "weekly-cleanup" and detail.reason == reason
      assert [%{payload: %{"reason" => ^reason}}] = events(ctx.project, "schedule.failed")
    end

    test "is not tried again before the next time" do
      ctx = single()
      row = on!(ctx)
      break_file!(ctx)
      assert [{_, {:failed, _}}] = Schedules.tick(later(row, 8))
      due = row(ctx.project).fires_after
      assert Schedules.tick(DateTime.add(due, 3600)) == []
      assert length(events(ctx.project, "schedule.failed")) == 1
    end

    test "pushes once, and a repeat failure updates the item and does not push again" do
      ctx = single()

      {:ok, _} =
        Forge.Push.subscribe(ctx.admin, subscription("https://push.example/a"))

      row = on!(ctx)
      break_file!(ctx)

      assert [{_, {:failed, _}}] = Schedules.tick(later(row, 8))
      Forge.Push.flush()

      assert_received {:push, "https://push.example/a", %{"title" => title, "body" => body},
                       _opts}

      assert title =~ "Schedule failed on"
      assert body =~ "weekly-cleanup"
      # Backdated, so that a failure that stamped the item afresh would be seen to have done so.
      first_alert = DateTime.add(row(ctx.project).alerted_at, -3600)

      Repo.update_all(from(s in Schedule, where: s.project_id == ^ctx.project.id),
        set: [alerted_at: first_alert]
      )

      assert [{_, {:failed, _}}] = Schedules.tick(later(row, 16))
      Forge.Push.flush()
      refute_received {:push, _, _, _}
      assert length(Queue.items(ctx.admin)) == 1
      assert row(ctx.project).alerted_at == first_alert
      assert length(events(ctx.project, "schedule.failed")) == 2
    end

    test "after a dismissal, a further failure is a new item and pushes again" do
      ctx = single()

      {:ok, _} =
        Forge.Push.subscribe(ctx.admin, subscription("https://push.example/a"))

      row = on!(ctx)
      break_file!(ctx)
      Schedules.tick(later(row, 8))
      Forge.Push.flush()
      assert_received {:push, _, _, _}

      assert {:ok, _} =
               Schedules.dismiss(ctx.project, {:user, ctx.member.id}, nil, "weekly-cleanup")

      assert Queue.items(ctx.admin) == []

      Schedules.tick(later(row, 16))
      Forge.Push.flush()
      assert_received {:push, _, _, _}
      assert [_item] = Queue.items(ctx.admin)
    end

    test "a type whose file cannot be admitted from fails when due" do
      ctx = typed()
      row = on!(ctx, "weekly-cleanup", "chore")
      # The file is there but cannot be admitted from: releases are not admitted as a type.
      commit_to_default(ctx.project, %{
        ".forge/workflows/chore.yml" => "release: true\n" <> workflow()
      })

      assert [{_, {:failed, _}}] = Schedules.tick(later(row, 8))
      assert tickets(ctx.project) == []
      assert Schedule.on?(row(ctx.project, "weekly-cleanup", "chore"))
    end
  end

  describe "leaving the file" do
    test "removed: switched off for good, recorded, with no item" do
      ctx = single()
      on!(ctx)
      commit_to_default(ctx.project, %{".forge/workflow.yml" => workflow("")})

      assert [{"weekly-cleanup", :left}] = Schedules.tick(DateTime.utc_now())
      left = row(ctx.project)
      refute Schedule.on?(left)
      assert left.problem == nil and left.alerted_at == nil
      assert Queue.items(ctx.admin) == []

      assert [%{actor: %{"kind" => "system"}, payload: %{"cause" => "left"}}] =
               events(ctx.project, "schedule.switched_off")
    end

    test "back under the same name it is off until an admin switches it on" do
      ctx = single()
      row = on!(ctx)
      commit_to_default(ctx.project, %{".forge/workflow.yml" => workflow("")})
      Schedules.tick(DateTime.utc_now())
      commit_to_default(ctx.project, %{".forge/workflow.yml" => workflow()})

      assert Schedules.tick(later(row, 8)) == []
      refute Schedule.on?(row(ctx.project))
      assert tickets(ctx.project) == []
    end

    test "renamed, the new name is off" do
      ctx = single()
      row = on!(ctx)

      commit_to_default(ctx.project, %{
        ".forge/workflow.yml" =>
          workflow(String.replace(@weekly, "weekly-cleanup", "weekly-tidy"))
      })

      assert [{"weekly-cleanup", :left}] = Schedules.tick(later(row, 8))
      assert row(ctx.project, "weekly-tidy") == nil
      assert tickets(ctx.project) == []
    end

    test "leaving clears an item that was open" do
      ctx = single()
      row = on!(ctx)
      break_file!(ctx)
      Schedules.tick(later(row, 8))
      assert [_item] = Queue.items(ctx.admin)

      commit_to_default(ctx.project, %{".forge/workflow.yml" => workflow("")})
      assert [{_, :left}] = Schedules.tick(later(row, 9))
      assert Queue.items(ctx.admin) == []
      assert row(ctx.project).problem == nil
    end

    test "a single-file schedule has left once the project moves to types" do
      ctx = single()
      on!(ctx)

      commit_to_default(ctx.project, %{
        ".forge/workflow.yml" => nil,
        ".forge/workflows/chore.yml" => workflow()
      })

      assert [{"weekly-cleanup", :left}] = Schedules.tick(DateTime.utc_now())
      refute Schedule.on?(row(ctx.project))
      assert tickets(ctx.project) == []
    end

    test "a type's schedule has left when its type's file is removed" do
      ctx = typed()
      on!(ctx, "weekly-cleanup", "chore")
      commit_to_default(ctx.project, %{".forge/workflows/chore.yml" => nil})

      assert [{_, :left}] = Schedules.tick(DateTime.utc_now())
      refute Schedule.on?(row(ctx.project, "weekly-cleanup", "chore"))
    end

    test "a file that stops parsing is not a schedule leaving it" do
      ctx = single()
      on!(ctx)
      break_file!(ctx)

      assert Schedules.tick(DateTime.utc_now()) == []
      assert Schedule.on?(row(ctx.project))
    end

    test "a project with no workflow at all is a failure to read, not a departure" do
      ctx = single()
      on!(ctx)
      commit_to_default(ctx.project, %{".forge/workflow.yml" => nil})

      assert Schedules.tick(DateTime.utc_now()) == []
      assert Schedule.on?(row(ctx.project))
    end
  end

  defp break_file!(ctx),
    do: commit_to_default(ctx.project, %{".forge/workflow.yml" => "version: 1\nstates: [\n"})

  describe "its admin can no longer act" do
    defp second_admin(ctx) do
      other = user_fixture()
      join!(ctx.project, other, :admin)
      {:ok, _} = Schedules.switch_on(ctx.project, other, nil, "monthly-deps")
      other
    end

    test "demoted: switched off with why, an item for the members, and another admin's untouched" do
      ctx = single()
      on!(ctx)
      other = second_admin(ctx)

      assert {:ok, _} = Projects.put_member(ctx.project, ctx.admin, :member, other)

      mine = row(ctx.project)
      refute Schedule.on?(mine)
      assert mine.problem_kind == :switched_off
      assert mine.problem =~ ctx.admin.email
      assert mine.alerted_at != nil
      assert Schedule.on?(row(ctx.project, "monthly-deps"))

      assert [%{kind: :schedule, detail: %{name: "weekly-cleanup"}}] = Queue.items(ctx.member)

      assert [%{actor: %{"kind" => "system"}, payload: %{"cause" => "demoted"}}] =
               events(ctx.project, "schedule.switched_off")
    end

    test "demoted in one project, a schedule they switched on in another stays on" do
      ctx = single()
      on!(ctx)
      elsewhere = single()
      join!(elsewhere.project, ctx.admin, :admin)
      {:ok, _} = Schedules.switch_on(elsewhere.project, ctx.admin, nil, "weekly-cleanup")
      other = second_admin(ctx)

      assert {:ok, _} = Projects.put_member(ctx.project, ctx.admin, :member, other)
      refute Schedule.on?(row(ctx.project))
      assert Schedule.on?(row(elsewhere.project))
    end

    test "an admin kept as an admin keeps their schedules" do
      ctx = single()
      on!(ctx)
      other = second_admin(ctx)

      assert {:ok, _} = Projects.put_member(ctx.project, ctx.admin, :admin, other)
      assert Schedule.on?(row(ctx.project))
    end

    test "removed from the project" do
      ctx = single()
      on!(ctx)
      other = second_admin(ctx)

      assert :ok = Projects.remove_member(ctx.project, ctx.admin, other)

      refute Schedule.on?(row(ctx.project))
      assert row(ctx.project).problem =~ "removed"
      assert Schedule.on?(row(ctx.project, "monthly-deps"))
    end

    test "suspended, in every project at once" do
      ctx = single()
      on!(ctx)
      elsewhere = single()
      {:ok, _} = Schedules.switch_on(elsewhere.project, ctx.admin, nil, "weekly-cleanup")
      join!(elsewhere.project, ctx.admin, :admin)
      node_admin = node_admin_fixture()

      assert {:ok, _} = Forge.Accounts.suspend_user(ctx.admin, node_admin)

      refute Schedule.on?(row(ctx.project))
      refute Schedule.on?(row(elsewhere.project))
      assert row(ctx.project).problem =~ "suspended"
    end

    test "a role changed behind the platform's back: nothing is admitted, and it switches itself off" do
      ctx = single()
      row = on!(ctx)

      Repo.update_all(
        from(m in Forge.Projects.Member, where: m.user_id == ^ctx.admin.id),
        set: [role: :member]
      )

      assert [{"weekly-cleanup", {:switched_off, reason}}] = Schedules.tick(later(row, 8))
      assert reason =~ ctx.admin.email
      assert tickets(ctx.project) == []

      off = row(ctx.project)
      refute Schedule.on?(off)
      assert off.problem_kind == :switched_off
      assert off.alerted_at != nil
      assert [%{kind: :schedule}] = Queue.items(ctx.member)
    end

    test "an admin whose account is suspended behind the platform's back admits nothing" do
      ctx = single()
      row = on!(ctx)

      Repo.update_all(from(u in Forge.Accounts.User, where: u.id == ^ctx.admin.id),
        set: [suspended_at: DateTime.utc_now(:second)]
      )

      assert [{_, {:switched_off, _}}] = Schedules.tick(later(row, 8))
      assert tickets(ctx.project) == []
    end
  end

  describe "the queue item" do
    test "is the members' and no one else's" do
      ctx = single()
      row = on!(ctx)
      break_file!(ctx)
      Schedules.tick(later(row, 8))

      stranger = user_fixture()
      assert [_] = Queue.items(ctx.admin)
      assert [_] = Queue.items(ctx.member)
      assert Queue.items(stranger) == []
      assert Queue.count(ctx.member) == 1
    end

    test "is not pushed to a member whose account is suspended" do
      ctx = single()
      {:ok, _} = Forge.Push.subscribe(ctx.member, subscription("https://push.example/member"))
      {:ok, _} = Forge.Push.subscribe(ctx.admin, subscription("https://push.example/admin"))

      Repo.update_all(
        from(u in Forge.Accounts.User, where: u.id == ^ctx.member.id),
        set: [suspended_at: DateTime.utc_now(:second)]
      )

      row = on!(ctx)
      break_file!(ctx)
      Schedules.tick(later(row, 8))
      Forge.Push.flush()

      assert_received {:push, "https://push.example/admin", _payload, _opts}
      refute_received {:push, "https://push.example/member", _payload, _opts}
    end

    test "leaves when the schedule next admits" do
      ctx = single()
      row = on!(ctx)
      break_file!(ctx)
      Schedules.tick(later(row, 8))
      assert [_] = Queue.items(ctx.admin)

      commit_to_default(ctx.project, %{".forge/workflow.yml" => workflow()})
      assert [{_, {:admitted, _}}] = Schedules.tick(later(row, 16))
      assert Queue.items(ctx.admin) == []
      assert row(ctx.project).problem == nil
    end

    test "leaves when an admin switches the schedule off" do
      ctx = single()
      row = on!(ctx)
      break_file!(ctx)
      Schedules.tick(later(row, 8))
      assert [_] = Queue.items(ctx.admin)

      {:ok, _} = Schedules.switch_off(ctx.project, ctx.admin, nil, "weekly-cleanup")
      assert Queue.items(ctx.admin) == []
      assert row(ctx.project).problem == nil
    end

    test "leaves when an admin switches the schedule on again after it switched itself off" do
      ctx = single()
      on!(ctx)
      other = user_fixture()
      join!(ctx.project, other, :admin)
      {:ok, _} = Projects.put_member(ctx.project, ctx.admin, :member, other)
      assert [_] = Queue.items(ctx.member)

      assert {:ok, row} = Schedules.switch_on(ctx.project, other, nil, "weekly-cleanup")
      assert row.alerted_at == nil and row.problem == nil
      assert Queue.items(ctx.member) == []
    end

    test "a dismissal clears the item and keeps the problem, and is recorded with who" do
      ctx = single()
      row = on!(ctx)
      break_file!(ctx)
      Schedules.tick(later(row, 8))
      problem = row(ctx.project).problem

      assert {:ok, dismissed} =
               Schedules.dismiss(ctx.project, {:user, ctx.member.id}, nil, "weekly-cleanup")

      assert dismissed.alerted_at == nil
      assert dismissed.problem == problem
      assert Queue.items(ctx.admin) == []
      assert [%{actor: %{"id" => id}}] = events(ctx.project, "schedule.dismissed")
      assert id == ctx.member.id

      assert {:error, :no_alert} =
               Schedules.dismiss(ctx.project, {:user, ctx.member.id}, nil, "weekly-cleanup")
    end
  end

  describe "declared/3" do
    test "pairs what the files declare with what is kept, by type" do
      ctx = typed()
      row = on!(ctx, "weekly-cleanup", "chore")
      {:ok, types} = Tickets.types(ctx.project)

      [chore, plain] = Schedules.declared(types, Schedules.rows(ctx.project), row.fires_after)
      assert chore.type == "chore" and plain.type == "plain"
      assert plain.schedules == []

      assert [weekly, monthly] = chore.schedules
      assert weekly.name == "weekly-cleanup" and weekly.on
      assert monthly.name == "monthly-deps" and not monthly.on
      assert %DateTime{} = weekly.next_at
    end

    test "a file that does not parse lists the schedules that are on, by name" do
      ctx = single()
      row = on!(ctx)
      break_file!(ctx)
      {:ok, types} = Tickets.types(ctx.project)

      assert [%{type: nil, error: [%ForgeCore.Error{}], schedules: [only]}] =
               Schedules.declared(types, Schedules.rows(ctx.project), row.fires_after)

      assert only.name == "weekly-cleanup" and only.title == nil
    end
  end

  describe "one pass over several projects" do
    test "applies each project's own files to its own schedules" do
      one = single()
      other = typed()
      a = on!(one)
      b = on!(other, "weekly-cleanup", "chore")

      # Neither project's layout may be read against the other's rows: `chore` is not in `one`'s
      # single file, and the nil type is not in `other`'s directory, and either would "leave".
      assert Schedules.tick(a.fires_after) == []
      assert Schedule.on?(row(one.project))
      assert Schedule.on?(row(other.project, "weekly-cleanup", "chore"))

      _ = b
      results = Schedules.tick(later(a, 8))
      assert Enum.count(results, &match?({_, {:admitted, _}}, &1)) == 2
      assert length(tickets(one.project)) == 1
      assert length(tickets(other.project)) == 1
    end
  end

  describe "an alert on a schedule that is off" do
    defp demoted_alert(ctx) do
      on!(ctx)
      other = user_fixture()
      join!(ctx.project, other, :admin)
      {:ok, _} = Projects.put_member(ctx.project, ctx.admin, :member, other)
      other
    end

    test "is left alone by a pass while its schedule is in its file" do
      ctx = single()
      demoted_alert(ctx)
      assert [_] = Queue.items(ctx.member)

      assert Schedules.tick(DateTime.utc_now()) == []
      assert [_] = Queue.items(ctx.member)
      assert row(ctx.project).problem =~ "no longer an admin"
    end

    test "is cleared, with its problem, when the schedule leaves its file" do
      ctx = single()
      demoted_alert(ctx)
      commit_to_default(ctx.project, %{".forge/workflow.yml" => workflow("")})

      assert [{"weekly-cleanup", :left}] = Schedules.tick(DateTime.utc_now())
      assert Queue.items(ctx.member) == []
      left = row(ctx.project)
      assert left.problem == nil and left.alerted_at == nil
      # It was off already: nothing was switched off, so nothing is recorded as being.
      assert [%{payload: %{"cause" => "demoted"}}] = events(ctx.project, "schedule.switched_off")
    end

    test "a schedule an admin switched on between the read and the leave is theirs" do
      ctx = single()
      on!(ctx)
      other = user_fixture()
      join!(ctx.project, other, :admin)
      commit_to_default(ctx.project, %{".forge/workflow.yml" => workflow("")})

      # The pass has read the row, switched on by the first admin; before it looks at the files the
      # schedule changes hands, so that the file's lacking it says nothing about the second's.
      read = fn project ->
        Repo.update_all(from(s in Schedule, where: s.project_id == ^project.id),
          set: [enabled_by_id: other.id]
        )

        Schedules.read_types(project)
      end

      assert Schedules.tick(DateTime.utc_now(), read: read) == []
      assert Schedule.on?(row(ctx.project))
      assert row(ctx.project).enabled_by_id == other.id
    end
  end

  describe "leaving, for a row the pass read off with an alert" do
    test "is not applied to a schedule an admin switched on before the lock" do
      ctx = single()
      on!(ctx)
      other = user_fixture()
      join!(ctx.project, other, :admin)
      {:ok, _} = Projects.put_member(ctx.project, ctx.admin, :member, other)
      commit_to_default(ctx.project, %{".forge/workflow.yml" => workflow("")})
      now = DateTime.utc_now(:second)

      # The pass reads the row off, with its alert; before the lock another admin has it on.
      read = fn project ->
        Repo.update_all(from(s in Schedule, where: s.project_id == ^project.id),
          set: [enabled_by_id: other.id, enabled_at: now, fires_after: now]
        )

        Schedules.read_types(project)
      end

      assert Schedules.tick(DateTime.utc_now(), read: read) == []
      assert row(ctx.project).enabled_by_id == other.id
      assert row(ctx.project).alerted_at != nil
    end
  end

  describe "a withdrawal's alert" do
    defp watch(user, endpoint),
      do: {:ok, _} = Forge.Push.subscribe(user, subscription("https://push.example/" <> endpoint))

    defp second(ctx) do
      other = user_fixture()
      join!(ctx.project, other, :admin)
      other
    end

    test "is pushed to the project's members when a demotion switches a schedule off" do
      ctx = single()
      on!(ctx)
      other = second(ctx)
      watch(ctx.member, "member")

      {:ok, _} = Projects.put_member(ctx.project, ctx.admin, :member, other)
      Forge.Push.flush()

      assert_received {:push, "https://push.example/member", %{"title" => title, "body" => body},
                       _}

      assert title =~ "Schedule switched off on"
      assert body =~ "weekly-cleanup"
    end

    test "is pushed when a removal does, and when a suspension does" do
      ctx = single()
      on!(ctx)
      other = second(ctx)
      watch(ctx.member, "member")
      assert :ok = Projects.remove_member(ctx.project, ctx.admin, other)
      Forge.Push.flush()
      assert_received {:push, "https://push.example/member", _payload, _}

      elsewhere = single()
      join!(elsewhere.project, ctx.admin, :admin)
      {:ok, _} = Schedules.switch_on(elsewhere.project, ctx.admin, nil, "weekly-cleanup")
      watch(elsewhere.member, "elsewhere")
      {:ok, _} = Forge.Accounts.suspend_user(ctx.admin, node_admin_fixture())
      Forge.Push.flush()
      assert_received {:push, "https://push.example/elsewhere", _payload, _}
    end

    test "does not push again while an alert is open, and keeps the item's first time" do
      ctx = single()
      row = on!(ctx)
      break_file!(ctx)
      Schedules.tick(later(row, 8))
      first = DateTime.add(row(ctx.project).alerted_at, -3600)

      Repo.update_all(from(s in Schedule, where: s.project_id == ^ctx.project.id),
        set: [alerted_at: first]
      )

      other = second(ctx)
      watch(ctx.member, "member")
      {:ok, _} = Projects.put_member(ctx.project, ctx.admin, :member, other)
      Forge.Push.flush()

      refute_received {:push, _, _, _}
      assert row(ctx.project).alerted_at == first
      assert row(ctx.project).problem_kind == :switched_off
    end

    test "a withdrawal that finds the row switched on by someone else in between does nothing" do
      ctx = single()
      row = on!(ctx)
      other = second(ctx)
      Repo.update_all(from(s in Schedule, where: s.id == ^row.id), set: [enabled_by_id: other.id])

      # The pass read the row as the first admin's, who has meanwhile lost the right to admit.
      Repo.update_all(from(m in Forge.Projects.Member, where: m.user_id == ^ctx.admin.id),
        set: [role: :member]
      )

      now = later(row, 8)
      {:ok, cron} = Cron.parse("0 6 * * MON")
      assert :stale = Schedules.fire(ctx.project, row, Cron.latest_at_or_before(cron, now), now)
      assert Schedule.on?(row(ctx.project))
      assert row(ctx.project).enabled_by_id == other.id
    end
  end

  describe "items/1" do
    test "are oldest first" do
      one = single()
      two = single()
      a = on!(one)
      b = on!(two)
      break_file!(one)
      break_file!(two)
      Schedules.tick(later(a, 8))
      assert length(Schedules.items(nil)) == 2

      # Backdated, the second project's alert is the older: it comes first.
      Repo.update_all(from(s in Schedule, where: s.project_id == ^two.project.id),
        set: [alerted_at: DateTime.add(row(one.project).alerted_at, -3600)]
      )

      _ = b
      assert [%{project: %{id: first}}, %{project: %{id: second}}] = Schedules.items(nil)
      assert first == two.project.id and second == one.project.id
    end
  end

  describe "the operations" do
    alias Forge.Operator

    test "switching on is a project admin's and no member's, and a non-member's is refused" do
      ctx = single()
      stranger = user_fixture()

      assert {:error, :forbidden} =
               Operator.switch_schedule_on(ctx.project, ctx.member, nil, "weekly-cleanup")

      assert {:error, :forbidden} =
               Operator.switch_schedule_on(ctx.project, stranger, nil, "weekly-cleanup")

      assert Schedules.rows(ctx.project) == []

      assert {:ok, %Schedule{}} =
               Operator.switch_schedule_on(ctx.project, ctx.admin, nil, "weekly-cleanup")
    end

    test "switching off is the same" do
      ctx = single()
      on!(ctx)
      stranger = user_fixture()

      assert {:error, :forbidden} =
               Operator.switch_schedule_off(ctx.project, ctx.member, nil, "weekly-cleanup")

      assert {:error, :forbidden} =
               Operator.switch_schedule_off(ctx.project, stranger, nil, "weekly-cleanup")

      assert Schedule.on?(row(ctx.project))

      assert {:ok, _} =
               Operator.switch_schedule_off(ctx.project, ctx.admin, nil, "weekly-cleanup")
    end

    test "dismissing is any member's, a write token's, and nobody else's" do
      ctx = single()
      row = on!(ctx)
      break_file!(ctx)
      Schedules.tick(later(row, 8))
      stranger = user_fixture()

      {:ok, _secret, read} =
        Forge.Git.Tokens.issue(ctx.project, name: "r", git: :reader, api: :read)

      {:ok, _secret, write} =
        Forge.Git.Tokens.issue(ctx.project, name: "w", git: :reader, api: :write)

      for who <- [stranger, read] do
        assert {:error, :forbidden} =
                 Operator.dismiss_schedule(ctx.project, who, nil, "weekly-cleanup")

        assert row(ctx.project).alerted_at
      end

      assert {:ok, _} = Operator.dismiss_schedule(ctx.project, write, nil, "weekly-cleanup")
      assert row(ctx.project).alerted_at == nil
      assert [%{actor: %{"kind" => "api"}}] = events(ctx.project, "schedule.dismissed")
    end
  end

  describe "the runner" do
    test "fires what has come due, by itself" do
      ctx = single()
      row = on!(ctx)

      Repo.update_all(from(s in Schedule, where: s.id == ^row.id),
        set: [fires_after: DateTime.add(row.fires_after, -9 * 86_400)]
      )

      Application.put_env(:forge, :schedule_poll_ms, 50)
      on_exit(fn -> Application.delete_env(:forge, :schedule_poll_ms) end)
      start_supervised!(Forge.Schedules.Runner)

      assert eventually(fn -> tickets(ctx.project) != [] end)
      assert [%{title: "Weekly cleanup · " <> _}] = tickets(ctx.project)
    end

    test "a project that cannot be read does not stop the others" do
      broken = single()
      good = single()
      row = on!(broken)
      good_row = on!(good)

      for r <- [row, good_row],
          do:
            Repo.update_all(from(s in Schedule, where: s.id == ^r.id),
              set: [fires_after: DateTime.add(r.fires_after, -9 * 86_400)]
            )

      read = fn project ->
        if project.id == broken.project.id,
          do: raise("the repository is gone"),
          else: Schedules.read_types(project)
      end

      log =
        ExUnit.CaptureLog.capture_log(fn -> Schedules.tick(DateTime.utc_now(), read: read) end)

      assert log =~ "the repository is gone"
      assert [_] = tickets(good.project)
      assert tickets(broken.project) == []
    end
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end
end
