defmodule ForgeWeb.CapacityGaugeTest do
  @moduledoc """
  The top bar's window gauge, and whose credentials it draws (`docs/design/credentials.md`
  § Showing the windows): the viewer's own on the queue and every page not about a project, that
  project's pool on a page about one — and never a credential that is neither.

  What the figure is — the mean, the count, the soonest reset — is `Forge.CredentialsTest`'s;
  here it is which credentials go into it, and that it is drawn at all.
  """

  use ForgeWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Forge.AccountsFixtures
  import Forge.ForgeFixtures

  alias Forge.{Jobs, Repo}

  setup :register_and_log_in_user

  setup %{user: user} do
    project = project_fixture()
    join!(project, user, :member)
    colleague = user_fixture()
    join!(project, colleague, :member)

    mine = pool!(project, credential_fixture(user))
    theirs = pool!(project, credential_fixture(colleague))

    # Somebody else's, in a project the viewer is not in: on no page of theirs, ever.
    elsewhere = project_fixture()
    stranger = pool!(elsewhere, credential_fixture(user_fixture()))

    reports!(project, mine, "allowed_warning", 0.9)
    reports!(project, theirs, "rejected", nil)
    reports!(elsewhere, stranger, "allowed_warning", 0.1)

    # The viewer's own, in the pool, reported — and revoked since: it funds nothing any more, so
    # it is in no gauge, theirs or the project's.
    gone = pool!(project, credential_fixture(user))
    reports!(project, gone, "allowed_warning", 0.1)
    {:ok, _} = Forge.Credentials.revoke(user, gone.id)

    %{project: project}
  end

  defp reports!(project, credential, status, utilization) do
    job = chat_fixture(%{project: project})

    Repo.update_all(from(j in Jobs.Job, where: j.id == ^job.id),
      set: [credential_id: credential.id]
    )

    :ok =
      Jobs.record_harness_event(job.id, %{
        type: "job.harness.rate_limit",
        payload: %{
          status: status,
          rate_limit_type: "five_hour",
          utilization: utilization,
          resets_at: System.os_time(:second) + 3600
        }
      })
  end

  defp title(view), do: view |> element("#capacity-five_hour") |> render() |> attribute("title")

  defp attribute(html, name) do
    [value] = html |> LazyHTML.from_fragment() |> LazyHTML.attribute(name)
    value
  end

  test "the queue draws the viewer's own credentials", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert title(view) =~ "90% used on average, 1 of 1 credentials reporting"

    # Ten ticks, one per tenth, filled up to the figure: nine of them at 90%.
    ticks =
      view
      |> element("#capacity-five_hour")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[aria-label] > span")
      |> Enum.map(&(&1 |> LazyHTML.attribute("class") |> hd()))

    assert length(ticks) == 10
    assert Enum.count(ticks, &String.ends_with?(&1, "bg-base-content")) == 9
  end

  # Every page about one project — the project, its settings, a ticket, its review, a job, a
  # conversation — each switching once it has allowed the viewer.
  test "a page about a project draws that project's pool, other members' included",
       %{conn: conn, project: project} do
    ticket = ticket_fixture(%{project: project})
    # A budget, because the job page draws one.
    job =
      job_fixture(%{
        ticket: ticket,
        spec: %{"prompt" => "agents/refine.md", "budget" => %{"turns" => 20, "cost" => 0.5}}
      })

    chat = chat_fixture(%{project: project})

    for path <- [
          ~p"/projects/#{project.name}",
          ~p"/projects/#{project.name}/settings",
          ~p"/tickets/#{project.name}/#{ticket.number}",
          ~p"/tickets/#{project.name}/#{ticket.number}/review",
          ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}",
          ~p"/chats/#{chat.id}"
        ] do
      {:ok, view, _html} = live(conn, path)

      # Its own 0.9 and the colleague's limited credential, counted as full: 0.95.
      assert title(view) =~ "95% used on average, 2 of 2 credentials reporting", path
    end
  end

  # Redrawn while the page is open: a report that arrives after it mounted is on the next tick.
  test "the gauge is redrawn on its tick", %{conn: conn, user: user, project: project} do
    {:ok, view, _html} = live(conn, ~p"/")

    reports!(project, credential_fixture(user), "allowed_warning", 0.5)
    send(view.pid, :capacity_tick)

    assert title(view) =~ "70% used on average, 2 of 2 credentials reporting"
  end

  test "nothing reported draws nothing", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())
    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "#capacity-gauge")
  end
end
