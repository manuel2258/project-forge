defmodule ForgeWeb.WorkersLive do
  @moduledoc """
  The machines that host jobs: what the database records, and what is actually connected.

  This page exists for one thing the CLI cannot do. Whether a worker is connected lives in a
  registry inside the running platform, so `mix forge.worker.list` — a different node — has no
  column for it. A LiveView runs inside the platform and can simply ask.

  **It shows the caller's own machines and nobody else's.** A machine has an owner, and a row names
  the projects it serves — a project a person is not in is not one they may learn exists
  (`docs/design/identity.md` § Workers). A node admin sees their own too: the flag governs
  accounts and grants no room.

  The two facts are kept apart on purpose. `status` is what was last written down; **connected**
  is whether a channel is held right now. A `ready` row that is not connected is a machine that
  looks healthy on every other surface and cannot take work, which is the state worth seeing.

  **One block per machine, not a table**, so the page works on a phone: a header line, three
  meters read from the machine's own live figures, and two columns that stack. And a third
  decision beside the two it had: ending the machine, which is its owner's. See
  `docs/design/ui.md` § The workers page.
  """

  use ForgeWeb, :live_view

  import ForgeCore.Workflow.Resources, only: [gib: 1]

  alias Forge.{Jobs, Projects, Provisioning, Workers}
  alias ForgeCore.WorkerProtocol
  alias ForgeWeb.Format

  # Connection and the live figures are read from a registry rather than pushed at us, so the
  # page asks again on a timer — the same five seconds a worker reports its figures on
  # (`docs/design/worker-channel.md` § Live figures). This is a readout, and nothing here is
  # waiting on a human.
  @doc """
  How often the workers pages read the registry and the table again: five seconds, the interval a
  worker reports its figures on. `ForgeWeb.WorkerLive` asks here, so a machine's log is re-read on
  the same timer as its block. `page_refresh_ms` in `Forge.Workers`' config exists only so a test
  can watch the timer fire without waiting five seconds for it.
  """
  @spec refresh_ms() :: pos_integer()
  def refresh_ms, do: Workers.config(:page_refresh_ms, :timer.seconds(5))

  @impl true
  def mount(_params, _session, socket) do
    # No event subscription: a worker's connection is not a ticket event, and reloading this
    # readout on every ticket in the system would spend far more than the timer it already has.
    if connected?(socket), do: :timer.send_interval(refresh_ms(), self(), :refresh)

    {:ok,
     socket
     |> assign(page_title: "Workers", show_destroyed: false, editing: nil, error: nil)
     |> load()}
  end

  defp load(socket) do
    user = socket.assigns.current_scope.user

    now = DateTime.utc_now()

    rows =
      for worker <- Workers.list(user),
          socket.assigns.show_destroyed or worker.status != :destroyed do
        jobs = Jobs.running_on(worker.id)
        connected = Workers.connected?(worker.id)

        %{
          worker: worker,
          connected: connected,
          # The machine's own last report, which lives and dies with its channel: a machine
          # that is not connected has none, rather than figures from before it went — the
          # registry drops the value with the process, so nothing here has to ask twice.
          stats: Workers.stats(worker.id),
          jobs: jobs,
          remaining_memory: Workers.remaining(worker),
          remaining_cores: Workers.remaining_cores(worker),
          # When the idle sweep will take it, from the function the sweep asks: on a provider
          # that bills by the hour that is a leeway point of an hour it has paid for, and a
          # machine idle for longer than its period would otherwise read as one the sweep had
          # forgotten.
          goes_at: Workers.goes_at(worker, now),
          serves: serving_projects(worker)
        }
      end

    assign(socket,
      rows: rows,
      projects: Projects.list(user),
      live_count: Enum.count(rows, &(&1.worker.status != :destroyed)),
      connected_count: Enum.count(rows, & &1.connected),
      slice_bytes: Workers.slice_bytes(),
      current_build: Workers.current_build(),
      now: now
    )
  end

  # The same sizes the grammar takes, so `8GiB` works here too. What does not parse is nil, and
  # `Workers.set_offer/3` refuses a blank figure rather than reading it as nothing: this form is
  # how an operator *sets* what a machine offers, and an empty memory field would silently
  # un-gate the machine it was meant to correct.
  defp offered_attrs(params) do
    memory =
      case ForgeCore.Workflow.Resources.parse_bytes(params["memory"] || "") do
        {:ok, memory} -> memory
        _other -> nil
      end

    cores =
      case Integer.parse(params["cores"] || "") do
        {cores, _rest} -> cores
        :error -> nil
      end

    %{memory_budget: memory, cores: cores, accepts: ticked(params)}
  end

  # Nothing ticked is nil, which every reader treats as "takes anything" — the same reading a
  # machine that reported no kinds gets.
  defp ticked(params) do
    case Enum.filter(Forge.Jobs.Job.kinds(), &(params["accepts_#{&1}"] == "true")) do
      [] -> nil
      kinds -> kinds
    end
  end

  # `Format.until/2` says `now` for anything less than a minute off, the moment already here
  # included, which reads as "goes now" rather than "goes in now".
  defp goes(at, now) do
    case Format.until(at, now) do
      "now" -> "goes now"
      left -> "goes in #{left}"
    end
  end

  # What a row says about which projects the machine serves. A permanent machine lists its own
  # assignments; one the platform made serves through its template, which is where the operator
  # would go to change it, so that is what it names.
  defp serving_projects(%{managed: false} = worker), do: {:direct, Workers.projects(worker)}

  defp serving_projects(%{template_id: nil}), do: {:template, nil, []}

  defp serving_projects(%{template_id: template_id}) do
    case Forge.Repo.get(Provisioning.Template, template_id) do
      nil -> {:template, nil, []}
      template -> {:template, template.name, Provisioning.for_projects(template)}
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

  **Only the owner's, and only a machine the platform did not make** — both decided by
  `Workers.set_offer/3`, which reads the row scoped to the caller. The id comes off the wire, and
  `docs/design/identity.md` § Sequencing records that a `handle_event` holding a client-supplied
  id is the shape these holes keep taking.
  """
  def handle_event("save", %{"worker_id" => id} = params, socket) do
    case Workers.set_offer(socket.assigns.current_scope.user, id, offered_attrs(params)) do
      {:ok, _worker} ->
        {:noreply, socket |> assign(editing: nil, error: nil) |> load()}

      {:error, :made_by_the_platform} ->
        {:noreply, assign(socket, error: "a machine the platform made is replaced, not edited")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, assign(socket, error: "those are not figures a machine can have")}

      {:error, :not_found} ->
        {:noreply, assign(socket, error: "that machine is not here")}
    end
  end

  # Both reach a project, and both are refused unless the caller owns the machine *and* is a
  # member of the project — `Workers.assign/3` reads both from the database, whatever ids arrive.
  def handle_event("assign", %{"worker" => id, "project" => project_id}, socket) do
    case Workers.assign(socket.assigns.current_scope.user, id, project_id) do
      {:ok, _assignment} -> {:noreply, socket |> assign(error: nil) |> load()}
      {:error, :not_a_member} -> {:noreply, assign(socket, error: "you are not in that project")}
      {:error, _reason} -> {:noreply, assign(socket, error: "could not assign it")}
    end
  end

  def handle_event("unassign", %{"worker" => id, "project" => project_id}, socket) do
    Workers.unassign(socket.assigns.current_scope.user, id, project_id)
    {:noreply, socket |> assign(error: nil) |> load()}
  end

  # **The third decision, and the owner's**: *Destroy machine* on a managed row, *Retire* on a
  # permanent one. The id is off the wire, so `Workers.retire_by_owner/2` reads the row scoped to
  # the caller before anything happens — another person's machine is not here, as for the other
  # two. Never with force: a refusal keeps the row with the driver's words, and the way out that
  # records a claim about the provider's console is the host's (`docs/design/provisioning.md`
  # § Whose account).
  def handle_event("destroy", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    case Workers.retire_by_owner(user, id) do
      {:ok, jobs} ->
        {:noreply, socket |> assign(error: nil) |> put_flash(:info, ended(id, jobs)) |> load()}

      {:error, :not_found} ->
        {:noreply, assign(socket, error: "that machine is not here")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(error: nil)
         |> put_flash(:error, refused(Workers.owned(user, id)))
         |> load()}
    end
  end

  def handle_event("toggle-destroyed", _params, socket) do
    {:noreply, socket |> update(:show_destroyed, &(not &1)) |> load()}
  end

  defp ended(id, jobs), do: "#{String.slice(id, 0, 8)} is gone; #{requeued(length(jobs))}."

  # The driver's words are on the row, where the sweeps leave them too.
  defp refused(worker) do
    "The provider did not destroy #{String.slice(worker.id, 0, 8)}: #{worker.last_error}. " <>
      "The row stays, so the machine is still counted. If you have looked at the provider and " <>
      "the machine is gone, retire it on the host with " <>
      "mix forge.worker.retire #{worker.id} --force."
  end

  @doc """
  What destroying a managed machine asks before it happens. One definition, so the sentence the
  confirm shows cannot drift from what the button does (`docs/design/ui.md` § The workers page).
  """
  @spec destroy_confirm(non_neg_integer()) :: String.t()
  def destroy_confirm(jobs),
    do: "Destroy this machine? It is deleted at the provider, and #{requeued(jobs)}."

  @doc "What retiring a permanent machine asks before it happens. One definition, as above."
  @spec retire_confirm(non_neg_integer()) :: String.t()
  def retire_confirm(jobs) do
    "Retire this machine? forge forgets it, the machine itself keeps running, and " <>
      "#{requeued(jobs)}."
  end

  defp requeued(0), do: "nothing is running on it to requeue"
  defp requeued(1), do: "its 1 running job is requeued"
  defp requeued(jobs), do: "its #{jobs} running jobs are requeued"

  @doc """
  Why the platform turned this machine away at its last join, or nil when it did not
  (`docs/design/worker-channel.md` § Versions).

  Drawn from the protocol the row recorded and the range this platform accepts **now**, so it
  cannot say something the machine's next join would not: a platform upgraded to accept it stops
  saying so the moment it is.
  """
  @spec refusal(Forge.Workers.Worker.t()) :: String.t() | nil
  def refusal(%{protocol: protocol}) when is_integer(protocol) do
    unless WorkerProtocol.compatible?(protocol),
      do:
        "refused: protocol #{protocol}, this platform accepts #{WorkerProtocol.range()} — update it"
  end

  def refusal(_worker), do: nil

  # A share of a whole, as a whole percent, or nil when either figure is missing — never zero
  # standing in for one that could not be read.
  defp percent(used, total)
       when is_number(used) and is_number(total) and total > 0,
       do: min(round(used * 100 / total), 100)

  defp percent(_used, _total), do: nil

  # **A full disk fails jobs rather than slowing them**, so it is said in words as well as drawn.
  @full_disk 95

  attr :label, :string, required: true
  attr :percent, :any, required: true
  attr :detail, :string, default: nil

  # One meter: a mono figure over a thin bar. **Neutral, never accent** — a full machine is not
  # waiting on a human, and the one loud colour is kept for what is (`docs/design/ui.md`
  # § Colour). A figure the machine could not read has no bar at all rather than an empty one,
  # which would say nothing is used.
  defp meter(assigns) do
    ~H"""
    <div class="min-w-0">
      <div class="flex items-baseline justify-between gap-2 font-mono text-[12.5px]">
        <span class="opacity-60">{@label}</span>
        <span>{if @percent, do: "#{@percent}%", else: "—"}</span>
      </div>
      <div :if={@percent} class="mt-1 h-[3px] w-full bg-base-300/60">
        <div class="h-full bg-base-content/50" style={"width: #{@percent}%"}></div>
      </div>
      <div :if={@detail} class="mt-1 font-mono text-[11px] opacity-50">{@detail}</div>
    </div>
    """
  end

  attr :row, :map, required: true

  # CPU, RAM and disk from the machine's last report, re-read on the page's refresh. A connected
  # machine that has sent none is running a release from before the figures existed; one that is
  # not connected draws nothing, because its last figures would be a guess about now.
  defp meters(%{row: %{connected: false}} = assigns), do: ~H""

  # **Which of the two a machine with no figures is, its join says.** A release that speaks a
  # protocol sends them from its first tick, seconds after joining, so it has none *yet*; one
  # that speaks none predates them, and only an update gives it any.
  defp meters(%{row: %{stats: nil, worker: %{protocol: protocol}}} = assigns)
       when protocol in [nil, 0] do
    ~H"""
    <p class="mt-3 text-sm opacity-60">no stats — update it</p>
    """
  end

  defp meters(%{row: %{stats: nil}} = assigns) do
    ~H"""
    <p class="mt-3 text-sm opacity-60">no stats yet</p>
    """
  end

  defp meters(%{row: %{stats: stats, worker: worker}} = assigns) do
    disk = percent(stats[:disk_used], stats[:disk_total])

    assigns =
      assign(assigns,
        stats: stats,
        cpu: stats[:cpu] && round(stats[:cpu]),
        memory: percent(stats[:memory_used], stats[:memory_total]),
        disk: disk,
        full: disk != nil and disk >= @full_disk,
        cores: worker.cores
      )

    ~H"""
    <div class="mt-3 grid gap-3 sm:grid-cols-3">
      <.meter label="cpu" percent={@cpu} detail={@cores && "of #{@cores} cores"} />
      <.meter
        label="ram"
        percent={@memory}
        detail={@memory && "#{gib(@stats[:memory_used])} of #{gib(@stats[:memory_total])}"}
      />
      <.meter
        label="disk"
        percent={@disk}
        detail={@disk && "#{gib(@stats[:disk_used])} of #{gib(@stats[:disk_total])}"}
      />
    </div>
    <p :if={@full} class="mt-2 text-sm text-error">
      disk nearly full — a job that needs to write fails when it is
    </p>
    """
  end

  attr :row, :map, required: true
  attr :projects, :list, required: true

  # Which projects may run their jobs on this machine. A job runs only on a machine assigned to
  # its project (`docs/design/identity.md` § Workers), so a permanent machine with none here takes
  # no work at all — which is the thing worth seeing on this row.
  defp serves(%{row: %{serves: {:template, name, projects}}} = assigns) do
    assigns = assign(assigns, name: name, assigned: projects)

    ~H"""
    <div class="text-[12.5px]">
      <span class="opacity-50">
        {if @name, do: "serves through template #{@name}:", else: "from a template since removed:"}
      </span>
      <span :for={project <- @assigned} class="ml-1 font-mono">{project.name}</span>
      <span :if={@assigned == []} class="ml-1 opacity-50">no project</span>
    </div>
    """
  end

  defp serves(%{row: %{serves: {:direct, projects}}} = assigns) do
    assigns = assign(assigns, assigned: projects)

    ~H"""
    <div class="flex flex-wrap items-center gap-2 text-[12.5px]">
      <span class="opacity-50">serves</span>
      <span
        :for={project <- @assigned}
        class="flex items-center gap-1 rounded-field border border-base-300 pl-2 font-mono"
      >
        {project.name}
        <button
          type="button"
          phx-click="unassign"
          phx-value-worker={@row.worker.id}
          phx-value-project={project.id}
          class="min-h-[46px] min-w-[46px] opacity-60 hover:opacity-100"
          aria-label={"Stop serving #{project.name}"}
        >
          ×
        </button>
      </span>
      <span :if={@assigned == []} class="text-error">no project, so it takes no work</span>
      <form
        :if={@row.worker.status != :destroyed and @projects != []}
        phx-submit="assign"
        class="flex items-center gap-2"
      >
        <input type="hidden" name="worker" value={@row.worker.id} />
        <select
          name="project"
          aria-label="Project"
          class="h-[46px] min-w-0 rounded-field border border-base-300 bg-base-100 px-2"
        >
          <option :for={project <- @projects} value={project.id}>{project.name}</option>
        </select>
        <button type="submit" class="min-h-[46px] text-primary hover:underline">Assign</button>
      </form>
    </div>
    """
  end

  attr :worker, :map, required: true
  attr :current_build, :string, default: nil

  # What the machine said it runs at its last join, and beside it what the platform knows: the
  # build this platform ships with. `other build` and never "older": a build is a hash with no
  # order, and a snapshot built from a newer checkout than the platform reads the same
  # (`docs/design/ui.md` § The workers page). No hint on a node built outside Nix, which knows no
  # build, and none for a row that has not joined since the release was on the wire.
  defp release(%{worker: %{protocol: nil}} = assigns), do: ~H""

  defp release(assigns) do
    assigns =
      assign(assigns, hint: Format.build_hint(assigns.worker.build, assigns.current_build))

    ~H"""
    <span class="font-mono text-[11px] opacity-50">
      {@worker.release || "release not reported"}<span :if={@hint}> · {@hint}</span>
    </span>
    """
  end

  attr :worker, :map, required: true
  attr :connected, :boolean, required: true
  attr :current_build, :string, default: nil

  @doc """
  A machine's header line: which machine, at which provider, in what state, whether it is held
  right now, whether the platform may end it, and what it runs. The same line heads its block here
  and its log on `ForgeWeb.WorkerLive`, so the two pages name a machine alike.
  """
  def identity(assigns) do
    ~H"""
    <span class="font-mono text-[12.5px]">{String.slice(@worker.id, 0, 8)}</span>
    <span class="font-mono text-[11px] break-all opacity-50">
      {@worker.provider}{if @worker.provider_id,
        do: " · " <> String.slice(@worker.provider_id, 0, 12)}
    </span>
    <span class="font-mono text-[12.5px]">{@worker.status}</span>
    <%!-- Read from the registry, not from the row: the one fact the database does not have
          and `mix forge.worker.list` therefore cannot show. --%>
    <span class="flex items-center gap-2 font-mono text-[12.5px]">
      <span class={[
        "inline-block size-[7px] rounded-full",
        if(@connected, do: "bg-success", else: "bg-base-300")
      ]} />
      {if @connected, do: "connected", else: "not connected"}
    </span>
    <%!-- The only thing that differs between a machine the platform may destroy and one it
          may not (docs/design/worker-tier.md § Managed and unmanaged). --%>
    <span class="font-mono text-[11px] opacity-50">
      {if @worker.managed, do: "managed", else: "permanent"}
    </span>
    <.release worker={@worker} current_build={@current_build} />
    """
  end

  attr :row, :map, required: true
  attr :projects, :list, required: true
  attr :editing, :any, required: true
  attr :now, :any, required: true
  attr :current_build, :string, default: nil

  # **A machine is a block, not a table row** (`docs/design/ui.md` § The workers page): seven
  # columns never fitted a phone. Separated from the next by a row rule, with no card and no box.
  defp machine(assigns) do
    ~H"""
    <li
      id={"worker-#{@row.worker.id}"}
      class={[
        "border-t border-base-300/60 py-[15px]",
        @row.worker.status == :destroyed && "opacity-50"
      ]}
    >
      <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
        <.identity worker={@row.worker} connected={@row.connected} current_build={@current_build} />
        <span class="ml-auto flex items-center gap-5">
          <%!-- A destroyed machine's too: "why did it go away?" is asked afterwards
                (docs/design/worker-log.md). --%>
          <.link
            navigate={~p"/workers/#{@row.worker.id}"}
            class="inline-flex min-h-[46px] items-center text-sm text-primary hover:underline"
          >
            Log
          </.link>
          <button
            :if={@row.worker.status != :destroyed}
            type="button"
            phx-click="destroy"
            phx-value-id={@row.worker.id}
            data-confirm={
              if @row.worker.managed,
                do: destroy_confirm(length(@row.jobs)),
                else: retire_confirm(length(@row.jobs))
            }
            class="min-h-[46px] text-sm text-error hover:underline"
          >
            {if @row.worker.managed, do: "Destroy machine", else: "Retire"}
          </button>
        </span>
      </div>

      <p :if={refusal(@row.worker)} class="mt-2 text-sm text-error">{refusal(@row.worker)}</p>

      <.meters row={@row} />

      <div class="mt-3 grid gap-x-8 gap-y-2 text-[12.5px] sm:grid-cols-2">
        <div class="flex min-w-0 flex-col gap-1">
          <%!-- Two dimensions, because the gate has two (docs/design/ui.md § The workers
                page). --%>
          <div class="font-mono">
            {gib(@row.remaining_memory)} of {gib(@row.worker.memory_budget)} free
          </div>
          <div class="font-mono opacity-60">
            {cores(@row.worker.cores, @row.remaining_cores)}
          </div>
          <div :if={@row.worker.accepts} class="font-mono opacity-60">
            takes {Enum.map_join(@row.worker.accepts, ", ", &to_string/1)}
          </div>
          <%!-- What the machine said, when it disagrees with what the row says it is. The row
                governs and an operator's edit survives a reconnect, so a difference is shown
                rather than silently resolved. --%>
          <div :if={mismatch(@row.worker)} class="font-mono text-error">
            reports {mismatch(@row.worker)}
          </div>
          <%!-- Why this row never became a machine. Until it was drawn, a driver refusing to
                create was invisible on every surface the operator has. --%>
          <div :if={@row.worker.last_error} class="text-error [overflow-wrap:anywhere]">
            never made: {@row.worker.last_error}
          </div>

          <%!-- A permanent worker's figures are the operator's to set, and the row governing the
                gate is what makes that edit stick across a reconnect. § The affordance rule — an
                editable field must look editable, so it is a form and not a hover. --%>
          <.link
            :if={not @row.worker.managed and @editing != @row.worker.id}
            phx-click="edit"
            phx-value-id={@row.worker.id}
            class="inline-flex min-h-[46px] items-center self-start text-primary hover:underline"
          >
            Set what it offers
          </.link>

          <.form
            :if={@editing == @row.worker.id}
            for={to_form(%{}, as: :worker)}
            phx-submit="save"
            class="mt-2 flex flex-col gap-2"
          >
            <input type="hidden" name="worker_id" value={@row.worker.id} />
            <input
              type="text"
              name="memory"
              value={@row.worker.memory_budget}
              aria-label="Memory budget in bytes, or a size like 8GiB"
              class="h-[46px] w-[10rem] max-w-full rounded-field border border-base-300 bg-base-100 px-2"
            />
            <input
              type="number"
              name="cores"
              value={@row.worker.cores}
              aria-label="Cores"
              class="h-[46px] w-[6rem] rounded-field border border-base-300 bg-base-100 px-2"
            />
            <label
              :for={kind <- Forge.Jobs.Job.kinds()}
              class="flex min-h-[46px] items-center gap-2"
            >
              <input
                type="checkbox"
                name={"accepts_#{kind}"}
                value="true"
                checked={@row.worker.accepts && kind in @row.worker.accepts}
              />
              {kind}
            </label>
            <div class="flex items-center gap-3">
              <button type="submit" class="min-h-[46px] text-primary hover:underline">
                Save
              </button>
              <button
                type="button"
                phx-click="cancel-edit"
                class="min-h-[46px] opacity-60 hover:opacity-100"
              >
                Cancel
              </button>
            </div>
          </.form>
        </div>

        <div class="flex min-w-0 flex-col gap-1">
          <%!-- What the machine said at `ready`: which harness and which version. The login line
                is only drawn for a row an older release wrote. A machine that reported no harness
                takes no agent job (`docs/design/credentials.md` § What a worker offers now). --%>
          <div class="font-mono">
            <span :if={is_nil(@row.worker.harness)} class="opacity-40">no harness reported</span>
            <span :if={@row.worker.harness}>
              {@row.worker.harness["name"] || @row.worker.harness["driver"]}
              <span class="opacity-50">{@row.worker.harness["version"]}</span>
            </span>
          </div>
          <div
            :if={@row.worker.harness && @row.worker.harness["login"] not in [nil, "ok"]}
            class="font-mono text-error"
          >
            login {@row.worker.harness["login"]}
          </div>
          <%!-- A release that does not take the job's credential from the assignment is given no
                inference job at all (`Workers.runs?/2`), so a machine that looks healthy
                everywhere else takes no work — which is the thing to say. --%>
          <div
            :if={@row.worker.status != :destroyed and not Workers.runs?(@row.worker, "claude_code")}
            class="text-error"
          >
            takes no agent job: its release predates per-job credentials; update it
          </div>

          <div class="font-mono">
            <span :for={job <- @row.jobs} class="mr-3">{job.state} #{job.attempt}</span>
            <span :if={@row.jobs == []} class="opacity-40">running nothing</span>
          </div>

          <div class="font-mono opacity-70">
            last seen {(@row.worker.last_seen_at && Format.ago(@row.worker.last_seen_at, @now)) ||
              "never"}<span :if={@row.worker.idle_since} class="opacity-70"> · idle {Format.ago(
              @row.worker.idle_since,
              @now
            )}</span><span :if={@row.goes_at} class="opacity-70"> · {goes(@row.goes_at, @now)}</span>
          </div>

          <.serves row={@row} projects={@projects} />
        </div>
      </div>
    </li>
    """
  end

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
        <.link
          navigate={~p"/templates"}
          class="inline-flex min-h-[46px] items-center text-primary hover:underline"
        >
          Templates ›
        </.link>
      </p>

      <p :if={@error} class="mt-4 text-sm text-error">{@error}</p>

      <p :if={@rows == []} class="mt-6 text-sm opacity-60">
        You have no machines. One is created from your templates when a job needs it, or provisioned by hand with <code class="font-mono text-[12.5px]">mix forge.worker.new</code>.
      </p>

      <ul :if={@rows != []} class="mt-4">
        <.machine
          :for={row <- @rows}
          row={row}
          projects={@projects}
          editing={@editing}
          now={@now}
          current_build={@current_build}
        />
      </ul>
    </Layouts.app>
    """
  end
end
