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

  **A row leads with its connection dot and what the machine is doing, in words** (`12f`): the
  job and its ticket, the chat, or when idle destroys it. Under that head, only where it applies,
  what today's block always said — refusal, unhealthy, three meters, what it offers the gate and
  the form that sets it, the projects it serves, and ending it. On a wide screen the heads line
  up as a table (`12o`). *New machine* mints a permanent machine for the viewer and shows its
  environment once. See `docs/design/ui.md` § Machines.
  """

  use ForgeWeb, :live_view

  import ForgeCore.Workflow.Resources, only: [gib: 1]
  import ForgeWeb.Operator.Components, only: [copyable: 1, shown_once: 1]
  import ForgeWeb.ProjectAssign, only: [project_assign: 1]

  alias Forge.{Jobs, Projects, Provisioning, Workers}
  alias ForgeCore.WorkerProtocol
  alias ForgeWeb.{Format, Toast}

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
     |> assign(
       page_title: "Machines",
       show_destroyed: false,
       editing: nil,
       error: nil,
       refused: nil,
       minting: false,
       minted: nil
     )
     |> load()}
  end

  defp load(socket) do
    user = socket.assigns.current_scope.user

    now = DateTime.utc_now()

    projects = Projects.list(user)
    member_of = MapSet.new(projects, & &1.id)
    templates = Provisioning.templates(user)
    workers = Workers.list(user)

    rows =
      for worker <- workers,
          socket.assigns.show_destroyed or worker.status != :destroyed do
        jobs = worker.id |> Jobs.running_on() |> Forge.Repo.preload([:ticket, :project])
        connected = Workers.connected?(worker.id)

        %{
          worker: worker,
          connected: connected,
          # What it is doing, named for this viewer: a job's ticket only where the viewer is in
          # its project, because a project a person is not in is not one they may learn exists
          # (`docs/design/identity.md` § Workers) — and the owner of a machine need not be.
          doing: Enum.map(jobs, &work(&1, member_of, now)),
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
          serves: serving(worker)
        }
      end

    live = Enum.reject(workers, &(&1.status == :destroyed))
    made = Map.new(templates, &{&1.id, Provisioning.live_count(&1)})

    assign(socket,
      rows: rows,
      projects: projects,
      # Whether the viewer has any template of their own: with none, no machine can be made for
      # them, and the page says so with the way to make one (`ui.md` § Machines).
      has_templates: templates != [],
      live_count: length(live),
      connected_count: Enum.count(rows, & &1.connected),
      busy_count: Enum.count(live, &(&1.status == :busy)),
      idle_count: Enum.count(live, &(&1.status in [:ready, :idle])),
      # The title menu's words for a full template: one whose machines are as many as it may make,
      # so new work for its projects waits (`provisioning.md` § Whose account).
      full_count: Enum.count(templates, &(made[&1.id] >= &1.max_workers)),
      slots: slots(live, templates, made),
      # The wide screen's right column (`12o`): the viewer's templates and credentials.
      templates: templates,
      made: made,
      credentials: Provisioning.credentials(user),
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

  # Less memory than one job can run in is said as that, naming the minimum
  # (`docs/design/workflow-grammar-v1.md` § Resources); anything else a machine cannot have is one
  # sentence, as it always was.
  defp offer_error(%Ecto.Changeset{errors: errors}) do
    too_little = ForgeCore.Workflow.Resources.too_little_memory()

    case errors[:memory_budget] do
      {^too_little, _opts} -> ForgeCore.Workflow.Resources.memory_refused()
      _other -> "those are not figures a machine can have"
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

  # `Format.until/2` says `now` for anything less than a minute off, the moment already here
  # included, which reads as "goes now" rather than "goes in now".
  defp goes(at, now) do
    case Format.until(at, now) do
      "now" -> "goes now"
      left -> "goes in #{left}"
    end
  end

  @doc """
  Which projects a machine serves, and through what: `{:direct, projects}` for a permanent machine,
  which lists its own assignments, or `{:template, name, projects}` for one the platform made,
  which serves through its template — where the operator would go to change it, so that is what
  it names. `name` is nil when the template has since been removed.
  """
  @spec serving(Forge.Workers.Worker.t()) ::
          {:direct, [Forge.Projects.Project.t()]}
          | {:template, String.t() | nil, [Forge.Projects.Project.t()]}
  def serving(%{managed: false} = worker), do: {:direct, Workers.projects(worker)}

  def serving(%{template_id: nil}), do: {:template, nil, []}

  def serving(%{template_id: template_id}) do
    case Forge.Repo.get(Provisioning.Template, template_id) do
      nil -> {:template, nil, []}
      template -> {:template, template.name, Provisioning.for_projects(template)}
    end
  end

  @doc """
  `serving/1` in the words a row's head and a machine's subline use (`12f`, `12g`): the template
  and its projects, or `permanent` and its own — `hetzner-cx22 · site`, `permanent · no project`.
  """
  @spec where_from({:direct, list()} | {:template, String.t() | nil, list()}) :: String.t()
  def where_from({:direct, projects}), do: "permanent · " <> project_names(projects)

  def where_from({:template, name, projects}),
    do: (name || "from a template since removed") <> " · " <> project_names(projects)

  defp project_names([]), do: "no project"
  defp project_names(projects), do: Enum.map_join(projects, ", ", & &1.name)

  @doc """
  One running job as a machine's row says it (`docs/design/ui.md` § Machines): the step and its
  attempt, or *chat*; the ticket or the project it is for, **only when `member_of` holds that
  project**; how long it has run. A job in a project the viewer is not in is its step alone.
  """
  @spec work(Forge.Jobs.Job.t(), MapSet.t(), DateTime.t()) :: String.t()
  def work(job, member_of, now) do
    [
      if(job.kind == :chat, do: "chat", else: "#{job.state} ##{job.attempt}"),
      MapSet.member?(member_of, job.project_id) && job_place(job),
      job.started_at && Format.ago(job.started_at, now)
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp job_place(%{ticket: %{number: number}, project: %{name: name}}), do: "#{name}##{number}"
  defp job_place(%{project: %{name: name}}), do: name
  defp job_place(_job), do: nil

  @doc """
  What a machine is doing, in words, for the head of its row: its jobs, or with none, being made,
  going when its idle time is up, waiting for work, or gone.
  """
  @spec doing(map(), DateTime.t()) :: String.t()
  def doing(%{doing: [_ | _] = jobs}, _now), do: Enum.join(jobs, "; ")

  def doing(%{worker: %{status: :destroyed} = worker}, now), do: destroyed(worker, now)

  # A row the platform turned away at its join is not still being made (UX pass, D14).
  def doing(%{worker: %{status: :creating} = worker}, _now),
    do: if(refusal(worker), do: "turned away at its join", else: "being made")

  def doing(%{goes_at: %DateTime{} = at}, now), do: "#{goes(at, now)} unless work arrives"
  def doing(%{worker: %{status: :busy}}, _now), do: "busy"
  def doing(_row, _now), do: "waiting for work"

  @doc "When a destroyed machine went, as its row and its page say it: `destroyed 2h ago`."
  @spec destroyed(Forge.Workers.Worker.t(), DateTime.t()) :: String.t()
  def destroyed(worker, now) do
    "destroyed " <> Format.ago_phrase(worker.updated_at, now)
  end

  # How many of the viewer's templates name a credential, in words: `2 templates`, `1 template`.
  defp named(templates, credential_id) do
    case Enum.count(templates, &(&1.provider_credential_id == credential_id)) do
      1 -> "1 template"
      n -> "#{n} templates"
    end
  end

  # One segment per machine that exists — busy, or not — and then one per machine the viewer's
  # templates may still make, so a full fleet reads as full before any job waits. Capped, since a
  # template allowed a hundred machines would otherwise draw a hundred.
  @slots 24
  defp slots(live, templates, made) do
    free =
      templates
      |> Enum.map(&max(&1.max_workers - Map.get(made, &1.id, 0), 0))
      |> Enum.sum()

    (Enum.map(live, &if(&1.status == :busy, do: :busy, else: :up)) ++
       List.duplicate(:free, free))
    |> Enum.take(@slots)
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

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, error: offer_error(changeset))}

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
        {:noreply,
         socket |> assign(error: nil, refused: nil) |> Toast.put(ended(id, jobs)) |> load()}

      {:error, :not_found} ->
        {:noreply, assign(socket, error: "that machine is not here")}

      # Said in the row whose button was pressed, which stays.
      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(error: nil, refused: {id, refused(Workers.owned(user, id))})
         |> load()}
    end
  end

  def handle_event("new-machine", _params, socket) do
    {:noreply, assign(socket, minting: true, error: nil)}
  end

  def handle_event("cancel-new", _params, socket) do
    {:noreply, assign(socket, minting: false, error: nil)}
  end

  # Mints a permanent machine for the viewer, and holds its environment for the one time it is
  # shown. **The owner is the session's user and nothing else** — the form has no owner field, and
  # no parameter is read for one — and a project, when one is chosen, is checked by
  # `Workers.mint/2` for membership before the row exists (`docs/design/identity.md` § Minting a
  # permanent machine). The project id is the client's, and a project the viewer is not in reads
  # the same as one that is not there.
  def handle_event("mint", params, socket) do
    project_id = if params["project"] in [nil, ""], do: nil, else: params["project"]

    case Workers.mint(socket.assigns.current_scope.user, project_id) do
      {:ok, _worker, env} ->
        {:noreply, socket |> assign(minting: false, minted: env, error: nil) |> load()}

      {:error, :not_a_member} ->
        {:noreply, assign(socket, error: "you are not in that project")}

      {:error, standing} when standing in [:not_approved, :suspended] ->
        {:noreply, assign(socket, error: "your account may not own a machine")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, assign(socket, error: "could not mint a machine")}
    end
  end

  # Gone from the page once dismissed: only the token's hash is kept, so nothing can draw it again.
  def handle_event("dismiss-minted", _params, socket) do
    {:noreply, assign(socket, minted: nil)}
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

  # A machine on a release from before tokens were counted during a run takes no job of any kind
  # (`Forge.Jobs.protocol_needs/1`), whatever else about it is in order. One this platform still
  # accepts joins and sits idle, which is the thing to say.
  defp too_old?(%{status: :destroyed}), do: false

  defp too_old?(%{protocol: protocol}) when is_integer(protocol),
    do: protocol < Jobs.usage_protocol()

  defp too_old?(_worker), do: false

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

  # `last_error` holds the driver's latest refusal, to create or to destroy, and which it was is
  # whether a machine was ever made: a row with no machine id was refused at its create, and one
  # with an id is a machine the driver would not destroy, which goes on running.
  defp driver_error(%{last_error: nil}), do: nil
  defp driver_error(%{provider_id: nil, last_error: error}), do: "never made: " <> error
  defp driver_error(%{last_error: error}), do: "would not destroy: " <> error

  @doc """
  What the machine said about its systemd, and what happens next, or nil when it is well
  (`docs/design/ui.md` § The workers page; `docs/design/worker-tier.md` § A machine whose systemd
  stops answering). Nothing is placed on a machine while this is drawn, and nothing on the page
  clears it: rejoining healthy does.
  """
  @spec unhealthy(Forge.Workers.Worker.t()) :: String.t() | nil
  def unhealthy(%{status: :destroyed}), do: nil
  def unhealthy(%{unhealthy_at: nil}), do: nil

  def unhealthy(worker),
    do:
      "unhealthy since #{clock(worker.unhealthy_at)}: #{worker.unhealthy_reason} — #{next(worker)}"

  defp next(%{managed: false}),
    do:
      "not the platform's to reboot: restart it, and it takes work again when it rejoins healthy"

  # Told in this episode, which is what `Workers.unhealthy/2` answers by: a reboot at or after
  # the episode began. Compared as times — a guard's `>=` on two `DateTime`s compares the structs
  # field by field, which is not chronological.
  defp next(%{rebooted_at: %DateTime{} = at, unhealthy_at: since} = worker) do
    if DateTime.compare(at, since) == :lt,
      do: next(%{worker | rebooted_at: nil}),
      else: "told to reboot at #{clock(at)}; takes work again when it rejoins healthy"
  end

  defp next(_worker),
    do: "rebooted within the hour, so not again: destroy it, or wait for it to rejoin healthy"

  defp clock(at), do: Calendar.strftime(at, "%H:%M UTC")

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

  # One meter: a mono figure over a thin bar. **Neutral, never amber** — a full machine is not
  # waiting on a human, and the one loud colour is kept for what is (`docs/design/ui.md`
  # § Colour). A figure the machine could not read has no bar at all rather than an empty one,
  # which would say nothing is used.
  defp meter(assigns) do
    ~H"""
    <div class="machine-meter">
      <div class="machine-meter-figure">
        <span class="text-ink-3">{@label}</span>
        <span>{if @percent, do: "#{@percent}%", else: "—"}</span>
      </div>
      <div :if={@percent} class="machine-meter-track">
        <div class="machine-meter-fill" style={"width: #{@percent}%"}></div>
      </div>
      <div :if={@detail} class="machine-meter-detail">{@detail}</div>
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
    <p class="machine-line text-ink-3">no stats — update it</p>
    """
  end

  defp meters(%{row: %{stats: nil}} = assigns) do
    ~H"""
    <p class="machine-line text-ink-3">no stats yet</p>
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
    <div class="machine-meters">
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
    <p :if={@full} class="machine-line text-danger">
      disk nearly full — a job that needs to write fails when it is
    </p>
    """
  end

  attr :row, :map, required: true
  attr :projects, :list, required: true

  # Which projects may run their jobs on a permanent machine, with the control that changes them.
  # A job runs only on a machine assigned to its project (`docs/design/identity.md` § Workers), so
  # a permanent machine with none here takes no work at all — which is the thing worth seeing on
  # this row. A managed machine's are its template's, named in the head.
  defp serves(%{row: %{serves: {:template, _name, _projects}}} = assigns), do: ~H""

  defp serves(%{row: %{serves: {:direct, projects}}} = assigns) do
    assigns = assign(assigns, assigned: projects)

    ~H"""
    <.project_assign
      id={"serves-#{@row.worker.id}"}
      assigned={@assigned}
      projects={@projects}
      assign="assign"
      unassign="unassign"
      values={[{"worker", @row.worker.id}]}
      remove="Stop serving"
      label="serves"
      none="no project, so it takes no work"
      none_tone="danger"
      can_add={@row.worker.status != :destroyed}
    />
    """
  end

  attr :worker, :map, required: true
  attr :current_build, :string, default: nil

  # What the machine said it runs at its last join, and beside it what the platform knows: the
  # build this platform ships with. `other build` and never "older": a build is a hash with no
  # order, and a snapshot built from a newer checkout than the platform reads the same
  # (`docs/design/ui.md` § Machines). No hint on a node built outside Nix, which knows no build,
  # and none for a row that has not joined since the release was on the wire.
  defp release(%{worker: %{protocol: nil}} = assigns), do: ~H""

  defp release(assigns) do
    assigns =
      assign(assigns, hint: Format.build_hint(assigns.worker.build, assigns.current_build))

    ~H"""
    <span>
      {@worker.release || "release not reported"}<span
        :if={@hint}
        class={@hint == "other build" && "text-warning"}
      > · {@hint}</span>
    </span>
    """
  end

  # The release's version alone, for the wide table's column: `0.31.0 (8rh57whmgk6m)` reads
  # `0.31.0`. Nothing for a machine that has not said.
  defp version(%{protocol: nil}), do: nil
  defp version(%{release: nil}), do: "—"
  defp version(%{release: release}), do: release |> String.split(" ", parts: 2) |> hd()

  @doc """
  Whether a row is busy or ready and not connected: a machine every other surface calls healthy
  that cannot take work or finish what it holds — drawn in danger, never in the quiet grey a
  machine that is merely gone gets (`docs/design/ui.md` § Machines).
  """
  @spec stranded?(map()) :: boolean()
  def stranded?(%{connected: false, worker: %{status: status}}) when status in [:busy, :ready],
    do: true

  def stranded?(_row), do: false

  # The release-predates line, only about a machine that has said what it runs: a row still being
  # made has reported nothing, and "its release predates" would be a claim about nothing.
  defp predates?(%{status: :destroyed}), do: false
  defp predates?(%{harness: nil, protocol: nil}), do: false
  defp predates?(worker), do: not Workers.runs?(worker, "claude_code")

  # What it offers, as the field is labelled — `8GiB`, never `8589934592` (UX pass, D15).
  defp offered_memory(bytes) when is_integer(bytes) and bytes > 0,
    do: ForgeCore.Workflow.Resources.humanize(bytes)

  defp offered_memory(bytes), do: bytes

  # What it has free, on a row that has said what it has and is still here.
  defp capacity?(%{status: :destroyed}), do: false
  defp capacity?(%{memory_budget: nil}), do: false
  defp capacity?(_worker), do: true

  # The harness by its display name — *Claude Code*, as You draws it — and not its driver's key.
  defp harness_name(harness) do
    case harness_text(harness["driver"]) do
      nil -> harness_text(harness["name"])
      driver -> Forge.Harness.label(driver)
    end
  end

  defp other_build?(worker, current_build),
    do: worker.protocol != nil and Format.build_hint(worker.build, current_build) == "other build"

  attr :worker, :map, required: true

  # The machine installs or updates its own Claude Code before it reports `ready`
  # (`docs/design/worker-tier.md` § Updating a worker), so the version on the line above is what
  # that attempt left behind and this is whether the attempt worked. **Quiet unless it failed**:
  # `succeeded` and `skipped` are both a machine that is fine, and the one loud thing in the
  # interface is an item waiting on a human (`docs/design/ui.md` § Colour). A machine whose image
  # predates the unit reports nothing, and nothing is drawn — the same treatment an absent `cores`
  # gets, and the reason the worker omits the key rather than sending a null.
  #
  # **The pattern is the guard and it is tested, not asserted.** `outcome` has to be a string
  # because it is drawn, and `update` has to be a map because `outcome` is read out of it: a
  # release that sends `"update" => "oops"` would otherwise raise in `Access.get/3`, and one that
  # sends a number for `outcome` would draw a line out of it. Both are covered, so relaxing this
  # head fails a test rather than passing quietly.
  defp claude_update(%{worker: %{harness: %{"update" => %{"outcome" => outcome}}}} = assigns)
       when is_binary(outcome) do
    update = assigns.worker.harness["update"]
    assigns = assign(assigns, outcome: outcome, error: harness_text(update["error"]))

    ~H"""
    <div
      id={"claude-update-#{@worker.id}"}
      class={["font-mono", (@outcome == "failed" && "text-danger") || "text-ink-3"]}
    >
      claude update {@outcome}<span :if={@error}>: {@error}</span>
    </div>
    """
  end

  defp claude_update(assigns), do: ~H""

  attr :worker, :map, required: true

  # The harnesses a machine offers beyond the one on the line above (`harnesses` is the list its
  # last `ready` sent; `harness` is the first of it): each with its version, and the outcome of its
  # own update when it left one, loud only when it failed, like Claude Code's. A row an older
  # release wrote has no list and draws nothing. Every value goes through `harness_text/1`.
  defp other_harnesses(%{worker: %{harnesses: [_primary | rest]}} = assigns) do
    assigns = assign(assigns, others: Enum.filter(rest, &is_map/1))

    ~H"""
    <div :for={offer <- @others} id={"harness-#{@worker.id}-#{harness_text(offer["driver"])}"}>
      <span>{harness_text(offer["name"]) || harness_text(offer["driver"])}</span>
      <span class="text-ink-3">
        {harness_text(offer["version"]) || "not installed"}
      </span>
      <span
        :if={harness_text(get_in(offer, ["update", "outcome"]))}
        class={[get_in(offer, ["update", "outcome"]) == "failed" && "text-danger"]}
      >
        · update {harness_text(get_in(offer, ["update", "outcome"]))}<span :if={
          harness_text(get_in(offer, ["update", "error"]))
        }>: {harness_text(get_in(offer, ["update", "error"]))}</span>
      </span>
    </div>
    """
  end

  defp other_harnesses(assigns), do: ~H""

  @doc """
  A string a machine sent about itself, or `nil` for anything that is not one.

  **Every value out of `harness` goes through here before it is drawn.** The map is whatever a
  worker pushed at `ready`, kept verbatim in a jsonb column (`Forge.Workers.record_ready/2`), and
  `Phoenix.HTML.Safe` is not implemented for a map or a list — so one release sending
  `%{"login" => %{...}}` took `/workers` down permanently for every operator who could see that
  row, the value being persisted and every later mount crashing on it again. This image cannot
  send one (`jq --arg` always writes a string) but any other release on the channel can, which is
  the whole reason a guard is here rather than a comment saying it cannot happen.

  Numbers are rendered rather than dropped: a version or an outcome arriving unquoted is a
  malformed report, not a reason to show the operator nothing.
  """
  @spec harness_text(term()) :: String.t() | nil
  def harness_text(value) when is_binary(value), do: value
  def harness_text(value) when is_number(value), do: to_string(value)
  def harness_text(_other), do: nil

  attr :worker, :map, required: true
  attr :connected, :boolean, required: true
  attr :current_build, :string, default: nil

  attr :stranded, :boolean, default: false, doc: "busy or ready and not connected: in danger"

  attr :full, :boolean,
    default: true,
    doc: "with the short id and the status; a row's head already says both"

  @doc """
  A machine's identifiers: which machine, at which provider, in what state, whether it is held
  right now, whether the platform may end it, and what it runs. The same line is under a row's
  head here and heads its log on `ForgeWeb.WorkerLive`, so the two pages name a machine alike.
  """
  def identity(assigns) do
    ~H"""
    <span :if={@full}>{String.slice(@worker.id, 0, 8)}</span>
    <span class="break-all text-ink-3">
      {@worker.provider}{if @worker.provider_id,
        do: " · " <> String.slice(@worker.provider_id, 0, 12)}
    </span>
    <span :if={@full}>{@worker.status}</span>
    <%!-- Read from the registry, not from the row: the one fact the database does not have
          and `mix forge.worker.list` therefore cannot show. --%>
    <span class={["inline-flex items-center gap-1.5", @stranded && "text-danger"]}>
      <span
        class={["machine-dot", @connected && "machine-dot--on", @stranded && "machine-dot--danger"]}
        aria-hidden="true"
      />
      {if @connected, do: "connected", else: "not connected"}
    </span>
    <%!-- The only thing that differs between a machine the platform may destroy and one it
          may not (docs/design/worker-tier.md § Managed and unmanaged). --%>
    <span class="text-ink-3">{if @worker.managed, do: "managed", else: "permanent"}</span>
    <.release worker={@worker} current_build={@current_build} />
    """
  end

  attr :worker, :map, required: true
  attr :stranded, :boolean, default: false

  # A row's status in the head: `▸ busy` in the running colour, the database's word otherwise,
  # and `gone` for a destroyed row (`12f`). Busy or ready and not connected is the one state that
  # cost a day, so the row draws it in danger instead — the caller's class, with the dot and the
  # *not connected* under it (UX pass, D14).
  defp status(%{stranded: true} = assigns), do: ~H"<span>{@worker.status}</span>"

  defp status(%{worker: %{status: :busy}} = assigns),
    do: ~H"""
    <.state_label state="running">busy</.state_label>
    """

  defp status(%{worker: %{status: :destroyed}} = assigns), do: ~H"<span>gone</span>"
  defp status(assigns), do: ~H"<span>{@worker.status}</span>"

  attr :row, :map, required: true
  attr :projects, :list, required: true
  attr :editing, :any, required: true
  attr :now, :any, required: true
  attr :current_build, :string, default: nil
  attr :refused, :any, default: nil, doc: "`{id, words}`: the last Destroy or Retire refused"

  # **A row leads with its connection dot and what it is doing** (`12f`): the head is the link to
  # the machine's log, and everything that is not a summary — the lines in danger, the meters,
  # what it offers, the projects it serves, ending it — sits under it, so nothing inside the link
  # commits (`docs/design/ui.md` § The affordance rule). Destroyed rows stay, dimmed.
  defp machine(assigns) do
    assigns =
      assign(assigns,
        gone: assigns.row.worker.status == :destroyed,
        other: other_build?(assigns.row.worker, assigns.current_build),
        stranded: stranded?(assigns.row)
      )

    ~H"""
    <li id={"worker-#{@row.worker.id}"} class={["machine", @gone && "machine--gone"]}>
      <.link navigate={~p"/workers/#{@row.worker.id}"} class="machine-head">
        <span
          class={[
            "machine-dot",
            @row.connected && "machine-dot--on",
            @stranded && "machine-dot--danger"
          ]}
          title={if @row.connected, do: "connected", else: "not connected"}
          aria-hidden="true"
        />
        <span class="machine-name">{String.slice(@row.worker.id, 0, 8)}</span>
        <span :if={@other} class="machine-flag text-warning">other build</span>
        <%!-- Stranded, the dot and *not connected* carry the danger; *busy* in red read as if
              being busy were the error (UX re-check #17). --%>
        <span class="machine-status">
          <.status worker={@row.worker} stranded={@stranded} />
        </span>
        <span class="machine-doing">{doing(@row, @now)}</span>
        <span class="machine-where">{where_from(@row.serves)}</span>
        <span class={["machine-version", @other && "text-warning"]}>{version(@row.worker)}</span>
        <span class="machine-chevron" aria-hidden="true">›</span>
      </.link>

      <div class="machine-more">
        <div class="machine-ids">
          <.identity
            worker={@row.worker}
            connected={@row.connected}
            current_build={@current_build}
            stranded={@stranded}
            full={false}
          />
        </div>

        <p :if={refusal(@row.worker)} class="machine-line text-danger">{refusal(@row.worker)}</p>
        <p :if={unhealthy(@row.worker)} class="machine-line text-danger [overflow-wrap:anywhere]">
          {unhealthy(@row.worker)}
        </p>
        <%!-- What the driver last refused: why this row never became a machine — until it was
              drawn, a driver refusing to create was invisible on every surface the operator
              has — or, for a machine it made, why it is still here. --%>
        <p :if={driver_error(@row.worker)} class="machine-line text-danger [overflow-wrap:anywhere]">
          {driver_error(@row.worker)}
        </p>
        <%!-- A release that does not take the job's credential from the assignment is given no
              inference job at all (`Workers.runs?/2`), so a machine that looks healthy
              everywhere else takes no work — which is the thing to say. --%>
        <%!-- A release from before tokens were counted during a run takes no job of any kind
              (`Forge.Jobs.protocol_needs/1`), whatever else about it is in order. --%>
        <p
          :if={too_old?(@row.worker)}
          id={"worker-#{@row.worker.id}-too-old"}
          class="machine-line text-danger"
        >
          takes no job: it speaks protocol {@row.worker.protocol} and counting tokens during a run
          needs {Jobs.usage_protocol()}; update it
        </p>
        <p
          :if={not too_old?(@row.worker) and predates?(@row.worker)}
          class="machine-line text-danger"
        >
          takes no agent job: its release predates per-job credentials; update it
        </p>

        <.meters row={@row} />

        <div class="machine-facts">
          <div class="machine-fact-column">
            <%!-- Two dimensions, because the gate has two (docs/design/ui.md § Machines). --%>
            <%!-- Not on a row that is gone or has never said what it has: "0.0 GiB of — free"
                  and a destroyed machine's "8.0 GiB free" were both figures about nothing. --%>
            <div :if={capacity?(@row.worker)}>
              {gib(@row.remaining_memory)} of {gib(@row.worker.memory_budget)} free
            </div>
            <div :if={capacity?(@row.worker)} class="text-ink-3">
              {cores(@row.worker.cores, @row.remaining_cores)}
            </div>
            <div :if={@row.worker.accepts} class="text-ink-3">
              takes {Enum.map_join(@row.worker.accepts, ", ", &to_string/1)}
            </div>
            <%!-- What the machine said, when it disagrees with what the row says it is. The row
                  governs and an operator's edit survives a reconnect, so a difference is shown
                  rather than silently resolved. --%>
            <div :if={mismatch(@row.worker)} class="text-danger">
              reports {mismatch(@row.worker)}
            </div>
          </div>

          <div class="machine-fact-column">
            <%!-- What the machine said at `ready`: which harness and which version. The login line
                  is only drawn for a row an older release wrote. A machine that reported no
                  harness takes no agent job (`docs/design/credentials.md` § What a worker offers
                  now).

                  Every one of these goes through `harness_text/1`, which is the guard: the map is
                  whatever some release pushed, and a non-string in any of them used to take this
                  page down for good. --%>
            <div>
              <span :if={is_nil(@row.worker.harness)} class="text-ink-4">no harness reported</span>
              <span :if={@row.worker.harness}>
                {harness_name(@row.worker.harness)}
                <span class="text-ink-3">{harness_text(@row.worker.harness["version"])}</span>
              </span>
            </div>
            <div
              :if={
                @row.worker.harness && harness_text(@row.worker.harness["login"]) not in [nil, "ok"]
              }
              class="text-danger"
            >
              login {harness_text(@row.worker.harness["login"])}
            </div>
            <.claude_update worker={@row.worker} />
            <.other_harnesses worker={@row.worker} />
            <div class="text-ink-3">
              last seen {(@row.worker.last_seen_at &&
                            Format.ago_phrase(@row.worker.last_seen_at, @now)) ||
                "never"}<span :if={@row.worker.idle_since && @row.worker.status != :busy}> · idle {Format.lasted(
                @row.worker.idle_since,
                @now
              )}</span>
            </div>
          </div>
        </div>

        <%!-- A permanent worker's figures are the operator's to set, and the row governing the
              gate is what makes that edit stick across a reconnect. § The affordance rule — an
              editable field must look editable, so it is a form and not a hover. --%>
        <.form
          :if={@editing == @row.worker.id}
          for={to_form(%{}, as: :worker)}
          id={"offer-#{@row.worker.id}"}
          phx-submit="save"
          class="machine-offer"
        >
          <input type="hidden" name="worker_id" value={@row.worker.id} />
          <.input
            name="memory"
            id={"offer-memory-#{@row.worker.id}"}
            value={offered_memory(@row.worker.memory_budget)}
            label="Memory (e.g. 8GiB)"
            mono
          />
          <.input
            name="cores"
            id={"offer-cores-#{@row.worker.id}"}
            type="number"
            value={@row.worker.cores}
            label="Cores"
            mono
          />
          <fieldset class="machine-kinds">
            <legend class="text-ink-3">Takes — nothing ticked means any kind</legend>
            <.choice_row
              :for={kind <- Forge.Jobs.Job.kinds()}
              name={"accepts_#{kind}"}
              value="true"
              label={to_string(kind)}
              multi
              selected={@row.worker.accepts && kind in @row.worker.accepts}
            />
          </fieldset>
          <div class="flex items-center gap-2">
            <.button type="button" variant="secondary" size="xl" phx-click="cancel-edit">
              Cancel
            </.button>
            <.button type="submit" variant="primary" size="xl" fill>Save it</.button>
          </div>
        </.form>

        <div class="machine-actions">
          <.serves row={@row} projects={@projects} />
          <.button
            :if={not @gone and not @row.worker.managed and @editing != @row.worker.id}
            variant="link"
            size="sm"
            phx-click="edit"
            phx-value-id={@row.worker.id}
          >
            Set what it offers
          </.button>
          <%!-- **The owner's decision**, outlined red behind a confirm from one definition each
                (docs/design/ui.md § Machines). --%>
          <.confirm
            :if={not @gone}
            id={"destroy-#{@row.worker.id}"}
            label={if @row.worker.managed, do: "Destroy machine", else: "Retire"}
            act={if @row.worker.managed, do: "Destroy it", else: "Retire it"}
            sentence={
              if @row.worker.managed,
                do: destroy_confirm(length(@row.jobs)),
                else: retire_confirm(length(@row.jobs))
            }
            class="ui-confirm--inline machine-destroy"
            phx-click="destroy"
            phx-value-id={@row.worker.id}
          />
        </div>
        <.error_note
          :if={match?({id, _} when id == @row.worker.id, @refused)}
          id={"refused-#{@row.worker.id}"}
        >
          {elem(@refused, 1)}
        </.error_note>
      </div>
    </li>
    """
  end

  # The subline under the title (`12f`): what the fleet is doing, and the templates that cannot
  # make another machine. Nothing is said of a count that is zero but the busy one, which leads.
  defp subline(assigns) do
    [
      "#{assigns.busy_count} busy",
      assigns.idle_count > 0 && "#{assigns.idle_count} idle",
      assigns.full_count > 0 &&
        "#{assigns.full_count} #{if assigns.full_count == 1, do: "template", else: "templates"} at its limit"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  @doc """
  The three views of the machines page (`docs/design/ui.md` § Machines): one list, so the strip,
  the tabs and the templates page cannot disagree about them.
  """
  @spec views() :: [map()]
  def views do
    [
      %{key: "machines", label: "Machines", navigate: "/workers"},
      %{key: "templates", label: "Templates", navigate: "/templates"},
      %{key: "credentials", label: "Credentials", navigate: "/templates?view=credentials"}
    ]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      frame={@frame}
      capacity={@capacity}
      title="Machines"
      subline={subline(assigns)}
      top_level={:machines}
      views={views()}
      view="machines"
      measure={nil}
    >
      <div id="machines-summary" class="machines-summary">
        <%!-- No node-wide ceiling: every machine the platform makes comes from a template and
              every ceiling is that template's, beside its price where the money is
              (`provisioning.md` § Whose account). The slots are this viewer's own. --%>
        <span class="machines-count">{@live_count} live · {@connected_count} connected</span>
        <span :if={@slots != []} class="machines-slots" aria-hidden="true">
          <span :for={slot <- @slots} class={"machines-slot machines-slot--#{slot}"} />
        </span>
        <span class="machines-bar">
          <.button variant="quiet" size="sm" phx-click="toggle-destroyed">
            {if @show_destroyed, do: "Hide destroyed", else: "Show destroyed"}
          </.button>
          <%!-- Gone while an environment is on screen, which would otherwise be thrown away by one
              more click. --%>
          <.button
            :if={not @minting and is_nil(@minted)}
            id="new-machine"
            variant="outline"
            size="sm"
            phx-click="new-machine"
          >
            + Add a machine
          </.button>
        </span>
      </div>

      <%!-- The one state in which this page has nothing to show and nothing will appear by
            waiting: the way out is filled. Primary, not amber — no person is waited on yet. --%>
      <div :if={not @has_templates} id="no-templates" class="machines-none">
        <p>You have no templates, so the platform can make no machine for you.</p>
        <.button id="templates-button" variant="primary" size="md" navigate={~p"/templates"} chevron>
          Templates
        </.button>
      </div>

      <%!-- One question, and no owner: the machine is the viewer's. --%>
      <.form
        :if={@minting}
        for={to_form(%{}, as: :machine)}
        id="mint-form"
        phx-submit="mint"
        class="machines-mint"
      >
        <h2 class="machines-mint-title">A machine you boot yourself</h2>
        <%!-- A select and not a box: a choice, which a rejoin has nothing to give back for. --%>
        <label for="mint-project" class="text-ink-3">Serving</label>
        <select id="mint-project" name="project" class="machine-select h-[46px]">
          <option value="">no project yet</option>
          <option :for={project <- @projects} value={project.id}>{project.name}</option>
        </select>
        <div class="flex items-center gap-2">
          <.button type="button" variant="secondary" size="xl" phx-click="cancel-new">
            Cancel
          </.button>
          <.button type="submit" variant="primary" size="xl" fill>Make it</.button>
        </div>
      </.form>

      <%!-- Once, and only here: the row keeps the token's hash and can never show it again. --%>
      <.shown_once :if={@minted} id="minted" done="dismiss-minted">
        <:note>
          It is the whole of what the machine needs: put it in a file named
          <code class="font-mono text-[12.5px]">worker.env</code>
          on a disk labelled <code class="font-mono text-[12.5px]">forge-config</code>, or give it to
          the provider as user data, and boot the worker image.
        </:note>
        <.copyable id="minted-env" value={@minted} label="worker.env" multiline />
      </.shown_once>

      <.error_note :if={@error} id="machines-error" class="machines-error">{@error}</.error_note>

      <p :if={@rows == []} class="machines-empty">
        You have no machines. One is created from your templates when a job needs it, or added with + Add a machine for a computer you boot yourself.
      </p>

      <div :if={@rows != []} class="machines-table">
        <div class="machines-columns" aria-hidden="true">
          <span />
          <span>machine</span>
          <span>status</span>
          <span>doing</span>
          <span>template · projects</span>
          <span>release</span>
          <span />
        </div>
        <ul id="machines">
          <.machine
            :for={row <- @rows}
            row={row}
            projects={@projects}
            editing={@editing}
            now={@now}
            current_build={@current_build}
            refused={@refused}
          />
        </ul>
      </div>

      <p class="machines-note">
        A job is scheduled against what it asked for, in memory and in cores, and against the
        kinds a machine says it takes. A job that declares nothing gets {gib(@slice_bytes)}.
      </p>

      <%!-- The right column on a wide screen (`12o`): the templates and credentials beside the
            table, each leading to its view. Hidden below 1440, where the views do the same. --%>
      <:aside>
        <div class="machines-aside">
          <section id="machines-templates">
            <div class="machines-aside-head">
              <.eyebrow>Templates</.eyebrow>
              <.link navigate={~p"/templates?new=1"}>+ New</.link>
            </div>
            <.link
              :for={template <- @templates}
              navigate={~p"/templates?template=#{template.id}"}
              class="machines-aside-row"
            >
              <span>{template.name}</span>
              <span class={[
                "template-slots",
                @made[template.id] >= template.max_workers && "template-slots--full"
              ]}>
                <span class="template-count">{@made[template.id]} of {template.max_workers}</span>
              </span>
              <span class="template-quiet">
                {[
                  template.size,
                  "up to #{template.max_workers}",
                  template.idle_ms && "idle #{div(template.idle_ms, 60_000)}m"
                ]
                |> Enum.filter(&is_binary/1)
                |> Enum.join(" · ")}
              </span>
            </.link>
          </section>
          <section id="machines-credentials">
            <div class="machines-aside-head">
              <.eyebrow>Credentials</.eyebrow>
              <.link navigate={~p"/templates?view=credentials"}>+ Add</.link>
            </div>
            <.link
              :for={credential <- @credentials}
              navigate={~p"/templates?view=credentials"}
              class="machines-aside-row"
            >
              <span>{credential.name}</span>
              <span class="template-quiet">
                {credential.provider} · {named(@templates, credential.id)}
              </span>
            </.link>
          </section>
        </div>
      </:aside>
    </Layouts.app>
    """
  end
end
