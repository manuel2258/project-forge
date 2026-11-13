defmodule ForgeWeb.ReleasesLiveTest do
  @moduledoc """
  A project's releases where an operator reads them (`docs/design/ui.md` § A project's releases):
  who may see them, the list and its bound, each of the four things a tag can have come to, the
  empty states, a release appearing while the page is open, and values that came from a document.
  Records are inserted directly: how one is written is `Forge.ReleaseRecordsTest`'s.
  """

  use ForgeWeb.ConnCase, async: false

  import Forge.AccountsFixtures
  import Forge.GitFixtures
  import Phoenix.LiveViewTest

  alias Forge.{Events, Projects, ReleaseRecords, Repo, Tickets}
  alias Forge.ReleaseRecords.Record

  @release """
  version: 1
  description: Cut a release.
  release: true
  initial: releasing
  states:
    releasing:
      prompt: agents/release.md
      produces: [release-notes.md]
      budget: { turns: 10, tokens: 200k }
    published: {}
  transitions:
    - { from: releasing, to: published }
  limits: { ticket_tokens: 1M }
  """

  @dev """
  version: 1
  description: Ordinary work.
  initial: implementing
  states:
    implementing:
      prompt: agents/implement.md
      produces: [implementation.md]
      budget: { turns: 10, tokens: 200k }
    review_ready: {}
  transitions:
    - { from: implementing, to: review_ready }
  limits: { ticket_tokens: 1M }
  """

  setup :register_and_log_in_user

  setup %{user: user} do
    repos = node_repos_dir()
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :repos_dir, repos))
    on_exit(fn -> Application.put_env(:forge, Forge.Jobs, original) end)

    register = fn files ->
      {:ok, project} =
        Projects.register(
          %{
            name: "rels-#{System.unique_integer([:positive])}",
            repo_path:
              seeded_repo(
                Map.merge(
                  %{
                    ".forge/workflow.yml" => nil,
                    ".forge/agents/release.md" => "Cut it.\n",
                    ".forge/agents/implement.md" => "Do it.\n",
                    ".forge/workflows/dev.yml" => @dev,
                    ".forge/workflows/release.yml" => @release
                  },
                  files
                )
              )
          },
          user
        )

      project
    end

    %{register: register, project: register.(%{})}
  end

  @sha "0123456789abcdef0123456789abcdef01234567"
  @other "fedcba9876543210fedcba9876543210fedcba98"

  # A record for a ticket of its own (a ticket has one), concluded `minutes` ago.
  defp record!(project, attrs \\ %{}) do
    {:ok, ticket} =
      Tickets.admit(project, %{title: "Release in progress", ticket_type: "dev"})

    base = %{
      project_id: project.id,
      ticket_id: ticket.id,
      version: "1.0.0",
      concluded_at: DateTime.utc_now(),
      commit_sha: @sha,
      tag_name: "v1.0.0",
      tag_status: :tagged
    }

    Repo.insert!(struct(Record, Map.merge(base, attrs)))
  end

  describe "who may see them" do
    test "a non-member gets the miss a project that does not exist gets, on every address", ctx do
      record = record!(ctx.project)
      outsider = user_fixture()
      Forge.ForgeFixtures.join!(Forge.ForgeFixtures.project_fixture(), outsider)
      conn = log_in_user(ctx.conn, outsider)

      for path <- [
            ~p"/projects/#{ctx.project.name}/releases",
            ~p"/projects/#{ctx.project.name}/releases/#{record.id}"
          ] do
        assert_raise Ecto.NoResultsError, fn -> live(conn, path) end
      end
    end

    # `identity.md`: a node admin is not implicitly a member of any project, and the project page
    # is a miss to them. These addresses answer exactly as it does.
    test "a node admin who is no member gets the project page's answer", ctx do
      record = record!(ctx.project)
      conn = log_in_user(ctx.conn, node_admin_fixture())

      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/projects/#{ctx.project.name}") end

      for path <- [
            ~p"/projects/#{ctx.project.name}/releases",
            ~p"/projects/#{ctx.project.name}/releases/#{record.id}"
          ] do
        assert_raise Ecto.NoResultsError, fn -> live(conn, path) end
      end
    end

    test "a record of another project, or no record, or no id, is a miss", ctx do
      other = ctx.register.(%{})
      foreign = record!(other)

      for id <- [foreign.id, Ecto.UUID.generate(), "nope"] do
        assert_raise Ecto.NoResultsError, fn ->
          live(ctx.conn, ~p"/projects/#{ctx.project.name}/releases/#{id}")
        end
      end
    end
  end

  describe "the list" do
    test "holds this project's releases only, in the list, the count and the latest line", ctx do
      other = ctx.register.(%{})
      mine = record!(ctx.project, %{version: "1.0.0"})
      for n <- 1..25, do: record!(other, %{version: "8.0.#{n}"})

      {:ok, view, html} = live(ctx.conn, ~p"/projects/#{ctx.project.name}/releases")
      assert has_element?(view, "#release-#{mine.id}")
      refute html =~ "8.0."
      refute has_element?(view, "#show-more")

      {:ok, home, _html} = live(ctx.conn, ~p"/projects/#{ctx.project.name}")
      assert has_element?(home, "#latest-release", "1.0.0")
      refute has_element?(home, "#latest-release", "8.0.")
    end

    test "is newest first, each entry linking to its own page", ctx do
      older =
        record!(ctx.project, %{version: "1.0.0", concluded_at: ~U[2026-01-01 10:00:00.000000Z]})

      newer =
        record!(ctx.project, %{version: "1.1.0", concluded_at: ~U[2026-02-01 10:00:00.000000Z]})

      {:ok, view, _html} = live(ctx.conn, ~p"/projects/#{ctx.project.name}/releases")

      ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("article")
        |> LazyHTML.attribute("id")

      assert ids == ["release-#{newer.id}", "release-#{older.id}"]

      assert has_element?(
               view,
               ~s|#release-#{newer.id} h2 a[href="/projects/#{ctx.project.name}/releases/#{newer.id}"]|,
               "1.1.0"
             )
    end

    test "shows twenty, then more by a link, and every release is reachable", ctx do
      records =
        for n <- 1..45 do
          record!(ctx.project, %{
            version: "2.0.#{n}",
            concluded_at: DateTime.add(~U[2026-01-01 00:00:00.000000Z], n, :minute)
          })
        end

      count = fn view ->
        view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("article") |> Enum.count()
      end

      {:ok, view, _html} = live(ctx.conn, ~p"/projects/#{ctx.project.name}/releases")
      assert count.(view) == 20
      assert has_element?(view, "#show-more", "25 older")
      refute has_element?(view, "#release-#{hd(records).id}")

      view |> element("#show-more") |> render_click()
      assert_patch(view, ~p"/projects/#{ctx.project.name}/releases?shown=40")
      assert count.(view) == 40

      {:ok, view, _html} = live(ctx.conn, ~p"/projects/#{ctx.project.name}/releases?shown=60")
      assert count.(view) == 45
      assert has_element?(view, "#release-#{hd(records).id}")
      refute has_element?(view, "#show-more")
    end

    test "shown below the first page's size is the first page, and one past a bigint is capped",
         ctx do
      for n <- 1..25, do: record!(ctx.project, %{version: "3.0.#{n}"})

      articles = fn html ->
        html |> LazyHTML.from_fragment() |> LazyHTML.query("article") |> Enum.count()
      end

      # Not three: a count under one step reads as one step.
      {:ok, _view, html} = live(ctx.conn, ~p"/projects/#{ctx.project.name}/releases?shown=3")
      assert articles.(html) == 20

      # More than a bigint holds is capped rather than sent to the database.
      {:ok, _view, html} =
        live(ctx.conn, ~p"/projects/#{ctx.project.name}/releases?shown=99999999999999999999999")

      assert articles.(html) == 25
    end

    test "a bad shown is the first page, not an error", ctx do
      record!(ctx.project)

      for bad <- ["abc", "-5", "0", "20x", ""] do
        assert {:ok, _view, html} =
                 live(ctx.conn, ~p"/projects/#{ctx.project.name}/releases?shown=#{bad}")

        assert html =~ "1.0.0"
      end
    end
  end

  describe "an entry" do
    test "shows version, tag, date, short commit linked, ticket, notes, files and links", ctx do
      record =
        record!(ctx.project, %{
          concluded_at: ~U[2026-03-04 05:06:07.000000Z],
          notes: "# Changes\n\nFixed **things**.",
          files: [
            %{"name" => "dist/forge-linux.tar.gz", "version" => 2, "size" => 1_572_864},
            %{"name" => "dist/tiny.txt", "version" => 1, "size" => 12},
            %{"name" => "dist/kib.bin", "version" => 1, "size" => 1024},
            %{"name" => "dist/mib.bin", "version" => 1, "size" => 1_048_576},
            %{"name" => "dist/gone.bin", "version" => 1, "size" => nil}
          ],
          links: [
            %{
              "label" => "Image",
              "url" => "https://ghcr.io/x/forge",
              "document" => "n",
              "version" => 1
            }
          ]
        })

      {:ok, view, _html} = live(ctx.conn, ~p"/projects/#{ctx.project.name}/releases/#{record.id}")
      ticket = Repo.preload(record, :ticket).ticket
      p = ctx.project.name

      assert render(view) =~ "Tagged v1.0.0"
      assert render(view) =~ "2026-03-04"
      assert has_element?(view, ~s|a[href="/projects/#{p}/repo/commits/#{@sha}"]|, "0123456")
      assert has_element?(view, ~s|a[href="/tickets/#{p}/#{ticket.number}"]|)
      assert has_element?(view, "article .doc h1", "Changes")
      assert has_element?(view, "article .doc strong", "things")

      assert has_element?(
               view,
               ~s|a[href="/tickets/#{p}/#{ticket.number}/artifacts/dist%2Fforge-linux.tar.gz/2"]|,
               "1.5 MB"
             )

      assert has_element?(view, "article a", "12 B")
      assert has_element?(view, "article a", "size unknown")
      assert has_element?(view, "article a", "1 KB")
      assert has_element?(view, "article a", "1.0 MB")
      assert has_element?(view, ~s|a[href="https://ghcr.io/x/forge"][rel~=noopener]|, "Image")
    end

    test "a record with no version is headed plainly", ctx do
      record = record!(ctx.project, %{version: nil, tag_name: nil, tag_status: :no_version})
      {:ok, view, _html} = live(ctx.conn, ~p"/projects/#{ctx.project.name}/releases/#{record.id}")
      assert has_element?(view, "article h2", "No version")
    end

    test "the heading is not a link on the record's own page", ctx do
      record = record!(ctx.project)
      {:ok, view, _html} = live(ctx.conn, ~p"/projects/#{ctx.project.name}/releases/#{record.id}")
      refute has_element?(view, "article h2 a")
      assert has_element?(view, "article h2", "1.0.0")
    end

    test "says what became of the tag in one of four sentences", ctx do
      record!(ctx.project, %{tag_status: :tagged, tag_name: "v1.0.0", version: "1.0.0"})

      record!(ctx.project, %{
        tag_status: :taken,
        tag_name: "v1.1.0",
        tag_detail: @other,
        version: "1.1.0"
      })

      record!(ctx.project, %{
        tag_status: :failed,
        tag_name: "v1.2.0",
        tag_detail: "git refused the tag: no",
        version: "1.2.0"
      })

      record!(ctx.project, %{tag_status: :no_version, tag_name: nil, version: nil})

      {:ok, _view, html} = live(ctx.conn, ~p"/projects/#{ctx.project.name}/releases")
      text = html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.replace(~r/\s+/, " ")

      assert text =~ "Tagged v1.0.0"
      assert text =~ "v1.1.0 was already taken by another commit (fedcba9) and was not moved"
      assert text =~ "Not tagged: git refused the tag: no"
      assert text =~ "No version, so no tag"
      assert text =~ "No version"
    end

    test "markup in values is text, and the notes are rendered as a document is", ctx do
      hostile = "<img src=x onerror=alert(1)>"

      record =
        record!(ctx.project, %{
          version: hostile,
          tag_name: nil,
          tag_status: :no_version,
          notes: "<script>alert(1)</script>\n\nhello",
          files: [%{"name" => "dist/" <> hostile, "version" => 1, "size" => 1}],
          links: [
            %{
              "label" => hostile,
              "url" => "https://ok.example/a",
              "document" => "n",
              "version" => 1
            }
          ]
        })

      {:ok, _view, html} = live(ctx.conn, ~p"/projects/#{ctx.project.name}/releases/#{record.id}")

      article =
        html |> LazyHTML.from_document() |> LazyHTML.query("article") |> LazyHTML.to_html()

      refute article =~ "<script"
      refute article =~ "<img"
      assert html =~ "&lt;img src=x onerror=alert(1)&gt;"
    end

    test "a hundred files are all listed", ctx do
      files = for n <- 1..100, do: %{"name" => "dist/f#{n}.bin", "version" => 1, "size" => n}
      record = record!(ctx.project, %{files: files})
      {:ok, view, _html} = live(ctx.conn, ~p"/projects/#{ctx.project.name}/releases/#{record.id}")

      assert view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("section a[href*=artifacts]")
             |> Enum.count() == 100
    end

    test "long values wrap and never stretch the page", ctx do
      long = String.duplicate("w", 200)

      record =
        record!(ctx.project, %{
          version: long,
          files: [%{"name" => "dist/" <> long, "version" => 1, "size" => 1}],
          links: [
            %{
              "label" => long,
              "url" => "https://ok.example/" <> long,
              "document" => "n",
              "version" => 1
            }
          ]
        })

      # Each long value is in an element that wraps, inside ones that may shrink.
      {:ok, view, _html} = live(ctx.conn, ~p"/projects/#{ctx.project.name}/releases/#{record.id}")
      assert has_element?(view, "article.min-w-0 h2.break-words")
      assert has_element?(view, "article section a.min-w-0 span.break-all")
      assert has_element?(view, "article section ul li.min-w-0 a.break-words.min-w-0")
      assert has_element?(view, "article p.break-words")
    end
  end

  describe "the empty page" do
    test "says a release appears once one ends done, when a workflow would make one", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/projects/#{ctx.project.name}/releases")
      assert has_element?(view, "#releases-empty", "once one ends done")
      refute has_element?(view, "#releases-no-workflow")
    end

    test "says no workflow sets the flag, when none does", ctx do
      project =
        ctx.register.(%{
          ".forge/workflows/release.yml" => String.replace(@release, "release: true\n", "")
        })

      {:ok, view, _html} = live(ctx.conn, ~p"/projects/#{project.name}/releases")
      assert has_element?(view, "#releases-no-workflow", "release: true")
      refute has_element?(view, "#releases-empty")
    end
  end

  describe "a release in progress" do
    test "is one line above the list naming and linking its ticket, and not a record", ctx do
      {:ok, ticket} = Forge.Operator.start_release(ctx.project, ctx.user, "")
      record!(ctx.project)

      {:ok, view, _html} = live(ctx.conn, ~p"/projects/#{ctx.project.name}/releases")

      assert has_element?(
               view,
               ~s|#release-in-progress a[href="/tickets/#{ctx.project.name}/#{ticket.number}"]|,
               "##{ticket.number}"
             )

      assert view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("article")
             |> Enum.count() == 1
    end

    test "is not there when none is open", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/projects/#{ctx.project.name}/releases")
      refute has_element?(view, "#release-in-progress")
    end
  end

  describe "live" do
    test "a release that concludes appears on an open page without a reload", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/projects/#{ctx.project.name}/releases")
      refute has_element?(view, "article")

      record = record!(ctx.project, %{version: "9.9.9"})
      Events.notify(record.ticket_id)

      assert render(view) =~ "9.9.9"
      assert ReleaseRecords.count(ctx.project) == 1
    end

    test "another project's ticket changing leaves this page as it was", ctx do
      other = ctx.register.(%{})
      {:ok, view, _html} = live(ctx.conn, ~p"/projects/#{ctx.project.name}/releases")

      record = record!(other, %{version: "7.7.7"})
      Events.notify(record.ticket_id)

      refute render(view) =~ "7.7.7"
    end

    test "a reconnect redraws the same records, there being nothing to lose", ctx do
      record!(ctx.project)
      {:ok, view, _html} = live(ctx.conn, ~p"/projects/#{ctx.project.name}/releases?shown=20")
      before = view |> element("#releases") |> render()
      {:ok, view, _html} = live(ctx.conn, ~p"/projects/#{ctx.project.name}/releases?shown=20")
      assert view |> element("#releases") |> render() == before
      assert before =~ "1.0.0"
    end
  end

  describe "the project page" do
    test "always links to the releases, and shows no latest line without a record", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/projects/#{ctx.project.name}")

      assert has_element?(
               view,
               ~s|header a[href="/projects/#{ctx.project.name}/releases"]|,
               "Releases"
             )

      refute has_element?(view, "#latest-release")
    end

    test "shows the latest release in one line: version, date, tag, linking to its page", ctx do
      record!(ctx.project, %{version: "1.0.0", concluded_at: ~U[2026-01-01 10:00:00.000000Z]})

      latest =
        record!(ctx.project, %{
          version: "1.1.0",
          concluded_at: ~U[2026-02-03 10:00:00.000000Z],
          tag_status: :taken,
          tag_name: "v1.1.0",
          tag_detail: @other
        })

      {:ok, view, _html} = live(ctx.conn, ~p"/projects/#{ctx.project.name}")

      assert has_element?(
               view,
               ~s|#latest-release a[href="/projects/#{ctx.project.name}/releases/#{latest.id}"]|,
               "1.1.0"
             )

      line =
        view
        |> element("#latest-release")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()

      assert line =~ "2026-02-03"
      assert line =~ "v1.1.0 was already taken by another commit (fedcba9) and was not moved"
      refute line =~ "1.0.0"
    end

    test "a release that concludes appears without a reload", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/projects/#{ctx.project.name}")
      refute has_element?(view, "#latest-release")

      record = record!(ctx.project, %{version: "4.0.0"})
      Events.notify(record.ticket_id)

      assert has_element?(view, "#latest-release", "4.0.0")
    end
  end
end
