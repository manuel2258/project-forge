defmodule Forge.Queue do
  @moduledoc """
  The operator's queue: everything waiting on a human decision, in one ordered list.
  Blocking questions, pending approvals, stuck tickets, and tickets resting in a human
  state that has a way forward.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Forge.{Artifacts, Conversations, Projects, Repo, Tickets}
  alias Forge.Artifacts.Question
  alias Forge.Jobs.Job
  alias Forge.Tickets.Ticket
  alias ForgeCore.Workflow

  @typedoc """
  One thing waiting on a person.

  `ticket` is nil for a conversation about a project, which is why every reader of this has to
  take a project of its own rather than reaching through the ticket.
  """
  @type item :: %{
          kind: :question | :approval | :stuck | :review | :chat,
          ticket: Ticket.t() | nil,
          project: Projects.Project.t(),
          since: DateTime.t(),
          question: Question.t() | nil,
          detail: map()
        }

  @spec items() :: [item()]
  def items do
    tickets =
      Repo.all(from t in Ticket, where: t.status in [:active, :stuck], order_by: t.inserted_at)

    (questions(tickets) ++ Enum.flat_map(tickets, &ticket_items/1) ++ chats())
    |> Enum.sort_by(& &1.since, DateTime)
  end

  # A conversation waiting on a person is literally what the queue is for: something that will
  # not move until someone acts. It is in the queue only while it is waiting — a chat mid-reply
  # is not waiting on you, it is working (`docs/design/conversations.md` § In the queue).
  defp chats do
    Repo.all(
      from j in Job,
        where: j.kind == :chat and j.status in ^Conversations.live_statuses()
    )
    |> Enum.flat_map(&chat_item/1)
  end

  defp chat_item(%Job{} = chat) do
    case Conversations.messages(chat.id) do
      [] ->
        []

      messages ->
        last = List.last(messages)
        if last.role == :assistant, do: [waiting_chat(chat, last)], else: []
    end
  end

  defp waiting_chat(%Job{} = chat, last) do
    %{
      kind: :chat,
      ticket: chat.ticket_id && Tickets.get!(chat.ticket_id),
      project: Projects.get!(chat.project_id),
      since: last.at,
      question: nil,
      detail: %{chat_id: chat.id, text: last.text, question: Conversations.question(last)}
    }
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
          project: Projects.get!(ticket.project_id),
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
        project: Projects.get!(ticket.project_id),
        since: ticket.updated_at,
        question: nil,
        detail: %{
          state: ticket.state,
          transitions: transitions_from(ticket),
          reviewable: reviewable?(ticket)
        }
      }
    ]
  end

  defp ticket_items(%Ticket{pending_transition: pending} = ticket) when is_map(pending) do
    [
      %{
        kind: :approval,
        ticket: ticket,
        project: Projects.get!(ticket.project_id),
        since: ticket.updated_at,
        question: nil,
        detail: pending
      }
    ]
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
          project: Projects.get!(ticket.project_id),
          since: ticket.updated_at,
          question: nil,
          detail: %{
            state: ticket.state,
            transitions: transitions_from(ticket),
            reviewable: reviewable?(ticket)
          }
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

  # Whether a decision from here pins the changeset — that is, whether it is a merge decision, and
  # so whether the operator should be offered the diff before taking it. Held on the item rather
  # than recomputed by the page, so the API serves the same fact.
  defp reviewable?(%Ticket{} = ticket) do
    case Tickets.parsed_workflow(ticket) do
      {:ok, workflow} ->
        workflow
        |> Workflow.transitions_from(ticket.state)
        |> Enum.any?(&(Workflow.changeset_artifact() in &1.approve))

      {:error, errors} ->
        unparseable(ticket, errors, false)
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
