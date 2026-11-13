defmodule Forge.UsageTest do
  @moduledoc """
  What spent the windows and how fast they fill (`docs/design/capacity.md` § Usage history): the
  pace projected from the latest figure, spend over time from the run ledger, and what spent it —
  with spend in a project the viewer is not in counted and never named.
  """

  use Forge.DataCase, async: true

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.UsageFixtures

  alias Ecto.Multi
  alias Forge.Jobs.{Run, Runs}
  alias Forge.Usage

  @now ~U[2026-11-10 15:20:00Z]

  defp at(time), do: DateTime.new!(~D[2026-11-10], time, "Etc/UTC")

  # A five-hour window that started at 14:00 and resets at 19:00, as the gauge reports it.
  defp five_hour(mean \\ 0.5),
    do:
      Usage.window(
        "five_hour",
        %{mean: mean, reporting: 1, known: 1, soonest: ~U[2026-11-10 19:00:00Z]},
        @now
      )

  describe "pace" do
    # The projection is to the reset, not to the time already gone: at 80 % after four and a half
    # hours the rate fills the rest in 67 minutes, which is after the reset half an hour away — on
    # pace — although it is well within the four and a half hours behind it.
    test "says full in ~N exactly when the projection reaches 100 % before the reset" do
      start = ~U[2026-11-10 10:00:00Z]

      assert {:full_in, seconds} =
               Usage.pace(0.9, start, ~U[2026-11-10 15:00:00Z], ~U[2026-11-10 14:00:00Z])

      # 10 % left at 90 % per four hours: four hours over nine.
      assert seconds == round(0.1 * 4 * 3_600 / 0.9)

      assert Usage.pace(0.8, start, ~U[2026-11-10 15:00:00Z], ~U[2026-11-10 14:30:00Z]) ==
               :on_pace
    end

    # Full exactly as the window resets is not running out: it is on pace.
    test "is on pace when the projection reaches 100 % exactly at the reset" do
      start = ~U[2026-11-10 10:00:00Z]

      assert Usage.pace(0.5, start, ~U[2026-11-10 12:00:00Z], ~U[2026-11-10 11:00:00Z]) ==
               :on_pace
    end

    test "is full at 100 %, on pace at 0, and nothing without a figure, a reset or a start" do
      start = ~U[2026-11-10 10:00:00Z]
      reset = ~U[2026-11-10 15:00:00Z]
      now = ~U[2026-11-10 12:00:00Z]

      assert Usage.pace(1.0, start, reset, now) == {:full_in, 0}
      assert Usage.pace(0.0, start, reset, now) == :on_pace
      assert Usage.pace(nil, start, reset, now) == nil
      assert Usage.pace(0.5, start, nil, now) == nil
      assert Usage.pace(0.5, now, reset, start) == nil
    end

    test "a window's start is its reset less its length, or its length before now when unknown" do
      window = five_hour(0.9)
      assert window.start == ~U[2026-11-10 14:00:00Z]
      # 90 % in 80 minutes: the rest in under nine, long before 19:00.
      assert {:full_in, _seconds} = window.pace

      unknown = Usage.window("seven_day", nil, @now)
      assert unknown.start == DateTime.add(@now, -7 * 86_400)
      assert unknown.resets_at == nil
      assert unknown.pace == nil
      assert unknown.known == 0
    end

    test "windows/2 reads the credentials' reports into both windows" do
      user = user_fixture()
      project = project_fixture() |> join!(user)
      now = DateTime.utc_now(:second)
      credential = credential_fixture(user)

      reported!(project, credential, %{
        "five_hour" => {0.5, DateTime.add(now, 3_600)},
        "seven_day" => {0.2, DateTime.add(now, 86_400)}
      })

      windows = Usage.windows([credential.id], now)
      assert windows["five_hour"].mean == 0.5
      assert windows["five_hour"].start == DateTime.add(now, 3_600 - 5 * 3_600)
      assert windows["seven_day"].mean == 0.2
      assert Usage.windows([], now)["five_hour"].mean == nil
    end
  end

  describe "spend over time" do
    setup do
      user = user_fixture()
      project = project_fixture() |> join!(user)
      %{user: user, project: project, credential: credential_fixture(user)}
    end

    # A bucket holds its start and not its end: 14:59:59 is the 14:45 step's, 15:00:00 the 15:00
    # step's.
    test "puts each run in the fifteen-minute step holding the moment its usage was written", %{
      project: project,
      credential: credential
    } do
      job = chat_fixture(%{project: project})
      spent!(job, credential, 200_000, at(~T[14:59:59]))
      spent!(job, credential, 400_000, at(~T[15:00:00]))
      # Before the window, and on somebody else's credential: neither is in it.
      spent!(job, credential, 1_800_000, at(~T[13:59:59]))
      spent!(job, credential_fixture(user_fixture()), 1_800_000, at(~T[14:10:00]))

      series = Usage.spend_series([credential.id], five_hour(), @now)

      assert length(series) == 20
      used = Enum.map(series, & &1.usage)
      assert Enum.at(used, 3) == 200_000
      assert Enum.at(used, 4) == 400_000
      assert used |> List.delete_at(3) |> List.delete_at(3) |> Enum.all?(&(&1 == 0))

      # 15:20 is in the step from 15:15; everything after it is the time left before the reset.
      assert Enum.map(series, & &1.when) ==
               List.duplicate(:past, 5) ++ [:now] ++ List.duplicate(:future, 14)
    end

    test "draws an open run at the moment it was last counted", %{
      project: project,
      credential: credential
    } do
      chat = chat_fixture(%{project: project})
      spent!(chat, credential, 300_000, at(~T[15:05:00]), open: true)

      series = Usage.spend_series([credential.id], five_hour(), @now)
      assert series |> Enum.at(4) |> Map.fetch!(:usage) == 300_000
    end

    # `Runs.record/3` is `update_all`, which stamps nothing: without writing `updated_at` itself an
    # open conversation's usage would sit at the moment its run opened.
    test "a conversation's turn records the moment it counted the run", %{
      project: project,
      credential: credential
    } do
      chat = chat_fixture(%{project: project})

      run =
        spent!(chat, credential, 0, DateTime.add(DateTime.utc_now(), -3 * 3_600), open: true)

      {:ok, _} = Multi.new() |> Runs.record(chat.id, %{usage: 80_000}) |> Repo.transaction()

      written = Repo.get!(Run, run.id)
      assert DateTime.diff(DateTime.utc_now(), written.updated_at, :second) < 5
      assert written.usage == 80_000
    end

    test "the week is seven days from its start, one bar each", %{credential: credential} do
      reset = ~U[2026-11-16 09:00:00Z]

      week =
        Usage.window("seven_day", %{mean: 0.6, reporting: 1, known: 1, soonest: reset}, @now)

      series = Usage.spend_series([credential.id], week, @now)

      assert Enum.map(series, &Calendar.strftime(&1.from, "%a %H:%M")) ==
               [
                 "Mon 09:00",
                 "Tue 09:00",
                 "Wed 09:00",
                 "Thu 09:00",
                 "Fri 09:00",
                 "Sat 09:00",
                 "Sun 09:00"
               ]

      assert Enum.map(series, & &1.when) == [
               :past,
               :now,
               :future,
               :future,
               :future,
               :future,
               :future
             ]
    end
  end

  describe "what spent it" do
    setup do
      viewer = user_fixture()
      mine = project_fixture(%{name: "game"}) |> join!(viewer)
      theirs = project_fixture(%{name: "secret-project"})
      credential = credential_fixture(viewer)
      %{viewer: viewer, mine: mine, theirs: theirs, credential: credential}
    end

    # The viewer's credential paid for work in a project they are not in: it is counted, as one
    # line, and nothing of it is read beyond its usage.
    test "names nothing in a project the viewer is not a member of", %{
      viewer: viewer,
      mine: mine,
      theirs: theirs,
      credential: credential
    } do
      ours = job_fixture(%{ticket: ticket_fixture(%{project: mine, title: "Persist the scores"})})
      hidden = ticket_fixture(%{project: theirs, title: "The acquisition nobody may know of"})
      spent!(ours, credential, 220_000, at(~T[14:30:00]))
      spent!(job_fixture(%{ticket: hidden}), credential, 80_000, at(~T[14:40:00]))
      spent!(chat_fixture(%{project: theirs}), credential, 20_000, at(~T[14:45:00]))

      for by <- [:item, :project, :model] do
        lines = Usage.breakdown([credential.id], five_hour().start, by, viewer)

        assert [elsewhere] = Enum.filter(lines, & &1.elsewhere)
        assert List.last(lines) == elsewhere
        assert elsewhere.usage == 100_000

        rendered = inspect(lines)
        refute rendered =~ "acquisition"
        refute rendered =~ "secret-project"
        refute rendered =~ theirs.id
      end

      assert [%{job: job, ticket: ticket, project: project}, _elsewhere] =
               Usage.breakdown([credential.id], five_hour().start, :item, viewer)

      assert {job.id, ticket.title, project.name} == {ours.id, "Persist the scores", "game"}
    end

    # Only what the credentials asked about paid for: a colleague's run in the same project, on
    # their own credential, is no line of the viewer's and no part of their spend.
    test "counts only the runs the given credentials paid for", %{
      viewer: viewer,
      mine: mine,
      credential: credential
    } do
      colleague = user_fixture()
      join!(mine, colleague)
      ours = chat_fixture(%{project: mine})
      spent!(ours, credential, 220_000, at(~T[14:30:00]))

      spent!(
        chat_fixture(%{project: mine}),
        credential_fixture(colleague),
        800_000,
        at(~T[14:30:00])
      )

      for by <- [:item, :project, :model] do
        assert [line] = Usage.breakdown([credential.id], five_hour().start, by, viewer)
        assert line.usage == 220_000
      end
    end

    # The unit is a window: 220k weighted tokens of a 1M-token window is 22 % of one.
    test "gives each line its share of a five-hour window, never dollars", %{
      viewer: viewer,
      mine: mine,
      credential: credential
    } do
      spent!(chat_fixture(%{project: mine}), credential, 220_000, at(~T[14:30:00]))

      assert [%{share: share}] =
               Usage.breakdown([credential.id], five_hour().start, :item, viewer)

      assert_in_delta share, 0.22, 1.0e-9
      assert Usage.window_tokens() == 1_000_000
    end

    # With the window's measured figure, the shares are that figure split by usage: they add up
    # to it, whatever a window is configured to hold (UX pass, D6). What is running now is split
    # the same way — of everything spent, not of the running alone.
    test "splits the window's figure by usage when it has one", %{
      viewer: viewer,
      mine: mine,
      credential: credential
    } do
      done = chat_fixture(%{project: mine})
      running = chat_fixture(%{project: mine})
      spent!(done, credential, 600_000, at(~T[14:30:00]))
      spent!(running, credential, 200_000, at(~T[14:40:00]), open: true)

      lines = Usage.breakdown([credential.id], five_hour().start, :item, viewer, of: 0.5)
      assert_in_delta Enum.sum(Enum.map(lines, & &1.share)), 0.5, 1.0e-9
      assert_in_delta Enum.find(lines, &(&1.key == done.id)).share, 0.375, 1.0e-9

      assert [%{share: share}] =
               Usage.breakdown([credential.id], five_hour().start, :item, viewer,
                 of: 0.5,
                 running: true
               )

      assert_in_delta share, 0.125, 1.0e-9

      # Without a figure, the estimate: a share of one 1M-token window.
      assert [_, _] = lines = Usage.breakdown([credential.id], five_hour().start, :item, viewer)
      assert_in_delta Enum.find(lines, &(&1.key == done.id)).share, 0.6, 1.0e-9
      assert_in_delta Enum.find(lines, &(&1.key == running.id)).share, 0.2, 1.0e-9
    end

    test "has no share when the window's size is not configured" do
      previous = Application.get_env(:forge, :capacity)
      Application.put_env(:forge, :capacity, window_tokens: 0)
      on_exit(fn -> Application.put_env(:forge, :capacity, previous) end)

      assert Usage.share(220_000) == nil
    end

    test "puts running items first, then the newest; the rest of a window is counted from its start",
         %{viewer: viewer, mine: mine, credential: credential} do
      old = chat_fixture(%{project: mine})
      new = chat_fixture(%{project: mine})
      running = chat_fixture(%{project: mine})
      spent!(old, credential, 600_000, at(~T[14:10:00]))
      spent!(new, credential, 20_000, at(~T[15:10:00]))
      spent!(running, credential, 40_000, at(~T[14:20:00]), open: true)

      spent!(
        job_fixture(%{ticket: ticket_fixture(%{project: mine})}),
        credential,
        1_000_000,
        at(~T[13:00:00])
      )

      lines = Usage.breakdown([credential.id], five_hour().start, :item, viewer)
      assert Enum.map(lines, & &1.key) == [running.id, new.id, old.id]
      assert Enum.map(lines, & &1.running) == [true, false, false]

      assert [%{key: key}] =
               Usage.breakdown([credential.id], five_hour().start, :item, viewer, running: true)

      assert key == running.id
    end

    test "a conversation is named by what it was opened with", %{
      viewer: viewer,
      mine: mine,
      credential: credential
    } do
      chat = chat_fixture(%{project: mine})

      for text <- ["Why is the build so slow on CI?", "And the tests?"] do
        {:ok, _} =
          Forge.Events.append("chat.message", {:user, viewer.id}, %{
            job_id: chat.id,
            payload: %{"text" => text}
          })
      end

      spent!(chat, credential, 200_000, at(~T[14:30:00]))

      assert [%{opening: "Why is the build so slow on CI?"}] =
               Usage.breakdown([credential.id], five_hour().start, :item, viewer)
    end

    test "by project and by model, largest first; a job that set no model is the project's default",
         %{viewer: viewer, mine: mine, credential: credential} do
      other = project_fixture(%{name: "forge"}) |> join!(viewer)
      opus = chat_fixture(%{project: mine, model: "claude-opus"})

      stated =
        job_fixture(%{
          ticket: ticket_fixture(%{project: other}),
          spec: %{"model" => "claude-opus"}
        })

      default = job_fixture(%{ticket: ticket_fixture(%{project: other})})
      spent!(opus, credential, 200_000, at(~T[14:30:00]))
      spent!(stated, credential, 100_000, at(~T[14:30:00]))
      spent!(default, credential, 400_000, at(~T[14:30:00]))

      assert [{"forge", 500_000}, {"game", 200_000}] =
               for(
                 line <- Usage.breakdown([credential.id], five_hour().start, :project, viewer),
                 do: {line.project.name, line.usage}
               )

      assert [{nil, 400_000}, {"claude-opus", 300_000}] =
               for(
                 line <- Usage.breakdown([credential.id], five_hour().start, :model, viewer),
                 do: {line.model, line.usage}
               )
    end
  end

  describe "credentials" do
    # A pool holds other people's credentials: the panel names only the viewer's own.
    test "names the viewer's own and counts the rest without naming them" do
      viewer = user_fixture()
      mine = credential_fixture(viewer, name: "my-key")
      theirs = credential_fixture(user_fixture(), name: "their-key")
      project = project_fixture() |> join!(viewer)
      now = DateTime.utc_now(:second)
      reported!(project, theirs, %{"five_hour" => {0.6, DateTime.add(now, 3_600)}})

      # The viewer's own, but not in the set asked about: not this panel's.
      _unpooled = credential_fixture(viewer, name: "my-other-key")

      %{own: own, others: others} = Usage.credentials([mine.id, theirs.id], viewer, now)

      assert [%{credential: %{name: "my-key"}, windows: %{}}] = own
      assert others.count == 1
      assert others.gauge["five_hour"].mean == 0.6
      refute inspect(others) =~ "their-key"
    end
  end
end
