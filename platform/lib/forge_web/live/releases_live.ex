defmodule ForgeWeb.ReleasesLive do
  @moduledoc """
  A project's releases, newest first (`docs/design/ui.md` § A project's releases).

  Nothing here writes, so a reconnect has nothing to lose. **How many are shown is the URL's**
  (`?shown=40`): *Show more* is a link, not a socket event, so the count survives a reconnect and
  a reload, and no release is unreachable however many there are.
  """

  use ForgeWeb, :live_view

  alias Forge.{Events, ReleaseRecords, ReleaseTickets, Tickets}
  alias ForgeWeb.ReleaseComponents

  @step 20

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    {project, _scope} = ForgeWeb.Access.project_by_name!(socket.assigns.current_scope, name)
    if connected?(socket), do: Events.subscribe()

    {:ok,
     socket
     |> assign(
       project: project,
       page_title: "#{project.name} releases",
       shown: @step,
       next: 2 * @step
     )
     |> ForgeWeb.Capacity.project(project)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    shown = shown(params["shown"])
    {:noreply, socket |> assign(shown: shown, next: shown + @step) |> load()}
  end

  # Anything that is not a whole number above one step reads as one step: the address is a
  # person's to type, and a bad one is the first page, not an error.
  defp shown(value) do
    case Integer.parse(value || "") do
      {count, ""} when count > @step -> min(count, 100_000)
      _other -> @step
    end
  end

  defp load(%{assigns: %{project: project, shown: shown}} = socket) do
    types = Tickets.types(project)

    assign(socket,
      records: ReleaseRecords.list(project, shown),
      count: ReleaseRecords.count(project),
      open: ReleaseTickets.open(project),
      has_workflow: ReleaseTickets.status(types) != {:error, :no_release_workflow}
    )
  end

  @impl true
  def handle_info({:ticket_changed, nil}, socket), do: {:noreply, socket}

  def handle_info({:ticket_changed, id}, socket) do
    project_id = socket.assigns.project.id

    # The project filter only spares a reload: `load/1` reads this project's records either way, so
    # a change of another project's ticket redrawing this page shows nothing different. An
    # equivalent mutant of "reload on every ticket change"; no test claims otherwise.
    case Forge.Repo.get(Forge.Tickets.Ticket, id) do
      %{project_id: ^project_id} -> {:noreply, load(socket)}
      _other -> {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      frame={@frame}
      capacity={@capacity}
      title="Releases"
      subline={subline(@project, @count)}
      context={{@project.name, ~p"/projects/#{@project.name}"}}
      back={{@project.name, ~p"/projects/#{@project.name}"}}
      views={ForgeWeb.ProjectLive.strip(@project, %{}, :navigate)}
      measure="44rem"
    >
      <div id="releases-page" class="releases">
        <p :if={@open} id="release-in-progress" class="releases-line">
          A release is in progress:
          <.link navigate={~p"/tickets/#{@project.name}/#{@open.number}"} class="release-target">
            #{@open.number} ›
          </.link>
        </p>

        <p :if={@records == [] and @has_workflow} id="releases-empty" class="releases-line">
          A release appears here once one ends done.
        </p>
        <p :if={@records == [] and not @has_workflow} id="releases-no-workflow" class="releases-line">
          No workflow in this project sets <code>release: true</code>, which is what would fill this
          page.
        </p>

        <div id="releases">
          <ReleaseComponents.entry :for={record <- @records} record={record} project={@project} />
        </div>

        <.link
          :if={@count > length(@records)}
          id="show-more"
          patch={~p"/projects/#{@project.name}/releases?shown=#{@next}"}
          class="release-more"
        >
          Show more › ({@count - length(@records)} older)
        </.link>
      </div>
    </Layouts.app>
    """
  end

  defp subline(project, 0), do: project.name
  defp subline(project, 1), do: "#{project.name} · 1 release"
  defp subline(project, count), do: "#{project.name} · #{count} releases"
end
