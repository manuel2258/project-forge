defmodule Forge.Workers.Updates do
  @moduledoc """
  A permanent machine updating itself, from the platform's side
  (`docs/design/worker-tier.md` § Updating a permanent machine).

  The platform decides one thing: **what a machine should be running** — its own build,
  `Forge.WorkerImage.release/0`, in either direction — and for whom. It never decides when, nor
  how: the machine does, and says where it is (`record/2`). A node with no release has nothing to
  send, a machine the platform made is replaced and never updated, and a permanent machine whose
  owner switched updates off is told nothing unless the owner presses *Update now*.

  **Only the owner acts.** `set_automatic/3` and `update_now/2` read the row scoped to the caller
  before anything else, as `Workers.retire_by_owner/2` does: a node admin, a project admin or
  someone else's id posted by hand is `:not_found` and nothing is written or sent
  (`docs/design/identity.md` § Sequencing).

  **What a machine says is text, and only text, from a machine that is only authenticated.** It is
  cleaned by `ForgeCore.WorkerUpdate` and again here for what a column cannot hold, because the
  value is kept in a jsonb column that every later mount of the workers page reads: a map where a
  string belongs once took the page down for good (`ForgeWeb.WorkersLive.harness_text/1`).
  """

  import Ecto.Query, only: [from: 2]

  alias Forge.Accounts.User
  alias Forge.{Jobs, Repo, WorkerImage, Workers}
  alias Forge.Workers.{Log, Worker}
  alias ForgeCore.WorkerUpdate

  # The protocol that added `update` (`docs/design/worker-channel.md` § Protocol 13 (ticket 54)):
  # a machine speaking less is not told anything, since it would take work it had been told to
  # stop taking.
  @protocol 13

  # What a machine in the middle of an update says, and what is not yet an end of it.
  @under_way ~w(downloading installing pausing restarting trying)

  @doc "The protocol a machine must speak to be updated by this platform."
  @spec protocol() :: pos_integer()
  def protocol, do: @protocol

  @doc "The steps that mean an update is under way, in the order it goes through them."
  @spec under_way() :: [String.t()]
  def under_way, do: @under_way

  @doc "A machine the owner booted and the platform never destroys: no template, not managed."
  @spec permanent?(Worker.t()) :: boolean()
  def permanent?(%Worker{managed: false, template_id: nil}), do: true
  def permanent?(%Worker{}), do: false

  @doc """
  What this machine should be running, as it goes on the wire — or nil, which tells it to stand
  down. Nil for: a node with no release, a machine the platform made, the owner's switch off, and
  a machine already running the platform's build.
  """
  @spec target(Worker.t()) :: map() | nil
  def target(%Worker{auto_update: true} = worker), do: wanted(worker)
  def target(%Worker{}), do: nil

  @doc "As `target/1`, with the switch ignored: what *Update now* sends."
  @spec wanted(Worker.t()) :: map() | nil
  def wanted(%Worker{} = worker) do
    with true <- permanent?(worker),
         %{} = release <- WorkerImage.release(),
         true <- worker.build != release.build do
      wire(release)
    else
      _nothing -> nil
    end
  end

  defp wire(release) do
    %{
      "build" => release.build,
      "version" => release.version,
      "repository" => release.repository,
      "digest" => release.digest,
      "raw_sha256" => release.raw_sha256,
      "raw_size" => release.raw_size
    }
  end

  @doc """
  Why this machine cannot update itself, as a code the page turns into a sentence, or nil: the old
  layout, a worker not running on the image, or a protocol before
  `update`. What the machine says of itself and what the platform knows of its protocol.
  """
  @spec unable(Worker.t()) :: String.t() | nil
  def unable(%Worker{protocol: protocol}) when not is_integer(protocol) or protocol < @protocol,
    do: "protocol"

  def unable(%Worker{update_state: %{"unable" => reason}}), do: reason
  def unable(%Worker{}), do: nil

  @doc "Whether an update is under way, by what the machine last said."
  @spec under_way?(Worker.t()) :: boolean()
  def under_way?(%Worker{update_state: %{"step" => step}}), do: step in @under_way
  def under_way?(%Worker{}), do: false

  @doc """
  Whether *Update now* is offered: a connected permanent machine whose build is not the
  platform's, that can update and has no update under way — whichever way the switch is set. A
  machine that is not connected, a refused one included, offers none: no request is kept for it.
  """
  @spec update_now?(Worker.t(), boolean()) :: boolean()
  def update_now?(%Worker{} = worker, connected?) do
    connected? and wanted(worker) != nil and is_nil(unable(worker)) and not under_way?(worker)
  end

  # -- what the machine says --------------------------------------------------------------------

  @doc """
  Records what a machine said of an update: the last report on the row, cleaned, and what it
  means for placing work. **`pausing` stops the platform placing anything here** (`updating_at`)
  and puts back in the queue whatever is running there that the machine did not name as one it
  will hibernate — a command, a job whose runner was not yet started, anything in flight; any
  step but `pausing` and `restarting` lifts it.
  """
  @spec record(String.t(), term()) :: :ok
  def record(worker_id, payload) do
    received = System.os_time(:millisecond)
    state = payload |> WorkerUpdate.normalise() |> clean() |> by_our_clock(received)

    case Workers.get(worker_id) do
      %Worker{status: status} = worker when status != :destroyed ->
        {:ok, _worker} = Workers.update(worker, row(state, DateTime.utc_now()))

        if state["step"] == "pausing" and is_list(state["jobs"]),
          do: requeue_unnamed(worker, state)

      _gone ->
        :ok
    end

    :ok
  end

  # **A time the machine named is dated by this platform's clock**, from how far ahead of its own
  # `at` it was: a machine whose clock is wrong would otherwise tell its owner a retry is at a time
  # that has no meaning here. `at` itself is not kept.
  defp by_our_clock(%{"at" => at} = state, received) do
    state = Map.delete(state, "at")

    case state do
      %{"next_at" => next_at} -> %{state | "next_at" => received + ahead(next_at - at)}
      _none -> state
    end
  end

  defp by_our_clock(state, _received), do: Map.delete(state, "next_at")

  # No retry is further off than the longest gap between tries, so a day is generous; a number
  # that would put the time past the year 9999 is not a time, so it is brought back to that day.
  @day_ms 86_400_000
  defp ahead(ms), do: ms |> max(0) |> min(@day_ms)

  # What a machine says at its join, which is its state as it was when the join was made: written
  # over what the row had, so a machine whose worker restarted mid-update stops reading as under
  # way, and the platform stops holding work back from it.
  @doc false
  @spec joined(Worker.t(), term()) :: Worker.t()
  def joined(%Worker{} = worker, payload) do
    state =
      payload
      |> WorkerUpdate.normalise()
      |> clean()
      |> by_our_clock(System.os_time(:millisecond))

    {:ok, worker} = Workers.update(worker, row(state, DateTime.utc_now()))
    worker
  end

  defp row(state, now) do
    paused? = state["step"] in ["pausing", "restarting"]

    %{
      update_state: empty_to_nil(state),
      update_reported_at: DateTime.truncate(now, :second),
      updating_at: if(paused?, do: now)
    }
  end

  defp empty_to_nil(state) when map_size(state) == 0, do: nil
  defp empty_to_nil(state), do: state

  defp requeue_unnamed(worker, state) do
    named = MapSet.new(state["jobs"] ++ Map.get(state, "chats", []))

    for job <- Jobs.running_on(worker.id), not MapSet.member?(named, job.id) do
      Jobs.requeue(job.id, :worker_updating)
    end

    :ok
  end

  # Every string a machine sent, as a column can keep it: no NUL, which a jsonb string cannot hold.
  defp clean(%{} = map), do: Map.new(map, fn {key, value} -> {key, clean(value)} end)
  defp clean(list) when is_list(list), do: Enum.flat_map(list, &List.wrap(clean(&1)))
  defp clean(text) when is_binary(text), do: Log.clean(text, 500)
  defp clean(other), do: other

  @doc """
  Records a disk report: kept on the row with its age, and drawn while the machine is away. A
  report with nothing usable in it is ignored, and the last good one stands.
  """
  @spec record_disk(String.t(), term()) :: :ok
  def record_disk(worker_id, payload) do
    received = System.os_time(:millisecond)

    case payload |> WorkerUpdate.normalise_disk() |> by_our_clock_disk(received) do
      report when map_size(report) == 0 ->
        :ok

      report ->
        {_count, _rows} =
          Repo.update_all(
            from(w in Worker, where: w.id == ^worker_id and w.status != :destroyed),
            set: [disk_report: report, disk_reported_at: DateTime.utc_now(:second)]
          )

        :ok
    end
  end

  # The machine's times are its own clock's; every time kept is this platform's, from how long
  # before the report each cleanup was — which is the difference of two readings of one clock.
  defp by_our_clock_disk(%{"at" => at, "cleanups" => cleanups} = report, received) do
    cleanups =
      Map.new(cleanups, fn {rule, %{"at" => ran} = record} ->
        {rule, %{record | "at" => received - max(at - ran, 0)}}
      end)

    %{report | "at" => received, "cleanups" => cleanups}
  end

  defp by_our_clock_disk(%{"cleanups" => _cleanups} = report, _received),
    do: Map.put(report, "cleanups", %{})

  defp by_our_clock_disk(report, _received), do: report

  # -- what the owner does ----------------------------------------------------------------------

  @doc """
  The owner's switch. **Read scoped to the caller first**; a machine the platform made has none.
  Writes a line to the machine's log naming the owner, and tells a connected machine at once: the
  target when it is turned on and the build differs, nothing when it is turned off. A machine that
  is away learns it at its next join.
  """
  @spec set_automatic(User.t(), String.t() | nil, boolean()) ::
          {:ok, Worker.t()} | {:error, :not_found}
  def set_automatic(%User{} = user, id, on) when is_boolean(on) do
    case mine(user, id) do
      nil ->
        {:error, :not_found}

      worker ->
        {:ok, worker} = Workers.update(worker, %{auto_update: on})

        Log.record(
          worker.id,
          "update.switch",
          :info,
          "#{user.email} turned automatic updates #{if on, do: "on", else: "off"}"
        )

        Workers.push(worker.id, {:update, %{"target" => target(worker), "requested_by" => nil}})
        {:ok, worker}
    end
  end

  @doc """
  *Update now*. **Read scoped to the caller first**, then only for a connected machine that
  `update_now?/2` allows; the target is sent with the owner's name, which the machine puts in its
  log. No request is kept for a machine that is away.
  """
  @spec update_now(User.t(), String.t() | nil) ::
          {:ok, Worker.t()} | {:error, :not_found | :not_connected | :nothing_to_do}
  def update_now(%User{} = user, id) do
    case mine(user, id) do
      nil ->
        {:error, :not_found}

      worker ->
        connected? = Workers.connected?(worker.id)

        cond do
          not connected? ->
            {:error, :not_connected}

          not update_now?(worker, true) ->
            {:error, :nothing_to_do}

          true ->
            :ok =
              Workers.push(
                worker.id,
                {:update, %{"target" => wanted(worker), "requested_by" => user.email}}
              )

            {:ok, worker}
        end
    end
  end

  # The caller's own permanent machine that still exists, or nil: another person's, a managed one
  # and a destroyed one are all the same answer.
  defp mine(user, id) do
    case Workers.owned(user, id) do
      %Worker{status: status} = worker when status != :destroyed ->
        if permanent?(worker), do: worker

      _none ->
        nil
    end
  end
end
