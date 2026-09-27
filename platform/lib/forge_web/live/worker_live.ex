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
  """

  use ForgeWeb, :live_view

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
     |> assign(page_title: "Worker #{short(worker.id)}", worker_id: worker.id)
     |> load()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    id = socket.assigns.worker_id

    assign(socket,
      worker: Workers.get!(id),
      connected: Workers.connected?(id),
      lines: Log.for_worker(id),
      current_build: Workers.current_build()
    )
  end

  defp at(at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S")

  defp short(id), do: String.slice(id, 0, 8)

  # Where a line came from, in the operator's words: the platform saw it, or the machine said it.
  defp source(:platform), do: "platform"
  defp source(:worker), do: "machine"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      capacity={@capacity}
      active={:workers}
      measure="74rem"
    >
      <.link
        navigate={~p"/workers"}
        class="inline-flex min-h-[46px] items-center text-sm text-primary hover:underline"
      >
        ‹ Workers
      </.link>

      <header
        id="machine"
        class={[
          "flex flex-wrap items-center gap-x-3 gap-y-1",
          @worker.status == :destroyed && "opacity-50"
        ]}
      >
        <WorkersLive.identity worker={@worker} connected={@connected} current_build={@current_build} />
      </header>

      <p class="mt-2 text-sm/[1.55] opacity-60">
        What the platform saw happen to this machine, and what the machine said about itself —
        newest first, times in UTC. What an agent did inside a job is on that job's page.
      </p>

      <p :if={@lines == []} class="mt-6 text-sm opacity-60">Nothing has been written yet.</p>

      <ol :if={@lines != []} id="log" class="mt-4">
        <li
          :for={line <- @lines}
          id={"line-#{line.id}"}
          class={[
            "grid gap-x-4 border-t border-base-300/60 py-[9px] text-[12.5px]",
            "sm:grid-cols-[10.5rem_4.5rem_9rem_minmax(0,1fr)]",
            line.level == :error && "text-error"
          ]}
        >
          <span class="font-mono opacity-60">{at(line.at)}</span>
          <span class="font-mono opacity-60">{source(line.source)}</span>
          <span class="font-mono break-all">{line.type}</span>
          <span class="[overflow-wrap:anywhere]">
            {line.message}
            <span :if={line.job_id} class="ml-1 font-mono opacity-60">job {short(line.job_id)}</span>
          </span>
        </li>
      </ol>
    </Layouts.app>
    """
  end
end
