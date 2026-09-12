defmodule Forge.Queue do
  @moduledoc """
  The operator's queue: everything waiting on a human decision, in one ordered list.
  Blocking questions, pending approvals, stuck tickets, and tickets resting in a human
  state that has a way forward.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

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
        detail: %{state: ticket.state, transitions: transitions_from(ticket)}
      }
    ]
  end

  defp ticket_items(%Ticket{pending_transition: pending} = ticket) when is_map(pending) do
    [%{kind: :approval, ticket: ticket, since: ticket.updated_at, question: nil, detail: pending}]
  end

  defp ticket_items(%Ticket{} = ticket) do
    case Tickets.parsed_workflow(ticket) do
      {:ok, workflow} -> review_item(ticket, workflow)
      {:error, errors} -> unparseable(ticket, errors, [])
    end
  end

  defp review_item(%Ticket{} = ticket, workflow) do
    state = Workflow.state(workflow, ticket.state)

    if state && ForgeCore.Workflow.State.human?(state) &&
         not Workflow.terminal?(workflow, ticket.state) do
      [
        %{
          kind: :review,
          ticket: ticket,
          since: ticket.updated_at,
          question: nil,
          detail: %{state: ticket.state, transitions: transitions_from(ticket)}
        }
      ]
    else
      []
    end
  end

  # The states an operator may move the ticket to from where it rests. Both stuck and review
  # items carry these, so the choices are in the queue and not only in the workflow file.
  # Two edges may share a target - the grammar only requires distinct `when` values per
  # `from` - and this names states, so each is named once.
  defp transitions_from(%Ticket{} = ticket) do
    case Tickets.parsed_workflow(ticket) do
      {:ok, workflow} ->
        workflow
        |> Workflow.transitions_from(ticket.state)
        |> Enum.map(& &1.to)
        |> Enum.uniq()

      {:error, errors} ->
        unparseable(ticket, errors, [])
    end
  end

  # The queue serves every ticket at once, so a definition that no longer validates costs the
  # operator that ticket's detail, not the whole queue.
  defp unparseable(%Ticket{} = ticket, errors, fallback) do
    Logger.warning(
      "ticket #{ticket.id} pinned a workflow that no longer parses: #{inspect(errors)}"
    )

    fallback
  end
end
