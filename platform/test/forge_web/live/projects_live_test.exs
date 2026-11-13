defmodule ForgeWeb.ProjectsLiveTest do
  @moduledoc """
  The projects page (`docs/design/ui.md` § The projects page, `11a`–`11e`): the viewer's projects
  and nobody else's, what waits on the viewer in each and what runs, waiting first, what each has
  to run on, and a project that can run nothing saying so.
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.ForgeFixtures

  alias Forge.{Projects, Provisioning, Repo, Tickets}

  setup :register_and_log_in_user

  defp project_for(user) do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Projects.register(
        %{
          name: "proj-#{n}",
          repo_path: Path.join(Forge.GitFixtures.tmp_dir("projects-live"), "p#{n}.git")
        },
        user
      )

    project
  end

  defp template_for(user, project) do
    {:ok, template} =
      Provisioning.create_template(user, %{
        name: "t-#{System.unique_integer([:positive])}",
        provider: "fake",
        memory: 8 * 1024 * 1024 * 1024,
        cores: 4,
        max_workers: 2
      })

    {:ok, _assignment} = Provisioning.assign(user, template.id, project.id)
    template
  end

  test "lists the viewer's projects, and not another person's", %{conn: conn, user: user} do
    mine = project_for(user)
    theirs = project_for(Forge.AccountsFixtures.user_fixture())

    {:ok, view, _html} = live(conn, ~p"/projects")

    assert has_element?(view, "a#project-#{mine.id}[href='/projects/#{mine.name}']", mine.name)
    assert has_element?(view, "a#project-cells-#{mine.id}[href='/projects/#{mine.name}']")
    refute has_element?(view, "#project-#{theirs.id}")
    refute render(view) =~ theirs.name
  end

  test "a project with a template and a credential shows its figures and no warning", %{
    conn: conn,
    user: user
  } do
    project = project_for(user)
    template_for(user, project)
    pool!(project, credential_fixture(user))
    # A revoked credential is not something the project can run on.
    revoked = pool!(project, credential_fixture(user))
    revoked |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second)) |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/projects")
    row = view |> element("#project-#{project.id}") |> render()

    assert row =~ ">0 open<"
    assert row =~ ">1 template · 1 credential<"
    refute row =~ "nothing runs"
  end

  test "a project with no template, or no credential, says it runs nothing", %{
    conn: conn,
    user: user
  } do
    bare = project_for(user)
    unfunded = project_for(user)
    template_for(user, unfunded)
    homeless = project_for(user)
    pool!(homeless, credential_fixture(user))

    {:ok, view, _html} = live(conn, ~p"/projects")

    assert view |> element("#project-#{bare.id}") |> render() =~
             "no template or machine, and no credential, so nothing runs"

    assert view |> element("#project-#{unfunded.id}") |> render() =~
             "no credential, so nothing runs"

    assert view |> element("#project-#{homeless.id}") |> render() =~
             "no template or machine, so nothing runs"
  end

  # A permanent machine assigned to a project serves its jobs with no template at all. Counted
  # while it lives; a destroyed one serves nothing.
  test "a project served by a permanent machine runs without a template", %{
    conn: conn,
    user: user
  } do
    project = project_for(user)
    pool!(project, credential_fixture(user))

    {:ok, machine, _token} =
      Forge.Workers.create(%{provider: "fake", managed: false, user_id: user.id})

    serve!(machine, project)

    {:ok, view, _html} = live(conn, ~p"/projects")
    row = view |> element("#project-#{project.id}") |> render()
    assert row =~ ">1 machine · 1 credential<"
    refute row =~ "nothing runs"

    machine |> Ecto.Changeset.change(status: :destroyed) |> Repo.update!()
    {:ok, view, _html} = live(conn, ~p"/projects")
    assert view |> element("#project-#{project.id}") |> render() =~ "no template or machine"
  end

  # The topic is global, and a ticket of one of the viewer's projects reloads the page — one of
  # somebody else's arriving first changes nothing on it.
  test "reloads for a ticket of its own projects", %{conn: conn, user: user} do
    {:ok, mine} =
      Projects.register(
        %{
          name: "live-#{System.unique_integer([:positive])}",
          repo_path: Forge.GitFixtures.seeded_repo()
        },
        user
      )

    other_user = Forge.AccountsFixtures.user_fixture()

    {:ok, theirs} =
      Projects.register(
        %{
          name: "other-#{System.unique_integer([:positive])}",
          repo_path: Forge.GitFixtures.seeded_repo()
        },
        other_user
      )

    {:ok, view, _html} = live(conn, ~p"/projects")
    assert view |> element("#project-#{mine.id}") |> render() =~ ">0 open<"

    {:ok, _ticket} = Tickets.admit(theirs, %{title: "not yours"}, {:user, other_user.id})

    {:ok, _ticket} = Tickets.admit(mine, %{title: "yours"}, {:user, user.id})

    assert view |> element("#project-#{mine.id}") |> render() =~ ">1 open<"
  end

  # Open is active or stuck; a ticket that is done is not work waiting to run.
  test "counts open tickets only", %{conn: conn, user: user} do
    {:ok, project} =
      Projects.register(
        %{
          name: "seeded-#{System.unique_integer([:positive])}",
          repo_path: Forge.GitFixtures.seeded_repo()
        },
        user
      )

    {:ok, _open} = Tickets.admit(project, %{title: "open"}, {:user, user.id})
    {:ok, stuck} = Tickets.admit(project, %{title: "stuck"}, {:user, user.id})
    {:ok, done} = Tickets.admit(project, %{title: "done"}, {:user, user.id})
    stuck |> Ecto.Changeset.change(status: :stuck) |> Repo.update!()
    done |> Ecto.Changeset.change(status: :done) |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/projects")
    assert view |> element("#project-#{project.id}") |> render() =~ ">2 open<"
  end

  # `11b`: the one fact someone needs in order to be added is their own address, and making a
  # project is the dock's one button rather than the top bar's.
  test "with no projects it says how to get one, with the address to be added by", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/projects")

    assert has_element?(view, "#no-projects #your-address", user.email)
    assert has_element?(view, ~s(.frame-composer a[href="/projects/new"]), "New project")
    # The dock sits in the content's own column, at its measure, under the message rather than a
    # window-wide slab at the foot of a desktop (UX pass, C18, `ui.md` § Three layouts).
    assert has_element?(
             view,
             ~s(.frame-main[style*="--frame-measure: 34rem"] > .frame-body + .frame-composer)
           )

    refute has_element?(view, "#top-bar a.ui-top-context")
    assert has_element?(view, "#top-bar", "no projects")
  end

  describe "what waits and what runs" do
    setup %{user: user} do
      mine = seeded_project(user, "mine")
      other = Forge.AccountsFixtures.user_fixture()
      theirs = seeded_project(other, "theirs")
      %{mine: mine, theirs: theirs, other: other}
    end

    # A stuck ticket is one item in its project's queue; the row draws the count amber, with the
    # edge, and the page's subline counts the projects that wait, as the title menu does — two
    # items in one project are one project waiting (UX re-check #9).
    test "a project's waiting items are its count, and the subline the projects that wait", %{
      conn: conn,
      user: user,
      mine: mine
    } do
      quiet = seeded_project(user, "quiet")
      stuck!(mine, user)
      stuck!(mine, user)

      {:ok, view, _html} = live(conn, ~p"/projects")

      assert has_element?(view, "#project-#{mine.id}.ui-row--accent .ui-count--accent", "◆ 2")
      assert has_element?(view, "#project-cells-#{mine.id} .ui-count--accent", "◆ 2")
      refute has_element?(view, "#project-#{quiet.id}.ui-row--accent")
      refute has_element?(view, "#project-#{quiet.id} .ui-count")
      assert has_element?(view, "#top-bar", "2 projects · 1 waits on you")
      refute has_element?(view, "#top-bar", "2 wait")

      view |> element("#top-bar .ui-top-title") |> render_click()
      assert has_element?(view, "#title-menu", "2 projects · 1 waits on you")
    end

    # Waiting first, and by name within each group: `quiet-…` sorts before `zz-…` by name, and
    # after it once `zz-…` has something waiting.
    test "projects that wait on you sort first", %{conn: conn, user: user} do
      first = seeded_project(user, "aa")
      waiting = seeded_project(user, "zz")
      stuck!(waiting, user)

      {:ok, view, _html} = live(conn, ~p"/projects")
      ids = view |> render() |> rows_in_order()

      assert Enum.find_index(ids, &(&1 == waiting.id)) < Enum.find_index(ids, &(&1 == first.id))
    end

    # Only a job on a machine now is running: one waiting for a machine is not, nor one that
    # finished.
    test "running counts the jobs on a machine now, and no other", %{
      conn: conn,
      user: user,
      mine: mine
    } do
      {:ok, ticket} = Tickets.admit(mine, %{title: "busy"}, {:user, user.id})
      # Admission made attempt 1, waiting for a machine.
      job_fixture(%{ticket: ticket, attempt: 2, status: :running})
      job_fixture(%{ticket: ticket, attempt: 3, status: :running})
      job_fixture(%{ticket: ticket, attempt: 4})

      job_fixture(%{ticket: ticket, attempt: 5})
      |> Ecto.Changeset.change(status: :finished, outcome: :converged)
      |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/projects")

      assert has_element?(view, "#project-#{mine.id} .project-running", "▸ 2 running")
      assert has_element?(view, "#project-cells-#{mine.id} .project-running", "▸ 2")
    end

    # Another person's project is not on the page at all, so what waits and runs in it cannot be
    # counted into a row or the subline of this one.
    test "another project's queue items and running jobs appear nowhere", %{
      conn: conn,
      mine: mine,
      theirs: theirs,
      other: other
    } do
      stuck!(theirs, other)
      {:ok, ticket} = Tickets.admit(theirs, %{title: "theirs runs"}, {:user, other.id})
      job_fixture(%{ticket: ticket, attempt: 2, status: :running})

      {:ok, view, _html} = live(conn, ~p"/projects")

      refute render(view) =~ theirs.name
      refute has_element?(view, "#project-#{mine.id} .ui-count")
      refute has_element?(view, "#project-#{mine.id} .project-running")
      assert has_element?(view, "#top-bar", "1 project")
      refute has_element?(view, "#top-bar", "waiting on you")
    end

    # The latest line: the most recently changed open ticket, and with none open, when the
    # project last merged.
    test "the latest line names the latest open ticket, or the last merge", %{
      conn: conn,
      user: user,
      mine: mine
    } do
      {:ok, older} = Tickets.admit(mine, %{title: "older"}, {:user, user.id})
      {:ok, newer} = Tickets.admit(mine, %{title: "newer"}, {:user, user.id})
      touch!(older, ~U[2026-01-01 00:00:00Z])
      touch!(newer, ~U[2026-01-02 00:00:00Z])

      {:ok, view, _html} = live(conn, ~p"/projects")
      assert has_element?(view, "#project-cells-#{mine.id}", "##{newer.number} is refining")

      newer |> Ecto.Changeset.change(status: :stuck) |> Repo.update!()
      {:ok, view, _html} = live(conn, ~p"/projects")

      assert has_element?(
               view,
               "#project-cells-#{mine.id}",
               "##{newer.number} is stuck in refining"
             )

      for ticket <- [older, newer],
          do: ticket |> Ecto.Changeset.change(status: :done) |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/projects")
      assert has_element?(view, "#project-cells-#{mine.id}", "nothing open")

      # Two merges: the line is the latest's, not the first's.
      for {ticket, at} <- [
            {older, DateTime.add(DateTime.utc_now(:second), -3, :day)},
            {newer, nil}
          ] do
        Repo.insert!(%Forge.Events.Event{
          type: "ticket.merged",
          actor: %{"kind" => "system", "id" => nil},
          ticket_id: ticket.id,
          project_id: mine.id,
          payload: %{"sha" => String.duplicate("a", 40)},
          inserted_at: at
        })
      end

      {:ok, view, _html} = live(conn, ~p"/projects")

      assert has_element?(
               view,
               "#project-cells-#{mine.id}",
               "nothing running · last merge just now"
             )
    end

    # A row with a count names what has waited longest, and how many more, in place of the
    # latest-changed ticket — which is what hid the waiting ones (ux/c.md C17).
    test "a waiting row names what has waited longest first", %{
      conn: conn,
      user: user,
      mine: mine
    } do
      # Somewhere to run, or the list row says that instead, which outranks any latest line.
      template_for(user, mine)
      pool!(mine, credential_fixture(user))
      old = stuck!(mine, user)
      young = stuck!(mine, user)
      touch!(old, DateTime.add(DateTime.utc_now(:second), -2, :hour))
      touch!(young, DateTime.add(DateTime.utc_now(:second), -5, :minute))
      # The latest-changed open ticket is neither of them.
      {:ok, _busy} = Tickets.admit(mine, %{title: "busy"}, {:user, user.id})

      {:ok, view, _html} = live(conn, ~p"/projects")

      for id <- ["#project-#{mine.id}", "#project-cells-#{mine.id}"] do
        assert has_element?(view, id, "##{old.number} is stuck in refining · 2h ago, and 1 more")
      end

      # One alone has no "more".
      young |> Ecto.Changeset.change(status: :active) |> Repo.update!()
      {:ok, view, _html} = live(conn, ~p"/projects")
      assert has_element?(view, "#project-cells-#{mine.id}", "##{old.number} is stuck")
      refute has_element?(view, "#project-cells-#{mine.id}", "more")
    end

    # The wide table's figures: every zero drawn the same quiet way, and a project that runs
    # nothing says so in two words with the reason in its title.
    test "the table draws zeros alike and shortens what cannot run", %{
      conn: conn,
      mine: mine
    } do
      {:ok, view, _html} = live(conn, ~p"/projects")
      cells = "#project-cells-#{mine.id}"

      assert view
             |> element(cells)
             |> render()
             |> then(&Regex.scan(~r/projects-table-zero/, &1))
             |> length() == 3

      assert has_element?(
               view,
               ~s(#{cells} .project-danger[title="no template or machine, and no credential, so nothing runs"]),
               "nothing can run"
             )
    end

    # A conversation waiting on its reader is a queue item: its change reloads the page.
    test "reloads for a conversation of its own projects", %{
      conn: conn,
      user: user,
      mine: mine
    } do
      {:ok, view, _html} = live(conn, ~p"/projects")
      refute has_element?(view, "#project-#{mine.id} .ui-count")

      # Changed behind the page's back, so only the message can make it show.
      {:ok, ticket} = Tickets.admit(mine, %{title: "quiet"}, {:user, user.id})
      {:ok, view, _html} = live(conn, ~p"/projects")
      ticket |> Ecto.Changeset.change(status: :stuck) |> Repo.update!()

      send(view.pid, {:chat_changed, Ecto.UUID.generate(), mine.id, nil})
      assert has_element?(view, "#project-#{mine.id} .ui-count", "◆ 1")
    end
  end

  # `/board` is gone with the board (`docs/design/ui.md` § The project page): no route answers.
  test "/board is not a page any more", %{conn: conn} do
    assert conn |> get("/board") |> response(404)
  end

  defp seeded_project(user, prefix) do
    {:ok, project} =
      Projects.register(
        %{
          name: "#{prefix}-#{System.unique_integer([:positive])}",
          repo_path: Forge.GitFixtures.seeded_repo()
        },
        user
      )

    project
  end

  defp stuck!(project, user) do
    {:ok, ticket} = Tickets.admit(project, %{title: "stuck"}, {:user, user.id})
    ticket |> Ecto.Changeset.change(status: :stuck) |> Repo.update!()
  end

  defp touch!(ticket, at),
    do: ticket |> Ecto.Changeset.change(updated_at: at) |> Repo.update!()

  # The project ids of the list rows, in the order the page draws them.
  defp rows_in_order(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("#project-rows > a")
    |> Enum.map(fn row ->
      row |> Floki.attribute("id") |> hd() |> String.trim_leading("project-")
    end)
  end
end
