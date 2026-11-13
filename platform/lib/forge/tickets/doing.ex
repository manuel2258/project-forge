defmodule Forge.Tickets.Doing do
  @moduledoc """
  What a project's open tickets are doing, for the project page's Tickets list
  (`docs/design/ui.md` § Tickets): the live job of each, the last thing its agent said, and the
  project's recent merges.

  **Every read takes a whole list of tickets and is one query**, never one per ticket: the list
  is the project's every open ticket, and a page that read each one's job and last line in turn
  would grow with the project's history. Each caller has already scoped the ticket ids — they
  are one project's, read after the page's membership check.
  """

  import Ecto.Query, only: [from: 2]

  alias Forge.Events.Event
  alias Forge.Jobs.Job
  alias Forge.Repo
  alias Forge.Tickets.Ticket

  @typedoc "A ticket's live work: the job on a machine, or waiting for one."
  @type live :: %{
          status: :running | :pending,
          attempt: pos_integer() | nil,
          started_at: DateTime.t() | nil,
          inserted_at: DateTime.t()
        }

  @doc """
  The live job of each ticket: one running if it has one, else one pending, newest within the
  class — the rule `Forge.Queue`'s under-way group uses, for the same reason (a ticket is on a
  machine the moment any of its work is). Workflow jobs and commands only: a ticket's chat step
  is drawn as the conversation it is, not as the ticket running.
  """
  @spec live([String.t()]) :: %{String.t() => live()}
  def live([]), do: %{}

  def live(ticket_ids) do
    Repo.all(
      from j in Job,
        where: j.ticket_id in ^ticket_ids,
        where: j.kind in [:workflow, :command],
        where: j.status in [:running, :pending],
        select: %{
          ticket_id: j.ticket_id,
          status: j.status,
          attempt: j.attempt,
          started_at: j.started_at,
          inserted_at: j.inserted_at
        }
    )
    |> Enum.group_by(& &1.ticket_id)
    |> Map.new(fn {id, jobs} -> {id, pick(jobs)} end)
  end

  defp pick(jobs) do
    {running, pending} = Enum.split_with(jobs, &(&1.status == :running))
    class = if running != [], do: running, else: pending
    class |> Enum.max_by(& &1.inserted_at, DateTime) |> Map.delete(:ticket_id)
  end

  @doc """
  The last thing each ticket's agent said, and when: the newest `job.harness.text` of any of its
  jobs, a subagent's report to its agent left out as `Forge.Conversations` leaves it out. In one
  query, which for each ticket walks its events newest first on the `(ticket_id, seq)` index and
  stops at the first that qualifies. A `DISTINCT ON (ticket_id) … ORDER BY ticket_id, seq DESC`
  said the same, but read and sorted every text a ticket's agents had ever said to find it.
  """
  @spec said([String.t()]) :: %{String.t() => {String.t(), DateTime.t()}}
  def said([]), do: %{}

  def said(ticket_ids) do
    newest =
      from e in Event,
        where: e.ticket_id == parent_as(:ticket).id and e.type == "job.harness.text",
        where: fragment("(? ->> 'parent_tool_use_id') IS NULL", e.payload),
        order_by: [desc: e.seq],
        limit: 1,
        select: %{payload: e.payload, at: e.inserted_at}

    Repo.all(
      from t in Ticket,
        as: :ticket,
        where: t.id in ^ticket_ids,
        inner_lateral_join: e in subquery(newest),
        on: true,
        select: {t.id, e.payload, e.at}
    )
    |> Map.new(fn {id, payload, at} -> {id, {first_line(payload["text"]), at}} end)
  end

  defp first_line(text) when is_binary(text) do
    text |> String.split("\n", trim: true) |> List.first("") |> String.slice(0, 200)
  end

  defp first_line(_none), do: ""

  @doc """
  The project's last `limit` merges, newest first: the ticket each landed and the commit, which
  is what the Merge view's *Merged lately* answers "did it land?" with.
  """
  @spec merged(String.t(), pos_integer()) :: [
          %{ticket: Ticket.t(), sha: String.t() | nil, at: DateTime.t()}
        ]
  def merged(project_id, limit) do
    Repo.all(
      from e in Event,
        join: t in Ticket,
        on: t.id == e.ticket_id,
        where: e.project_id == ^project_id and e.type == "ticket.merged",
        order_by: [desc: e.seq],
        limit: ^limit,
        select: %{ticket: t, sha: fragment("? ->> 'sha'", e.payload), at: e.inserted_at}
    )
  end
end
