defmodule ForgeWeb.JobLive do
  @moduledoc """
  One job, inside its ticket's frame (`docs/design/ui.md` § The job page): the title is the
  ticket, the subline the job, and the strip the ticket's, so the way out is the strip.

  **The outcome is the headline**, the three figures one line under it, and what the job did, its
  manifest and what it wrote behind a segmented switch — the strip's tabs belong to the ticket.
  Where it stands — its plan, its facts, the earlier attempts at this state in this visit — is a
  column on the right of a wide screen, a band under the title on a portrait one, and follows the
  stream on a phone: one markup, placed by `areas/job.css`.

  **There is no Stop.** No operation stops a workflow job, and a stop with nothing behind it is a
  hidden refusal; cancelling the ticket is the way to end its work.

  **The stream reads in order, newest at the bottom**, a page at a time from the end, pinned there
  while the reader is (`ForgeWeb.Operator.Components.scroll_pane/1`). A running job's is tailed,
  because someone who opened it is looking at that one piece of work (`ui.md` § Motion and
  structure).
  """

  use ForgeWeb, :live_view

  import ForgeWeb.Indicators
  import ForgeWeb.Actions, only: [checklist: 1, clip: 1, line: 1]
  import ForgeWeb.Operator.Components, only: [scroll_pane: 1]
  import ForgeWeb.UI.Data, only: [eyebrow: 1, fact_list: 1]
  import ForgeWeb.UI.Forms, only: [segmented: 1]

  alias Forge.{Archive, Artifacts, Events, Jobs, Tickets}
  alias Forge.Jobs.{Memory, Runs}
  alias ForgeWeb.{Actions, Diff, FileType, Format, JobStream, Markdown, TicketViews, WorkScreen}

  @panes ~w(stream manifest wrote)
  @shows ~w(transcript raw)

  # A ticket's live job's statuses, as its page's chip reads them: the chip points at one of these.
  @live [:pending, :running, :waiting, :parked]

  @impl true
  def mount(%{"project" => name, "number" => number, "job_id" => job_id}, _session, socket) do
    {ticket, project} = Tickets.fetch!(name, number)
    ForgeWeb.Access.project_scope!(socket.assigns.current_scope, project)

    job =
      Enum.find(
        Jobs.for_ticket(ticket.id) ++ Jobs.commands_for_ticket(ticket.id),
        &(&1.id == job_id)
      ) ||
        raise Ecto.NoResultsError, queryable: Jobs.Job

    if connected?(socket) do
      Events.subscribe()
      Events.subscribe_job(job.id)
    end

    {:ok,
     socket
     |> assign(
       project: project,
       ticket: ticket,
       job_id: job.id,
       pane: "stream",
       show: "transcript"
     )
     |> JobStream.init()
     |> ForgeWeb.Capacity.project(project)
     |> load()
     |> load_ticket()}
  end

  defp load(%{assigns: %{job_id: job_id, ticket: ticket, project: project}} = socket) do
    job = Jobs.get!(job_id)
    events = Events.for_job(job.id)
    written = Artifacts.written_by(job.id)

    assign(socket,
      page_title: "#{project.name}##{ticket.number} · #{job.state} ##{job.attempt}",
      job: job,
      spec: Jobs.spec(job),
      written: written,
      written_names: MapSet.new(written, fn {artifact, _v} -> artifact.name end),
      refusals: Jobs.refusals(job),
      archive_reads: Archive.reads(job.id),
      runs: Runs.for_job(job.id),
      now: DateTime.utc_now()
    )
    |> assign(events: events, memory: Memory.trouble(events), held: held(events))
  end

  # What the page knows of its ticket rather than of its job: the strip's counts, the job running
  # now and the attempts at this job's state in this visit. Read on mount and when the ticket
  # changes, never per event of the job's own stream.
  defp load_ticket(%{assigns: %{project: project, ticket: %{id: id}, job: job}} = socket) do
    ticket = Tickets.get!(id)
    jobs = Jobs.for_ticket(ticket.id)
    current = List.last(jobs)

    assign(socket,
      ticket: ticket,
      strip: TicketViews.strip_of(project, ticket, current, {job.id, socket.assigns.events}),
      live: live(current, job),
      attempts: attempts(jobs, job)
    )
  end

  # The job running now while the person reads another (`6e`): the chip still points at it.
  defp live(%{id: id, status: status} = current, job) when status in @live and id != job.id,
    do: current

  defp live(_current, _job), do: nil

  # The attempts at this job's state in this visit: the run of the ticket's jobs in that state
  # that this job is part of, oldest first — Steps' own grouping. A command's attempt counts the
  # ticket's commands rather than a state's visits, so a command's page has none.
  defp attempts(jobs, %{kind: :workflow, id: id}) do
    jobs
    |> Enum.chunk_by(& &1.state)
    |> Enum.find([], fn visit -> Enum.any?(visit, &(&1.id == id)) end)
  end

  defp attempts(_jobs, _command), do: []

  # Only a count: a title or a file name from another ticket never reaches this layout. The events
  # behind the count are left out of every list of events (`Forge.Events.archive_reads/1` reads
  # them), so no row of the stream names a file either (`docs/design/archive.md` § What is recorded).
  defp archive_line(0), do: "nothing opened"
  defp archive_line(1), do: "1 file opened"
  defp archive_line(count), do: "#{count} files opened"

  # What each run held, by name and version, from its `job.secrets` record — never a value, which
  # nothing on the platform side keeps in a form this page could show (`secrets.md` § Surfaces).
  defp held(events), do: for(%{type: "job.secrets", payload: payload} <- events, do: payload)

  # Only a workflow job's and a command's: a conversation is not opened here, and only a
  # conversation runs without a secret it named, so a run on this page has nothing gone to show.
  defp held_line(%{"held" => held}),
    do: Enum.map_join(held, ", ", &"#{&1["name"]} v#{&1["version"]}")

  # Per job, so the subscription is the filter. What the harness streams is added to the log the
  # page holds (`ForgeWeb.JobStream`); anything else on the topic — a wait, the run ending —
  # reloads. Adding rather than reloading is a saving and not a behaviour — this page holds
  # nothing a reload takes away — so the `streamed?/1` test answering false here is an
  # equivalent mutant: what it saves is the job, its spec and its log read again per event.
  @impl true
  def handle_info({:job_event, id, event}, %{assigns: %{job_id: id}} = socket) do
    if JobStream.streamed?(event) do
      case JobStream.add(socket.assigns.events, event) do
        :seen ->
          {:noreply, socket}

        {:ok, events} ->
          {:noreply, assign(socket, events: events, memory: Memory.trouble(events))}
      end
    else
      {:noreply, load(socket)}
    end
  end

  def handle_info({:job_event, _id, _event}, socket), do: {:noreply, socket}

  def handle_info({:ticket_changed, id}, %{assigns: %{ticket: %{id: id}}} = socket),
    do: {:noreply, socket |> load() |> load_ticket()}

  def handle_info({:ticket_changed, _}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("more", params, socket), do: JobStream.handle_event("more", params, socket)

  def handle_event("notices", params, socket),
    do: JobStream.handle_event("notices", params, socket)

  # Which of Stream · Manifest · Wrote is on screen, and which of the stream's three readings: the
  # page's own, read by nothing else. A value the switch does not draw changes nothing.
  def handle_event("pane", %{"value" => pane}, socket) when pane in @panes,
    do: {:noreply, assign(socket, pane: pane)}

  def handle_event("pane", _params, socket), do: {:noreply, socket}

  def handle_event("show", %{"value" => show}, socket) when show in @shows,
    do: {:noreply, assign(socket, show: show)}

  def handle_event("show", _params, socket), do: {:noreply, socket}

  # Each `produces` entry as the declaration says it, beside the name the artifact is recorded
  # under — `{"deck.md!", "deck.md"}`, `{"shots/*", "shots"}`, `{"plan.md", "plan.md"}` — and
  # whether it is missing: neither written nor refused.
  defp declared(spec, written, refusals) do
    for entry <- spec.produces do
      recorded = ForgeCore.Workflow.produced_name(entry)

      {entry, recorded,
       not MapSet.member?(written, recorded) and not Map.has_key?(refusals, recorded)}
    end
  end

  # Why there is no log to link, which is three different things.
  defp no_log(command, job) do
    cond do
      command["produces"] == nil ->
        "not recorded on the ticket: the command declares no artifact for it"

      job.status == :finished ->
        "not recorded on the ticket: no log came back from the machine"

      true ->
        "recorded on the ticket once the command ends"
    end
  end

  # -- the stream ---------------------------------------------------------------------------

  # The stream in reading order: the newest page of what `WorkScreen.entries/2` draws, oldest at
  # the top, and how many earlier entries wait behind the control above it.
  defp transcript(events, shown, notices) do
    entries = WorkScreen.entries(events, notices)
    {entries |> Enum.take(shown) |> Enum.reverse(), max(length(entries) - shown, 0)}
  end

  # The entries on screen that failed: the first is where the stream head's link jumps, and how
  # many there are is what it says.
  defp failures(entries), do: Enum.filter(entries, &failed?/1)

  # Each row's minute where it differs from the row above's, in reading order: on a phone the time
  # is said once a minute as a divider rather than on every row, where `21:50:56` nine times took a
  # fifth of the width (UX pass, B5). The first row always opens its minute.
  defp minutes(ats) do
    ats
    |> Enum.map_reduce(nil, fn at, previous ->
      minute = at && Calendar.strftime(at, "%H:%M")
      {if(minute != previous, do: minute), minute}
    end)
    |> elem(0)
  end

  defp failed?({:action, _event, action}), do: Actions.errors([action]) != []
  defp failed?({:event, event}), do: String.ends_with?(event.type, "error")

  defp seq({:action, event, _action}), do: event.seq
  defp seq({:event, event}), do: event.seq

  defp at({:action, event, _action}), do: event.inserted_at
  defp at({:event, event}), do: event.inserted_at

  defp clock(nil), do: nil
  defp clock(at), do: Calendar.strftime(at, "%H:%M:%S")

  # -- where it stands -----------------------------------------------------------------------

  # The agent's own plan: its latest `TodoWrite`, read as the transcript reads one.
  defp plan(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value([], fn
      %{type: "job.harness.tool_use", payload: %{"name" => "TodoWrite"} = payload} = event ->
        payload |> Forge.Conversations.action(event.inserted_at) |> Actions.todos()

      _other ->
        nil
    end)
  end

  # What its runs used between them, in weighted tokens: the run ledger, which every figure of
  # usage is read from (`Forge.Jobs.Runs`, `Forge.Usage`).
  defp spent(runs), do: runs |> Enum.map(& &1.usage) |> Enum.sum()

  # Where it ran: the latest run's machine, by the first eight of its id as a machine's page shows it.
  defp machine([]), do: nil

  defp machine(runs) do
    case List.last(runs).worker_id do
      nil -> nil
      id -> "machine " <> String.slice(id, 0, 8)
    end
  end

  # When the run it is in started (`ui.md` § A job waiting for a machine: a running line's age is
  # the current run's), and how long ago; a job not running, its first start.
  defp started(%{started_at: nil}, _runs, _now), do: "—"

  defp started(job, runs, now) do
    at =
      case {job.status, List.last(runs)} do
        {:running, %{finished_at: nil, started_at: at}} -> at
        _first -> job.started_at
      end

    "#{Calendar.strftime(at, "%H:%M")} · #{Format.ago(at, now)}"
  end

  # The model it ran on, or the project's when the job named none, and the effort beside it.
  defp model(job),
    do: [job.model || "the project's", job.effort] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")

  defp subline(ticket, job, spec) do
    mark = if job.status in @live, do: "▸ ", else: ""
    "##{ticket.number} · #{mark}#{job_name(job, spec)}"
  end

  defp job_name(%{kind: :command, state: state}, spec), do: "$ #{spec.command["name"]} · #{state}"
  defp job_name(job, _spec), do: "#{job.state} ##{job.attempt}"

  defp job_path(project, ticket, job),
    do: ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      frame={@frame}
      capacity={@capacity}
      title={@ticket.title}
      subline={subline(@ticket, @job, @spec)}
      context={{@project.name, ~p"/projects/#{@project.name}"}}
      back={{"#{@project.name}##{@ticket.number}", ~p"/tickets/#{@project.name}/#{@ticket.number}"}}
      views={@strip}
      measure={nil}
    >
      <:composer :if={@live}>
        <div class="ticket-dock ticket-dock--chip">
          <.link id="job-chip" navigate={job_path(@project, @ticket, @live)} class="ticket-job-chip">
            ▸ {@live.state} #{@live.attempt} · {@live.status}
          </.link>
        </div>
      </:composer>

      <.command_page :if={@job.kind == :command} {assigns} />
      <.job_page :if={@job.kind != :command} {assigns} />
    </Layouts.app>
    """
  end

  defp job_page(assigns) do
    assigns = assign(assigns, plan: plan(assigns.events), spent: spent(assigns.runs))

    ~H"""
    <div id="job-page" class="job-page">
      <header class="job-head">
        <.back_row project={@project} ticket={@ticket} job={@job} spec={@spec} runs={@runs} />

        <div id="job-headline" class="job-headline">
          <.outcome
            :if={@job.declared_outcome || @job.outcome}
            value={@job.declared_outcome || to_string(@job.outcome)}
            bucket={@job.declared_outcome && bucket(@job.outcome)}
            class="job-outcome"
          />
          <.outcome :if={@job.declared_outcome && @job.outcome} value={to_string(@job.outcome)} />
          <%!-- Which ceiling stopped it, where one did. Only a `budget_exhausted` job has one, and
                such a job declared nothing, so this qualifies the outcome beside it and never the
                agent's own word. --%>
          <.ceiling job={@job} />
          <.job_status :if={is_nil(@job.outcome)} status={@job.status} />
        </div>

        <%!-- **The turns a job used, not a ratio.** `job.turns` is the harness's `num_turns`
              summed over every invocation this job has had — a run the engine resumed after a
              rate limit adds to it — while `spec.budget.turns` is the `--max-turns` ceiling each
              single invocation gets. Drawn as `37/30` the pair claimed a cap had been breached by
              seven that was never breached at all; the ceiling is a fact of its own, saying what
              it bounds. --%>
        <p id="job-figures" class="job-figures">
          <span id="job-turns">{Format.counted(@job.turns, "turn")}</span>
          · <span id="job-usage" title={Format.exact(@spent)}>{Format.windows(@spent) || "—"}</span>
          · {Format.duration(@job)}
        </p>

        <%!-- Which is which, once there is an outcome to name: a running job has neither. --%>
        <p :if={@job.declared_outcome || @job.outcome} id="job-caption" class="job-caption">
          <%= if @job.declared_outcome && @job.outcome do %>
            What the agent declared, then what the engine concluded.
          <% else %>
            The engine's outcome. The agent declared nothing.
          <% end %>
        </p>

        <%!-- Only when memory was the trouble, so it is seen without opening the stream
              (`docs/design/capacity.md` § Memory, which a job holds rather than spends). --%>
        <p :if={@memory} id="job-memory" class="job-memory">{Memory.words(@memory)}</p>
      </header>

      <section id="job-stand" class="job-stand" aria-label="Where it stands">
        <div class="job-stand-plan">
          <.eyebrow>Its plan</.eyebrow>
          <div :if={@plan != []} id="job-plan" class="job-plan"><.checklist todos={@plan} /></div>
          <p :if={@plan == []} class="job-none">no plan written</p>

          <div :if={length(@attempts) > 1} id="job-attempts" class="job-attempts">
            <.eyebrow>Attempts this visit</.eyebrow>
            <ul>
              <li :for={attempt <- @attempts} id={"attempt-#{attempt.id}"} class="job-attempt">
                <span class="job-dim">#{attempt.attempt}</span>
                <.outcome :if={attempt.outcome} value={to_string(attempt.outcome)} />
                <.job_status :if={is_nil(attempt.outcome)} status={attempt.status} />
                <span class="job-dim">{Format.counted(attempt.turns, "turn")}</span>
                <.link
                  :if={attempt.id != @job.id}
                  navigate={job_path(@project, @ticket, attempt)}
                  class="job-attempt-open"
                >
                  Open ›
                </.link>
                <span :if={attempt.id == @job.id} class="job-attempt-open job-dim">this one</span>
              </li>
            </ul>
          </div>
          <%!-- What each process used (ticket 43): windows with the exact weighted tokens in the
                title, and its tokens by kind — a converted run has none, only the dollars the
                migration read, and says so. --%>
          <div :if={@runs != []} id="job-runs" class="job-attempts">
            <.eyebrow>{if length(@runs) == 1, do: "Run", else: "Runs"}</.eyebrow>
            <ul>
              <li :for={{run, n} <- Enum.with_index(@runs, 1)} id={"run-#{run.id}"} class="job-run">
                <span class="job-run-head">
                  <span class="job-dim">run {n}</span>
                  <span title={Format.exact(run.usage)}>{Format.windows(run.usage) || "—"}</span>
                </span>
                <span :if={Format.kinds(run.tokens)} class="job-run-kinds">
                  {Format.kinds(run.tokens)}
                </span>
                <span :if={run.converted} class="job-run-kinds">converted from dollars</span>
              </li>
            </ul>
          </div>
        </div>

        <div class="job-stand-facts">
          <.eyebrow>This job</.eyebrow>
          <.fact_list id="job-facts" dense>
            <:fact label="state">{@job.state}</:fact>
            <:fact label="attempt">#{@job.attempt}</:fact>
            <:fact label="started">{started(@job, @runs, @now)}</:fact>
            <%!-- The ceiling beside the figure and named as what it bounds: per run. A spec made
                  without a budget — a fixture's, a look's — has none to name. --%>
            <:fact label="turns">
              {@job.turns}<span :if={@spec.budget}> · {@spec.budget.turns} turns per run</span>
            </:fact>
            <:fact label="usage">
              <span title={Format.exact(@spent)}>{Format.windows(@spent) || "—"}</span>
              <span :if={@job.usage_converted} class="job-dim"> · converted from dollars</span>
            </:fact>
            <:fact label="harness">
              <span id="job-harness">{Forge.Jobs.harness_line(@job, @project)}</span>
            </:fact>
            <:fact label="model">{model(@job)}</:fact>
            <:fact :if={machine(@runs)} label="worker">{machine(@runs)}</:fact>
            <:fact label="branch">{@spec.branch}</:fact>
            <:fact label="base">{Diff.short(@ticket.base_commit)}</:fact>
            <:fact :if={@held != []} label="secrets">
              <span class="job-secrets">
                <span :for={run <- @held} class="block">{held_line(run)}</span>
              </span>
            </:fact>
            <:fact label="environment">{@spec.env || "none"}</:fact>
            <:fact label="archive">
              <span class="job-archive">{archive_line(@archive_reads)}</span>
            </:fact>
            <:fact :if={@job.harness_session_id} label="session">
              {@job.harness_session_id}
            </:fact>
          </.fact_list>
        </div>
      </section>

      <section id="job-work" class="job-work">
        <.segmented
          id="job-panes"
          size="sm"
          on_select="pane"
          value={@pane}
          options={[
            {"Stream #{WorkScreen.activity_count(@events)}", "stream"},
            {"Manifest", "manifest"},
            {"Wrote #{length(@written)}", "wrote"}
          ]}
        />

        <.stream
          :if={@pane == "stream"}
          job={@job}
          spec={@spec}
          events={@events}
          shown={@shown}
          notices={@notices}
          show={@show}
        />
        <.manifest
          :if={@pane == "manifest"}
          job={@job}
          spec={@spec}
          written_names={@written_names}
          refusals={@refusals}
        />
        <.wrote :if={@pane == "wrote"} project={@project} ticket={@ticket} written={@written} />
      </section>
    </div>
    """
  end

  attr :project, :map, required: true
  attr :ticket, :map, required: true
  attr :job, :map, required: true
  attr :spec, :map, required: true
  attr :runs, :list, required: true

  # The drill-in's back row (`6c`, `6e`): back to the ticket's Steps, where every one of its jobs
  # is, then which job this is and where it ran.
  defp back_row(assigns) do
    ~H"""
    <div class="job-back-row">
      <.link navigate={~p"/tickets/#{@project.name}/#{@ticket.number}?tab=steps"} class="job-back">
        ‹ Steps
      </.link>
      <span id="job-name" class="job-name">{job_name(@job, @spec)}</span>
      <span :if={machine(@runs)} class="job-dim">{machine(@runs)}</span>
    </div>
    """
  end

  attr :job, :map, required: true
  attr :spec, :map, required: true
  attr :events, :list, required: true
  attr :shown, :integer, required: true
  attr :notices, :boolean, required: true
  attr :show, :string, required: true

  defp stream(assigns) do
    {entries, earlier} = transcript(assigns.events, assigns.shown, assigns.notices)

    failures = failures(entries)

    assigns =
      assign(assigns,
        entries: Enum.zip(entries, minutes(Enum.map(entries, &at/1))),
        earlier: earlier,
        failures: failures,
        notice_count: WorkScreen.notice_count(assigns.events)
      )

    ~H"""
    <%!-- One switch on the page, the panes'; what the stream shows is a quiet toggle in its head,
          and the prompt is an input, so it is the Manifest's (UX pass, B14). --%>
    <div class="job-stream-head">
      <span class="job-dim">{WorkScreen.stream_heading(@job, @events)}</span>
      <%!-- A link in the head's own mono, in danger ink, only while a failure is on screen: it was
            a full-width outline button that read as the page's primary act (UX pass, B15). --%>
      <a
        :if={@show == "transcript" and @failures != []}
        id="job-first-error"
        href={"#job-events-#{seq(hd(@failures))}"}
        class="job-first-error"
      >
        ✗ {length(@failures)} failed · first ↑
      </a>
      <button
        type="button"
        id="job-raw-toggle"
        phx-click="show"
        phx-value-value={if @show == "raw", do: "transcript", else: "raw"}
        aria-pressed={to_string(@show == "raw")}
        class="job-raw-toggle"
      >
        raw log
      </button>
    </div>

    <.scroll_pane :if={@show == "transcript"} id="job-stream" height={nil} class="job-pane">
      <button :if={@earlier > 0} type="button" phx-click="more" class="job-earlier">
        ▸ {@earlier} earlier
      </button>
      <ol id="job-events" class="job-entries" data-scroll-items>
        <li
          :for={{entry, minute} <- @entries}
          :key={seq(entry)}
          id={"job-events-#{seq(entry)}"}
          class="job-entry"
          data-minute={minute}
        >
          <span class="job-entry-time">{clock(at(entry))}</span>
          <div class="job-entry-main">
            <%= case entry do %>
              <% {:action, _event, action} -> %>
                <div data-activity="action"><.line line={{:one, action}} /></div>
              <% {:event, %{type: "job.harness.text"} = event} -> %>
                <%!-- The agent's words as the transcript draws them: a box, its Markdown
                      rendered, never clipped (`ui.md` § Activity: the whole of an agent's text). --%>
                <div class="job-said" data-said="agent">
                  <div class="doc msg">{Markdown.to_html(event.payload["text"], %{})}</div>
                </div>
              <% {:event, event} -> %>
                <%!-- A memory row's type in `warning`: not waiting on a person, and not an error
                      either (`docs/design/capacity.md` § Memory). --%>
                <span class={[
                  "job-entry-type",
                  String.ends_with?(event.type, "error") && "text-danger",
                  event.type == "job.harness.memory" && "text-warning"
                ]}>
                  {String.replace_prefix(event.type, "job.harness.", "")}
                </span>
                <div class="job-entry-detail"><.clip text={Forge.Events.detail(event)} /></div>
            <% end %>
          </div>
        </li>
      </ol>
      <p :if={@job.status == :finished} id="job-stream-end" class="job-stream-end">
        finished · {@job.outcome} · {clock(@job.finished_at)}
      </p>
    </.scroll_pane>

    <div :if={@show == "transcript"} class="job-stream-foot">
      <%!-- Only when there is something behind it. --%>
      <button
        :if={@notice_count > 0}
        type="button"
        phx-click="notices"
        id="job-notices"
        class="ui-btn ui-btn--secondary ui-btn--md"
      >
        {if @notices, do: "Hide", else: "Show"} {@notice_count} harness notices
      </button>
    </div>

    <.raw_log :if={@show == "raw"} events={@events} shown={@shown} />
    """
  end

  attr :events, :list, required: true
  attr :shown, :integer, required: true

  # Every event as it was recorded, oldest first, nothing paired and nothing hidden: the record the
  # transcript is drawn from. Paged from the end, as the transcript is.
  defp raw_log(assigns) do
    events = Enum.take(assigns.events, -assigns.shown)

    assigns =
      assign(assigns,
        events: Enum.zip(events, minutes(Enum.map(events, & &1.inserted_at))),
        earlier: max(length(assigns.events) - assigns.shown, 0)
      )

    ~H"""
    <.scroll_pane id="job-raw-pane" height={nil} class="job-pane">
      <button :if={@earlier > 0} type="button" phx-click="more" class="job-earlier">
        ▸ {@earlier} earlier
      </button>
      <ol id="job-raw" class="job-entries" data-scroll-items>
        <li
          :for={{event, minute} <- @events}
          :key={event.seq}
          id={"job-raw-#{event.seq}"}
          class="job-entry"
          data-minute={minute}
        >
          <span class="job-entry-time">{clock(event.inserted_at)}</span>
          <div class="job-entry-main">
            <span class="job-entry-type">{event.type}</span>
            <div class="job-entry-detail"><.clip text={Forge.Events.detail(event)} /></div>
          </div>
        </li>
      </ol>
    </.scroll_pane>
    """
  end

  attr :job, :map, required: true
  attr :spec, :map, required: true
  attr :written_names, :any, required: true
  attr :refusals, :map, required: true

  defp manifest(assigns) do
    ~H"""
    <div id="job-manifest" class="job-manifest">
      <%!-- What the job was handed to do, first: an input like the rest of the manifest, folded
            because it is long and read once (UX pass, B14). --%>
      <details
        :if={@spec.prompt}
        id="job-prompt"
        class="job-prompt-fold"
        phx-mounted={Actions.keep_open()}
      >
        <summary class="job-prompt-summary">The prompt it was given</summary>
        <pre id="state-prompt" class="job-prompt">{@spec.prompt}</pre>
      </details>

      <.eyebrow>Pinned manifest</.eyebrow>
      <.fact_list dense>
        <:fact label="commit">{Diff.short(@spec.commit)}</:fact>
        <:fact :if={@spec.budget} label="budget">
          {@spec.budget.turns} turns per run · {Format.windows(@spec.budget.tokens) || "—"}
        </:fact>
      </.fact_list>

      <.eyebrow>Inputs, at their exact version</.eyebrow>
      <ul class="job-list">
        <li :for={input <- @spec.inputs} class="job-list-row">
          <span class="truncate">{input.name}</span>
          <span class="job-dim">v{input.version}</span>
        </li>
        <li :if={@spec.inputs == []} class="job-none">none</li>
      </ul>

      <.eyebrow>Allowed outcomes</.eyebrow>
      <ul class="job-list">
        <li :for={name <- @spec.outcomes} class="job-list-row">
          <.outcome value={name} />
          <span :if={name == @job.declared_outcome} class="job-dim">← declared</span>
        </li>
      </ul>

      <%!-- What it declared, and what it actually wrote. A job that failed for a missing output
            appears in the first list and not the second, and that difference is the whole story
            of the run. The declaration is drawn as written, marker and all, and looked up by the
            name the artifact is really recorded under: a presentation declared `deck.md!`
            arrives as `deck.md`, and comparing the raw string would call every one of them "not
            written". --%>
      <.eyebrow>Declares</.eyebrow>
      <ul class="job-list">
        <li
          :for={{name, recorded, missing} <- declared(@spec, @written_names, @refusals)}
          class={["job-declared", missing && "job-dim"]}
        >
          {name}<span :if={missing}> not written</span><span
            :if={Map.has_key?(@refusals, recorded)}
            class="text-danger"
          > refused</span>
          <%!-- A refused document is not kept, so why is only here: the reason a job ended
                `error` having written its document. --%>
          <pre
            :if={Map.has_key?(@refusals, recorded)}
            id={"refused-#{recorded}"}
            class="job-refusal"
          >{@refusals[recorded]}</pre>
        </li>
        <li :if={@spec.produces == []} class="job-none">nothing</li>
      </ul>
    </div>
    """
  end

  attr :project, :map, required: true
  attr :ticket, :map, required: true
  attr :written, :list, required: true

  # What the job produced, each with its type's tile and linked to its exact bytes (`ui.md`
  # § Addressable artifact versions).
  defp wrote(assigns) do
    ~H"""
    <ul id="job-wrote" class="job-wrote">
      <li :for={{artifact, version} <- @written}>
        <.link
          href={
            ~p"/tickets/#{@project.name}/#{@ticket.number}/artifacts/#{artifact.name}/#{version.version}"
          }
          class="job-file"
        >
          <FileType.file_icon artifact={artifact} />
          <span class="job-file-name">{artifact.name}</span>
          <span class="job-dim">v{version.version}</span>
          <span class="job-dim" aria-hidden="true">›</span>
        </.link>
      </li>
      <li :if={@written == []} class="job-none">this run wrote nothing</li>
    </ul>
    """
  end

  # `docs/design/ui.md` § The job page: a command's page is the job page with what a command has —
  # its exit status, the script as it ran, its argument vector, its commit, its timeout, the job
  # that invoked it and its log — and none of an agent's turns, budget or prompt.
  defp command_page(assigns) do
    command = assigns.spec.command

    assigns =
      assign(assigns,
        command: command,
        log:
          Enum.find(assigns.written, fn {artifact, _v} -> artifact.name == command["produces"] end),
        no_log: no_log(command, assigns.job)
      )

    ~H"""
    <div id="job-page" class="job-page">
      <header class="job-head">
        <.back_row project={@project} ticket={@ticket} job={@job} spec={@spec} runs={@runs} />
        <div id="job-headline" class="job-headline">
          <.exit_status job={@job} class="job-outcome" />
        </div>
        <p class="job-figures">
          {Format.duration(@job)} · timeout {div(@command["timeout_ms"] || 0, 1000)}s
        </p>
        <p class="job-caption">The script's exit status, or the engine's reason it has none.</p>
      </header>

      <section id="job-stand" class="job-stand" aria-label="As it ran">
        <div class="job-stand-facts">
          <.eyebrow>As it ran</.eyebrow>
          <.fact_list dense>
            <:fact label="arguments">
              <span id="command-args">{ForgeCore.Workflow.Command.argv(@command["args"])}</span>
            </:fact>
            <:fact label="commit">{Diff.short(@command["at"])}</:fact>
            <:fact label="script">{@command["run"]}</:fact>
            <:fact label="environment">{@spec.env || "none"}</:fact>
            <:fact :if={machine(@runs)} label="worker">{machine(@runs)}</:fact>
            <:fact :if={@held != []} label="secrets">
              <span class="job-secrets">
                <span :for={run <- @held} class="block">{held_line(run)}</span>
              </span>
            </:fact>
          </.fact_list>

          <.link
            :if={@job.parent_job_id}
            navigate={~p"/tickets/#{@project.name}/#{@ticket.number}/jobs/#{@job.parent_job_id}"}
            class="job-file"
          >
            <span class="job-file-name">invoked by {@job.state}</span>
            <span class="job-dim" aria-hidden="true">›</span>
          </.link>

          <.eyebrow>Log</.eyebrow>
          <.link
            :if={@log}
            href={
              ~p"/tickets/#{@project.name}/#{@ticket.number}/artifacts/#{elem(@log, 0).name}/#{elem(@log, 1).version}"
            }
            class="job-file"
          >
            <FileType.file_icon artifact={elem(@log, 0)} />
            <span class="job-file-name">{elem(@log, 0).name}</span>
            <span class="job-dim">v{elem(@log, 1).version}</span>
            <span class="job-dim" aria-hidden="true">›</span>
          </.link>
          <p :if={!@log} class="job-none">{@no_log}</p>
        </div>
      </section>

      <section id="job-work" class="job-work">
        <.eyebrow>Script</.eyebrow>
        <pre id="command-script" class="job-prompt">{@command["script"]}</pre>
      </section>
    </div>
    """
  end
end
