defmodule ForgeWeb.ProjectsLive do
  @moduledoc """
  The projects you are a member of, one row each, with what each has to run on
  (`docs/design/ui.md` § The projects page).

  Before it a project was reached from a ticket, a board column or a URL, and nothing answered
  "which projects are there, and can each of them run anything?". A project with no template or
  no credential takes no work, and looks fine everywhere else — so its row says so.
  """

  use ForgeWeb, :live_view

  alias Forge.{Events, Projects, Tickets}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe()
    {:ok, socket |> assign(page_title: "Projects") |> load()}
  end

  defp load(socket) do
    rows = Projects.summaries(socket.assigns.current_scope.user)
    assign(socket, rows: rows, project_ids: MapSet.new(rows, & &1.project.id))
  end

  # A ticket admitted or finished changes a row's count of open tickets. The topic is global, so
  # the event is filtered to this viewer's projects before the page reloads anything (`CLAUDE.md`).
  # An assignment of a template, machine or credential is not announced on it, and shows on the
  # next visit. **The filter is unobservable from outside**: a reload for another project's ticket
  # draws the same rows, so reloading always is an equivalent mutant the tests cannot catch — the
  # rule it keeps is about work, not output.
  @impl true
  def handle_info({:ticket_changed, id}, socket) do
    if Tickets.project_id(id) in socket.assigns.project_ids,
      do: {:noreply, load(socket)},
      else: {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      capacity={@capacity}
      active={:projects}
      measure="60rem"
    >
      <header class="flex flex-wrap items-baseline gap-x-4 gap-y-2">
        <h1 class="text-2xl font-semibold -tracking-[.025em]">Projects</h1>
        <.link
          navigate={~p"/projects/new"}
          class="ml-auto flex min-h-[46px] items-center rounded-field border border-base-300 px-3 text-sm hover:border-base-content/30"
        >
          New project
        </.link>
      </header>

      <p :if={@rows == []} id="no-projects" class="mt-6 text-sm/[1.55] opacity-60">
        You are in no project yet. Make one, or ask someone in one to add you.
      </p>

      <ul :if={@rows != []} class="mt-4">
        <li
          :for={row <- @rows}
          id={"project-#{row.project.id}"}
          class="border-b border-base-300/60 py-[15px]"
        >
          <.link
            navigate={~p"/projects/#{row.project.name}"}
            class="flex min-h-[46px] flex-wrap items-baseline gap-x-4 gap-y-1"
          >
            <span class="text-sm font-medium">{row.project.name}</span>
            <span class="font-mono text-[12.5px] opacity-60">
              {figures(row)}
            </span>
            <span :if={runs_nothing?(row)} class="text-[12.5px] text-error">
              {missing(row)}, so nothing runs
            </span>
            <span aria-hidden="true" class="ml-auto opacity-40">›</span>
          </.link>
        </li>
      </ul>
    </Layouts.app>
    """
  end

  defp figures(row) do
    Enum.join(
      [
        count(row.open_tickets, "open ticket"),
        count(row.templates, "template"),
        count(row.machines, "machine"),
        count(row.credentials, "credential")
      ],
      " · "
    )
  end

  # Nothing runs without a credential to pay for it, and nothing runs without somewhere to run:
  # a template to make a machine from, or a permanent machine assigned to the project.
  defp runs_nothing?(row), do: row.credentials == 0 or no_machine?(row)

  defp no_machine?(row), do: row.templates == 0 and row.machines == 0

  defp missing(row) do
    case {no_machine?(row), row.credentials == 0} do
      {true, true} -> "no template or machine, and no credential"
      {true, false} -> "no template or machine"
      {false, true} -> "no credential"
    end
  end

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"
end
