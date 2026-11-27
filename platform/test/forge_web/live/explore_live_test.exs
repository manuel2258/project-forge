defmodule ForgeWeb.ExploreLiveTest do
  @moduledoc """
  The explorer (`docs/design/ui.md` § The explorer, criteria 12 to 22 and 31, 34): what a person
  sees of a kept command copy, answered by `Forge.FakeExplore`, which stands in for the machine.
  The round trip to a real machine is `Forge.Explore`'s own test; here the question is what the
  page makes of each answer.

  The copy is a finished command with its `warm_*` columns, as the platform holds one.
  """

  use ForgeWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Forge.BuildFixtures
  import Forge.GitFixtures, only: [tmp_dir: 1]

  alias Forge.{FakeExplore, FakeWorker, Repo}
  alias Forge.Jobs.Job

  @files %{
    "src/main.rs" => {:file, "fn main() {}\n"},
    "src/lib.rs" => {:file, "pub fn a() {}\n"},
    "target/debug/app" => {:file, <<0, 1, 2, 3>>},
    "README.md" => {:file, "# hello\n"},
    "to-etc" => {:link, "/etc/shadow"},
    "<b>bold.txt" => {:file, "x"},
    "big.log" => {:file, "the first of it\n", 41_943_040}
  }

  setup :register_and_log_in_user

  setup %{user: user} do
    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

    worker = FakeWorker.connect()
    {project, ticket} = ticket_on(user)
    # The second is the command that will replace the copy, in the tests that say so.
    [command, spare] = invoke_builds(ticket, worker, [[], ["--later"]])
    job = keep(command, worker, 0, size: 5_242_880, folders: folders())
    FakeExplore.install(@files)
    %{worker: worker, project: project, ticket: ticket, job: job, spare: spare}
  end

  # The names of a listing's rows, as text, in the order they are drawn.
  defp names(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find(".explore-name")
    |> Enum.map(&(&1 |> Floki.text() |> String.trim()))
  end

  defp at(project, ticket, job, query \\ ""),
    do: "/tickets/#{project.name}/#{ticket.number}/builds/#{job.id}" <> query

  defp open(conn, project, ticket, job, query \\ "") do
    {:ok, view, _html} = live(conn, at(project, ticket, job, query))
    render_async(view, 5_000)
    view
  end

  describe "a folder" do
    test "lists folders first and then files, in name order, with what each is", ctx do
      view = open(ctx.conn, ctx.project, ctx.ticket, ctx.job)
      html = view |> element("#explore-entries") |> render()

      assert names(html) == ["src/", "target/", "<b>bold.txt", "README.md", "big.log", "to-etc"]

      # A folder says how many entries it has, a file its size, a link its target.
      assert has_element?(view, "#explore-entry-0", "2 entries")
      assert has_element?(view, "#explore-entry-4", "40 MB")
      assert has_element?(view, "#explore-entry-5", "→ /etc/shadow")
      assert has_element?(view, "#explore-entry-5", "2026-")
    end

    test "draws a name with markup, and one 300 characters long, as text that breaks anywhere",
         ctx do
      long = String.duplicate("n", 300)
      FakeExplore.install(Map.put(@files, long, {:file, "x"}))
      view = open(ctx.conn, ctx.project, ctx.ticket, ctx.job)
      # The text of the entry is the markup itself; no element came of it.
      assert long in names(view |> element("#explore-entries") |> render())
      assert has_element?(view, "#explore-entries", "<b>bold.txt")
      refute has_element?(view, "#explore-entries b")
      assert has_element?(view, "#explore-entries .explore-name.break-all.min-w-0")
    end

    test "draws a name that is not valid text with the replacement character, and still opens it",
         ctx do
      bad = <<0xFF, 0xFE, ".bin">>
      FakeExplore.install(Map.put(@files, bad, {:file, <<1, 2>>}))
      view = open(ctx.conn, ctx.project, ctx.ticket, ctx.job)

      assert render(view) =~ "\uFFFD"

      # The address carries bytes that cannot cross a query string as base64.
      encoded = Base.url_encode64(bad, padding: false)
      assert has_element?(view, ~s(a[href*="path64=#{encoded}"]))

      open(ctx.conn, ctx.project, ctx.ticket, ctx.job, "?path64=#{encoded}")
      assert_received {:explored, :file, ^bad}
    end

    test "shows the first 200 entries and 'show 200 more', then the rest", ctx do
      many =
        for n <- 1..450, into: %{}, do: {"f#{String.pad_leading("#{n}", 3, "0")}", {:file, "x"}}

      FakeExplore.install(many)
      view = open(ctx.conn, ctx.project, ctx.ticket, ctx.job)

      assert has_element?(view, "#explore-entry-199")
      refute has_element?(view, "#explore-entry-200")
      assert has_element?(view, "#explore-more", "show 200 more")

      view |> element("#explore-more") |> render_click()
      assert_patch(view, at(ctx.project, ctx.ticket, ctx.job, "?show=400"))
      render_async(view, 5_000)
      assert has_element?(view, "#explore-entry-399")
      assert has_element?(view, "#explore-more", "show 50 more")

      # The address holds the place: a reload shows the same 400.
      view = open(ctx.conn, ctx.project, ctx.ticket, ctx.job, "?show=400")
      assert has_element?(view, "#explore-entry-399")
      refute has_element?(view, "#explore-entry-400")
    end

    test "opens a folder from its row and says where it is", ctx do
      view = open(ctx.conn, ctx.project, ctx.ticket, ctx.job)
      view |> element("#explore-entry-0 a") |> render_click()
      render_async(view, 5_000)

      # The address is the place and nothing more: `show` is there only when it is not the default.
      assert URI.parse(assert_patch(view)).query == "path=src"
      assert has_element?(view, "#explore-crumbs", "src")
      assert has_element?(view, "#explore-entries", "main.rs")
      refute has_element?(view, "#explore-saved")
    end

    test "is opened at the place the address names, which a shared link reaches", ctx do
      view = open(ctx.conn, ctx.project, ctx.ticket, ctx.job, "?path=src")
      assert has_element?(view, "#explore-entries", "lib.rs")
    end

    test "downloads the whole copy with its size, and a folder without one", ctx do
      view = open(ctx.conn, ctx.project, ctx.ticket, ctx.job)
      assert has_element?(view, ~s(#explore-download[href$="/download"]), "5 MB")

      view = open(ctx.conn, ctx.project, ctx.ticket, ctx.job, "?path=src")
      assert has_element?(view, ~s(#explore-download[href$="/download?path=src"]))
      refute view |> element("#explore-download") |> render() =~ "MB"
    end
  end

  describe "the sizes saved when the copy was kept" do
    test "are the ignored folders, largest first, then the totals", ctx do
      view = open(ctx.conn, ctx.project, ctx.ticket, ctx.job)
      html = view |> element("#explore-saved") |> render()

      {target, _} = :binary.match(html, "target/")
      {deps, _} = :binary.match(html, "deps/")
      assert target < deps
      assert html =~ "2.8 GB"
      assert has_element?(view, "#explore-saved-more", "2 smaller ignored folders")
      assert has_element?(view, "#explore-saved-loose", "3 ignored files")
      assert has_element?(view, "#explore-saved-rest", "everything else")

      assert has_element?(
               view,
               ~s(#explore-saved-0 a[href$="/download?path=target"]),
               "Download"
             )
    end

    test "say so when a release saved none", %{conn: conn, user: user} do
      worker = FakeWorker.connect()
      {project, ticket} = ticket_on(user)
      [command] = invoke_builds(ticket, worker, [[]])
      job = keep(command, worker, 0, folders: nil)
      FakeExplore.install(@files)

      view = open(conn, project, ticket, job)

      assert has_element?(
               view,
               "#explore-saved-none",
               "kept by a release that saved no folder sizes"
             )
    end
  end

  describe "a file" do
    test "shows its size, time, hash and text", ctx do
      view = open(ctx.conn, ctx.project, ctx.ticket, ctx.job, "?path=src/main.rs")
      render_async(view, 5_000)

      assert has_element?(view, "#explore-content", "fn main() {}")
      assert has_element?(view, "#explore-file-facts", "13 B")
      assert has_element?(view, "#explore-file-facts", "2026-")

      expected = Base.encode16(:crypto.hash(:sha256, "fn main() {}\n"), case: :lower)
      assert has_element?(view, "#explore-hash", expected)

      # The whole hash is on the page and wraps: it is not drawn in a value that is cut with an
      # ellipsis (`.ui-fact-value`'s `nowrap`), which is what a phone showed.
      assert has_element?(view, "#explore-hash.break-all")

      css = File.read!("assets/css/areas/explore.css")
      assert css =~ "#explore-file-facts .ui-fact-value"
      assert css =~ ~r/#explore-file-facts \.ui-fact-value \{[^}]*white-space: normal/
      refute css =~ ~r/#explore-file-facts \.ui-fact-value \{[^}]*(nowrap|ellipsis)/
      # Wrapping at any character is what lets a 64-character hash fit a phone.
      assert css =~ ~r/#explore-file-facts \.ui-fact-value \{[^}]*overflow-wrap: anywhere/
      assert has_element?(view, ~s(#explore-download[href*="path=src%2Fmain.rs"]), "13 B")
    end

    test "says how much of a long text file it shows", ctx do
      view = open(ctx.conn, ctx.project, ctx.ticket, ctx.job, "?path=big.log")
      assert has_element?(view, "#explore-truncated", "showing the first 1 MiB of 40 MiB")
    end

    test "offers a file that is not text for download and shows none of it", ctx do
      view = open(ctx.conn, ctx.project, ctx.ticket, ctx.job, "?path=target/debug/app")

      assert has_element?(view, "#explore-not-text")
      refute has_element?(view, "#explore-content")
      assert has_element?(view, "#explore-download", "Download")
    end

    test "shows a link as its target, and never asks the machine for what it points at", ctx do
      view = open(ctx.conn, ctx.project, ctx.ticket, ctx.job, "?path=to-etc")

      assert has_element?(view, "#explore-link-target", "/etc/shadow")
      refute has_element?(view, "#explore-content")
      refute has_element?(view, "#explore-download")

      assert_received {:explored, :list, "to-etc"}
      assert_received {:explored, :file, "to-etc"}
      refute_received {:explored, _op, "/etc/shadow"}
    end

    test "draws a file's content as text, never as markup", ctx do
      FakeExplore.install(%{"x.html" => {:file, "<script>alert(1)</script>"}})
      view = open(ctx.conn, ctx.project, ctx.ticket, ctx.job, "?path=x.html")

      html = view |> element("#explore-content") |> render()
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      refute html =~ "<script>alert"
    end
  end

  describe "the header" do
    test "says how long the copy is held once the machine has answered", ctx do
      view = open(ctx.conn, ctx.project, ctx.ticket, ctx.job)

      assert has_element?(
               view,
               "#explore-held",
               "10 minutes after the last action"
             )

      assert render(view) =~ ~r/held as it was until \d\d:\d\d, 10 minutes/
    end
  end

  describe "when the machine cannot answer" do
    test "says it is asking, with the machine's name, until it has", ctx do
      FakeExplore.gate(true)
      {:ok, view, _html} = live(ctx.conn, at(ctx.project, ctx.ticket, ctx.job))
      machine = "machine " <> String.slice(ctx.worker.id, 0, 8)
      assert has_element?(view, "#explore-asking", "Asking #{machine}…")
      FakeExplore.gate(false)
      render_async(view, 5_000)
      refute has_element?(view, "#explore-asking")
    end

    test "says it did not answer in 15 seconds, and Try again asks it once more", ctx do
      FakeExplore.fail(:machine_not_answering)
      view = open(ctx.conn, ctx.project, ctx.ticket, ctx.job)
      machine = "machine " <> String.slice(ctx.worker.id, 0, 8)

      assert has_element?(
               view,
               "#explore-did-not-answer",
               "#{machine} did not answer in 15 seconds"
             )

      FakeExplore.fail(nil)
      view |> element("#explore-retry") |> render_click()
      render_async(view, 5_000)

      refute has_element?(view, "#explore-did-not-answer")
      assert has_element?(view, "#explore-entries")
    end

    test "says the machine is not connected, and until when its copy can be explored", ctx do
      FakeExplore.fail(:machine_not_connected)
      view = open(ctx.conn, ctx.project, ctx.ticket, ctx.job)
      machine = "machine " <> String.slice(ctx.worker.id, 0, 8)

      assert has_element?(view, "#explore-not-connected", "#{machine} is not connected.")

      assert has_element?(
               view,
               "#explore-not-connected",
               "This copy can be explored when it reconnects, until"
             )

      assert has_element?(view, "#explore-retry", "Try again")
    end

    test "says the machine runs an older release", ctx do
      FakeExplore.fail(:machine_outdated)
      view = open(ctx.conn, ctx.project, ctx.ticket, ctx.job)
      machine = "machine " <> String.slice(ctx.worker.id, 0, 8)

      assert has_element?(
               view,
               "#explore-outdated",
               "#{machine} runs an older release: update it to explore this copy."
             )
    end

    test "says the copy is no longer there, with no more than that when nothing is known", ctx do
      FakeExplore.fail(:no_copy)
      view = open(ctx.conn, ctx.project, ctx.ticket, ctx.job)
      machine = "machine " <> String.slice(ctx.worker.id, 0, 8)

      assert view |> element("#explore-gone") |> render() =~
               "This copy is no longer on #{machine}"
    end

    test "says it was replaced, linking the command that replaced it", ctx do
      # The copy was kept before the command that replaced it finished (timestamps are seconds).
      earlier = DateTime.add(DateTime.utc_now(:second), -600)
      Repo.update_all(from(j in Job, where: j.id == ^ctx.job.id), set: [finished_at: earlier])
      later = keep(ctx.spare, ctx.worker, 0)

      FakeExplore.fail(:copy_gone)
      view = open(ctx.conn, ctx.project, ctx.ticket, ctx.job)

      assert has_element?(view, "#explore-gone", "was replaced")

      assert has_element?(
               view,
               ~s(#explore-replaced-by[href$="/jobs/#{later.id}"]),
               "build"
             )
    end

    test "says a path that is not inside the copy is not, and offers the way back", ctx do
      view = open(ctx.conn, ctx.project, ctx.ticket, ctx.job, "?path=../etc")

      assert has_element?(view, "#explore-refused", "That path is not one inside the copy")
      refute_received {:explored, _op, _path}
    end

    test "says there is nothing at a path the machine does not have", ctx do
      view = open(ctx.conn, ctx.project, ctx.ticket, ctx.job, "?path=nope")
      assert has_element?(view, "#explore-refused", "Nothing is there")
      assert has_element?(view, "#explore-refused a", "Back to the top of the copy")
    end
  end

  describe "who may look" do
    test "a person who is not a member of the project is told there is nothing here", ctx do
      stranger = Forge.AccountsFixtures.user_fixture()
      conn = log_in_user(build_conn(), stranger)

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, at(ctx.project, ctx.ticket, ctx.job))
      end

      refute_received {:explored, _op, _path}
    end

    test "a copy of another ticket answers as one that does not exist", ctx do
      worker = FakeWorker.connect()
      {_project, other_ticket} = ticket_on(ctx.user)
      [command] = invoke_builds(other_ticket, worker, [[]])
      other = keep(command, worker, 0)

      assert_raise Ecto.NoResultsError, fn ->
        live(ctx.conn, at(ctx.project, ctx.ticket, other))
      end

      refute_received {:explored, _op, _path}
    end

    test "an address that is no id at all answers as one that does not exist", ctx do
      assert_raise Ecto.NoResultsError, fn ->
        live(ctx.conn, at(ctx.project, ctx.ticket, %{id: "not-an-id"}))
      end
    end
  end
end
