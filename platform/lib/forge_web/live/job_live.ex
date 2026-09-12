defmodule ForgeWeb.JobLive do
  @moduledoc "One job: the pinned manifest it ran with, and what the harness did."

  use ForgeWeb, :live_view

  import ForgeWeb.Operator.Components

  alias Forge.{Events, Jobs, Tickets}

  @impl true
  def mount(%{"project" => name, "number" => number, "job_id" => job_id}, _session, socket) do
    {ticket, project} = Tickets.fetch!(name, number)

    job =
      Enum.find(Jobs.for_ticket(ticket.id), &(&1.id == job_id)) ||
        raise Ecto.NoResultsError, queryable: Jobs.Job

    if connected?(socket), do: Events.subscribe()

    {:ok, socket |> assign(project: project, ticket: ticket, job_id: job.id) |> load()}
  end

  defp load(%{assigns: %{job_id: job_id, ticket: ticket, project: project}} = socket) do
    job = Jobs.get!(job_id)
    spec = Jobs.spec(job)

    assign(socket,
      page_title: "#{project.name}##{ticket.number} · #{job.state} ##{job.attempt}",
      job: job,
      spec: spec,
      events: Events.for_job(job.id)
    )
  end

  @impl true
  def handle_info({:ticket_changed, id}, %{assigns: %{ticket: %{id: id}}} = socket),
    do: {:noreply, load(socket)}

  def handle_info({:ticket_changed, _}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-2xl flex flex-col gap-6">
        <header class="flex flex-col gap-1">
          <.link
            navigate={~p"/tickets/#{@project.name}/#{@ticket.number}"}
            class="text-sm link link-hover opacity-60"
          >
            ← {@project.name}#{@ticket.number} · {@ticket.title}
          </.link>
          <h1 class="text-xl font-semibold font-mono">{@job.state} #{@job.attempt}</h1>
          <div class="flex flex-wrap items-center gap-2 text-sm">
            <.status_badge status={@job.status} />
            <span :if={@job.outcome}>{@job.outcome}{if @job.declared_outcome,
              do: " (#{@job.declared_outcome})"}</span>
            <span class="opacity-60">{@job.turns} turns · ${@job.cost_usd}</span>
            <span :if={@job.harness_session_id} class="font-mono opacity-60">session {@job.harness_session_id}</span>
          </div>
        </header>

        <section class="flex flex-col gap-2">
          <h2 class="font-medium">Pinned manifest</h2>
          <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
            <dt class="opacity-60">Branch</dt>
            <dd class="font-mono">{@spec.branch}</dd>
            <dt class="opacity-60">Workflow commit</dt>
            <dd class="font-mono truncate">{@spec.commit}</dd>
            <dt class="opacity-60">Environment</dt>
            <dd class="font-mono">{@spec.env || "none"}</dd>
            <dt class="opacity-60">Budget</dt>
            <dd>{@spec.budget.turns} turns · ${@spec.budget.cost}</dd>
            <dt class="opacity-60">Outcomes</dt>
            <dd class="font-mono">{Enum.join(@spec.outcomes, ", ")}</dd>
          </dl>
          <h3 class="text-sm font-medium mt-2">Inputs</h3>
          <ul class="text-sm font-mono">
            <li :for={input <- @spec.inputs}>{input.name} · {input.version}</li>
            <li :if={@spec.inputs == []} class="opacity-60">none</li>
          </ul>
          <h3 class="text-sm font-medium mt-2">Produces</h3>
          <ul class="text-sm font-mono">
            <li :for={name <- @spec.produces}>{name}</li>
          </ul>
          <details class="collapse collapse-arrow bg-base-200">
            <summary class="collapse-title text-sm">State prompt ({@spec.prompt_path})</summary>
            <div class="collapse-content">
              <pre class="text-xs whitespace-pre-wrap">{@spec.prompt}</pre>
            </div>
          </details>
        </section>

        <section class="flex flex-col gap-2">
          <h2 class="font-medium">Harness events</h2>
          <ol class="flex flex-col gap-1 text-xs font-mono" id="job-events">
            <li :for={event <- @events} class="flex gap-2">
              <span class="opacity-50 shrink-0">{Calendar.strftime(event.inserted_at, "%H:%M:%S")}</span>
              <span class="shrink-0">{String.replace_prefix(event.type, "job.harness.", "")}</span>
              <span class="opacity-70 break-all">{Events.summary(event)}</span>
            </li>
          </ol>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
