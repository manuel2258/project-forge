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
      capacity={@capacity}
      active={:board}
      measure="74rem"
    >
      <.link
        navigate={~p"/projects/#{@project.name}/releases"}
        class="flex min-h-[46px] items-center font-mono text-[12.5px] opacity-60 hover:opacity-100"
      >
        ‹ Releases
      </.link>

      <div class="mt-2">
        <ReleaseComponents.entry record={@record} project={@project} link={false} />
      </div>
    </Layouts.app>
    """
  end
end
