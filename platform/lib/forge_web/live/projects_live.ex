defmodule ForgeWeb.ProjectsLive do
  @moduledoc """
  The projects you are a member of (`docs/design/ui.md` § The projects page, `11a`–`11e`): what
  waits on you in each and what runs, then what each has to run on, waiting first. The rows are
  `ForgeWeb.ProjectRows`', which `ForgeWeb.ProjectNewLive` draws beside its form on a wide screen.

  With none (`11b`) it says how to get one, with the one fact someone needs to be added: the
  address they signed in with.
  """

  use ForgeWeb, :live_view

  alias Forge.{Events, Projects, Tickets}
  alias ForgeWeb.ProjectRows

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Events.subscribe()
      Events.subscribe_chats()
    end

    {:ok, socket |> assign(page_title: "Projects") |> load()}
  end

  defp load(socket) do
    rows = Projects.summaries(socket.assigns.current_scope.user)

    assign(socket,
      rows: rows,
      project_ids: MapSet.new(rows, & &1.project.id),
      now: DateTime.utc_now()
    )
  end

  # A ticket admitted, moved or finished changes a row's counts, and a conversation waiting on its
  # reader is one of them too. Both topics are global, so the change is matched against this
  # viewer's projects before the page reloads anything (`CLAUDE.md`). An assignment of a template,
  # machine or credential is not announced, and shows on the next visit. **The filter is
  # unobservable from outside**: a reload for another project's change draws the same rows, so
  # reloading always is an equivalent mutant the tests cannot catch — the rule it keeps is about
  # work, not output.
  @impl true
  def handle_info({:ticket_changed, id}, socket) do
    if Tickets.project_id(id) in socket.assigns.project_ids,
      do: {:noreply, load(socket)},
      else: {:noreply, socket}
  end

  def handle_info({:chat_changed, _id, project_id, _ticket_id}, socket) do
    if project_id in socket.assigns.project_ids,
      do: {:noreply, load(socket)},
      else: {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      frame={@frame}
      capacity={@capacity}
      title="Projects"
      subline={ProjectRows.subline(@rows)}
      top_level={:projects}
      context={if @rows != [], do: {"+ New", ~p"/projects/new"}}
      measure={if @rows == [], do: "34rem"}
    >
      <div :if={@rows == []} id="no-projects" class="project-none">
        <h2 class="project-none-title">You are in no project yet.</h2>
        <p>
          Make one, or ask someone in one to add you. They add you from the project's settings,
          by the address you signed in with.
        </p>
        <div id="your-address" class="project-address">
          <span>your address</span>
          <span class="project-address-value">{@current_scope.user.email}</span>
        </div>
      </div>

      <div :if={@rows != []} class="projects">
        <ProjectRows.list rows={@rows} now={@now} />
        <ProjectRows.table rows={@rows} now={@now} />
      </div>

      <:composer :if={@rows == []}>
        <div class="project-dock">
          <.button variant="primary" size="xl" fill navigate={~p"/projects/new"}>
            New project
          </.button>
        </div>
      </:composer>
    </Layouts.app>
    """
  end
end
