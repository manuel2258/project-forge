defmodule ForgeWeb.JobArchiveRowTest do
  @moduledoc """
  The one line the archive adds to an operator page (`docs/design/archive.md` § What is recorded):
  how many versions the job opened, as a count and nothing else.
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.GitFixtures

  alias Forge.{Archive, Artifacts, Jobs, Projects, Tickets}

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, project} =
      Projects.register(
        %{name: "arch-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
        user
      )

    # A title that would break a layout, or inject into it, if it reached the row.
    {:ok, ticket} =
      Tickets.admit(
        project,
        %{title: "<b onclick=x>#{String.duplicate("long ", 60)}</b>"},
        :system
      )

    [job] = Jobs.for_ticket(ticket.id)
    %{project: project, ticket: ticket, job: job}
  end

  defp row(conn, project, ticket, job) do
    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}")
    view |> element(".job-archive") |> render()
  end

  test "reads `nothing opened` before anything is", %{
    conn: conn,
    project: project,
    ticket: ticket,
    job: job
  } do
    html = row(conn, project, ticket, job)

    assert html =~ "archive"
    assert html =~ "nothing opened"
  end

  test "counts the distinct versions opened, and shows no name", context do
    %{conn: conn, project: project, ticket: ticket, job: job} = context

    for body <- ["one", "two"] do
      {:ok, version} =
        Artifacts.record_version(
          ticket.id,
          "<i>plan</i>.md",
          :document,
          {:user, Ecto.UUID.generate()},
          %{
            content: body,
            parse: false
          }
        )

      {:ok, v, facts} = Archive.version(project, ticket.number, version.id)
      Archive.record_read(job, v, facts)
      Archive.record_read(job, v, facts)
    end

    html = row(conn, project, ticket, job)
    assert html =~ "2 files opened"
    refute html =~ "plan"
    refute html =~ "long"
  end

  test "draws no row of the stream for a file, however many were opened", context do
    %{conn: conn, project: project, ticket: ticket, job: job} = context

    for n <- 1..5 do
      {:ok, version} =
        Artifacts.record_version(
          ticket.id,
          "secret-name-#{n}.md",
          :document,
          {:user, Ecto.UUID.generate()},
          %{
            content: "x",
            parse: false
          }
        )

      {:ok, v, facts} = Archive.version(project, ticket.number, version.id)
      Archive.record_read(job, v, facts)
    end

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}")
    html = render(view)

    assert html =~ "5 files opened"
    refute html =~ "archive_read"
    refute html =~ "version_id"
    refute html =~ "secret-name"

    {:ok, _view, ticket_html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    refute ticket_html =~ "archive_read"
    refute ticket_html =~ "version_id"
  end

  test "says `1 file opened` for one", %{conn: conn, project: project, ticket: ticket, job: job} do
    {:ok, version} =
      Artifacts.record_version(ticket.id, "plan.md", :document, {:user, Ecto.UUID.generate()}, %{
        content: "x",
        parse: false
      })

    {:ok, v, facts} = Archive.version(project, ticket.number, version.id)
    Archive.record_read(job, v, facts)

    assert row(conn, project, ticket, job) =~ "1 file opened"
  end
end
