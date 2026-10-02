defmodule ForgeWeb.ReviewLive do
  @moduledoc """
  The merge decision: the diff, beside what only the platform knows about it.

  The diff on its own is what any forge shows. What this page adds is the chain of documents the
  change was built from, the verification report at the end of it, every question a person
  answered along the way, and what the whole ticket consumed — so the decision is taken on the
  reasoning rather than on the patch alone.

  Approval pins an exact `changeset` version, which is an exact commit. The diff is bounded, and
  says where it was bound rather than trailing off. See `docs/design/ui.md`.
  """

  use ForgeWeb, :live_view

  import ForgeWeb.Indicators
  import ForgeWeb.Operator.Components

  alias Forge.{Artifacts, Events, Merge, Projects, Tickets}
  alias ForgeCore.Workflow
  alias ForgeWeb.{Diff, Format, Markdown}
  alias ForgeWeb.Operator.Actions
  alias ForgeWeb.Operator.Board

  # Beyond this the patch is offered per file instead. A page nobody can read is not a review.
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
    changeset = Artifacts.latest(ticket.id, Workflow.changeset_artifact())

    assign(socket,
      page_title: "#{project.name}##{ticket.number} review",
      ticket: ticket,
      workflow: workflow,
      changeset: changeset,
      merged: Merge.merged?(ticket),
      diff: diff(project, ticket, changeset),
      documents: documents(ticket),
      answers: Artifacts.answered(ticket.id),
      pending: ticket.pending_transition,
      approve: approve_pins(project, ticket, changeset),
      now: DateTime.utc_now()
    )
  end

  # The map of the change is never truncated; the patch under it may be.
  defp diff(_project, _ticket, nil), do: nil

  defp diff(project, ticket, %{blob_uri: "git:" <> head}),
    do: Diff.build(Projects.repo_path(project), ticket.base_commit, head)

  defp diff(_project, _ticket, %{blob_uri: other}), do: %{error: {:not_a_commit, other}}

  # The chain the change was built from, in the order it was written. The last document is the
  # verification report in every workflow that has one; naming it by convention would hard-code a
  # state name the grammar leaves to the project.
  defp documents(ticket) do
    for artifact <- Artifacts.list(ticket.id),
        artifact.kind == :document,
        version = Artifacts.latest(ticket.id, artifact.name),
        version != nil do
      %{
        name: artifact.name,
        version: version,
        approved: Artifacts.approved?(version),
        html: Markdown.to_html(version.content)
      }
    end
    |> Enum.sort_by(& &1.version.inserted_at, DateTime)
  end

  defp approve_pins(project, ticket, changeset) do
    for name <- Forge.Engine.awaiting_approval(ticket),
        changeset && name == Workflow.changeset_artifact(),
        do: pinned(project.name, ticket, name, changeset)
  end

  @impl true
  def handle_info({:ticket_changed, id}, %{assigns: %{ticket_id: id}} = socket),
    do: {:noreply, load(socket)}

  def handle_info({:ticket_changed, _other}, socket), do: {:noreply, socket}

  @impl true
  def handle_event(event, params, socket) do
    case Actions.handle(event, params, socket) do
      {:handled, socket} -> {:noreply, load(socket)}
      {:state, socket} -> {:noreply, socket}
      :unknown -> {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} capacity={@capacity} measure="74rem">
      <.link
        navigate={~p"/tickets/#{@project.name}/#{@ticket.number}"}
        class="flex min-h-[46px] items-center font-mono text-[12.5px] opacity-60 hover:opacity-100"
      >
        ‹ {@project.name}#{@ticket.number} · {@ticket.title}
      </.link>

      <header class="mt-4 flex flex-col gap-2">
        <div class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">The change</div>
        <h1 class="text-[23px] font-semibold -tracking-[.03em] sm:text-3xl">{@ticket.title}</h1>
        <div class="flex flex-wrap items-center gap-3">
          <.state name={@ticket.state} topology={Board.topology(@workflow, @ticket.state)} />
          <.status_flag status={@ticket.status} age={Format.ago(@ticket.updated_at, @now)} />
          <span :if={@merged} class="font-mono text-[12.5px] text-success">✓ merged</span>
        </div>
      </header>

      <section
        :if={@pending && @approve != []}
        class="mt-6 rounded-box border border-accent bg-accent/5 p-4"
        id="merge-decision"
      >
        <h2 class="font-mono text-[11px] tracking-[.14em] uppercase text-accent">Waiting on you</h2>
        <div class="mt-3">
          <.approval_card ticket={@ticket} pending={@pending} approve={@approve} />
        </div>
      </section>

      <p :if={is_nil(@changeset)} class="mt-6 text-sm/[1.55] opacity-70">
        No job has produced a changeset on this ticket yet. The state that declares
        <span class="font-mono text-[12.5px]">changeset</span>
        records one when it finishes.
      </p>

      <div :if={@changeset} class="mt-8 flex flex-col gap-10 lg:flex-row lg:gap-0">
        <div class="lg:min-w-0 lg:flex-1 lg:pr-8">
          <Diff.section diff={@diff} id="review-diff" />

          <section :if={@documents != []} class="mt-8 border-t border-base-300 pt-5">
            <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
              What it was built from
            </h2>
            <details
              :for={doc <- @documents}
              class="mt-3 min-w-0"
              id={"review-doc-#{doc.name}"}
            >
              <summary class="flex min-h-[46px] cursor-pointer items-center gap-2 font-mono text-[12.5px]">
                {doc.name}
                <span class="opacity-60">v{doc.version.version}</span>
                <span :if={doc.approved} class="text-success">✓ approved</span>
              </summary>
              <div class="mt-2 min-w-0 rounded-box bg-base-200 px-4 py-3">
                <div class="doc">{doc.html}</div>
                <.link
                  href={
                    ~p"/tickets/#{@project.name}/#{@ticket.number}/artifacts/#{doc.name}/#{doc.version.version}"
                  }
                  class="mt-3 flex min-h-[46px] items-center font-mono text-[12.5px] text-primary hover:underline"
                >
                  source ›
                </.link>
              </div>
            </details>
          </section>

          <section class="mt-8 border-t border-base-300 pt-5" id="review-answers">
            <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
              Questions answered
            </h2>
            <ol :if={@answers != []} class="mt-3 flex flex-col gap-5">
              <li :for={entry <- @answers} class="flex flex-col gap-1.5">
                <blockquote
                  :if={entry.question.anchor}
                  class="border-l-2 border-base-300 pl-3 text-sm/[1.55] opacity-70"
                >
                  {entry.question.anchor}
                </blockquote>
                <p class="text-sm/[1.55]">{entry.question.text}</p>
                <p class="text-sm/[1.55]">
                  <span class="opacity-50">answered</span>
                  <span :if={entry.answer.choice} class="font-mono text-[12.5px]">
                    {entry.answer.choice}
                  </span>
                  <span :if={entry.answer.text}>{entry.answer.text}</span>
                </p>
                <div class="font-mono text-[12.5px] opacity-50">
                  {entry.question.key} ·
                  <.link
                    href={
                      ~p"/tickets/#{@project.name}/#{@ticket.number}/artifacts/#{entry.artifact}/#{entry.version}"
                    }
                    class="hover:opacity-100"
                  >
                    {entry.artifact} v{entry.version}
                  </.link>
                </div>
              </li>
            </ol>
            <p :if={@answers == []} class="mt-3 text-sm/[1.55] opacity-60">
              No question stopped a job on this ticket. Everything the agents needed, they had.
            </p>
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
            <.fact label="changeset" value={"v#{@changeset.version}"} />
            <.fact label="commit" value={short(@diff[:head])} />
            <.fact label="base" value={short(@ticket.base_commit)} />
            <.fact label="branch" value={@ticket.branch} />
            <.fact label="files" value={files_label(@diff)} />
            <.fact label="lines" value={lines_label(@diff)} />
          </dl>
        </aside>
      </div>
    </Layouts.app>
    """
  end

  defp short(nil), do: "—"
  defp short(sha), do: String.slice(sha, 0, 12)

  defp files_label(%{files: files}), do: Integer.to_string(length(files))
  defp files_label(_diff), do: "—"

  defp lines_label(%{added: added, removed: removed}), do: "+#{added} −#{removed}"
  defp lines_label(_diff), do: "—"

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
