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

    {:ok,
     socket
     |> assign(page_title: "Workers", show_destroyed: false, editing: nil, error: nil)
     |> load()}
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
          remaining_memory: Workers.remaining(worker),
          remaining_cores: Workers.remaining_cores(worker)
        }
      end

    assign(socket,
      rows: rows,
      live_count: Enum.count(rows, &(&1.worker.status != :destroyed)),
      connected_count: Enum.count(rows, & &1.connected),
      slice_bytes: Workers.slice_bytes(),
      now: DateTime.utc_now()
    )
  end

  # Blank is refused rather than read as nothing: this form is how an operator *sets* what a
  # machine offers, and an empty memory field would silently un-gate the machine it was meant
  # to correct. The same sizes the grammar takes, so `8GiB` works here too.
  defp offered_attrs(params) do
    with {:ok, memory} <- ForgeCore.Workflow.Resources.parse_bytes(params["memory"] || ""),
         {cores, _rest} <- Integer.parse(params["cores"] || "") do
      {:ok, %{memory_budget: memory, cores: cores, accepts: ticked(params)}}
    else
      _other -> {:error, %Ecto.Changeset{}}
    end
  end

  # Nothing ticked is nil, which every reader treats as "takes anything" — the same reading a
  # machine that reported no kinds gets.
  defp ticked(params) do
    case Enum.filter(Forge.Jobs.Job.kinds(), &(params["accepts_#{&1}"] == "true")) do
      [] -> nil
      kinds -> kinds
    end
  end

  # A machine that has never said how many cores it has is not gated on them, so showing a
  # figure here would invent one (`docs/design/provisioning.md` § What a worker offers).
  defp cores(nil, _remaining), do: "cores not reported"
  defp cores(total, remaining), do: "#{remaining} of #{total} cores free"

  @doc """
  What the machine last said about itself, when it differs from what the row says it is.

  The row governs the gate, so a machine reporting less than its row is one the platform will
  overcommit — and the per-job ceiling cannot catch that, because what breaks is the *sum*
  (`docs/design/provisioning.md` § What a worker offers). Nil when they agree, which is the
  case nobody needs told about.
  """
  @spec mismatch(Forge.Workers.Worker.t()) :: String.t() | nil
  def mismatch(%{reported: nil}), do: nil

  def mismatch(worker) do
    [
      difference("memory", worker.reported["memory_budget"], worker.memory_budget, &gib/1),
      difference("cores", worker.reported["cores"], worker.cores, &to_string/1)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, ", ")
    end
  end

  defp difference(_label, same, same, _format), do: nil
  defp difference(_label, nil, _row, _format), do: nil
  defp difference(label, reported, _row, format), do: "#{label} #{format.(reported)}"

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    {:noreply, assign(socket, editing: id, error: nil)}
  end

  def handle_event("cancel-edit", _params, socket) do
    {:noreply, assign(socket, editing: nil, error: nil)}
  end

  @doc """
  Sets what a permanent machine offers.

  **Only a machine the platform did not make.** A managed worker was given its figures by the
  template that made it and will be replaced rather than corrected, so editing one would be an
  edit with a lifetime of one idle period. A permanent machine is the operator's, and the row
  governing the gate (`docs/design/provisioning.md` § What a worker offers) is what makes the
  edit survive the next `ready`.

  The id comes off the wire, so the row is fetched and checked here rather than trusted —
  `docs/design/identity.md` § Sequencing records that a `handle_event` holding a
  client-supplied id is the shape these holes keep taking.
  """
  def handle_event("save", %{"worker_id" => id} = params, socket) do
    with %Forge.Workers.Worker{managed: false} = worker <- Workers.get(id),
         {:ok, attrs} <- offered_attrs(params),
         {:ok, _worker} <- Workers.update(worker, attrs) do
      {:noreply, socket |> assign(editing: nil, error: nil) |> load()}
    else
      %Forge.Workers.Worker{} ->
        {:noreply, assign(socket, error: "a machine the platform made is replaced, not edited")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, assign(socket, error: "those are not figures a machine can have")}

      _other ->
        {:noreply, assign(socket, error: "that machine is not here")}
    end
  end

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
        <%!-- No node-wide ceiling any more: every machine comes from a template and every
              ceiling is that template's, beside its price where the money is
              (`provisioning.md` § Whose account). A number here would be one nothing
              enforces. --%>
        <span class="font-mono text-[12.5px] opacity-60">
          {@live_count} live · {@connected_count} connected
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
        A job is scheduled against what it asked for, in memory and in cores, and against the
        kinds a machine says it takes. A job that declares nothing gets {gib(@slice_bytes)}.
        <.link navigate={~p"/templates"} class="text-primary hover:underline">
          Templates ›
        </.link>
      </p>

      <p :if={@error} class="mt-4 text-sm text-error">{@error}</p>

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
              <th class="py-2 pr-3 font-normal">Harness</th>
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

              <%!-- Two dimensions, because the gate has two. This used to be a count of
                    identical slices, which stopped being true the moment a job could declare
                    what it needs — see docs/design/ui.md § The workers page. --%>
              <td class="py-3 pr-3 font-mono">
                <div>{gib(row.remaining_memory)} of {gib(row.worker.memory_budget)} free</div>
                <div class="text-[11px] opacity-50">
                  {cores(row.worker.cores, row.remaining_cores)}
                </div>
                <div :if={row.worker.accepts} class="text-[11px] opacity-50">
                  takes {Enum.map_join(row.worker.accepts, ", ", &to_string/1)}
                </div>
                <%!-- What the machine said, when it disagrees with what the row says it is. The
                      row governs and an operator's edit survives a reconnect, so a difference is
                      shown rather than silently resolved. --%>
                <div :if={mismatch(row.worker)} class="text-[11px] text-error">
                  reports {mismatch(row.worker)}
                </div>

                <%!-- Why this row never became a machine. Until it was drawn, a driver refusing
                      to create was invisible on every surface the operator has: the scheduler
                      reads every error as "not right now" and tries again. --%>
                <div :if={row.worker.last_error} class="text-[11px] text-error">
                  never made: {row.worker.last_error}
                </div>

                <%!-- The one decision this page carries, and only for a machine the platform did
                      not make: a permanent worker's figures are the operator's to set, and the
                      row governing the gate is what makes that edit stick across a reconnect.
                      § The affordance rule — an editable field on the one page that has never
                      had one must look editable, so it is a form and not a hover. --%>
                <.link
                  :if={not row.worker.managed and @editing != row.worker.id}
                  phx-click="edit"
                  phx-value-id={row.worker.id}
                  class="mt-1 inline-flex min-h-[46px] items-center text-[11px] text-primary hover:underline"
                >
                  Set what it offers
                </.link>

                <.form
                  :if={@editing == row.worker.id}
                  for={to_form(%{}, as: :worker)}
                  phx-submit="save"
                  class="mt-2 flex flex-col gap-2"
                >
                  <input type="hidden" name="worker_id" value={row.worker.id} />
                  <input
                    type="text"
                    name="memory"
                    value={row.worker.memory_budget}
                    aria-label="Memory budget in bytes, or a size like 8GiB"
                    class="h-[40px] w-[10rem] rounded-field border border-base-300 bg-base-100 px-2"
                  />
                  <input
                    type="number"
                    name="cores"
                    value={row.worker.cores}
                    aria-label="Cores"
                    class="h-[40px] w-[6rem] rounded-field border border-base-300 bg-base-100 px-2"
                  />
                  <label :for={kind <- Forge.Jobs.Job.kinds()} class="flex items-center gap-2">
                    <input
                      type="checkbox"
                      name={"accepts_#{kind}"}
                      value="true"
                      checked={row.worker.accepts && kind in row.worker.accepts}
                    />
                    {kind}
                  </label>
                  <div class="flex items-center gap-3">
                    <button type="submit" class="min-h-[40px] text-primary hover:underline">
                      Save
                    </button>
                    <button
                      type="button"
                      phx-click="cancel-edit"
                      class="min-h-[40px] opacity-60 hover:opacity-100"
                    >
                      Cancel
                    </button>
                  </div>
                </.form>
              </td>

              <%!-- What the machine said at `ready`, not what the platform assumes. A worker that
                    joined before it reported this, or whose probe could not reach anything, shows
                    a dash and still takes work — see docs/design/worker-channel.md § What a
                    worker offers. The login line appears only when it is a problem, because a
                    machine that is logged in is the case nobody needs told about. --%>
              <td class="py-3 pr-3 font-mono">
                <span :if={is_nil(row.worker.harness)} class="opacity-40">—</span>
                <div :if={row.worker.harness}>
                  {row.worker.harness["name"] || row.worker.harness["driver"]}
                  <span class="opacity-50">{row.worker.harness["version"]}</span>
                </div>
                <div :if={row.worker.harness} class="text-[11px] opacity-50">
                  {length(row.worker.harness["models"] || [])} models
                </div>
                <div
                  :if={row.worker.harness && row.worker.harness["login"] not in [nil, "ok"]}
                  class="text-[11px] text-error"
                >
                  login {row.worker.harness["login"]}
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
