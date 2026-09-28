defmodule ForgeWeb.ProjectsLiveTest do
  @moduledoc """
  The projects page (`docs/design/ui.md` § The projects page): the viewer's projects and nobody
  else's, what each has to run on, and a project that can run nothing saying so.
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

    assert has_element?(view, "#project-#{mine.id} a[href='/projects/#{mine.name}']", mine.name)
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

    assert row =~ "0 open tickets · 1 template · 0 machines · 1 credential"
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
    assert row =~ "0 templates · 1 machine · 1 credential"
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
    assert view |> element("#project-#{mine.id}") |> render() =~ "0 open tickets"

    {:ok, _ticket} = Tickets.admit(theirs, %{title: "not yours"}, {:user, other_user.id})

    {:ok, _ticket} = Tickets.admit(mine, %{title: "yours"}, {:user, user.id})

    assert view |> element("#project-#{mine.id}") |> render() =~ "1 open ticket"
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
    assert view |> element("#project-#{project.id}") |> render() =~ "2 open tickets"
  end

  test "with no projects it says how to get one", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/projects")
    assert has_element?(view, "#no-projects")
  end

  test "is in the top row and in the More sheet", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    # Once in the laptop's top row and once in the phone's More sheet.
    assert length(Regex.scan(~r/href="\/projects"/, html)) == 2
  end
end
