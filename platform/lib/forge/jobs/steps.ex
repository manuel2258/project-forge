defmodule Forge.Jobs.Steps do
  @moduledoc """
  A command's **steps**: the times a worker took around its script, kept as one `command.step`
  event each on the command's job (`docs/design/worker-tier.md` § Looking into a copy, ticket 84).

  They are lifecycle events: neither type begins `job.harness.`, so `forge_event_swept/1` keeps
  them for good (`docs/design/storage.md` § Retention), and `Forge.Events` leaves them out of its
  lists, as it does the archive's reads, because a page draws them as a table and not as a line
  each. A result from a worker below protocol 18 reports none, which is recorded as one
  `command.steps_unrecorded` so that a page can tell *the machine's release predates step timings*
  from *ran before forge recorded steps*, which is no event at all.
  """

  alias Ecto.Multi
  alias Forge.{Events, Repo}
  alias Forge.Jobs.Job
  alias Forge.Workers.Worker
  alias ForgeCore.CommandSteps

  @step "command.step"
  @unrecorded "command.steps_unrecorded"

  # The first protocol that reports steps (`docs/design/worker-channel.md` § Protocol 18).
  @steps_protocol 18

  @doc "The protocol a worker reports steps from."
  @spec steps_protocol() :: pos_integer()
  def steps_protocol, do: @steps_protocol

  @doc "The event types this module writes: what `Forge.Events` leaves out of its lists."
  @spec types() :: [String.t()]
  def types, do: [@step, @unrecorded]

  @doc """
  Adds the events for a command's `steps` (as the worker reported them) to `multi`, in order. No
  steps from a worker below protocol 18 is one `command.steps_unrecorded`; no steps from any other
  worker, or from a job that is not a command, is nothing at all.
  """
  @spec put(Multi.t(), Job.t(), term()) :: Multi.t()
  def put(multi, %Job{kind: :command} = job, steps) do
    case CommandSteps.sanitize(steps) do
      nil -> put_unrecorded(multi, job, worker_protocol(job))
      cleaned -> cleaned |> Enum.with_index() |> Enum.reduce(multi, &put_step(&2, job, &1))
    end
  end

  def put(multi, %Job{}, _steps), do: multi

  defp put_step(multi, job, {step, index}) do
    Events.log(multi, {:step, index}, @step, :system, %{
      ticket_id: job.ticket_id,
      job_id: job.id,
      payload: step
    })
  end

  defp put_unrecorded(multi, job, protocol) when is_integer(protocol) do
    if protocol < @steps_protocol do
      Events.log(multi, :steps_unrecorded, @unrecorded, :system, %{
        ticket_id: job.ticket_id,
        job_id: job.id,
        payload: %{"protocol" => protocol}
      })
    else
      multi
    end
  end

  defp put_unrecorded(multi, _job, nil), do: multi

  defp worker_protocol(%Job{worker_id: nil}), do: nil

  defp worker_protocol(%Job{worker_id: id}) do
    case Repo.get(Worker, id) do
      %Worker{protocol: protocol} -> protocol
      nil -> nil
    end
  end

  @doc """
  What a command's page says about its steps: `{:steps, [step]}` in the order they were taken, or
  `{:unrecorded, :release}` when its machine's release predates them, or `{:unrecorded, :before}`
  when forge recorded nothing about it.
  """
  @spec read(String.t()) :: {:steps, [map()]} | {:unrecorded, :release | :before}
  def read(job_id) do
    events = Events.command_step_events(job_id)

    case Enum.filter(events, &(&1.type == @step)) do
      [] ->
        if Enum.any?(events, &(&1.type == @unrecorded)),
          do: {:unrecorded, :release},
          else: {:unrecorded, :before}

      steps ->
        {:steps, Enum.map(steps, & &1.payload)}
    end
  end

  @doc "Several commands' steps in one query, by job id; a job with none is `{:unrecorded, :before}`."
  @spec read_many([String.t()]) :: %{String.t() => {:steps, [map()]} | {:unrecorded, atom()}}
  def read_many(job_ids) do
    events = Events.command_step_events_many(job_ids)
    by_job = Enum.group_by(events, & &1.job_id)

    Map.new(job_ids, fn id -> {id, read_value(Map.get(by_job, id, []))} end)
  end

  defp read_value(events) do
    case Enum.filter(events, &(&1.type == @step)) do
      [] ->
        {:unrecorded,
         if(Enum.any?(events, &(&1.type == @unrecorded)), do: :release, else: :before)}

      steps ->
        {:steps, Enum.map(steps, & &1.payload)}
    end
  end
end
