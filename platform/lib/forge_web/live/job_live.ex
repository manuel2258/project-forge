defmodule ForgeWeb.JobLive do
  @moduledoc "One job: the pinned manifest it ran with, and what the harness did."

  use ForgeWeb, :live_view

  import ForgeWeb.Indicators

  alias Forge.{Artifacts, Events, Jobs, Tickets}
  alias Forge.Jobs.Memory
  alias ForgeWeb.{FileType, Format, Indicators, JobStream, WorkScreen}

  # Newest first, a page at a time (`ForgeWeb.JobStream`). A finished job's stream is read
  # backwards from its outcome; a running one's is tailed, because someone who opened it is
  # looking at that one piece of work (`docs/design/ui.md` § Motion and structure). Newest first
  # needs no pinning: what arrives appears at the top, where the reader already is.

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
     |> assign(project: project, ticket: ticket, job_id: job.id)
     |> JobStream.init()
     |> ForgeWeb.Capacity.project(project)
     |> load()}
  end

  defp load(%{assigns: %{job_id: job_id, ticket: ticket, project: project}} = socket) do
    job = Jobs.get!(job_id)
    events = Events.for_job(job.id)
    spec = Jobs.spec(job)
    written = Artifacts.written_by(job.id)

    assign(socket,
      page_title: "#{project.name}##{ticket.number} · #{job.state} ##{job.attempt}",
      job: job,
      spec: spec,
      written: written,
      written_names: MapSet.new(written, fn {artifact, _v} -> artifact.name end),
      refusals: Jobs.refusals(job)
    )
    |> assign(events: events, memory: Memory.trouble(events), held: held(events))
  end

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
    do: {:noreply, load(socket)}

  def handle_info({:ticket_changed, _}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("more", params, socket), do: JobStream.handle_event("more", params, socket)

  def handle_event("notices", params, socket),
    do: JobStream.handle_event("notices", params, socket)

  # Each `produces` entry as the declaration says it, beside the name the artifact is recorded
  # under: `{"deck.md!", "deck.md"}`, `{"shots/*", "shots"}`, `{"plan.md", "plan.md"}`.
  defp declared(spec), do: Enum.map(spec.produces, &{&1, ForgeCore.Workflow.produced_name(&1)})

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

  # `docs/design/ui.md` § Decide and Timeline: a command's page is the job page with what a command
  # has — its exit status, the script as it ran, its argument vector, its commit, its timeout, the
  # job that invoked it and its log — and none of an agent's turns, budget or prompt.
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
    <div class="mt-4 flex flex-col gap-8 lg:flex-row lg:gap-0">
      <div class="lg:min-w-0 lg:flex-1 lg:pr-8">
        <header class="flex flex-col gap-2">
          <div class="font-mono text-[12.5px] opacity-60">
            $ {@command["name"]} · {@job.state}
          </div>
          <div class="flex flex-wrap items-baseline gap-3 text-3xl">
            <.exit_status job={@job} />
          </div>
          <p class="text-sm/[1.55] opacity-60">
            The script's exit status, or the engine's reason it has none.
          </p>
        </header>

        <dl class="mt-6 grid grid-cols-2 gap-4 border-y border-base-300 py-4">
          <div class="min-w-0">
            <dt class="font-mono text-[11px] tracking-[.14em] uppercase opacity-50">Duration</dt>
            <dd class="mt-1 font-mono text-[17px]">{Format.duration(@job)}</dd>
          </div>
          <div class="min-w-0">
            <dt class="font-mono text-[11px] tracking-[.14em] uppercase opacity-50">Timeout</dt>
            <dd class="mt-1 font-mono text-[17px]">{div(@command["timeout_ms"] || 0, 1000)}s</dd>
          </div>
        </dl>

        <section class="mt-8">
          <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Script</h2>
          <pre
            id="command-script"
            class="mt-2 overflow-x-auto rounded-box bg-base-200 p-3 text-[12.5px]"
          >{@command["script"]}</pre>
        </section>
      </div>

      <aside class="lg:w-[21rem] lg:shrink-0 lg:border-l lg:border-base-300 lg:pl-8">
        <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">As it ran</h2>
        <dl class="mt-3 flex flex-col gap-2 text-[12.5px]">
          <div class="flex min-w-0 justify-between gap-3">
            <dt class="opacity-50">arguments</dt>
            <dd id="command-args" class="truncate font-mono">
              {ForgeCore.Workflow.Command.argv(@command["args"])}
            </dd>
          </div>
          <div class="flex min-w-0 justify-between gap-3">
            <dt class="opacity-50">commit</dt>
            <dd class="truncate font-mono">{String.slice(@command["at"] || "", 0, 12)}</dd>
          </div>
          <div class="flex min-w-0 justify-between gap-3">
            <dt class="opacity-50">script</dt>
            <dd class="truncate font-mono">{@command["run"]}</dd>
          </div>
          <div class="flex min-w-0 justify-between gap-3">
            <dt class="opacity-50">environment</dt>
            <dd class="font-mono">{@spec.env || "none"}</dd>
          </div>
          <div :if={@held != []} class="flex min-w-0 justify-between gap-3">
            <dt class="opacity-50">secrets</dt>
            <dd class="job-secrets min-w-0 text-right font-mono">
              <div :for={run <- @held}>{held_line(run)}</div>
            </dd>
          </div>
        </dl>

        <.link
          :if={@job.parent_job_id}
          navigate={~p"/tickets/#{@project.name}/#{@ticket.number}/jobs/#{@job.parent_job_id}"}
          class="mt-4 flex min-h-[46px] items-center gap-2 border-b border-base-300/60 font-mono text-[12.5px] hover:bg-base-200"
        >
          <span class="min-w-0 flex-1 truncate">invoked by {@job.state}</span>
          <span class="shrink-0 opacity-40" aria-hidden="true">›</span>
        </.link>

        <h3 class="mt-6 font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Log</h3>
        <.link
          :if={@log}
          href={
            ~p"/tickets/#{@project.name}/#{@ticket.number}/artifacts/#{elem(@log, 0).name}/#{elem(@log, 1).version}"
          }
          class="mt-2 flex min-h-[46px] items-center gap-2 border-b border-base-300/60 font-mono text-[12.5px] hover:bg-base-200"
        >
          <FileType.file_icon artifact={elem(@log, 0)} />
          <span class="min-w-0 flex-1 truncate">{elem(@log, 0).name}</span>
          <span class="shrink-0 opacity-60">v{elem(@log, 1).version}</span>
          <span class="shrink-0 opacity-40" aria-hidden="true">›</span>
        </.link>
        <p :if={!@log} class="mt-2 font-mono text-[12.5px] opacity-50">
          {@no_log}
        </p>
      </aside>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- Wider than the review page it is laid out like: its column is the harness stream, whose
          lines are an agent's paragraphs (`docs/design/ui.md` § Space, measure and targets). --%>
    <Layouts.app flash={@flash} current_scope={@current_scope} capacity={@capacity} measure="96rem">
      <.link
        navigate={~p"/tickets/#{@project.name}/#{@ticket.number}"}
        class="flex min-h-[46px] items-center font-mono text-[12.5px] opacity-60 hover:opacity-100"
      >
        ‹ {@project.name}#{@ticket.number} · {@ticket.title}
      </.link>

      <.command_page :if={@job.kind == :command} {assigns} />

      <div :if={@job.kind != :command} class="mt-4 flex flex-col gap-8 lg:flex-row lg:gap-0">
        <div class="lg:min-w-0 lg:flex-1 lg:pr-8">
          <header class="flex flex-col gap-2">
            <div class="font-mono text-[12.5px] opacity-60">{@job.state} #{@job.attempt}</div>

            <div class="flex flex-wrap items-baseline gap-3">
              <.outcome
                :if={@job.declared_outcome || @job.outcome}
                value={@job.declared_outcome || to_string(@job.outcome)}
                bucket={@job.declared_outcome && Indicators.bucket(@job.outcome)}
                class="text-3xl"
              />
              <.outcome :if={@job.declared_outcome && @job.outcome} value={to_string(@job.outcome)} />
              <%!-- Which ceiling stopped it, where one did. Only a `budget_exhausted` job has
                    one, and such a job declared nothing, so this qualifies the badge above it
                    and never the agent's own word. --%>
              <.ceiling job={@job} />
              <.job_status :if={is_nil(@job.outcome)} status={@job.status} />
            </div>

            <p class="text-sm/[1.55] opacity-60">
              <%= if @job.declared_outcome && @job.outcome do %>
                What the agent declared, then what the engine concluded.
              <% else %>
                The engine's outcome. The agent declared nothing.
              <% end %>
            </p>

            <%!-- Only when memory was the trouble, so it is seen without scrolling the timeline
                  (`docs/design/capacity.md` § Memory, which a job holds rather than spends). --%>
            <p :if={@memory} id="job-memory" class="font-mono text-[12.5px] text-warning">
              ⚠ {Memory.words(@memory)}
            </p>
          </header>

          <dl class="mt-6 grid grid-cols-3 gap-4 border-y border-base-300 py-4">
            <%!-- **The turns a job used, not a ratio.** `job.turns` is the harness's `num_turns`
                  summed over every invocation this job has had — a run the engine resumed after
                  a rate limit adds to it — while `spec.budget.turns` is the `--max-turns` ceiling
                  each single invocation gets. Drawn as `37/30` the pair claimed a cap had been
                  breached by seven that was never breached at all. The ceiling is in the pinned
                  manifest, which says what it bounds; what ended the job is beside its outcome. --%>
            <div class="min-w-0">
              <dt class="font-mono text-[11px] tracking-[.14em] uppercase opacity-50">Turns</dt>
              <dd id="job-turns" class="mt-1 font-mono text-[17px]">{@job.turns}</dd>
            </div>
            <div class="min-w-0">
              <dt class="font-mono text-[11px] tracking-[.14em] uppercase opacity-50">Usage</dt>
              <dd class="mt-1 font-mono text-[17px]">{Format.windows(@job.cost_usd) || "—"}</dd>
            </div>
            <div class="min-w-0">
              <dt class="font-mono text-[11px] tracking-[.14em] uppercase opacity-50">Duration</dt>
              <dd class="mt-1 font-mono text-[17px]">{Format.duration(@job)}</dd>
            </div>
          </dl>

          <section class="mt-8">
            <%!-- Tool calls as the action lines a conversation draws them with, and notices
                  behind their count: `WorkScreen.activity/1`, the same stream a work screen's
                  Activity tab draws. --%>
            <%!-- Scrolls inside itself rather than growing the page (`ui.md` § Motion and
                  structure): this page is not a work screen, so no tab body bounds it. Newest
                  first, so it needs no pinning. --%>
            <WorkScreen.activity
              class="max-h-[60vh] overflow-y-auto overscroll-contain"
              events={@events}
              shown={@shown}
              notices={@notices}
              heading={WorkScreen.stream_heading(@job, @events)}
            />
          </section>
        </div>

        <aside class="lg:w-[21rem] lg:shrink-0 lg:border-l lg:border-base-300 lg:pl-8">
          <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Pinned manifest</h2>
          <dl class="mt-3 flex flex-col gap-2 text-[12.5px]">
            <div class="flex min-w-0 justify-between gap-3">
              <dt class="opacity-50">branch</dt>
              <dd class="truncate font-mono">{@spec.branch}</dd>
            </div>
            <div :if={@held != []} class="flex min-w-0 justify-between gap-3">
              <dt class="opacity-50">secrets</dt>
              <dd class="job-secrets min-w-0 text-right font-mono">
                <div :for={run <- @held}>{held_line(run)}</div>
              </dd>
            </div>
            <div class="flex min-w-0 justify-between gap-3">
              <dt class="opacity-50">commit</dt>
              <dd class="truncate font-mono">{String.slice(@spec.commit || "", 0, 12)}</dd>
            </div>
            <div class="flex min-w-0 justify-between gap-3">
              <dt class="opacity-50">environment</dt>
              <dd class="font-mono">{@spec.env || "none"}</dd>
            </div>
            <div class="flex min-w-0 justify-between gap-3">
              <dt class="opacity-50">budget</dt>
              <dd class="font-mono">
                {@spec.budget.turns} turns per run · {Format.windows(@spec.budget.cost) || "—"}
              </dd>
            </div>
            <div :if={@job.harness_session_id} class="flex min-w-0 justify-between gap-3">
              <dt class="opacity-50">session</dt>
              <dd class="truncate font-mono">{@job.harness_session_id}</dd>
            </div>
          </dl>

          <h3 class="mt-6 font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
            Inputs, at their exact version
          </h3>
          <ul class="mt-3 flex flex-col gap-1 font-mono text-[12.5px]">
            <li :for={input <- @spec.inputs} class="flex min-w-0 justify-between gap-3">
              <span class="truncate">{input.name}</span>
              <span class="opacity-60">v{input.version}</span>
            </li>
            <li :if={@spec.inputs == []} class="opacity-50">none</li>
          </ul>

          <h3 class="mt-6 font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
            Allowed outcomes
          </h3>
          <ul class="mt-3 flex flex-col gap-1 font-mono text-[12.5px]">
            <li :for={name <- @spec.outcomes} class="flex items-center gap-2">
              <.outcome value={name} />
              <span :if={name == @job.declared_outcome} class="opacity-50">←</span>
            </li>
          </ul>

          <%!-- What it declared, and what it actually wrote. A job that failed for a missing
                output appears in the first list and not the second, and that difference is the
                whole story of the run. Every name links to its exact bytes; see
                docs/design/ui.md § Addressable artifact versions. --%>
          <h3 class="mt-6 font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Declares</h3>
          <ul class="mt-3 flex flex-col gap-1 font-mono text-[12.5px]">
            <%!-- The declaration is drawn as written, marker and all, and looked up by the name
                  the artifact is really recorded under: a presentation declared `deck.md!`
                  arrives as `deck.md`, and comparing the raw string would call every one of them
                  "not written". --%>
            <li
              :for={{name, recorded} <- declared(@spec)}
              class={
                not MapSet.member?(@written_names, recorded) &&
                  not Map.has_key?(@refusals, recorded) &&
                  "opacity-50"
              }
            >
              {name}<span
                :if={
                  not MapSet.member?(@written_names, recorded) and
                    not Map.has_key?(@refusals, recorded)
                }
                class="ml-2 opacity-70"
              >not written</span><span :if={Map.has_key?(@refusals, recorded)} class="ml-2 text-error">refused</span>
              <%!-- A refused document is not kept, so why is only here: the reason a job ended
                    `error` having written its document (`docs/design/ui.md` § Decide and
                    Timeline). --%>
              <pre
                :if={Map.has_key?(@refusals, recorded)}
                id={"refused-#{recorded}"}
                class="mt-1 whitespace-pre-wrap break-words font-mono text-[12px]/[1.5] opacity-80"
              >{@refusals[recorded]}</pre>
            </li>
            <li :if={@spec.produces == []} class="opacity-50">nothing</li>
          </ul>

          <h3 class="mt-6 font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Wrote</h3>
          <ul class="mt-3 flex flex-col">
            <li :for={{artifact, version} <- @written}>
              <.link
                href={
                  ~p"/tickets/#{@project.name}/#{@ticket.number}/artifacts/#{artifact.name}/#{version.version}"
                }
                class="flex min-h-[46px] items-center gap-2 border-b border-base-300/60 font-mono text-[12.5px] hover:bg-base-200"
              >
                <FileType.file_icon artifact={artifact} />
                <span class="min-w-0 flex-1 truncate">{artifact.name}</span>
                <span class="shrink-0 opacity-60">v{version.version}</span>
                <span class="shrink-0 opacity-40" aria-hidden="true">›</span>
              </.link>
            </li>
            <li :if={@written == []} class="font-mono text-[12.5px] opacity-50">
              this run wrote nothing
            </li>
          </ul>

          <%!-- A running job's page reloads on its events; the prompt stays open while it does. --%>
          <details id="state-prompt" class="mt-6" phx-mounted={ForgeWeb.Actions.keep_open()}>
            <summary class="flex min-h-[46px] cursor-pointer items-center font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
              State prompt
            </summary>
            <pre class="mt-2 whitespace-pre-wrap text-[12.5px] opacity-70">{@spec.prompt}</pre>
          </details>
        </aside>
      </div>
    </Layouts.app>
    """
  end
end
