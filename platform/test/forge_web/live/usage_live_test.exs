defmodule ForgeWeb.UsageLiveTest do
  @moduledoc """
  `/usage` and the usage panel (`23a`, `23b`, `22e`, `docs/design/ui.md` § Usage): both windows
  with their reset, pace and spend over time; what spent the five-hour window by item, project and
  model; and the two things neither may ever say — a title from a project the viewer is not in,
  and the name of somebody else's credential.
  """

  use ForgeWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.UsageFixtures

  alias Forge.Projects.Member
  alias Forge.Repo

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  setup :register_and_log_in_user

  setup %{user: user} do
    now = DateTime.utc_now(:second)
    game = project_fixture(%{name: "game"}) |> join!(user)
    credential = credential_fixture(user, name: "my-key")

    reported!(game, credential, %{
      "five_hour" => {0.91, DateTime.add(now, 72 * 60)},
      # Five days in at 63 %: the rest would take three more, and it resets in two.
      "seven_day" => {0.63, DateTime.add(now, 2 * 86_400)}
    })

    %{now: now, game: game, credential: credential}
  end

  describe "/usage" do
    test "draws both windows with their figure, reset, pace and spend over time", %{
      conn: conn,
      game: game,
      credential: credential,
      now: now
    } do
      spent!(chat_fixture(%{project: game}), credential, 200_000, DateTime.add(now, -600))

      {:ok, view, _html} = live(conn, ~p"/usage")

      assert text(view, "#usage-five_hour .usage-card-figure") == "91%"
      assert has_element?(view, "#usage-five_hour .usage-card-figure.usage-tone--warning")
      assert text(view, "#usage-five_hour .usage-reset") =~ "↻ resets"
      assert text(view, "#usage-five_hour .usage-reset") =~ "in 1h 1"
      # 91 % in 3h 48m: the rest fills in about 22 minutes, before the reset in 72.
      assert text(view, "#usage-five_hour .usage-pace--full") =~ ~r/^full in ~2\dm at this rate$/
      assert text(view, "#usage-seven_day .usage-card-figure") == "63%"
      assert text(view, "#usage-seven_day .usage-pace") == "on pace"

      # Twenty fifteen-minute steps, the last four or five the time left; seven days.
      assert view
             |> render()
             |> LazyHTML.from_document()
             |> LazyHTML.query("#usage-five_hour .usage-bar")
             |> Enum.count() == 20

      assert has_element?(view, "#usage-five_hour .usage-bar--now.usage-tone--warning")
      assert has_element?(view, ~s(#usage-five_hour .usage-bar--past[data-usage="200000"]))
      assert has_element?(view, "#usage-five_hour .usage-axis span", "now")
      assert has_element?(view, "#usage-seven_day .usage-days .usage-day--now")

      assert view
             |> render()
             |> LazyHTML.from_document()
             |> LazyHTML.query("#usage-seven_day .usage-bar")
             |> Enum.count() == 7
    end

    # The viewer's credential paid for work in a project they have since left: the spend is on
    # the page, as *elsewhere*, and nothing of that project — its name, a ticket's title — is.
    test "counts a run in a project the viewer left and never renders its title", %{
      conn: conn,
      user: user,
      game: game,
      credential: credential,
      now: now
    } do
      left = project_fixture(%{name: "left-behind"}) |> join!(user)
      hidden = ticket_fixture(%{project: left, title: "The acquisition nobody may know of"})
      spent!(job_fixture(%{ticket: hidden}), credential, 100_000, DateTime.add(now, -1_200))

      ticket = ticket_fixture(%{project: game, title: "Persist the high score table"})
      ours = job_fixture(%{ticket: ticket})
      spent!(ours, credential, 220_000, DateTime.add(now, -600))

      Repo.delete_all(from m in Member, where: m.project_id == ^left.id and m.user_id == ^user.id)

      for by <- ~w(item project model) do
        {:ok, view, html} = live(conn, ~p"/usage?by=#{by}")
        refute html =~ "acquisition"
        refute html =~ "left-behind"
        assert text(view, "#usage-line-elsewhere") =~ "elsewhere"
        # 0.50 of the 1.60 spent, of the 91 % the card draws.
        assert text(view, "#usage-line-elsewhere .usage-line-share") == "28%"
      end

      {:ok, view, _html} = live(conn, ~p"/usage")
      line = text(view, "#usage-line-#{ours.id}")
      assert line =~ "game##{ticket.number} · #{ours.state} #1"
      assert line =~ "Persist the high score table"
      # 1.10 of the 1.60 spent, of 91 %: with elsewhere's 28, the card's 91 and not more.
      assert text(view, "#usage-line-#{ours.id} .usage-line-share") == "63%"

      assert has_element?(
               view,
               ~s(#usage-line-#{ours.id} a[href="/tickets/game/#{ticket.number}/jobs/#{ours.id}"])
             )
    end

    test "switches what spent it between item, project and model", %{
      conn: conn,
      game: game,
      credential: credential,
      now: now
    } do
      chat = chat_fixture(%{project: game, status: :running})
      spent!(chat, credential, 80_000, DateTime.add(now, -60), open: true)
      # A second model, so By model has something to say that By item does not.
      opus = chat_fixture(%{project: game, model: "claude-opus"})
      spent!(opus, credential, 20_000, DateTime.add(now, -120))

      {:ok, view, _html} = live(conn, ~p"/usage")
      assert has_element?(view, "#usage-line-#{chat.id}.usage-line--running", "▸ chat · game")

      view |> element(~s(#usage-by button[phx-value-value="project"])) |> render_click()
      assert_patch(view, ~p"/usage?by=project")
      assert text(view, "#usage-line-#{game.id}") =~ "game"
      assert has_element?(view, ~s(#usage-by button[aria-checked="true"]), "By project")

      view |> element(~s(#usage-by button[phx-value-value="model"])) |> render_click()
      assert_patch(view, ~p"/usage?by=model")
      assert text(view, "#usage-line-default") =~ "the project's default"

      # The week's split by project, drawn beside the list on a wide screen: the week's 63 %,
      # all of it game's.
      assert text(view, "#usage-week-projects") =~ "game"
      assert text(view, "#usage-week-projects .usage-week-figure") == "63%"
      assert text(view, "#usage-week-projects") =~ "shares of the 63% above"
    end

    # With one model behind the window, By model is By item's total under another name, so the
    # switch leaves it out — but keeps it while it is the one shown (UX pass, D21).
    test "leaves By model out when one model spent the window", %{
      conn: conn,
      game: game,
      credential: credential,
      now: now
    } do
      spent!(chat_fixture(%{project: game}), credential, 80_000, DateTime.add(now, -60))

      {:ok, view, _html} = live(conn, ~p"/usage")
      assert has_element?(view, ~s(#usage-by button[phx-value-value="project"]))
      refute has_element?(view, ~s(#usage-by button[phx-value-value="model"]))

      {:ok, view, _html} = live(conn, ~p"/usage?by=model")

      assert has_element?(
               view,
               ~s(#usage-by button[phx-value-value="model"][aria-checked="true"])
             )
    end

    # The card says 91 %; what spent it says how that 91 % divides, and never adds up to more
    # (UX pass, D6: shares of a configured window cost read 95 % under a 91 % headline). Three
    # equal items are 30.33 % each: rounded one by one they would read 30 + 30 + 30.
    test "splits the window's figure by usage, adding up to it exactly", %{
      conn: conn,
      game: game,
      credential: credential,
      now: now
    } do
      chats =
        for minutes <- 1..3 do
          chat = chat_fixture(%{project: game})
          spent!(chat, credential, 140_000, DateTime.add(now, -60 * minutes))
          chat
        end

      {:ok, view, _html} = live(conn, ~p"/usage")

      shown =
        for chat <- chats do
          view |> text("#usage-line-#{chat.id} .usage-line-share") |> Integer.parse() |> elem(0)
        end

      # In the page's order, newest first: the point left over goes to the first of equals.
      assert shown == [31, 30, 30]

      # And says that what the credentials did outside forge is in the figure, split in with
      # these (review fixes 7, M2).
      assert text(view, "#usage-legend") =~
               "shares of the 91% above, split by what each used; " <>
                 "use of these credentials outside forge is split in with them"

      # The bars are absolute: a third of 91 % draws about 30 % of the track, not all of it.
      [first | _] = chats

      assert has_element?(
               view,
               ~s(#usage-line-#{first.id} .usage-line-bar span[style="width: 30.3%"])
             )
    end

    # The lines are handed out to the card's own rounded figure. Rounding their sum instead put
    # 95.49999… beside the card's round(95.5): 95 % of lines under a 96 % card (review fixes 7, L1).
    test "the lines add up to the card's figure where float sums fall short of it", %{conn: conn} do
      user = user_fixture()
      game = project_fixture(%{name: "halves"}) |> join!(user)
      credential = credential_fixture(user, name: "half-key")
      now = DateTime.utc_now(:second)
      reported!(game, credential, %{"five_hour" => {0.955, DateTime.add(now, 3_600)}})
      one = chat_fixture(%{project: game})
      two = chat_fixture(%{project: game})
      spent!(one, credential, 20_000, DateTime.add(now, -60))
      spent!(two, credential, 40_000, DateTime.add(now, -120))

      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/usage")

      assert text(view, "#usage-five_hour .usage-card-figure") == "96%"

      shown =
        for chat <- [one, two] do
          view |> text("#usage-line-#{chat.id} .usage-line-share") |> Integer.parse() |> elem(0)
        end

      assert Enum.sum(shown) == 96
    end

    # Under a measured figure, work that has used nothing yet is no share of it — and is not
    # divided by: the total it would be split over is zero (review fixes 7, L2).
    test "draws work that has used nothing under a figure as no share", %{
      conn: conn,
      game: game,
      credential: credential,
      now: now
    } do
      chat = chat_fixture(%{project: game, status: :running})
      spent!(chat, credential, 0, DateTime.add(now, -60), open: true)

      {:ok, view, _html} = live(conn, ~p"/usage")

      assert text(view, "#usage-five_hour .usage-card-figure") == "91%"
      assert text(view, "#usage-line-#{chat.id} .usage-line-share") == "0%"
    end

    test "says a share is an estimate when no credential has reported the window", %{conn: conn} do
      user = user_fixture()
      game = project_fixture(%{name: "quiet"}) |> join!(user)
      credential = credential_fixture(user, name: "quiet-key")
      chat = chat_fixture(%{project: game})
      spent!(chat, credential, 220_000, DateTime.add(DateTime.utc_now(), -60))

      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/usage")

      # 1.10 of a 5.00 window, said to be that.
      assert text(view, "#usage-line-#{chat.id} .usage-line-share") == "22%"
      assert text(view, "#usage-legend") =~ "share of one 5h window, estimated from tokens used"
    end

    # A job that ended without converging says so in words, never as the enum (UX pass, D21).
    test "names how a job ended in words", %{
      conn: conn,
      game: game,
      credential: credential,
      now: now
    } do
      job =
        job_fixture(%{ticket: ticket_fixture(%{project: game, title: "Sound toggle"})})

      Repo.update_all(from(j in Forge.Jobs.Job, where: j.id == ^job.id),
        set: [outcome: :did_not_converge]
      )

      spent!(job, credential, 60_000, DateTime.add(now, -60))

      {:ok, view, _html} = live(conn, ~p"/usage")
      assert text(view, "#usage-line-#{job.id}") =~ "Sound toggle · didn't converge"
      refute render(view) =~ "did_not_converge"
    end

    # Ticks on the hour, not every 75 minutes from wherever the window began (UX pass, D21).
    test "labels the five-hour axis on whole hours", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/usage")

      labels =
        view
        |> render()
        |> LazyHTML.from_document()
        |> LazyHTML.query("#usage-five_hour .usage-axis span")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert "now" in labels
      {hours, ["now" | _end]} = Enum.split_while(labels, &(&1 != "now"))
      assert hours != []
      assert Enum.all?(hours, &String.ends_with?(&1, ":00"))
    end

    test "folds the items after the first five into one line, elsewhere apart", %{
      conn: conn,
      game: game,
      credential: credential,
      now: now
    } do
      for minutes <- 1..7 do
        spent!(
          chat_fixture(%{project: game}),
          credential,
          10_000,
          DateTime.add(now, -60 * minutes)
        )
      end

      {:ok, view, _html} = live(conn, ~p"/usage")
      assert text(view, "#usage-line-earlier") =~ "2 earlier jobs and chats"
      # Two sevenths of the 91 %: the folded lines' shares added up.
      assert text(view, "#usage-line-earlier .usage-line-share") == "26%"
    end

    test "says plainly when nothing reported and nothing spent", %{conn: conn} do
      {:ok, view, _html} = live(log_in_user(conn, user_fixture()), ~p"/usage")

      assert text(view, "#usage-five_hour .usage-card-figure") == "—"
      assert text(view, "#usage-five_hour") =~ "No credential has reported this window."
      assert text(view, "#usage-five_hour .usage-reset") =~ "no reset reported"
      assert text(view, "#usage-spent") =~ "Nothing has spent this window yet."
      refute has_element?(view, "#usage-week-projects")
    end

    test "reads again on its minute", %{conn: conn, game: game, credential: credential, now: now} do
      {:ok, view, _html} = live(conn, ~p"/usage")
      refute has_element?(view, ".usage-line")

      spent!(chat_fixture(%{project: game}), credential, 100_000, now)
      send(view.pid, :usage_tick)
      assert has_element?(view, ".usage-line", "chat · game")
    end

    test "is reached from the title menu and the desktop digits", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")
      assert has_element?(view, ~s(a#usage-digits[href="/usage"]))

      # The menu's Usage row opens the panel, whose Details goes on to the page.
      view |> element("#desktop-header .frame-switch") |> render_click()
      view |> element("#menu-usage", "Usage") |> render_click()
      assert has_element?(view, ~s(#usage-panel-details[href="/usage"]))

      {:ok, view, _html} = live(conn, ~p"/usage")
      assert has_element?(view, ~s(#title-row h1), "Usage")
      view |> element("#desktop-header .frame-switch") |> render_click()
      assert has_element?(view, ~s(#menu-usage[aria-current="page"]))
    end
  end

  describe "the usage panel" do
    # What is running is a part of what spent the window, so its lines add up to their own sum
    # rounded, not to the card's figure, which the rest of the window's work shares (L1).
    test "draws what is running as its share of the figure, not all of it", %{
      conn: conn,
      game: game,
      credential: credential,
      now: now
    } do
      running = chat_fixture(%{project: game, status: :running})
      spent!(running, credential, 20_000, now, open: true)
      spent!(chat_fixture(%{project: game}), credential, 60_000, DateTime.add(now, -600))

      {:ok, view, _html} = live(conn, ~p"/usage")
      view |> element("#usage-5h") |> render_click()

      # A quarter of the usage, a quarter of 91 %.
      assert text(view, "#usage-panel-now .usage-line-share") == "23%"
    end

    # On a page about a project the panel breaks down its pool, which holds a colleague's
    # credential too: counted, never named.
    test "names the viewer's own credentials and never another member's", %{
      conn: conn,
      game: game,
      credential: credential,
      now: now
    } do
      pool!(game, credential)
      colleague = member_fixture(game)
      theirs = pool!(game, credential_fixture(colleague, name: "colleagues-key"))
      reported!(game, theirs, %{"five_hour" => {0.51, DateTime.add(now, 3_600)}})

      running = chat_fixture(%{project: game, status: :running})
      spent!(running, theirs, 40_000, now, open: true)

      {:ok, view, _html} = live(conn, ~p"/projects/game")
      view |> element("#usage-5h") |> render_click()

      panel = text(view, "#usage-panel")
      assert panel =~ "my-key"
      refute panel =~ "colleagues-key"
      assert text(view, "#usage-panel-others") =~ "1 other in game's pool"
      assert text(view, "#usage-panel-others") =~ "5h 51%"

      # The pool's line: 0.91 and 0.51.
      assert text(view, "#usage-panel-five_hour .frame-usage-figure") == "71%"
      assert text(view, "#usage-panel-now") =~ "▸ chat · game"
      assert has_element?(view, ~s(#usage-panel-details[href="/usage"]), "Details ›")
    end

    test "on any other page breaks down the viewer's own, pace and all", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")
      view |> element("#usage-week") |> render_click()

      assert text(view, "#usage-panel-credentials") =~ "my-key 5h 91% · wk 63%"
      refute has_element?(view, "#usage-panel-others")
      assert text(view, "#usage-panel-five_hour .usage-pace--full") =~ "full in ~"
      assert text(view, "#usage-panel-seven_day .usage-pace") == "on pace"
      assert text(view, "#usage-panel-now") =~ "Nothing is running on these credentials."
    end
  end
end
