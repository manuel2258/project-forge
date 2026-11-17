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
  alias Forge.Jobs.{Job, Runs}
  alias Forge.Repo
  alias Forge.Tickets.Ticket

  @typedoc """
  A ticket's live work: the job on a machine, or waiting for one. `started_at` is the start of
  the run it is in *now* when it is running (`live/1`).
  """
  @type live :: %{
          id: String.t(),
          kind: :workflow | :command,
          status: :running | :pending,
          attempt: pos_integer() | nil,
          started_at: DateTime.t() | nil,
          inserted_at: DateTime.t()
        }

  @doc """
  The live job of each ticket: one running if it has one, else one pending, newest within the
  class — a ticket is on a machine the moment any of its work is. Workflow jobs and commands only:
  a ticket's chat step is drawn as the conversation it is, not as the ticket running.

  **A running job's `started_at` is its current run's**, from the run ledger
  (`Forge.Jobs.Runs.started/1`), not `jobs.started_at`, which keeps the first run's start for the
  life of the job: a job answered at 19:00 after stopping on a question at 09:10 would read ten
  hours old a minute into its second run. The column is the fallback for a running row whose run
  the ledger does not have. `kind` says whether the spend cap gates it: a workflow job is, a
  command takes no spend gate (`Jobs.assign_command/2`), so only a pending *workflow* job is
  `paused · spend` (`ForgeWeb.ProjectTickets`).
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
          id: j.id,
          ticket_id: j.ticket_id,
          kind: j.kind,
          status: j.status,
          attempt: j.attempt,
          started_at: j.started_at,
          inserted_at: j.inserted_at
        }
    )
    |> Enum.group_by(& &1.ticket_id)
    |> Map.new(fn {id, jobs} -> {id, pick(jobs)} end)
    |> current_run()
  end

  defp current_run(picked) do
    runs = Runs.started(for {_ticket, %{status: :running, id: id}} <- picked, do: id)

    Map.new(picked, fn
      {ticket_id, %{status: :running, id: id} = job} ->
        {ticket_id, %{job | started_at: runs[id] || job.started_at}}

      other ->
        other
    end)
  end

  defp pick(jobs) do
    {running, pending} = Enum.split_with(jobs, &(&1.status == :running))
    class = if running != [], do: running, else: pending
    class |> Enum.max_by(& &1.inserted_at, DateTime) |> Map.delete(:ticket_id)
  end

  @doc """
  The reads a list of ticket rows draws from besides the queue's items and the clock
  (`ForgeWeb.ProjectTickets.rows/2`), for `tickets` of one project or of several: `:live`,
  `:said`, `:paused`, `:places` (the merge queue's, per project) and `:milestones` (their names,
  by id). **One function for the project page and the queue page**, so a ticket is drawn the same
  on both from the same reads, and neither has a second copy of what makes a row.

  `places:` is what a caller that already read the merge queue passes, so it is not read twice.
  """
  @spec facts([Ticket.t()], keyword()) :: %{
          live: map(),
          said: map(),
          paused: boolean(),
          places: map(),
          milestones: map()
        }
  def facts(tickets, opts \\ []) do
    ids = Enum.map(tickets, & &1.id)
    projects = tickets |> Enum.map(& &1.project_id) |> Enum.uniq()

    %{
      live: live(ids),
      said: said(ids),
      paused: Forge.Spend.paused?(),
      places: Keyword.get_lazy(opts, :places, fn -> places(projects) end),
      milestones:
        projects |> Enum.map(&Forge.Milestones.names/1) |> Enum.reduce(%{}, &Map.merge/2)
    }
  end

  defp places(project_ids) do
    for project_id <- project_ids,
        {entry, place} <- Forge.MergeQueue.with_places(project_id),
        into: %{},
        do: {entry.ticket_id, place}
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
