defmodule ForgeWeb.TicketLive do
  @moduledoc """
  One ticket: what happened to it, what it cost, and the one thing it may be waiting for.

  The spine is ordered by **time, not topology** — a step is a visit to a state, so a revisit is
  another step further down with the same name. Stuck is drawn on the step it happened in, never
  as a step of its own, because there is no such state. If the ticket has an answerable action it
  is hoisted once, directly under the header; everything below it is reference.
  """

  use ForgeWeb, :live_view

  import ForgeWeb.Indicators
  import ForgeWeb.Operator.Components

  alias Forge.{Artifacts, Events, Jobs, Proposals, Spend, Tickets}
  alias ForgeCore.Workflow
  alias ForgeWeb.{Format, Indicators, Markdown}
  alias ForgeWeb.Operator.Actions
  alias ForgeWeb.Operator.Board

  @impl true
  def mount(%{"project" => name, "number" => number}, _session, socket) do
    {ticket, project} = Tickets.fetch!(name, number)
    ForgeWeb.Access.project_scope!(socket.assigns.current_scope, project)
    if connected?(socket), do: Events.subscribe()

    {:ok,
     socket
     |> assign(project: project, ticket_id: ticket.id)
     |> ForgeWeb.Capacity.project(project)
     |> load()}
  end

  defp load(%{assigns: %{ticket_id: id, project: project}} = socket) do
    ticket = Tickets.get!(id)
    workflow = Tickets.workflow(ticket)
    jobs = Jobs.for_ticket(ticket.id)

    # Approval state is shown only where approval is possible: an artifact no transition lists in
    # `approve:` would otherwise be marked `unapproved` for ever, flagging a job the operator does
    # not have. See docs/design/ui.md § Semantics that must not be lost.
    approvable = Artifacts.approvable(workflow)

    artifacts =
      for artifact <- Artifacts.list(ticket.id) do
        latest = Artifacts.latest(ticket.id, artifact.name)

        %{
          artifact: artifact,
          latest: latest,
          approved: Artifacts.approved?(latest),
          approvable:
            artifact.kind != :presentation and MapSet.member?(approvable, artifact.name),
          html: artifact.kind == :document && latest && Markdown.to_html(latest.content)
        }
      end

    assign(socket,
      page_title: "#{project.name}##{ticket.number}",
      ticket: ticket,
      workflow: workflow,
      questions: Artifacts.open_questions(ticket.id),
      jobs: jobs,
      steps: steps(jobs, artifacts, ticket, workflow),
      artifacts: artifacts,
      events: ticket.id |> Events.for_ticket() |> Enum.reverse() |> Enum.take(4),
      transitions:
        workflow |> Workflow.transitions_from(ticket.state) |> Enum.map(& &1.to) |> Enum.uniq(),
      human_state:
        ticket.status in [:active, :stuck] and
          not Workflow.State.job?(Workflow.state(workflow, ticket.state)),
      approve: approve_versions(ticket),
      proposals: Proposals.open_for_ticket(ticket.id),
      reviewable: reviewable?(ticket, workflow),
      paused: ticket.status == :active and Spend.paused?(),
      until_midnight: until_midnight(),
      now: DateTime.utc_now()
    )
  end

  # The rail names what this ticket's jobs proposed and sends the decision to the project page,
  # where every proposal on the project is in one place. Deciding here too would put the same
  # affordance in two places, and one of them would be the one you did not open.
  defp proposal_title(version) do
    case ForgeCore.Proposal.parse(version.content || "") do
      {:ok, proposal} -> proposal.title
      {:error, _errors} -> "(could not be read)"
    end
  end

  # One step per state visit, in the order the jobs ran. A state the ticket reached without a
  # job — a human state it is resting in — still gets its step, because the operator is looking
  # for where the ticket is, not only for where work happened.
  defp steps(jobs, artifacts, ticket, workflow) do
    visits =
      jobs
      |> Enum.chunk_by(& &1.state)
      |> Enum.map(fn group ->
        %{
          name: hd(group).state,
          jobs: group,
          artifacts: Enum.filter(artifacts, &written_in?(&1, group)),
          cost: Enum.reduce(group, Decimal.new(0), &Decimal.add(&2, &1.cost_usd))
        }
      end)

    if Enum.any?(visits, &(&1.name == ticket.state)) do
      visits
    else
      visits ++ [%{name: ticket.state, jobs: [], artifacts: [], cost: Decimal.new(0)}]
    end
    |> Enum.map(&Map.put(&1, :topology, Board.topology(workflow, &1.name)))
  end

  defp written_in?(%{latest: nil}, _jobs), do: false

  defp written_in?(%{latest: latest}, jobs) do
    case latest.author do
      %{"kind" => "job", "id" => id} -> Enum.any?(jobs, &(&1.id == id))
      _other -> false
    end
  end

  defp approve_versions(%{pending_transition: pending}) when is_map(pending), do: pending
  defp approve_versions(_ticket), do: nil

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
    <Layouts.app flash={@flash} current_scope={@current_scope} capacity={@capacity} measure="74rem">
      <header class="flex flex-col gap-2">
        <div class="font-mono text-[12.5px] opacity-60">
          <.link navigate={~p"/projects/#{@project.name}"} class="hover:opacity-100">
            {@project.name}
          </.link>#{@ticket.number}
        </div>
        <h1 class="text-[23px] font-semibold -tracking-[.03em] sm:text-3xl">{@ticket.title}</h1>
        <div class="flex flex-wrap items-center gap-3">
          <.state name={@ticket.state} topology={Board.topology(@workflow, @ticket.state)} />
          <.status_flag status={@ticket.status} age={Format.ago(@ticket.updated_at, @now)} />
          <.paused :if={@paused} reason="spend" until={@until_midnight} />
          <span :if={waiting_clause(assigns)} class="text-sm opacity-70">
            {waiting_clause(assigns)}
          </span>
        </div>
        <p :if={@ticket.body != ""} class="mt-2 text-sm/[1.55] whitespace-pre-line opacity-80">
          {@ticket.body}
        </p>
        <div class="flex flex-wrap items-center gap-4">
          <.link
            navigate={~p"/chats/new?project=#{@project.name}&ticket=#{@ticket.number}"}
            class="flex min-h-[46px] items-center text-sm text-primary hover:underline"
          >
            New chat ›
          </.link>
        </div>
      </header>

      <section
        :if={@ticket.pending_transition || @questions != [] || stuck_or_human?(assigns)}
        class="mt-6 rounded-box border border-accent bg-accent/5 p-4"
        id="hoisted-decision"
      >
        <h2 class="font-mono text-[11px] tracking-[.14em] uppercase text-accent">Waiting on you</h2>
        <div class="mt-3">
          <.approval_card
            :if={@ticket.pending_transition}
            ticket={@ticket}
            pending={@ticket.pending_transition}
            approve={approve_pairs(@approve, @artifacts)}
          />

          <.link
            :if={@reviewable}
            navigate={~p"/tickets/#{@project.name}/#{@ticket.number}/review"}
            class="mt-2 flex min-h-[46px] items-center text-sm text-primary hover:underline"
          >
            Read the change first ›
          </.link>
          <div :if={!@ticket.pending_transition and @questions != []} class="flex flex-col gap-6">
            <.question_card :for={q <- @questions} question={q} ticket_id={@ticket.id} />
          </div>
          <.transition_card
            :if={!@ticket.pending_transition and @questions == [] and stuck_or_human?(assigns)}
            ticket={@ticket}
            transitions={@transitions}
          />
        </div>
      </section>

      <div class="mt-8 flex flex-col gap-10 lg:flex-row lg:gap-0">
        <div class="lg:min-w-0 lg:flex-1 lg:pr-8">
          <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Timeline</h2>

          <ol class="mt-4">
            <li :for={step <- @steps} class="grid grid-cols-[26px_1fr] pb-5 lg:pb-[26px]">
              <div class="flex flex-col items-center">
                <span class={[
                  "mt-1.5 size-[11px] rounded-full",
                  if(step.name == @ticket.state,
                    do: "bg-accent ring-4 ring-accent/20",
                    else: "bg-base-300"
                  )
                ]} />
                <span class="mt-1 w-px flex-1 bg-base-300" />
              </div>

              <div class="pb-2">
                <div class="flex flex-wrap items-baseline justify-between gap-2">
                  <.state name={step.name} topology={step.topology} />
                  <span :if={step.jobs != []} class="font-mono text-[12.5px] opacity-50">
                    {length(step.jobs)} {if length(step.jobs) == 1, do: "job", else: "jobs"} · {Format.windows(
                      step.cost
                    ) || "—"}
                  </span>
                </div>

                <%!-- The whole row is the target, at the full 46px: hunting for a 20px `#3` is
                      the failure docs/design/ui.md § The affordance rule names. Nothing inside
                      a job row commits anything, so the row may be a link. --%>
                <ol :if={step.jobs != []} class="mt-2 flex flex-col">
                  <li :for={job <- step.jobs}>
                    <.link
                      navigate={~p"/tickets/#{@project.name}/#{@ticket.number}/jobs/#{job.id}"}
                      class="flex min-h-[46px] items-center gap-3 border-b border-base-300/60 text-[12.5px] hover:bg-base-200"
                    >
                      <span class="w-8 shrink-0 font-mono">#{job.attempt}</span>
                      <span class="min-w-0 flex-1">
                        <.outcome
                          :if={job.declared_outcome || job.outcome}
                          value={job.declared_outcome || to_string(job.outcome)}
                          bucket={job.declared_outcome && Indicators.bucket(job.outcome)}
                        />
                        <.job_status :if={is_nil(job.outcome)} status={job.status} />
                      </span>
                      <span class="shrink-0 font-mono opacity-60">{job.turns} turns</span>
                      <span class="w-20 shrink-0 text-right font-mono opacity-60">
                        {Format.windows(job.cost_usd) || "—"}
                      </span>
                      <span class="shrink-0 font-mono opacity-40" aria-hidden="true">›</span>
                    </.link>
                  </li>
                </ol>

                <div :if={step.artifacts != []} class="mt-2 flex flex-wrap gap-2">
                  <.artifact_chip
                    :for={entry <- step.artifacts}
                    entry={entry}
                    project={@project.name}
                    number={@ticket.number}
                  />
                </div>
              </div>
            </li>
          </ol>

          <%!-- Until the document-with-margin-questions view exists, this disclosure is how a
                rendered document is read; `source ›` is the exact bytes behind it. The body is
                `.doc` on base-200: a document is the one thing on the page the product did not
                write, and it is contained so it can never widen this column into the rail. See
                docs/design/ui.md § Documents. --%>
          <section :if={Enum.any?(@artifacts, & &1.html)} class="mt-6 border-t border-base-300 pt-5">
            <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Documents</h2>
            <details
              :for={entry <- Enum.filter(@artifacts, & &1.html)}
              class="mt-3 min-w-0"
              id={"artifact-#{entry.artifact.id}"}
            >
              <summary class="flex min-h-[46px] cursor-pointer items-center gap-2 font-mono text-[12.5px]">
                {entry.artifact.name}
                <span class="opacity-60">v{entry.latest.version}</span>
              </summary>
              <div class="mt-2 min-w-0 rounded-box bg-base-200 px-4 py-3">
                <div class="doc">{entry.html}</div>
                <.link
                  href={
                    ~p"/tickets/#{@project.name}/#{@ticket.number}/artifacts/#{entry.artifact.name}/#{entry.latest.version}"
                  }
                  class="mt-3 flex min-h-[46px] items-center font-mono text-[12.5px] text-primary hover:underline"
                >
                  source ›
                </.link>
              </div>
            </details>
          </section>
        </div>

        <aside class="lg:w-[21rem] lg:shrink-0 lg:border-l lg:border-base-300 lg:pl-8">
          <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Usage</h2>
          <div class="mt-3">
            <div class="font-mono text-[17px]">{Format.windows(@ticket.cost_usd) || "—"}</div>
            <div class="mt-2 h-[5px] w-full bg-base-300">
              <div class="h-full bg-accent" style={"width: #{usage_pct(@ticket, @workflow)}%"} />
            </div>
            <div class="mt-1 font-mono text-[11px] opacity-50">
              allowance {Format.windows(@workflow.limits.ticket_cost) || "—"}
            </div>
          </div>

          <h2 class="mt-6 font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Facts</h2>
          <dl class="mt-3 flex flex-col gap-2 text-[12.5px]">
            <.fact label="branch">{@ticket.branch}</.fact>
            <.fact label="base">{String.slice(@ticket.base_commit || "", 0, 12)}</.fact>
            <.fact label="workflow">{String.slice(@ticket.workflow_commit || "", 0, 12)}</.fact>
            <.fact label="admitted">{Format.ago(@ticket.inserted_at, @now)} ago</.fact>
          </dl>

          <h2
            :if={@proposals != []}
            class="mt-6 font-mono text-[11px] tracking-[.14em] uppercase opacity-60"
          >
            Proposed here
          </h2>
          <ul :if={@proposals != []} class="mt-3 flex flex-col gap-2 text-[12.5px]">
            <li :for={p <- @proposals} class="opacity-70">{proposal_title(p.version)}</li>
          </ul>
          <p :if={@proposals != []} class="mt-2 text-[12.5px] opacity-50">
            Waiting on you, on <.link
              navigate={~p"/projects/#{@project.name}"}
              class="hover:underline"
            >
              the project page
            </.link>.
          </p>

          <h2 class="mt-6 font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Artifacts</h2>
          <div class="mt-3 flex flex-wrap gap-2">
            <.artifact_chip
              :for={entry <- @artifacts}
              entry={entry}
              project={@project.name}
              number={@ticket.number}
            />
            <p :if={@artifacts == []} class="text-sm opacity-50">
              The first job writes the first document.
            </p>
          </div>

          <h2 class="mt-6 font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
            Last four events
          </h2>
          <ol class="mt-3 flex flex-col gap-1 font-mono text-[12.5px]">
            <li :for={event <- @events} class="flex gap-2">
              <span class="shrink-0 opacity-50">
                {Calendar.strftime(event.inserted_at, "%m-%d %H:%M")}
              </span>
              <span class="truncate">{event.type}</span>
            </li>
          </ol>
        </aside>
      </div>
    </Layouts.app>
    """
  end

  # There is no chip without a version: approval attaches to an exact version, and a human edit
  # creating v3 does not carry v2's approval. A presentation has no approval slot at all, and
  # neither has an artifact the pinned workflow never approves — see docs/design/ui.md.
  #
  # The chip is a link to the exact version's bytes, which is also why it is bordered: a border
  # means you can tap it. A changeset is a commit rather than a file and the controller sends it
  # to the review page, where a diff is rendered.
  attr :entry, :map, required: true
  attr :project, :string, required: true
  attr :number, :integer, required: true

  defp artifact_chip(assigns) do
    ~H"""
    <.link
      :if={@entry.latest}
      href={
        ~p"/tickets/#{@project}/#{@number}/artifacts/#{@entry.artifact.name}/#{@entry.latest.version}"
      }
      class={[
        "inline-flex min-h-[46px] items-center gap-1.5 rounded-field px-2 py-1 font-mono text-[12.5px] hover:bg-base-200",
        if(@entry.artifact.kind == :presentation,
          do: "border border-dashed border-base-300",
          else: "border border-base-300"
        )
      ]}
    >
      {@entry.artifact.name}
      <span class="opacity-60">v{@entry.latest.version}</span>
      <span :if={@entry.artifact.kind == :presentation} class="tracking-[.14em] uppercase opacity-50">
        view only
      </span>
      <span :if={@entry.approvable and @entry.approved} class="text-success">✓ approved</span>
      <span :if={@entry.approvable and not @entry.approved} class="text-warning">◇ unapproved</span>
    </.link>
    """
  end

  defp stuck_or_human?(assigns),
    do: (assigns.ticket.status == :stuck or assigns.human_state) and assigns.transitions != []

  defp waiting_clause(%{ticket: %{status: :stuck}}), do: "Stuck, and waiting for you to choose."

  defp waiting_clause(%{ticket: %{pending_transition: p}}) when is_map(p),
    do: "Waiting for approval."

  defp waiting_clause(%{questions: [_ | _]}), do: "A job stopped to ask you something."
  defp waiting_clause(_assigns), do: nil

  # A decision that pins the changeset is a merge decision, which has a page of its own — whether
  # it is waiting as a pending approval or as the transition out of the state the ticket rests in.
  defp reviewable?(%{pending_transition: pending}, _workflow) when is_map(pending),
    do: Workflow.changeset_artifact() in List.wrap(pending["approve"])

  defp reviewable?(ticket, workflow) do
    workflow
    |> Workflow.transitions_from(ticket.state)
    |> Enum.any?(&(Workflow.changeset_artifact() in &1.approve))
  end

  defp approve_pairs(nil, _artifacts), do: []

  defp approve_pairs(pending, artifacts) do
    for name <- List.wrap(pending["approve"]),
        entry = Enum.find(artifacts, &(&1.artifact.name == name)),
        entry && entry.latest,
        do: {name, entry.latest.version}
  end

  # The daily cap is resolved by the clock, so the figure beside it is a countdown, not an age.
  defp until_midnight do
    now = DateTime.utc_now()
    {:ok, midnight} = DateTime.new(Date.add(DateTime.to_date(now), 1), ~T[00:00:00], "Etc/UTC")

    case DateTime.diff(midnight, now, :second) do
      s when s < 3600 -> "#{div(s, 60)}m"
      s -> "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"
    end
  end

  defp usage_pct(ticket, workflow) do
    cap = workflow.limits.ticket_cost

    if is_number(cap) and cap > 0 do
      ticket.cost_usd
      |> Decimal.to_float()
      |> Kernel./(cap)
      |> Kernel.*(100)
      |> min(100)
      |> round()
    else
      0
    end
  end
end
