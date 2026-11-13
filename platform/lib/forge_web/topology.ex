defmodule ForgeWeb.Topology do
  @moduledoc """
  What kind of state a workflow state is, and the mark that tells them apart (`mark/1`): `▸` for
  one that runs work on entry, `●` for one that waits on a person, `○` for the end.

  Its own module rather than the board's, because the queue, the ticket, the project and the
  review all draw it and the board is going (`docs/design/ui.md` § The projects page).
  """

  alias Forge.Tickets
  alias ForgeCore.Workflow

  @doc "The kind of `name` in `workflow`; `:unknown` when either is missing."
  @spec of(Workflow.t() | nil, String.t()) :: :job | :human | :terminal | :unknown
  def of(nil, _name), do: :unknown

  def of(workflow, name) do
    state = Workflow.state(workflow, name)

    cond do
      is_nil(state) -> :unknown
      # A command state runs work on entry as a job state does, and draws as one: `▸`.
      Workflow.State.runs?(state) -> :job
      Workflow.terminal?(workflow, name) -> :terminal
      true -> :human
    end
  end

  @doc """
  The workflow each of `tickets` is pinned to, parsed once per pin rather than once per ticket —
  tickets admitted together share one — keyed by `{workflow_commit, ticket_type}`; nil for a pin
  that does not parse.
  """
  @spec workflows([Tickets.Ticket.t()]) :: %{
          {String.t() | nil, String.t() | nil} => Workflow.t() | nil
        }
  def workflows(tickets) do
    tickets
    |> Enum.uniq_by(&pin/1)
    |> Map.new(fn ticket ->
      parsed =
        case Tickets.parsed_workflow(ticket) do
          {:ok, workflow} -> workflow
          {:error, _errors} -> nil
        end

      {pin(ticket), parsed}
    end)
  end

  @doc "The workflow `ticket` is pinned to, out of `workflows/1`'s map."
  @spec pinned(map(), Tickets.Ticket.t()) :: Workflow.t() | nil
  def pinned(workflows, ticket), do: workflows[pin(ticket)]

  @doc """
  The kind of the state each of `tickets` rests in, by ticket id, from the workflow it is pinned
  to: what a list of tickets draws its marks from.
  """
  @spec kinds([Tickets.Ticket.t()]) :: %{String.t() => :job | :human | :terminal | :unknown}
  def kinds(tickets) do
    workflows = workflows(tickets)
    Map.new(tickets, &{&1.id, of(pinned(workflows, &1), &1.state)})
  end

  defp pin(ticket), do: {ticket.workflow_commit, ticket.ticket_type}

  @doc """
  The mark a kind of state is drawn with (`docs/design/ui.md` § The three axes): `▸` runs work,
  `●` waits on a person, `○` the end, where nothing will happen, `·` unknown. The one mapping the
  subline, the state label and the workflow map all draw.
  """
  @spec mark(:job | :human | :terminal | :unknown | nil) :: String.t()
  def mark(:job), do: "▸"
  def mark(:human), do: "●"
  def mark(:terminal), do: "○"
  def mark(_unknown), do: "·"

  @doc """
  A workflow's state names in the order it reaches them, from `initial` outwards, along
  `on_conflict` too — an integrating state is reached by nothing else. What a workflow track
  draws, and the order every list of a workflow's states reads in.
  """
  @spec order(Workflow.t()) :: [String.t()]
  def order(%Workflow{} = workflow), do: walk(workflow, [workflow.initial], [])

  defp walk(_workflow, [], seen), do: Enum.reverse(seen)

  defp walk(workflow, [state | rest], seen) do
    if state in seen do
      walk(workflow, rest, seen)
    else
      next = workflow |> Workflow.edges_from(state) |> Enum.map(& &1.to)
      walk(workflow, rest ++ next, [state | seen])
    end
  end
end
