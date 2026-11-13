defmodule ForgeWeb.WorkerLive do
  @moduledoc """
  One machine, looked at alone: its header line and its log, newest first
  (`docs/design/worker-log.md` § The page). What the platform saw happen to it and what the machine
  said about itself, in one list told apart on every line — the answer to "what was this machine
  doing, and why did it go away?" that nothing else the operator has could give.

  **Only the owner's.** The id is off the wire and the row is read scoped to the viewer, so
  somebody else's machine is not here exactly as a missing one is not
  (`docs/design/identity.md` § Sequencing). A destroyed machine's log is still here: that is when
  it is read.

  Drawn as `12g`: the machine's short id as the title, how it stands and where it comes from as
  the subline, its identifiers, and the log as two-line entries, a job id linking to its job page
  where the viewer may open that.
  """

  use ForgeWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Forge.Jobs.Job
  alias Forge.Projects
  alias Forge.Workers
  alias Forge.Workers.Log
  alias ForgeWeb.WorkersLive

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    worker =
      Workers.owned(socket.assigns.current_scope.user, id) ||
        raise Ecto.NoResultsError, queryable: Workers.Worker

    # The workers page's timer: connection is read from a registry and the log from a table, and
    # neither is pushed at this page. A readout, and nothing here waits on a human.
    if connected?(socket), do: :timer.send_interval(WorkersLive.refresh_ms(), self(), :refresh)

    {:ok,
     socket
     |> assign(page_title: "Machine #{short(worker.id)}", worker_id: worker.id)
     |> load()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    id = socket.assigns.worker_id
    worker = Workers.get!(id)
    lines = Log.for_worker(id)

    assign(socket,
      worker: worker,
      connected: Workers.connected?(id),
      lines: lines,
      jobs: job_paths(socket.assigns.current_scope.user, lines),
      serves: WorkersLive.serving(worker),
      current_build: Workers.current_build(),
      now: DateTime.utc_now()
    )
  end

  # Where each job a line names may be opened, for this viewer: its job page, or its chat's —
  # **only in a project the viewer is in**. The machine is the owner's, but the work it ran was
  # some project's, and a project a person is not in is not one they may learn exists
  # (`docs/design/identity.md` § Workers); such a job is its short id and no link. One query for
  # the whole log, re-read with it.
  defp job_paths(user, lines) do
    ids = lines |> Enum.map(& &1.job_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    member_of = MapSet.new(Projects.list(user), & &1.id)

    from(j in Job, where: j.id in ^ids, preload: [:ticket, :project])
    |> Forge.Repo.all()
    |> Enum.filter(&MapSet.member?(member_of, &1.project_id))
    |> Map.new(&{&1.id, job_path(&1)})
  end

  defp job_path(%{kind: :chat, id: id}), do: ~p"/chats/#{id}"

  defp job_path(%{ticket: %{number: number}, project: %{name: name}, id: id}),
    do: ~p"/tickets/#{name}/#{number}/jobs/#{id}"

  defp job_path(_job), do: nil

  defp at(at), do: Calendar.strftime(at, "%Y-%m-%d")
  defp time(at), do: Calendar.strftime(at, "%H:%M:%S")

  defp short(id), do: String.slice(id, 0, 8)

  # Where a line came from, in the operator's words: the platform saw it, or the machine said it.
  defp source(:platform), do: "platform"
  defp source(:worker), do: "machine"

  # The subline (`12g`): how the machine stands — for a destroyed one, how long ago — and where
  # it comes from, as its row on /workers says it.
  defp subline(%{worker: %{status: :destroyed} = worker, serves: serves, now: now}),
    do: WorkersLive.destroyed(worker, now) <> " · " <> WorkersLive.where_from(serves)

  defp subline(%{worker: worker, serves: serves}),
    do: "#{worker.status} · " <> WorkersLive.where_from(serves)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      section="Machines"
      flash={@flash}
      current_scope={@current_scope}
      frame={@frame}
      capacity={@capacity}
      title={short(@worker.id)}
      subline={subline(assigns)}
      context={{"Machines", ~p"/workers"}}
      measure="52rem"
    >
      <header
        id="machine"
        class={["machine-header", @worker.status == :destroyed && "machine--gone"]}
      >
        <WorkersLive.identity worker={@worker} connected={@connected} current_build={@current_build} />
      </header>

      <div class="machine-log-head">
        <.eyebrow>Log</.eyebrow>
        <span class="machine-log-zone">UTC</span>
      </div>

      <p class="machine-log-note">
        What the platform saw happen to this machine, and what the machine said about itself,
        newest first. What an agent did inside a job is on that job's page.
      </p>

      <p :if={@lines == []} class="machine-log-note">Nothing has been written yet.</p>

      <%!-- Two lines an entry (`12g`): when, from whom and what kind above, the message under it.
            An error keeps the danger colour across the whole entry. --%>
      <ol :if={@lines != []} id="log" class="machine-log">
        <li
          :for={line <- @lines}
          id={"line-#{line.id}"}
          class={["machine-log-entry", line.level == :error && "text-danger"]}
        >
          <div class="machine-log-top">
            <span class="machine-log-day">{at(line.at)}</span>
            <span>{time(line.at)}</span>
            <span class="machine-log-source">{source(line.source)}</span>
            <span class="machine-log-type">{line.type}</span>
          </div>
          <div class="machine-log-message">
            {line.message}
            <.link
              :if={line.job_id && @jobs[line.job_id]}
              navigate={@jobs[line.job_id]}
              class="machine-log-job"
            >
              job {short(line.job_id)}
            </.link>
            <span :if={line.job_id && !@jobs[line.job_id]} class="machine-log-job">
              job {short(line.job_id)}
            </span>
          </div>
        </li>
      </ol>
    </Layouts.app>
    """
  end
end
