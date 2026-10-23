defmodule ForgeWeb.PhoneTest do
  @moduledoc """
  The phone (`docs/design/ui.md` § The phone): a bar of Queue, Board, Chats and More; the sheet
  More opens, with everything the laptop keeps in its header; a board that stacks and expands a
  column in place; tables that reflow without losing their controls; and the 46px floor, which
  has no phone exception.

  The widths themselves are CSS no test here can apply. What is pinned is the markup each rule
  depends on, aimed at the rule — the row in the sheet, the ticket already on the page, the
  control still in its row — rather than at a class name standing in for it where a behaviour
  can be asserted instead.
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Projects, Tickets}
  alias ForgeWeb.Operator.Board

  setup :register_and_log_in_user

  # What a person reads inside an element, attributes excluded: the capacity gauge's `title` and
  # its ticks' `aria-label` carry the percentage whether or not it is drawn, so the markup as a
  # string cannot tell a number on the screen from one on hover.
  defp drawn(view, selector) do
    view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
  end

  describe "the bar" do
    test "carries Queue, Board, Chats and More", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      bar = view |> element("nav.fixed.bottom-0") |> render()
      assert bar =~ ~s(href="/")
      assert bar =~ ~s(href="/board")
      assert bar =~ ~s(href="/chats")
      assert bar =~ ~s(id="more-button")
    end

    # A dispatched event and the element's own showModal(): focus and inertness come from the
    # dialog, not from code.
    test "opens the More sheet, a native dialog", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      more = view |> element("#more-button") |> render()
      assert more =~ "forge:sheet-open"
      assert more =~ "#more"
      assert has_element?(view, "dialog#more.modal.modal-bottom")
    end
  end

  describe "the More sheet" do
    # The release this node runs, as the last line of the sheet: a phone has no top bar to put it
    # beside the wordmark in (docs/design/ui.md § Navigation).
    test "ends with the version the node runs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      version = :forge |> Application.spec(:vsn) |> to_string()

      assert version == String.trim(File.read!(Path.expand("../../../../VERSION", __DIR__)))
      assert view |> element("dialog#more #more-version") |> render() =~ "forge #{version}"

      sheet = view |> element("dialog#more") |> render()
      {log_out, _length} = :binary.match(sheet, ~s(href="/users/log-out"))
      {line, _length} = :binary.match(sheet, ~s(id="more-version"))
      assert line > log_out, "the version is not the sheet's last line"
    end

    test "holds the places and the account, in order, each a 46px row", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/")
      sheet = view |> element("dialog#more") |> render()

      order =
        for marker <- [
              ~s(href="/workers"),
              ~s(href="/templates"),
              ~s(href="/projects/new"),
              ~s(href="/users/settings"),
              "phx:set-theme",
              ~s(href="/users/log-out")
            ] do
          {at, _length} = :binary.match(sheet, marker)
          at
        end

      assert order == Enum.sort(order)
      assert sheet =~ user.email

      for href <- ~w(/workers /templates /projects/new /users/settings /users/log-out) do
        link = view |> element(~s(dialog#more a[href="#{href}"])) |> render()
        assert link =~ "min-h-[46px]", "#{href} is under the floor"
      end
    end

    # Account governance is a node admin's; a link to it anyone else can see is a link to a
    # page they are refused.
    test "offers Accounts to a node admin only", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, ~s(dialog#more a[href="/accounts"]))

      admin = node_admin_fixture()
      {:ok, view, _html} = live(log_in_user(build_conn(), admin), ~p"/")
      assert has_element?(view, ~s(dialog#more a[href="/accounts"]), "Accounts")
    end

    # A phone has no hover, so the gauge's title is written out as a line under it.
    test "writes the capacity gauge out", %{conn: conn, user: user} do
      project = project_fixture()
      join!(project, user, :member)
      credential = pool!(project, credential_fixture(user))
      job = chat_fixture(%{project: project})

      {:ok, _job} =
        job |> Ecto.Changeset.change(credential_id: credential.id) |> Forge.Repo.update()

      :ok =
        Forge.Jobs.record_harness_event(job.id, %{
          type: "job.harness.rate_limit",
          payload: %{
            status: "allowed_warning",
            rate_limit_type: "five_hour",
            utilization: 0.9,
            resets_at: System.os_time(:second) + 3600
          }
        })

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#more-capacity-five_hour")
      assert has_element?(view, "#more-capacity p", "5h window: 90% used on average")

      # Said once. The sentence states the percentage, so the gauge above it draws its ticks and
      # its countdown and no number — the same digits twice, two lines apart, is what writing
      # the title out is for (`docs/design/ui.md` § The capacity gauge in the top bar). Read as
      # text, because the gauge's `title` and its ticks' `aria-label` carry the figure either way.
      refute drawn(view, "#more-capacity-five_hour") =~ "%"

      # A work screen draws no More sheet; its details sheet carries the written-out gauge for
      # the strip's compact one.
      {:ok, chat_view, _html} = live(conn, ~p"/chats/#{job.id}")
      refute has_element?(chat_view, "dialog#more")
      assert has_element?(chat_view, "dialog#details #details-capacity p", "5h window")

      # The compact one ends the strip, on a ticket's work screen as on a conversation's.
      ticket = ticket_fixture(%{project: project})
      {:ok, ticket_view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")

      for view <- [chat_view, ticket_view] do
        assert has_element?(view, "#context-strip #strip-five_hour")

        # And it draws the number: the strip is the second surface the ticket names, and it gets
        # the number from `figure`'s default rather than from anything it says. Without this,
        # `figure={false}` on the strip's own call would pass the whole suite.
        assert drawn(view, "#context-strip #strip-five_hour") =~ "90%"
      end
    end
  end

  describe "the board" do
    setup %{user: user} do
      {:ok, project} =
        Projects.register(
          %{name: "phone-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
          user
        )

      tickets =
        for n <- 1..6 do
          {:ok, ticket} = Tickets.admit(project, %{title: "Ticket #{n}"}, {:user, user.id})
          ticket
        end

      %{project: project, tickets: tickets}
    end

    # The tickets "N more" reveals are already on the page; the control shows them in place
    # rather than navigating to a page that has them. Each ticket is on the page once, the four
    # shown and the rest in a hidden block, and the button's own command shows that block.
    test "expands a column in place, with every ticket already on the page", %{
      conn: conn,
      project: project,
      tickets: tickets
    } do
      {:ok, _view, html} = live(conn, ~p"/board")
      column = "#" <> Board.column_id(project.name, "refining")
      doc = Floki.parse_document!(html)

      for ticket <- tickets do
        href = "/tickets/#{project.name}/#{ticket.number}"
        assert [_once] = Floki.find(doc, ~s(#{column} a[href="#{href}"]))
      end

      [hidden] = Floki.find(doc, column <> "-more")
      assert "hidden" in (hidden |> Floki.attribute("class") |> hd() |> String.split())
      assert length(Floki.find(hidden, "a")) == 2

      [button] = Floki.find(doc, column <> "-expand")
      assert Floki.text(button) =~ "2 more"
      assert expands?(doc, button, hidden)
    end

    # A state's name may hold what a selector reads as syntax: `code.review` is an id and a
    # class. The command still finds the block it shows.
    test "expands a column whose state's name has a dot in it" do
      tickets =
        for n <- 1..5,
            do: %Tickets.Ticket{
              id: "t#{n}",
              number: n,
              title: "T#{n}",
              status: :active,
              updated_at: DateTime.utc_now()
            }

      column = %{
        name: "code.review",
        topology: :human,
        tickets: tickets,
        shown: Enum.take(tickets, 4),
        more: 1
      }

      html =
        render_component(&Board.column/1, column: column, project: "p.x", now: DateTime.utc_now())

      doc = Floki.parse_document!(html)
      [button] = Floki.find(doc, "button[phx-click]")
      [hidden] = Floki.find(doc, "#" <> Board.column_id("p.x", "code.review") <> "-more")

      assert expands?(doc, button, hidden)
    end

    # What the button's command does, read from the command itself: it shows exactly the block
    # of hidden tickets, and hides only the button.
    defp expands?(doc, button, hidden) do
      [[op, %{"to" => target}] | rest] =
        button |> Floki.attribute("phx-click") |> hd() |> Jason.decode!()

      op == "show" and Floki.find(doc, target) == [hidden] and
        Enum.all?(rest, fn [op, args] -> op == "hide" and not Map.has_key?(args, "to") end)
    end

    # A state with nothing in it is its heading and a muted 0, not a sentence about absence.
    test "draws an empty state as its heading and a muted 0", %{conn: conn, project: project} do
      {:ok, view, html} = live(conn, ~p"/board")

      refute html =~ "nothing in this state"
      merged = view |> element("#" <> Board.column_id(project.name, "merged")) |> render()
      assert merged =~ ~r/opacity-30[^>]*>\s*0\s*</
    end

    test "stacks below sm and runs in columns from it", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/board")

      column = view |> element("#" <> Board.column_id(project.name, "refining")) |> render()
      assert column =~ "w-full"
      assert column =~ "sm:w-60"
    end
  end

  describe "tables" do
    # One block per row below sm: every cell but the identity carries its label, and the row
    # keeps its controls — a table scrolled sideways would hide the decision off the edge. The
    # workers page draws no table (`ui.md` § The workers page); its blocks are its own tests'.
    test "a project's workflow table reflows", %{conn: conn, user: user} do
      {:ok, project} =
        Projects.register(
          %{name: "flow-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
          user
        )

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      assert has_element?(view, "table#workflow.reflow")
      assert has_element?(view, ~s(table#workflow td[data-label="Goes to"]))
    end

    # Its mirrors, which need a repository at the standard address, are
    # `ProjectSettingsMirrorTest`'s.
    test "a project's tokens reflow and keep their controls", %{
      conn: conn,
      user: user
    } do
      {:ok, project} =
        Projects.register(
          %{name: "tok-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
          user
        )

      {:ok, _token, _row} = Forge.Git.Tokens.issue(project)

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")

      assert has_element?(view, ~s(table#tokens.reflow td[data-label="Expires"]))
      assert has_element?(view, ~s(table#tokens tbody tr button[phx-click="revoke"]))
    end
  end

  describe "the 46px floor" do
    test "holds for the theme toggle's buttons", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      for theme <- ~w(system light dark) do
        button =
          view |> element(~s(dialog#more button[data-phx-theme="#{theme}"])) |> render()

        assert button =~ "min-h-[46px]"
        assert button =~ "min-w-[46px]"
      end
    end

    test "holds for a worker's unassign and its select", %{conn: conn, user: user} do
      {:ok, project} = Projects.register(%{name: "floor", repo_path: seeded_repo()}, user)

      {:ok, worker, _token} =
        Forge.Workers.create(%{provider: "fake", managed: false, user_id: user.id})

      {:ok, _} = Forge.Workers.assign(user, worker.id, project.id)
      {:ok, view, _html} = live(conn, ~p"/workers")

      unassign = view |> element(~s(button[phx-click="unassign"])) |> render()
      assert unassign =~ "min-h-[46px]"
      assert unassign =~ "min-w-[46px]"
      assert view |> element(~s(form[phx-submit="assign"] select)) |> render() =~ "h-[46px]"
    end
  end
end
