defmodule Forge.Merge.Watch do
  @moduledoc """
  What a merge into the default branch did to the project's other open tickets
  (`docs/design/git-hosting.md` § After a merge, the other tickets).

  A merge moves the default branch under every other ticket, and the one it moved into a conflict
  used to find out only when somebody approved it. So after each merge every other open ticket
  with a changeset is checked against the new head, and one that now conflicts is recorded as
  `ticket.conflict_found` — once per commit — and told so on its page. Nothing is
  started: a job spends a credential, and what to do about a conflict is a person's call
  (`docs/design/workflow-grammar-v1.md` § Merging).

  **It runs in a task of its own beside the merge's request**, under the platform's task
  supervisor, so pressing merge on a project with many open tickets is not made slow by them. Configured
  `inline: true` it runs in the caller instead, which is what the tests ask for: a task that
  outlived its test would write to a sandbox nobody owns any more.
  """

  import Ecto.Query, only: [from: 2]

  require Forge.Tickets.Ticket

  alias Forge.{Engine, Events, Merge, Repo, Tickets}
  alias Forge.Events.Event
  alias Forge.Tickets.Ticket

  @typedoc ~s(What made the merge: `%{"ticket" => number}` or `%{"chat" => id}`.)
  @type cause :: %{String.t() => term()}

  @doc """
  Checks the open tickets of `project_id` against `merged`, the commit a merge just put on the
  default branch; `cause` is what made it. The ticket that merged needs no leaving out: its commit
  is on `merged`, which is the clean answer.
  """
  @spec after_merge(String.t(), String.t(), cause()) :: :ok
  def after_merge(project_id, merged, cause) do
    if Keyword.get(Application.get_env(:forge, __MODULE__, []), :inline, false) do
      check(project_id, merged, cause)
    else
      {:ok, _pid} =
        Task.Supervisor.start_child(Forge.TaskSupervisor, fn ->
          check(project_id, merged, cause)
        end)
    end

    :ok
  end

  @doc """
  The checking itself, in the caller: each open ticket of the project whose latest changeset
  version has not been found conflicting yet is checked against `merged`, and the ones that
  conflict are recorded. Returns them.
  """
  @spec check(String.t(), String.t(), cause() | nil) :: [Ticket.t()]
  def check(project_id, merged, cause) do
    from(t in Ticket,
      where: t.project_id == ^project_id and t.status in ^Ticket.open_statuses(),
      order_by: t.number
    )
    |> Repo.all()
    |> Enum.filter(&found?(&1, merged, cause))
  end

  defp found?(%Ticket{} = ticket, merged, cause) do
    with {:ok, source} <- Merge.changeset(ticket),
         false <- found_before?(ticket, source.sha),
         {:conflict, paths, head} <- Merge.check(ticket, source.sha, merged) do
      Events.append("ticket.conflict_found", :system, %{
        ticket_id: ticket.id,
        payload: %{
          "paths" => paths,
          "head" => head,
          "changeset" => source.sha,
          "changeset_version" => source.version,
          "cause" => caused(ticket, source.sha, merged, cause)
        }
      })

      Events.notify(ticket.id)
      true
    else
      _clean_or_known -> false
    end
  end

  # Once per commit: a ticket that conflicts after every merge of a busy day is told once, until its
  # changeset is another commit.
  defp found_before?(%Ticket{id: id}, sha) do
    Repo.exists?(
      from e in Event,
        where:
          e.ticket_id == ^id and e.type == "ticket.conflict_found" and
            fragment("?->>'changeset'", e.payload) == ^sha
    )
  end

  # The merge caused it when the ticket merged cleanly on top of what the merge was made on — its
  # first parent. Conflicting there too, it conflicted already, and the merge is not named.
  defp caused(ticket, sha, merged, cause) do
    if Merge.check(ticket, sha, merged <> "^1") == :ok, do: cause
  end

  @doc """
  What the ticket's page says about a conflict found after a merge, or nil when there is nothing
  true to say: the ticket is not open, nothing was found, its changeset has changed since, or it
  has taken the conflict route since. `send_to` is the state `Forge.Engine.integrate/2` would
  send it to, or nil when it would refuse.
  """
  @spec notice(Ticket.t()) :: map() | nil
  def notice(%Ticket{status: status} = ticket) when Ticket.open?(status) do
    with %Event{payload: %{"changeset" => sha} = found, seq: seq} <-
           Events.latest_for_ticket(ticket.id, "ticket.conflict_found"),
         {:ok, %{sha: ^sha}} <- Merge.changeset(ticket),
         false <- routed_since?(ticket.id, seq) do
      %{
        paths: found["paths"],
        head: found["head"],
        cause: found["cause"],
        send_to: Engine.integrates_to(ticket, Tickets.workflow(ticket))
      }
    else
      _nothing -> nil
    end
  end

  def notice(%Ticket{}), do: nil

  # A conflict the route was taken on — not the one the loop's bound stuck on, which went nowhere.
  defp routed_since?(ticket_id, seq) do
    Repo.exists?(
      from e in Event,
        where:
          e.ticket_id == ^ticket_id and e.type == "ticket.merge_conflicted" and e.seq > ^seq and
            not is_nil(fragment("?->>'to'", e.payload))
    )
  end
end
