defmodule ForgeWeb.ReleaseLive do
  @moduledoc """
  One release record, at an address that never changes (`docs/design/ui.md` § A project's
  releases). A record is written once and never changed, so the page has nothing to subscribe to.
  An id that names no record of this project, or is not an id, is a miss, as is a project the
  person cannot see.
  """

  use ForgeWeb, :live_view

  alias Forge.ReleaseRecords
  alias ForgeWeb.ReleaseComponents

  @impl true
  def mount(%{"name" => name, "id" => id}, _session, socket) do
    {project, _scope} = ForgeWeb.Access.project_by_name!(socket.assigns.current_scope, name)
    record = ReleaseRecords.get!(project, id)

    {:ok,
     socket
     |> assign(
       project: project,
       record: record,
       page_title: "#{project.name} #{ReleaseComponents.heading(record)}"
     )
     |> ForgeWeb.Capacity.project(project)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      frame={@frame}
      capacity={@capacity}
      title={ReleaseComponents.heading(@record)}
      subline={"#{@project.name} · release · #{ReleaseComponents.date(@record)}"}
      context={{@project.name, ~p"/projects/#{@project.name}"}}
      back={{"Releases", ~p"/projects/#{@project.name}/releases"}}
      views={ForgeWeb.ProjectLive.strip(@project, %{}, :navigate)}
      measure="44rem"
    >
      <div id="release-page" class="releases">
        <.link navigate={~p"/projects/#{@project.name}/releases"} class="release-target">
          ‹ Releases
        </.link>
        <ReleaseComponents.entry record={@record} project={@project} link={false} />
      </div>
    </Layouts.app>
    """
  end
end
