defmodule Forge.Steps do
  @moduledoc """
  What a chat step looks like to the person deciding whether to end it
  (`docs/design/ui.md` § The Accept area): one read model for the conversation's page and the
  ticket's Decide tab, so neither can disagree about what Accept would do or why it cannot.

  Pure reading. Whether Accept is allowed is `Forge.Engine.accept/5`'s answer, in a transaction;
  this is the page's best knowledge at the moment it draws, which is why the versions it shows are
  the ones Accept is told it was shown.
  """

  import Ecto.Query, only: [from: 2]

  alias Forge.{Artifacts, Conversations, Engine, Events, Jobs, Repo, Tickets}
  alias Forge.Jobs.Job
  alias Forge.Tickets.Ticket
  alias ForgeCore.Workflow
  alias ForgeCore.Workflow.State

  @type document :: %{
          name: String.t(),
          version: pos_integer() | nil,
          optional: boolean(),
          own: boolean(),
          this_visit: boolean()
        }

  @type outcome :: %{
          outcome: String.t(),
          to: String.t(),
          approve: [String.t()],
          blocked: nil | :no_edge | :max_spent | :no_version,
          unwritten: [String.t()]
        }

  @type t :: %{
          chat: Job.t(),
          state: String.t(),
          visit: pos_integer(),
          current: boolean(),
          over: nil | :moved | :superseded | :accepted | :not_open,
          documents: [document()],
          outcomes: [outcome()],
          in_flight: boolean(),
          dormant: boolean(),
          missing: [String.t()],
          ready: boolean()
        }

  @doc "The conversation that is the ticket's current chat step, newest visit, or nil."
  @spec chat_for(Ticket.t()) :: Job.t() | nil
  def chat_for(%Ticket{id: id, state: state}) do
    Repo.one(
      from j in Job,
        where: j.ticket_id == ^id and j.state == ^state and j.kind == :chat,
        order_by: [desc: j.attempt],
        limit: 1
    )
  end

  @doc """
  The Accept area's state for `chat`, a step's conversation, on `ticket` as it is now.

  `ready` is true when the page may draw a button that is not already known to fail: the step is
  current, no turn is in flight, every document it must produce has a version, and at least one
  outcome has an edge left. A refusal the page cannot know — a version written between the draw
  and the press — is Accept's own.
  """
  @spec view(Ticket.t(), Job.t()) :: t()
  def view(%Ticket{} = ticket, %Job{} = chat) do
    workflow = Tickets.workflow(ticket)
    state = Workflow.state(workflow, chat.state) || %State{name: chat.state}
    over = over(ticket, chat)

    documents =
      for name <- document_names(workflow, state) do
        version = Artifacts.latest(ticket.id, name)

        %{
          name: name,
          version: version && version.version,
          optional: name in state.optional,
          own: name in state.produces,
          this_visit: version != nil and version.author == Events.encode_actor({:job, chat.id})
        }
      end

    missing = for %{version: nil, optional: false, own: true, name: name} <- documents, do: name
    in_flight = Conversations.in_flight?(chat)

    outcomes = outcomes(ticket, workflow, chat, state)

    %{
      chat: chat,
      state: chat.state,
      visit: chat.attempt,
      current: over == nil,
      over: over,
      documents: documents,
      outcomes: outcomes,
      in_flight: in_flight,
      dormant: not Conversations.live?(chat),
      missing: missing,
      ready:
        over == nil and not in_flight and missing == [] and
          Enum.any?(outcomes, &(&1.blocked == nil))
    }
  end

  # What the person is shown, and sends back as seen: the documents the step declares, then those
  # any of its edges approves that it does not (an earlier state's). Accept checks the chosen
  # edge's against what was sent (`Forge.Engine.accept/5`), so each must be on the page.
  defp document_names(workflow, state) do
    own = for name <- state.produces, Workflow.document?(name), do: name

    approved =
      for edge <- Workflow.transitions_from(workflow, state.name),
          name <- edge.approve,
          Workflow.document?(name),
          name not in own,
          uniq: true,
          do: name

    own ++ approved
  end

  defp over(ticket, chat) do
    cond do
      ticket.status not in [:active, :stuck] -> :not_open
      ticket.state != chat.state -> :moved
      Conversations.accepted?(chat.id) -> :accepted
      latest_visit(ticket.id, chat.state) != chat.attempt -> :superseded
      true -> nil
    end
  end

  defp latest_visit(ticket_id, state) do
    Repo.one(
      from j in Job,
        where: j.ticket_id == ^ticket_id and j.state == ^state and j.kind == :chat,
        select: max(j.attempt)
    )
  end

  defp outcomes(ticket, workflow, chat, %State{outcomes: declared}) do
    # `|| [done]` is reached only as `Forge.Engine.accepted_edge/4` says.
    for outcome <- declared || [Workflow.default_outcome()],
        edge <- Workflow.transitions_from(workflow, chat.state),
        ForgeCore.Workflow.Transition.outcome(edge) == outcome do
      unwritten = unwritten(ticket, edge)
      blocked = blocked(unwritten, Engine.accepted_edge(ticket, workflow, chat, outcome))

      %{
        outcome: outcome,
        to: edge.to,
        approve: edge.approve,
        blocked: blocked,
        unwritten: unwritten
      }
    end
  end

  # An edge that approves a document no state has written would be refused at the press
  # (`Engine.offered_edges/2` does not offer it either), so it is drawn as blocked, not as a button.
  defp blocked([], {:ok, _edge}), do: nil
  defp blocked(_unwritten, {:ok, _edge}), do: :no_version
  defp blocked(_unwritten, {:error, {:max_spent, _outcome}}), do: :max_spent
  defp blocked(_unwritten, {:error, _reason}), do: :no_edge

  # An approved document with no version at all: one an earlier state was to write, or an optional
  # one of this step's that never was.
  defp unwritten(ticket, edge),
    do: Enum.filter(edge.approve, &(Artifacts.latest(ticket.id, &1) == nil))

  @doc "Why Accept was refused, in words a person acts on."
  @spec refusal(term()) :: String.t()
  def refusal(:forbidden), do: "You are not a member of this project."
  def refusal(:suspended), do: "Your account is suspended."
  def refusal(:not_approved), do: "Your account is not approved."
  def refusal(:in_flight), do: "The agent is still replying. Accept once the reply has finished."
  def refusal(:already_accepted), do: "This step was already accepted."
  def refusal(:superseded), do: "The ticket has been through this step again since."
  def refusal(:not_a_step), do: "This conversation is not a workflow step."
  def refusal({:not_in_step, _state}), do: "The ticket has already left this step."
  def refusal({:not_active, status}), do: "The ticket is #{status}; it cannot be accepted."

  def refusal({:no_version, names}),
    do: "Nothing has been written for #{list(List.wrap(names))} yet. Ask the agent to write it."

  def refusal({:stale, names}),
    do:
      "#{list(names)} changed while you were looking. It is shown again below; read it, then Accept."

  def refusal({:no_edge, outcome}), do: "The workflow has no way on from #{inspect(outcome)}."

  def refusal({:max_spent, outcome}),
    do: "#{inspect(outcome)} has already been taken as often as the workflow allows."

  def refusal({:unknown_outcome, outcome}),
    do: "#{inspect(outcome)} is not an outcome of this step."

  def refusal({:merge_conflict, _conflict}), do: "The change no longer merges cleanly."
  def refusal(other), do: "Could not accept: #{inspect(other)}"

  defp list(names), do: Enum.map_join(names, ", ", &inspect/1)

  @doc "Whether a ticket's current state is a chat step."
  @spec step?(Ticket.t()) :: boolean()
  def step?(%Ticket{} = ticket) do
    case Tickets.parsed_workflow(ticket) do
      {:ok, workflow} -> State.chat?(Workflow.state(workflow, ticket.state) || %State{name: ""})
      {:error, _errors} -> false
    end
  end

  @doc "The live conversation of the ticket's current chat step, or nil."
  @spec live(Ticket.t()) :: Job.t() | nil
  def live(%Ticket{id: id, state: state}), do: Jobs.live_step(id, state)
end
