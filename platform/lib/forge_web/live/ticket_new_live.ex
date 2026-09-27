defmodule ForgeWeb.TicketNewLive do
  @moduledoc """
  Admitting a ticket.

  The project's workflow is resolved as soon as a project is chosen, and what is wrong with it
  is said there — not after a title and a body have been typed. See `docs/design/ui.md`
  § Creating things. `Tickets.admissible/1` runs exactly the checks `admit/3` makes, and
  `admit/3` makes them again: the repository is a shared surface.
  """

  use ForgeWeb, :live_view

  alias Forge.{Operator, Projects, Tickets}
  alias ForgeWeb.Operator.Admission

  @impl true
  def mount(params, _session, socket) do
    projects = Projects.list(socket.assigns.current_scope.user)
    named = params["project"]
    chosen = named || with([first | _rest] <- projects, do: first.name)

    {:ok,
     socket
     |> assign(
       page_title: "New ticket",
       projects: projects,
       error: nil,
       # Named in the address and real: then it is stated rather than asked.
       fixed: is_binary(named) and Enum.any?(projects, &(&1.name == named))
     )
     |> assign(form: to_form(%{"project" => chosen, "title" => "", "body" => ""}, as: :ticket))
     |> assign_workflow(chosen)}
  end

  defp assign_workflow(socket, nil), do: assign(socket, project: nil, workflow: nil)

  defp assign_workflow(socket, name) do
    case Enum.find(socket.assigns.projects, &(&1.name == name)) do
      nil -> assign(socket, project: nil, workflow: nil)
      project -> assign(socket, project: project, workflow: Tickets.admissible(project))
    end
  end

  @impl true
  def handle_event("validate", %{"ticket" => params}, socket) do
    socket = assign(socket, form: to_form(params, as: :ticket), error: nil)

    if params["project"] == (socket.assigns.project && socket.assigns.project.name) do
      {:noreply, socket}
    else
      {:noreply, assign_workflow(socket, params["project"])}
    end
  end

  def handle_event("create", %{"ticket" => params}, socket) do
    title = String.trim(params["title"] || "")

    cond do
      is_nil(socket.assigns.project) ->
        {:noreply, assign(socket, error: "choose a project")}

      title == "" ->
        {:noreply,
         assign(socket, form: to_form(params, as: :ticket), error: "a title is required")}

      true ->
        admit(socket, params, title)
    end
  end

  defp admit(socket, params, title) do
    project = socket.assigns.project
    attrs = %{title: title, body: String.trim(params["body"] || "")}

    case Operator.admit(project, socket.assigns.current_scope.user, attrs) do
      {:ok, ticket} ->
        {:noreply,
         socket
         |> put_flash(:info, "admitted #{project.name}##{ticket.number} in #{ticket.state}")
         |> push_navigate(to: ~p"/tickets/#{project.name}/#{ticket.number}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(form: to_form(params, as: :ticket), error: Admission.explain(reason))
         |> assign_workflow(project.name)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      capacity={@capacity}
      active={:queue}
      measure="34rem"
    >
      <.link
        navigate={if @fixed, do: ~p"/projects/#{@project.name}", else: ~p"/board"}
        class="flex min-h-[46px] items-center font-mono text-[12.5px] opacity-60 hover:opacity-100"
      >
        ‹ {if @fixed, do: @project.name, else: "Board"}
      </.link>

      <h1 class="mt-4 text-2xl font-semibold -tracking-[.025em]">New ticket</h1>

      <p :if={@projects == []} class="mt-4 text-sm/[1.55] opacity-70">
        There are no projects yet.
        <.link navigate={~p"/projects/new"} class="text-primary hover:underline">
          Register one first ›
        </.link>
      </p>

      <.form
        :if={@projects != []}
        for={@form}
        id="ticket-form"
        phx-change="validate"
        phx-submit="create"
        class="mt-6 flex flex-col gap-4"
      >
        <%!-- Reached from a project, the project is not a question. The select survives only for
              the bare /tickets/new, which nothing links to. See docs/design/ui.md § Creating
              things. --%>
        <div :if={@fixed} class="flex flex-wrap items-baseline gap-2">
          <span class="font-mono text-[11px] tracking-[.14em] uppercase opacity-50">Project</span>
          <.link
            navigate={~p"/projects/#{@project.name}"}
            class="font-mono text-[12.5px] hover:underline"
          >
            {@project.name}
          </.link>
        </div>
        <input :if={@fixed} type="hidden" name="ticket[project]" value={@project.name} />

        <.input
          :if={not @fixed}
          field={@form[:project]}
          type="select"
          label="Project"
          options={Enum.map(@projects, &{&1.name, &1.name})}
        />

        <%!-- What is wrong with the repository, said here rather than after a body is typed. --%>
        <div
          :if={@project && not Admission.ready?(@workflow)}
          class="rounded-box border border-warning/40 bg-warning/5 p-4"
        >
          <h2 class="font-mono text-[11px] tracking-[.14em] uppercase text-warning">
            Not ready for a ticket
          </h2>
          <p class="mt-2 text-sm/[1.55]">
            This project cannot take a ticket: {Admission.explain(elem(@workflow, 1))}.
          </p>
          <p class="mt-2 text-sm/[1.55] opacity-70">
            A workflow lives in the project's own repository, so it is pushed rather than edited
            here.
            <.link navigate={~p"/projects/#{@project.name}"} class="text-primary hover:underline">
              {@project.name} has the clone URL ›
            </.link>
          </p>
        </div>

        <div
          :if={@project && Admission.ready?(@workflow)}
          class="font-mono text-[12.5px] opacity-60"
        >
          starts in {elem(@workflow, 1).initial}
        </div>

        <.input field={@form[:title]} type="text" label="Title" autocomplete="off" required />
        <.input
          field={@form[:body]}
          type="textarea"
          label="Body"
          rows="6"
          placeholder="What is wrong, or what should exist. The first job reads this."
        />

        <p :if={@error} class="text-sm text-error">{@error}</p>

        <button
          type="submit"
          disabled={not Admission.ready?(@workflow)}
          class="h-[52px] rounded-field bg-base-content px-4 text-sm font-medium text-base-100 disabled:opacity-40"
        >
          Admit it
        </button>
      </.form>
    </Layouts.app>
    """
  end
end
