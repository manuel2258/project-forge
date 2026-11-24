defmodule Forge.Pages.Bursts do
  @moduledoc """
  Closes the audit of a page's data into events (`docs/design/pages.md` § The audit).

  Every write already put its change in a `page_bursts` row in its own transaction. This runs
  every 15 seconds and closes a burst once its writer has written nothing to that page for 60
  seconds, or 10 minutes after it opened, writing one `page.data_changed` event — who, which page,
  how many changes, the keys — in the transaction that deletes the row. **Never a value.**

  Off in the suite, which calls `sweep/1`, as `Forge.Attachments.Sweeper` is.
  """

  use GenServer

  import Ecto.Query

  alias Ecto.Multi
  alias Forge.{Events, Pages, Repo}
  alias Forge.Pages.{Burst, Page}

  require Logger

  @interval :timer.seconds(15)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule()
    {:noreply, state}
  rescue
    error ->
      Logger.error("pages: closing bursts failed: #{Exception.message(error)}")
      schedule()
      {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval)

  @doc """
  Closes every burst that is due at `now`, and returns how many it closed. A burst is due when its
  writer has been quiet for `burst_quiet_seconds` or it was opened `burst_max_seconds` ago.
  """
  @spec sweep(DateTime.t()) :: non_neg_integer()
  def sweep(now \\ DateTime.utc_now()) do
    limits = Pages.limits()
    quiet = DateTime.add(now, -limits[:burst_quiet_seconds], :second)
    oldest = DateTime.add(now, -limits[:burst_max_seconds], :second)

    due =
      Repo.all(
        from b in Burst,
          where: b.last_at <= ^quiet or b.opened_at <= ^oldest,
          select: b.id
      )

    Enum.count(due, &close/1)
  end

  # One burst in one transaction: the row goes and the event is written, or neither. A burst
  # another sweep closed first is not there to delete, and is not counted.
  defp close(id) do
    Multi.new()
    |> Multi.run(:burst, fn repo, _changes ->
      case repo.one(from b in Burst, where: b.id == ^id, lock: "FOR UPDATE SKIP LOCKED") do
        nil -> {:error, :gone}
        burst -> repo.delete(burst)
      end
    end)
    |> Multi.run(:page, fn repo, %{burst: burst} -> {:ok, repo.get!(Page, burst.page_id)} end)
    |> Multi.run(:event, fn repo, %{burst: burst, page: page} ->
      %Events.Event{}
      |> Events.Event.changeset(%{
        type: "page.data_changed",
        actor: Events.encode_actor(actor(burst.writer)),
        ticket_id: page.ticket_id,
        job_id: page.job_id,
        project_id: page.project_id,
        payload: %{
          "page" => page.name,
          "page_id" => page.id,
          "writer" => burst.writer,
          "changes" => burst.changes,
          "keys" => burst.keys,
          "key_count" => burst.key_count,
          "opened_at" => DateTime.to_iso8601(burst.opened_at),
          "last_at" => DateTime.to_iso8601(burst.last_at)
        }
      })
      |> repo.insert()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, _changes} -> true
      {:error, _step, _reason, _changes} -> false
    end
  end

  defp actor(%{"kind" => "user", "id" => id}), do: {:user, id}
  defp actor(%{"kind" => "job", "id" => id}), do: {:job, id}
  defp actor(%{"kind" => "api", "id" => id, "name" => name}), do: {:api, id, name || "token"}
end
