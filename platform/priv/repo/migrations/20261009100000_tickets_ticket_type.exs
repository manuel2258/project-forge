defmodule Forge.Repo.Migrations.TicketsTicketType do
  @moduledoc """
  `tickets.ticket_type`: the ticket type a ticket was admitted as — the stem of its file under
  `.forge/workflows/` — or nil for a ticket admitted from the single `.forge/workflow.yml`
  (`docs/design/ticket-types.md` § Pinning and re-pinning). Beside `workflow_commit` it names the
  file a re-pin reads.

  Nil for every existing ticket, which is what each of them is: every one was admitted from the
  single file, the only form there was.
  """

  use Ecto.Migration

  def change do
    alter table(:tickets) do
      add :ticket_type, :string
    end
  end
end
