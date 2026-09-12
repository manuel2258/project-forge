defmodule ForgeWeb.TicketLive do
  @moduledoc "One ticket: state, pending decision, open questions, jobs, artifacts, events."

  use ForgeWeb, :live_view

  import ForgeWeb.Operator.Components

  alias Forge.{Artifacts, Events, Jobs, Tickets}
  alias ForgeCore.Workflow
  alias ForgeWeb.Markdown
  alias ForgeWeb.Operator.Actions

  @impl true
  def mount(%{"project" => name, "number" => number}, _session, socket) do
    {ticket, project} = Tickets.fetch!(name, number)
    if connected?(socket), do: Events.subscribe()

    {:ok, socket |> assign(project: project, ticket_id: ticket.id) |> load()}
  end

  defp load(%{assigns: %{ticket_id: id, project: project}} = socket) do
    ticket = Tickets.get!(id)
    workflow = Tickets.workflow(ticket)

    artifacts =
      for artifact <- Artifacts.list(ticket.id) do
        latest = Artifacts.latest(ticket.id, artifact.name)

        %{
          artifact: artifact,
          latest: latest,
          html: artifact.kind == :document && Markdown.to_html(latest.content)
        }
      end

    assign(socket,
      page_title: "#{project.name}##{ticket.number}",
      ticket: ticket,
      questions: Artifacts.open_questions(ticket.id),
      jobs: Jobs.for_ticket(ticket.id),
      artifacts: artifacts,
      events:
        ticket.id
        |> Events.for_ticket()
        |> Enum.reject(&String.starts_with?(&1.type, "job.harness."))
        |> Enum.reverse(),
      transitions:
        workflow |> Workflow.transitions_from(ticket.state) |> Enum.map(& &1.to) |> Enum.uniq(),
      human_state:
        ticket.status in [:active, :stuck] and
          not Workflow.State.job?(Workflow.state(workflow, ticket.state))
    )
  end

  @impl true
  def handle_info({:ticket_changed, id}, %{assigns: %{ticket_id: id}} = socket),
    do: {:noreply, load(socket)}

  def handle_info({:ticket_changed, _other}, socket), do: {:noreply, socket}

  @impl true
  def handle_event(event, params, socket) do
    case Actions.handle(event, params, socket) do
      {:handled, socket} -> {:noreply, load(socket)}
      :unknown -> {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-2xl flex flex-col gap-6">
        <header class="flex flex-col gap-1">
          <div class="text-sm opacity-60">{@project.name}#{@ticket.number}</div>
          <h1 class="text-xl font-semibold">{@ticket.title}</h1>
          <div class="flex flex-wrap items-center gap-2 text-sm">
            <span class="font-mono">{@ticket.state}</span>
            <.status_badge status={@ticket.status} />
            <span class="opacity-60">${@ticket.cost_usd}</span>
            <span class="font-mono opacity-60">{@ticket.branch}</span>
          </div>
          <p :if={@ticket.body != ""} class="text-sm opacity-80 whitespace-pre-line">
            {@ticket.body}
          </p>
        </header>

        <section :if={@ticket.pending_transition} class="flex flex-col gap-2">
          <.approval_card ticket={@ticket} pending={@ticket.pending_transition} />
        </section>

        <section :if={@questions != []} class="flex flex-col gap-2">
          <h2 class="font-medium">Open questions</h2>
          <.question_card :for={q <- @questions} question={q} ticket_id={@ticket.id} />
        </section>

        <section :if={(@ticket.status == :stuck or @human_state) and @transitions != []}>
          <.transition_card
            ticket={@ticket}
            transitions={@transitions}
            label={if @ticket.status == :stuck, do: "Stuck", else: "Human state"}
          />
        </section>

        <section class="flex flex-col gap-2">
          <h2 class="font-medium">Jobs</h2>
          <ul class="flex flex-col gap-1">
            <li :for={job <- @jobs} class="flex flex-wrap items-center gap-2 text-sm">
              <.link
                navigate={~p"/tickets/#{@project.name}/#{@ticket.number}/jobs/#{job.id}"}
                class="link link-hover font-mono"
              >
                {job.state} #{job.attempt}
              </.link>
              <.status_badge status={job.status} />
              <span :if={job.outcome} class="opacity-70">{job.outcome}{if job.declared_outcome,
                do: " (#{job.declared_outcome})"}</span>
              <span class="opacity-60">{job.turns} turns · ${job.cost_usd}</span>
            </li>
          </ul>
        </section>

        <section class="flex flex-col gap-2">
          <h2 class="font-medium">Artifacts</h2>
          <details
            :for={entry <- @artifacts}
            class="collapse collapse-arrow bg-base-200"
            id={"artifact-#{entry.artifact.id}"}
          >
            <summary class="collapse-title text-sm font-mono">
              {entry.artifact.name} · v{entry.latest.version} · {entry.artifact.kind}
            </summary>
            <div class="collapse-content text-sm">
              <div :if={entry.html} class="prose prose-sm max-w-none">{entry.html}</div>
              <p :if={!entry.html} class="font-mono opacity-70">{entry.latest.blob_uri}</p>
            </div>
          </details>
        </section>

        <section class="flex flex-col gap-2">
          <h2 class="font-medium">Timeline</h2>
          <ol class="flex flex-col gap-1 text-xs font-mono">
            <li :for={event <- @events} class="flex gap-2">
              <span class="opacity-50 shrink-0">{Calendar.strftime(event.inserted_at, "%m-%d %H:%M")}</span>
              <span>{event.type}</span>
              <span class="opacity-60 truncate">{Events.summary(event)}</span>
            </li>
          </ol>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
