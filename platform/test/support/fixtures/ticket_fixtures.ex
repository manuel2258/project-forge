defmodule Forge.TicketFixtures do
  @moduledoc """
  A ticket's history, made directly: jobs that ran and ended, a job running now with what it did,
  a document's versions, and a merge — for the ticket page's look setup (`ticket_views`) and its
  tests. Built on `Forge.ForgeFixtures`.
  """

  import Forge.ForgeFixtures

  alias Forge.{Artifacts, Jobs, Repo}

  @doc "A job of `ticket` in `state` that ran and ended with `outcome` (`:converged` by default)."
  def ran!(ticket, state, attrs \\ %{}) do
    {outcome, attrs} = Map.pop(attrs, :outcome, :converged)
    job = job_fixture(Map.merge(%{ticket: ticket, state: state}, Map.take(attrs, [:attempt])))
    now = DateTime.utc_now(:second)

    job
    |> Jobs.Job.progress_changeset(
      Map.merge(
        %{
          status: :finished,
          outcome: outcome,
          turns: 12,
          usage: 80_000,
          started_at: DateTime.add(now, -900, :second),
          finished_at: DateTime.add(now, -300, :second)
        },
        Map.drop(attrs, [:attempt])
      )
    )
    |> Repo.update!()
  end

  @doc "A job of `ticket` in its state, running, that has done what each of `commands` says."
  def running!(ticket, commands) do
    job = job_fixture(%{ticket: ticket, status: :running})

    for {command, i} <- Enum.with_index(commands) do
      :ok =
        Jobs.record_harness_event(job.id, %{
          type: "job.harness.tool_use",
          payload: %{id: "t#{i}", name: "Bash", input: %{"command" => command}}
        })

      :ok =
        Jobs.record_harness_event(job.id, %{
          type: "job.harness.tool_result",
          payload: %{tool_use_id: "t#{i}", is_error: false, excerpt: "ok", bytes: 2}
        })
    end

    job
  end

  @doc "`content` recorded as the next version of `name` on `ticket`, by `author`."
  def wrote!(ticket, name, content, author \\ :system) do
    {:ok, version} =
      Artifacts.record_version(ticket.id, name, :document, author, %{content: content})

    version
  end

  @doc "`ticket` resting where it is with its pending approval of `approve`, into `to`."
  def pending!(ticket, to, approve) do
    ticket
    |> Ecto.Changeset.change(
      status: :active,
      pending_transition: %{
        "from" => ticket.state,
        "to" => to,
        "outcome" => nil,
        "approve" => approve
      }
    )
    |> Repo.update!()
  end

  @doc "`ticket` merged `ago` seconds ago: its `ticket.merged` event, and the ticket done."
  def merged!(ticket, ago \\ 0) do
    Repo.insert!(%Forge.Events.Event{
      type: "ticket.merged",
      actor: %{"kind" => "system", "id" => nil},
      ticket_id: ticket.id,
      project_id: ticket.project_id,
      payload: %{},
      inserted_at: DateTime.add(DateTime.utc_now(:second), -ago, :second)
    })

    ticket |> Ecto.Changeset.change(status: :done) |> Repo.update!()
  end
end
