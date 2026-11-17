defmodule ForgeWeb.ProjectTicketsTest do
  @moduledoc """
  The rows the project page and the queue's Open tickets both draw (`ForgeWeb.ProjectTickets`):
  what each says it is doing, and the two attributes that let one list hold tickets of several
  projects (`named`) and show usage whenever there is some (`usage_always`).
  """

  use Forge.DataCase, async: true

  import Forge.ForgeFixtures
  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias ForgeWeb.ProjectTickets

  @now ~U[2026-11-16 12:00:00Z]

  defp facts(ticket, live, extra \\ %{}) do
    Map.merge(
      %{
        items: [],
        live: %{ticket.id => live},
        said: %{},
        places: %{},
        paused: false,
        milestones: %{},
        now: @now
      },
      extra
    )
  end

  defp pending(kind),
    do: %{
      id: "job",
      kind: kind,
      status: :pending,
      attempt: 1,
      started_at: nil,
      inserted_at: @now
    }

  defp doing(ticket, live, extra \\ %{}) do
    [row] = ProjectTickets.rows([ticket], facts(ticket, live, extra))
    {row.doing, row.tone}
  end

  describe "a pending job under the daily spend cap" do
    # The cap gates a workflow job and not a command: `Jobs.assign_command/2` takes no spend gate,
    # so a pending command is placed at the next pass whatever the cap says, and drawing it
    # paused would hide a ticket that is only waiting for room.
    test "a workflow job is paused, a command is only waiting for a machine" do
      ticket = ticket_fixture()

      assert {"paused · spend", :idle} = doing(ticket, pending(:workflow), %{paused: true})

      assert {"waiting for a machine", :running} =
               doing(ticket, pending(:command), %{paused: true})

      assert {"waiting for a machine", :running} = doing(ticket, pending(:workflow))
    end
  end

  describe "list" do
    defp html(rows, attrs) do
      assigns = Map.merge(%{rows: rows, id: "rows", now: @now}, attrs)

      rendered_to_string(~H"""
      <ProjectTickets.list
        id={@id}
        rows={@rows}
        project={assigns[:project]}
        named={assigns[:named]}
        usage_always={assigns[:usage_always] || false}
        now={@now}
      />
      """)
    end

    test "one project's rows are numbered and linked as before" do
      ticket = ticket_fixture()
      [row] = ProjectTickets.rows([ticket], facts(ticket, pending(:workflow)))

      out = html([row], %{project: "forge"})

      assert out =~ ~s(id="rows-#{ticket.number}")
      assert out =~ ~s(href="/tickets/forge/#{ticket.number}")
      refute out =~ "forge##{ticket.number}"
    end

    # Numbers repeat across projects, so a list of several names each row's project, links into
    # it, and takes its DOM id from the ticket's id.
    test "named rows read forge#53, link into their own project and are keyed by id" do
      one = ticket_fixture()
      two = ticket_fixture()
      names = %{one.project_id => "alpha", two.project_id => "beta"}

      rows =
        ProjectTickets.rows(
          [one, two],
          Map.merge(facts(one, pending(:workflow)), %{live: %{}})
        )

      out = html(rows, %{named: names})

      assert out =~ "alpha##{one.number}"
      assert out =~ "beta##{two.number}"
      assert out =~ ~s(href="/tickets/alpha/#{one.number}")
      assert out =~ ~s(href="/tickets/beta/#{two.number}")
      assert out =~ ~s(id="rows-#{one.id}")
      assert out =~ ~s(id="rows-#{two.id}")
    end

    test "usage is shown below half the allowance only when asked to, and never when nothing was spent" do
      spent = ticket_fixture() |> Ecto.Changeset.change(usage: 1_000) |> Repo.update!()
      unspent = ticket_fixture()
      rows = ProjectTickets.rows([spent, unspent], facts(spent, pending(:workflow)))
      by = fn ticket -> Enum.find(rows, &(&1.ticket.id == ticket.id)) end

      refute html([by.(spent)], %{project: "p"}) =~ "ticket-usage"
      assert html([by.(spent)], %{project: "p", usage_always: true}) =~ "ticket-usage"
      refute html([by.(unspent)], %{project: "p", usage_always: true}) =~ "ticket-usage"
    end
  end
end
