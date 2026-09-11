defmodule Forge.Queue do
  @moduledoc """
  The operator's queue: everything waiting on a human decision, in one ordered list.
  Blocking questions, pending approvals, stuck tickets, and tickets resting in a human
  state that has a way forward.
  """

  import Ecto.Query, only: [from: 2]

  alias Forge.{Artifacts, Repo, Tickets}
  alias Forge.Artifacts.Question
  alias Forge.Tickets.Ticket
  alias ForgeCore.Workflow

  @type item :: %{
          kind: :question | :approval | :stuck | :review,
          ticket: Ticket.t(),
          since: DateTime.t(),
          question: Question.t() | nil,
          detail: map()
        }

  @spec items() :: [item()]
  def items do
    tickets =
      Repo.all(from t in Ticket, where: t.status in [:active, :stuck], order_by: t.inserted_at)

    (questions(tickets) ++ Enum.flat_map(tickets, &ticket_items/1))
    |> Enum.sort_by(& &1.since, DateTime)
  end

  defp questions(tickets) do
    by_id = Map.new(tickets, &{&1.id, &1})

    Enum.flat_map(tickets, fn ticket ->
      ticket.id
      |> Artifacts.open_questions()
      |> Enum.filter(& &1.blocking)
      |> Enum.map(fn question ->
        %{
          kind: :question,
          ticket: by_id[ticket.id],
          since: question.inserted_at,
          question: question,
          detail: %{key: question.key, text: question.text}
        }
      end)
    end)
  end

  defp ticket_items(%Ticket{status: :stuck} = ticket) do
    [
      %{
        kind: :stuck,
        ticket: ticket,
        since: ticket.updated_at,
        question: nil,
        detail: %{state: ticket.state}
      }
    ]
  end

  defp ticket_items(%Ticket{pending_transition: pending} = ticket) when is_map(pending) do
    [%{kind: :approval, ticket: ticket, since: ticket.updated_at, question: nil, detail: pending}]
  end

  defp ticket_items(%Ticket{} = ticket) do
    workflow = Tickets.workflow(ticket)
    state = Workflow.state(workflow, ticket.state)

    if state && ForgeCore.Workflow.State.human?(state) &&
         not Workflow.terminal?(workflow, ticket.state) do
      [
        %{
          kind: :review,
          ticket: ticket,
          since: ticket.updated_at,
          question: nil,
          detail: %{
            state: ticket.state,
            transitions: Enum.map(Workflow.transitions_from(workflow, ticket.state), & &1.to)
          }
        }
      ]
    else
      []
    end
  end
end
