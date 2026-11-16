defmodule Forge.Tickets.Past do
  @moduledoc """
  Where a ticket has been, read from what the platform already records and stored nowhere
  (`docs/design/ui.md` § What each kind shows, *Every item about a ticket*): a line per step with
  how often it ran and how its latest run ended, and the loops that have fired as rounds of their
  limit. The queue draws it on every item that has a ticket.

  **Steps and runs come from what ran, not from the workflow**, so a step the pinned workflow no
  longer declares is still listed and a workflow that cannot be read costs the limits and the
  step kinds the workflow would have given, never the lines. What counts as a run:

    * an agent step counts its workflow jobs, a retry included and a job that waited for answers
      and resumed once — it is one row — but not a pending job that never started, which is a job
      waiting for a machine and not yet a run;
    * a command step counts its batches (`commands.started`), not the commands an agent invokes
      from inside another step, which have no such event;
    * a conversation step counts its conversations, a human step the times the ticket arrived.
  """

  import Ecto.Query, only: [from: 2]

  alias Forge.{Conversations, Engine, Jobs, Repo}
  alias Forge.Events.Event
  alias Forge.Jobs.{Commands, Job}
  alias ForgeCore.Workflow
  alias ForgeCore.Workflow.{State, Transition}

  @typedoc "A step the ticket has been in."
  @type step :: %{
          name: String.t(),
          kind: :agent | :command | :conversation | :human,
          runs: non_neg_integer(),
          last: String.t() | nil,
          current: boolean(),
          job: Job.t() | nil
        }

  @typedoc "A transition that has fired, with the limit its workflow declares, if it does."
  @type loop :: %{
          from: String.t(),
          to: String.t(),
          outcome: String.t(),
          rounds: pos_integer(),
          max: pos_integer() | nil
        }

  # The tail of a failed command's log: 4 KiB, the figure the ticket page's Steps view uses
  # (`ForgeWeb.TicketLive`'s own `@tail_bytes`; the two are kept equal by hand).
  @tail_bytes 4096

  @doc "How many bytes of a failed command's log the queue draws."
  @spec tail_bytes() :: pos_integer()
  def tail_bytes, do: @tail_bytes

  @doc """
  The ticket's steps in the order it first reached them. `workflow` is the pinned one, or nil when
  it cannot be read; `jobs` is `Forge.Jobs.for_ticket/1`, which the caller has already read.
  """
  @spec steps(Forge.Tickets.Ticket.t(), Workflow.t() | nil, [Job.t()]) :: [step()]
  def steps(ticket, workflow, jobs) do
    events = events(ticket.id)
    chats = Jobs.step_chats_for_ticket(ticket.id)
    batches = batches(events)
    started = started_command_jobs(batches)
    arrivals = arrivals(events)
    accepted = for %{type: "step.accepted"} = e <- events, into: %{}, do: {e.job_id, e.payload}

    decided =
      for %{type: "commands.decided"} = e <- events, into: %{}, do: {e.payload["batch"], e}

    # A state with runs and no arrival is not expected; it is listed after the others rather than
    # lost, in the order its kinds are read here.
    ran =
      Enum.map(workflow_jobs(jobs), & &1.state) ++
        Enum.map(batches, & &1.state) ++ Enum.map(chats, & &1.state)

    names = Enum.uniq(arrivals ++ [ticket.state] ++ ran)

    for name <- names do
      kind = kind(workflow, name, jobs, batches, chats)

      step =
        case kind do
          :agent -> agent_step(name, jobs)
          :command -> command_step(name, batches, started, decided)
          :conversation -> conversation_step(name, chats, accepted)
          :human -> %{runs: Enum.count(arrivals, &(&1 == name)), last: nil, job: nil}
        end

      Map.merge(step, %{name: name, kind: kind, current: name == ticket.state})
    end
  end

  @doc """
  The loops that have fired, as rounds of their limit: every transition the workflow declares with
  a `max` that has fired at least once, in declaration order, then every fired edge the workflow
  does not declare, with no limit. With no readable workflow no edge is declared, so every fired
  one is listed without a limit.

  The counts are `Forge.Engine.rounds/1` — the figures `max` is decided on — so a person's own move
  along an edge counts and a count may read above its limit; it is shown as it is.
  """
  @spec loops(Forge.Tickets.Ticket.t(), Workflow.t() | nil) :: [loop()]
  def loops(ticket, workflow) do
    rounds = Engine.rounds(ticket.id)
    transitions = (workflow && workflow.transitions) || []
    declared = MapSet.new(transitions, &Transition.id/1)

    limited =
      for %Transition{max: max} = t when is_integer(max) <- transitions,
          count = Map.get(rounds, Transition.id(t), 0),
          count > 0,
          do: loop(Transition.id(t), count, max)

    # **A merge-conflict reroute is not a loop**: the engine logs it as a `transition.taken` on an
    # edge built from the merging state's `on_conflict` (`ForgeCore.Workflow.conflict_transition/3`),
    # which no workflow declares in `transitions` and no `max` governs, so it is left out here as it
    # is not an edge the workflow dropped.
    conflict = Workflow.merge_conflict_outcome()

    undeclared =
      for {{_from, _to, outcome} = id, count} <- Enum.sort(rounds),
          outcome != conflict,
          not MapSet.member?(declared, id) do
        loop(id, count, nil)
      end

    limited ++ undeclared
  end

  defp loop({from, to, outcome}, rounds, max),
    do: %{from: from, to: to, outcome: outcome, rounds: rounds, max: max}

  @doc """
  What a step's latest run said, for its opened line: an agent's job with its closing words, a
  command step's last batch with the end of each failed command's log, a conversation's last
  reply. Nil for a human step and for one that never ran.
  """
  @spec latest_run(Forge.Tickets.Ticket.t(), step()) :: map() | nil
  def latest_run(_ticket, %{kind: :agent, job: %Job{} = job}),
    do: %{kind: :agent, job: job, closing: Jobs.last_words(job)}

  def latest_run(ticket, %{kind: :command, name: name, runs: runs}) when runs > 0 do
    case Commands.latest_batch(ticket.id, name, @tail_bytes) do
      nil -> nil
      batch -> Map.put(batch, :kind, :command)
    end
  end

  def latest_run(_ticket, %{kind: :conversation, job: %Job{} = chat}),
    do: %{kind: :conversation, job: chat, reply: last_reply(chat)}

  def latest_run(_ticket, _step), do: nil

  @doc "The last thing the conversation's agent said, or nil."
  @spec last_reply(Job.t()) :: String.t() | nil
  def last_reply(%Job{id: id}) do
    id
    |> Conversations.messages()
    |> Enum.filter(&(&1.role == :assistant))
    |> List.last()
    |> case do
      %{text: text} -> text
      nil -> nil
    end
  end

  # -- reads ---------------------------------------------------------------------------------

  # Only the events that say where the ticket went and what ran, in order; the payloads are small.
  @types ~w(ticket.admitted transition.taken commands.started commands.decided step.accepted)

  defp events(ticket_id) do
    Repo.all(
      from e in Event,
        where: e.ticket_id == ^ticket_id and e.type in @types,
        order_by: e.seq,
        select: %{type: e.type, job_id: e.job_id, payload: e.payload}
    )
  end

  # The states the ticket arrived in, in order, one entry per arrival: admission, then each
  # transition's target.
  defp arrivals(events) do
    Enum.flat_map(events, fn
      %{type: "ticket.admitted", payload: %{"state" => state}} -> [state]
      %{type: "transition.taken", payload: %{"to" => to}} -> [to]
      _other -> []
    end)
  end

  defp batches(events) do
    for %{type: "commands.started", payload: %{"state" => state, "batch" => batch} = payload} <-
          events,
        do: %{state: state, batch: batch, jobs: payload["jobs"] || []}
  end

  # Which of a batch's jobs has started: a batch whose every job is still waiting for a machine has
  # not run.
  defp started_command_jobs(batches) do
    ids = Enum.flat_map(batches, & &1.jobs)

    Repo.all(
      from j in Job,
        where: j.id in ^ids,
        select: {j.id, j.status, j.started_at}
    )
    |> Map.new(fn {id, status, started_at} -> {id, status != :pending or started_at != nil} end)
  end

  defp workflow_jobs(jobs), do: Enum.filter(jobs, &(&1.kind == :workflow))

  # What it is: the pinned workflow's word where it declares the state, otherwise what ran there.
  defp kind(workflow, name, jobs, batches, chats) do
    declared_kind(workflow, name) || kind_by_runs(name, jobs, batches, chats)
  end

  @doc """
  What kind of step the workflow makes `name`, or nil when it does not declare it (or there is no
  workflow): `:conversation`, `:agent`, `:command`, or `:human` for a state that waits for a person
  or ends the workflow.
  """
  @spec declared_kind(Workflow.t() | nil, String.t()) ::
          :agent | :command | :conversation | :human | nil
  def declared_kind(workflow, name) do
    case workflow && Workflow.state(workflow, name) do
      %State{chat: true} -> :conversation
      %State{prompt: prompt} when is_binary(prompt) -> :agent
      %State{invoke: [_ | _]} -> :command
      %State{} -> :human
      nil -> nil
    end
  end

  defp kind_by_runs(name, jobs, batches, chats) do
    cond do
      Enum.any?(workflow_jobs(jobs), &(&1.state == name)) -> :agent
      Enum.any?(batches, &(&1.state == name)) -> :command
      Enum.any?(chats, &(&1.state == name)) -> :conversation
      true -> :human
    end
  end

  defp agent_step(name, jobs) do
    counted =
      Enum.filter(
        workflow_jobs(jobs),
        &(&1.state == name and not (&1.status == :pending and is_nil(&1.started_at)))
      )

    last = List.last(counted)

    %{
      runs: length(counted),
      last: last && (last.declared_outcome || to_string(last.outcome || last.status)),
      job: last
    }
  end

  defp command_step(name, batches, started, decided) do
    counted =
      Enum.filter(batches, fn batch ->
        batch.state == name and Enum.any?(batch.jobs, &Map.get(started, &1, false))
      end)

    last = List.last(counted)

    %{
      runs: length(counted),
      last:
        last && ((decided[last.batch] && decided[last.batch].payload["outcome"]) || "running"),
      job: nil
    }
  end

  defp conversation_step(name, chats, accepted) do
    here = Enum.filter(chats, &(&1.state == name))
    last = List.last(here)

    %{
      runs: length(here),
      last:
        last &&
          ((accepted[last.id] && accepted[last.id]["outcome"]) || to_string(last.status)),
      job: last
    }
  end
end
