defmodule ForgeWeb.JobLive do
  @moduledoc "One job: the pinned manifest it ran with, and what the harness did."

  use ForgeWeb, :live_view

  import ForgeWeb.Indicators

  alias Forge.{Artifacts, Events, Jobs, Tickets}
  alias ForgeWeb.{Format, Indicators}

  # Newest first, 50 at a time. A finished job's stream is read backwards from its outcome, not
  # watched forwards — see docs/design/ui.md § Motion and structure, which now permits live
  # output where someone is waiting for it and still does not want it here.
  @page 50

  @impl true
  def mount(%{"project" => name, "number" => number, "job_id" => job_id}, _session, socket) do
    {ticket, project} = Tickets.fetch!(name, number)

    job =
      Enum.find(Jobs.for_ticket(ticket.id), &(&1.id == job_id)) ||
        raise Ecto.NoResultsError, queryable: Jobs.Job

    if connected?(socket), do: Events.subscribe()

    {:ok,
     socket
     |> assign(project: project, ticket: ticket, job_id: job.id, shown: @page, notices: false)
     |> load()}
  end

  defp load(%{assigns: %{job_id: job_id, ticket: ticket, project: project}} = socket) do
    job = Jobs.get!(job_id)
    spec = Jobs.spec(job)
    written = Artifacts.written_by(job.id)

    assign(socket,
      page_title: "#{project.name}##{ticket.number} · #{job.state} ##{job.attempt}",
      job: job,
      spec: spec,
      written: written,
      written_names: MapSet.new(written, fn {artifact, _v} -> artifact.name end),
      events: Events.for_job(job.id)
    )
  end

  @impl true
  def handle_info({:ticket_changed, id}, %{assigns: %{ticket: %{id: id}}} = socket),
    do: {:noreply, load(socket)}

  def handle_info({:ticket_changed, _}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("more", _params, socket),
    do: {:noreply, update(socket, :shown, &(&1 + @page))}

  def handle_event("notices", _params, socket),
    do: {:noreply, update(socket, :notices, &(not &1))}

  # What the harness says about itself rather than about the work: Claude Code turns every
  # `system` message into one of these, and `thinking_tokens` alone can outnumber everything else
  # in a job. They are recorded, because the event log is the record and nothing may quietly drop
  # what a job did; they are not drawn, because a stream that is mostly telemetry is the
  # "streaming log, no activity feed — nothing that invites watching agents work" that
  # `docs/design/ui.md` § Motion rules out.
  #
  # One type and not a guessed list: a notice is the harness's own chatter by definition, and
  # every other type is something that happened to the ticket.
  @telemetry ["job.harness.notice"]

  # Newest first, which is the order the stream is drawn in either way.
  defp stream(events, true), do: Enum.reverse(events)

  defp stream(events, false),
    do: events |> Enum.reject(&(&1.type in @telemetry)) |> Enum.reverse()

  defp telemetry_count(events), do: Enum.count(events, &(&1.type in @telemetry))

  # A run that has ended says so; one still going says how far it has got. Neither tails.
  defp stream_heading(%{status: :finished}, events),
    do: "complete · #{length(events)} #{if length(events) == 1, do: "entry", else: "entries"}"

  defp stream_heading(job, events), do: "#{job.status} · #{length(events)} so far"

  defp duration(%{started_at: nil}), do: "—"
  defp duration(%{finished_at: nil}), do: "running"

  defp duration(%{started_at: started, finished_at: finished}) do
    case DateTime.diff(finished, started, :second) do
      s when s < 60 -> "#{s}s"
      s when s < 3_600 -> "#{div(s, 60)}m #{rem(s, 60)}s"
      s -> "#{div(s, 3_600)}h #{div(rem(s, 3_600), 60)}m"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} measure="74rem">
      <.link
        navigate={~p"/tickets/#{@project.name}/#{@ticket.number}"}
        class="font-mono text-[12.5px] opacity-60 hover:opacity-100"
      >
        ‹ {@project.name}#{@ticket.number} · {@ticket.title}
      </.link>

      <div class="mt-4 flex flex-col gap-8 lg:flex-row lg:gap-0">
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
              <.job_status :if={is_nil(@job.outcome)} status={@job.status} />
            </div>

            <p class="text-sm/[1.55] opacity-60">
              <%= if @job.declared_outcome && @job.outcome do %>
                What the agent declared, then what the engine concluded.
              <% else %>
                The engine's outcome. The agent declared nothing.
              <% end %>
            </p>
          </header>

          <dl class="mt-6 grid grid-cols-3 gap-4 border-y border-base-300 py-4">
            <div class="min-w-0">
              <dt class="font-mono text-[11px] tracking-[.14em] uppercase opacity-50">Turns</dt>
              <dd class="mt-1 font-mono text-[17px]">
                {@job.turns}<span class="opacity-50">/{@spec.budget.turns}</span>
              </dd>
            </div>
            <div class="min-w-0">
              <dt class="font-mono text-[11px] tracking-[.14em] uppercase opacity-50">Usage</dt>
              <dd class="mt-1 font-mono text-[17px]">{Format.windows(@job.cost_usd) || "—"}</dd>
            </div>
            <div class="min-w-0">
              <dt class="font-mono text-[11px] tracking-[.14em] uppercase opacity-50">Duration</dt>
              <dd class="mt-1 font-mono text-[17px]">{duration(@job)}</dd>
            </div>
          </dl>

          <section class="mt-8">
            <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
              {stream_heading(@job, @events)}
            </h2>
            <%!-- Scrolls inside itself rather than growing the page, and deliberately without
                  the conversation's pin-to-bottom: this stream is newest first, so what arrives
                  appears at the top, where the reader already is. Pinning it to the bottom would
                  scroll away from the newest entry to reach the oldest. --%>
            <ol
              class="mt-3 flex max-h-[60vh] flex-col overflow-y-auto overscroll-contain"
              id="job-events"
            >
              <%!-- Two rows narrow, one row wide. The type column is 196px because the longest
                    type in the product, `artifact.version_written`, is 24 mono characters and
                    a column narrower than its content does not clip — it overlaps the next one,
                    which is what a vertical screen showed. --%>
              <li
                :for={event <- Enum.take(stream(@events, @notices), @shown)}
                class="grid grid-cols-[64px_1fr] gap-x-2 border-b border-base-300/60 py-1.5 font-mono text-[12.5px] sm:grid-cols-[64px_196px_1fr]"
              >
                <span class="opacity-50">{Calendar.strftime(event.inserted_at, "%H:%M:%S")}</span>
                <span class={[
                  "min-w-0 truncate",
                  String.ends_with?(event.type, "tool_use") && "text-info",
                  String.ends_with?(event.type, "error") && "text-error"
                ]}>
                  {String.replace_prefix(event.type, "job.harness.", "")}
                </span>
                <span class="col-start-2 min-w-0 truncate opacity-70 sm:col-start-3">
                  {Events.summary(event)}
                </span>
              </li>
            </ol>
            <div class="mt-3 flex flex-wrap items-center gap-2">
              <button
                :if={length(stream(@events, @notices)) > @shown}
                type="button"
                phx-click="more"
                class="min-h-[46px] rounded-field border border-base-300 px-4 text-sm hover:border-base-content/30"
              >
                Load 50 more
              </button>

              <%!-- Only when there is something behind it. A job whose harness said nothing about
                    itself should not carry a control that reveals nothing. --%>
              <button
                :if={telemetry_count(@events) > 0}
                type="button"
                phx-click="notices"
                id="job-notices"
                class="min-h-[46px] rounded-field px-4 text-sm opacity-60 hover:opacity-100"
              >
                {if @notices, do: "Hide", else: "Show"} {telemetry_count(@events)} harness notices
              </button>
            </div>
          </section>
        </div>

        <aside class="lg:w-[21rem] lg:shrink-0 lg:border-l lg:border-base-300 lg:pl-8">
          <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Pinned manifest</h2>
          <dl class="mt-3 flex flex-col gap-2 text-[12.5px]">
            <div class="flex min-w-0 justify-between gap-3">
              <dt class="opacity-50">branch</dt>
              <dd class="truncate font-mono">{@spec.branch}</dd>
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
                {@spec.budget.turns} turns · {Format.windows(@spec.budget.cost) || "—"}
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
            <li
              :for={name <- @spec.produces}
              class={not MapSet.member?(@written_names, name) && "opacity-50"}
            >
              {name}<span :if={not MapSet.member?(@written_names, name)} class="ml-2 opacity-70">not written</span>
            </li>
            <li :if={@spec.produces == []} class="opacity-50">nothing</li>
          </ul>

          <h3 class="mt-6 font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Wrote</h3>
          <ul class="mt-3 flex flex-col">
            <li :for={{artifact, version} <- @written}>
              <.link
                href={
                  ~p"/tickets/#{@project.name}/#{@ticket.number}/artifacts/#{version.version}/#{artifact.name}"
                }
                class="flex min-h-[46px] items-center gap-2 border-b border-base-300/60 font-mono text-[12.5px] hover:bg-base-200"
              >
                <span class="min-w-0 flex-1 truncate">{artifact.name}</span>
                <span class="shrink-0 opacity-60">v{version.version}</span>
                <span class="shrink-0 opacity-40" aria-hidden="true">›</span>
              </.link>
            </li>
            <li :if={@written == []} class="font-mono text-[12.5px] opacity-50">
              this run wrote nothing
            </li>
          </ul>

          <details class="mt-6">
            <summary class="cursor-pointer font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
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
