defmodule ForgeWeb.WorkersLive do
  @moduledoc """
  The machines that host jobs: what the database records, and what is actually connected.

  This page exists for one thing the CLI cannot do. Whether a worker is connected lives in a
  registry inside the running platform, so `mix forge.worker.list` — a different node — has no
  column for it. A LiveView runs inside the platform and can simply ask.

  The two facts are kept apart on purpose. `status` is what was last written down; **connected**
  is whether a channel is held right now. A `ready` row that is not connected is a machine that
  looks healthy on every other surface and cannot take work, which is the state worth seeing.
  See `docs/design/ui.md` § The workers page.
  """

  use ForgeWeb, :live_view

  alias Forge.{Jobs, Workers}
  alias ForgeWeb.Format

  # Connection is read from a registry rather than pushed at us, so the page asks again on a
  # timer. Slower than the worker's own 20s heartbeat: this is a readout, and nothing here is
  # waiting on a human.
  @refresh :timer.seconds(5)

  @impl true
  def mount(_params, _session, socket) do
    # No event subscription: a worker's connection is not a ticket event, and reloading this
    # readout on every ticket in the system would spend far more than the timer it already has.
    if connected?(socket), do: :timer.send_interval(@refresh, self(), :refresh)

    {:ok, socket |> assign(page_title: "Workers", show_destroyed: false) |> load()}
  end

  defp load(socket) do
    rows =
      for worker <- Workers.list(),
          socket.assigns.show_destroyed or worker.status != :destroyed do
        jobs = Jobs.running_on(worker.id)

        %{
          worker: worker,
          connected: Workers.connected?(worker.id),
          jobs: jobs,
          slices: slices(worker.memory_budget)
        }
      end

    assign(socket,
      rows: rows,
      live_count: Enum.count(rows, &(&1.worker.status != :destroyed)),
      connected_count: Enum.count(rows, & &1.connected),
      max_workers: Workers.config(:max_workers, 1),
      slice_bytes: Workers.slice_bytes(),
      now: DateTime.utc_now()
    )
  end

  # How many jobs the memory gate would let this machine hold at once — the figure the scheduler
  # actually decides on, rather than the byte count it is derived from.
  defp slices(nil), do: nil
  defp slices(budget), do: div(budget, Workers.slice_bytes())

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("toggle-destroyed", _params, socket) do
    {:noreply, socket |> update(:show_destroyed, &(not &1)) |> load()}
  end

  defp gib(nil), do: "—"
  defp gib(bytes), do: :erlang.float_to_binary(bytes / 1024 / 1024 / 1024, decimals: 1) <> " GiB"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:workers} measure="74rem">
      <header class="flex flex-wrap items-baseline gap-x-4 gap-y-2">
        <h1 class="text-2xl font-semibold -tracking-[.025em]">Workers</h1>
        <span class="font-mono text-[12.5px] opacity-60">
          {@live_count} of {@max_workers} · {@connected_count} connected
        </span>
        <button
          type="button"
          phx-click="toggle-destroyed"
          class="ml-auto flex min-h-[46px] items-center text-sm text-primary hover:underline"
        >
          {if @show_destroyed, do: "Hide destroyed", else: "Show destroyed"}
        </button>
      </header>

      <p class="mt-2 text-sm/[1.55] opacity-60">
        A job is scheduled against memory, not against a count: one slice is {gib(@slice_bytes)},
        and a machine takes as many as its budget holds.
      </p>

      <p :if={@rows == []} class="mt-6 text-sm opacity-60">
        No machines. One is created when a job needs it, or provisioned by hand with <code class="font-mono text-[12.5px]">mix forge.worker.new</code>.
      </p>

      <div :if={@rows != []} class="mt-6 overflow-x-auto">
        <table class="w-full text-left text-[12.5px]">
          <thead class="font-mono text-[11px] tracking-[.14em] uppercase opacity-50">
            <tr class="border-b border-base-300">
              <th class="py-2 pr-3 font-normal">Machine</th>
              <th class="py-2 pr-3 font-normal">Status</th>
              <th class="py-2 pr-3 font-normal">Channel</th>
              <th class="py-2 pr-3 font-normal">Capacity</th>
              <th class="py-2 pr-3 font-normal">Running</th>
              <th class="py-2 font-normal">Last seen</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={row <- @rows}
              class={[
                "border-b border-base-300/60 align-top",
                row.worker.status == :destroyed && "opacity-50"
              ]}
            >
              <td class="py-3 pr-3">
                <div class="font-mono">{String.slice(row.worker.id, 0, 8)}</div>
                <div class="font-mono text-[11px] opacity-50">
                  {row.worker.provider}{if row.worker.provider_id,
                    do: " · " <> String.slice(row.worker.provider_id, 0, 12)}
                </div>
              </td>

              <td class="py-3 pr-3">
                <div class="font-mono">{row.worker.status}</div>
                <%!-- The only thing that differs between a machine the platform may destroy and
                      one it may not, and an unmanaged row holds a slot until somebody retires
                      it. See docs/design/worker-tier.md § Managed and unmanaged. --%>
                <div class="font-mono text-[11px] opacity-50">
                  {if row.worker.managed, do: "managed", else: "permanent"}
                </div>
              </td>

              <%!-- Read from the registry, not from the row: this is the one fact the database
                    does not have and `mix forge.worker.list` therefore cannot show. --%>
              <td class="py-3 pr-3">
                <span class="flex items-center gap-2 font-mono">
                  <span class={[
                    "inline-block size-[7px] rounded-full",
                    if(row.connected, do: "bg-success", else: "bg-base-300")
                  ]} />
                  {if row.connected, do: "connected", else: "not connected"}
                </span>
              </td>

              <td class="py-3 pr-3 font-mono">
                <div>{gib(row.worker.memory_budget)}</div>
                <div :if={row.slices} class="text-[11px] opacity-50">
                  {row.slices} {if row.slices == 1, do: "slice", else: "slices"}
                </div>
              </td>

              <td class="py-3 pr-3">
                <div :for={job <- row.jobs} class="font-mono">
                  {job.state} #{job.attempt}
                </div>
                <span :if={row.jobs == []} class="font-mono opacity-40">—</span>
              </td>

              <td class="py-3 font-mono opacity-70">
                {(row.worker.last_seen_at && Format.ago(row.worker.last_seen_at, @now)) || "never"}
                <div :if={row.worker.idle_since} class="text-[11px] opacity-50">
                  idle {Format.ago(row.worker.idle_since, @now)}
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end
end
