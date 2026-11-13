defmodule ForgeWeb.TicketNewLive do
  @moduledoc """
  Admitting a ticket.

  The project's workflow is resolved as soon as a project is chosen, and what is wrong with it
  is said there — not after a title and a body have been typed. See `docs/design/ui.md`
  § Creating things. `Tickets.types/2` runs the checks `admit/3` makes for every type at once,
  and `admit/3` makes them again: the repository is a shared surface.

  A project with more than one ticket type asks which, and preselects nothing
  (`docs/design/ticket-types.md` § Admission): a default is how a bug runs the feature lifecycle.
  A broken type is offered as broken, beside the ones that are not. A project's release is not
  offered at all (`docs/design/ticket-types.md` § Releases): `ReleaseTickets.ordinary/1` takes it
  out of what the form is shown, and a project with nothing else says so as it does a project
  with no workflow.
  """

  use ForgeWeb, :live_view

  alias Forge.{Operator, Projects, ReleaseTickets, Tickets}
  alias ForgeWeb.{Indicators, Topology, WorkflowMap}
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
     |> assign(
       form:
         to_form(%{"project" => chosen, "ticket_type" => "", "title" => "", "body" => ""},
           as: :ticket
         )
     )
     |> assign_workflow(chosen)}
  end

  defp assign_workflow(socket, nil), do: assign(socket, project: nil, types: nil, workflow: nil)

  defp assign_workflow(socket, name) do
    case Enum.find(socket.assigns.projects, &(&1.name == name)) do
      nil ->
        assign(socket, project: nil, types: nil, workflow: nil)

      project ->
        socket
        |> assign(
          project: project,
          types: project |> Tickets.types() |> ReleaseTickets.ordinary()
        )
        |> assign_chosen()
    end
  end

  # The workflow the chosen type would run: `{:ok, workflow}`, `{:error, reason}`, or nil while a
  # project with several types has none chosen — which is not an error, and draws no warning.
  defp assign_chosen(socket) do
    chosen = socket.assigns.form.params["ticket_type"]
    assign(socket, workflow: chosen_workflow(socket.assigns.types, chosen))
  end

  defp chosen_workflow({:error, reason}, _chosen), do: {:error, reason}
  defp chosen_workflow({:ok, %{types: [only]}}, _chosen), do: only.workflow

  defp chosen_workflow({:ok, %{types: types}}, chosen) do
    case Enum.find(types, &(&1.name == chosen)) do
      nil -> nil
      type -> type.workflow
    end
  end

  # The types offered as a choice: only when there is one to make.
  defp choices({:ok, %{form: :types, types: [_, _ | _] = types}}), do: types
  defp choices(_types), do: []

  # The one type a directory holding one implies, said rather than asked.
  defp implied({:ok, %{form: :types, types: [%{name: name}]}}), do: name
  defp implied(_types), do: nil

  defp option(%{name: name, workflow: {:ok, _workflow}}), do: {name, name}
  defp option(%{name: name}), do: {"#{name} — does not parse", name}

  # The first step as `12e` reads it, once (ux/c.md C19): the state by its mark, its budget beside
  # it, and its job — the prompt and what it writes — as small print under them, as the project's
  # Workflow view says them (`ForgeWeb.WorkflowMap`).
  defp first_state(workflow), do: ForgeCore.Workflow.state(workflow, workflow.initial)

  # The chosen type's description, said under the control that chose it: as the select's hint,
  # or under the type a one-type project implies.
  defp description({:ok, workflow}), do: workflow.description
  defp description(_none_or_broken), do: nil

  # Whether the form can take a ticket at all. While it cannot, the boxes are disabled too, so
  # nobody types a ticket they cannot submit.
  defp blocked?(project, workflow), do: project != nil and match?({:error, _reason}, workflow)

  @impl true
  def handle_event("validate", %{"ticket" => params}, socket) do
    socket = assign(socket, form: to_form(params, as: :ticket), error: nil)

    if params["project"] == (socket.assigns.project && socket.assigns.project.name) do
      {:noreply, assign_chosen(socket)}
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

    attrs = %{
      title: title,
      body: String.trim(params["body"] || ""),
      ticket_type: params["ticket_type"]
    }

    case Operator.admit(project, socket.assigns.current_scope.user, attrs) do
      {:ok, ticket} ->
        {:noreply,
         socket
         |> ForgeWeb.Toast.put(
           "Admitted #{project.name}##{ticket.number}",
           ForgeWeb.Toast.started(ticket)
         )
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
      frame={@frame}
      capacity={@capacity}
      title="New ticket"
      subline={@fixed && "admitted to #{@project.name}"}
      context={
        if @fixed,
          do: {@project.name, ~p"/projects/#{@project.name}"},
          else: {"Projects", ~p"/projects"}
      }
      measure="34rem"
    >
      <p :if={@projects == []} class="mt-4 text-sm/[1.55] opacity-70">
        There are no projects yet.
        <.link navigate={~p"/projects/new"} class="text-link hover:underline">
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
        <div :if={@fixed} class="ticket-new-fact">
          <.eyebrow>Project</.eyebrow>
          <.link navigate={~p"/projects/#{@project.name}"} class="ticket-new-fact-value">
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

        <%!-- Ticket types: asked only when there is a choice, and nothing preselected. See
              docs/design/ticket-types.md § Admission. The chosen type's description is the
              select's hint, under it rather than floating above the first step. --%>
        <.input
          :if={choices(@types) != []}
          field={@form[:ticket_type]}
          type="select"
          label="Type"
          prompt="Choose a type"
          options={Enum.map(choices(@types), &option/1)}
          hint={description(@workflow)}
        />
        <div :if={implied(@types)} class="ticket-new-fact">
          <.eyebrow>Type</.eyebrow>
          <span id="implied-type" class="ticket-new-fact-value">{implied(@types)}</span>
        </div>
        <p
          :if={choices(@types) == [] and description(@workflow)}
          id="type-description"
          class="ui-field-hint"
        >
          {description(@workflow)}
        </p>

        <%!-- What is wrong with the repository, said here rather than after a body is typed, and
              where the way to fix it is: a chat writes the workflow on its own branch, as the
              created screen says (ux/c.md C3). --%>
        <.notice
          :if={blocked?(@project, @workflow)}
          id="not-ready"
          tone="warning"
          title="Not ready for a ticket"
        >
          {if choices(@types) == [], do: "This project", else: "This type"} cannot take a ticket: {Admission.explain(
            elem(@workflow, 1)
          )}. A workflow is written in a chat, on its own branch, and merged.
          <.link
            navigate={~p"/chats/new?#{[project: @project.name]}"}
            class="project-link"
          >
            {if choices(@types) == [], do: "Set it up in a chat ›", else: "Fix it in a chat ›"}
          </.link>
        </.notice>

        <%!-- The first step and its budget, before anything is admitted (`12e`): where the
              ticket starts, what it may spend, and in small print what runs there. --%>
        <div :if={@project && Admission.ready?(@workflow)} id="first-step" class="first-step">
          <.eyebrow>First step</.eyebrow>
          <p class="first-step-line">
            <Indicators.state
              name={elem(@workflow, 1).initial}
              topology={Topology.of(elem(@workflow, 1), elem(@workflow, 1).initial)}
            />
            <span :if={WorkflowMap.budget(first_state(elem(@workflow, 1)))}>
              · {WorkflowMap.budget(first_state(elem(@workflow, 1)))}
            </span>
          </p>
          <p class="first-step-job">{WorkflowMap.job(first_state(elem(@workflow, 1)))}</p>
        </div>

        <.input
          field={@form[:title]}
          type="text"
          label="Title"
          autocomplete="off"
          required
          disabled={blocked?(@project, @workflow)}
        />
        <.input
          field={@form[:body]}
          type="textarea"
          label="Body"
          rows="6"
          placeholder="What is wrong, or what should exist. The first job reads this."
          disabled={blocked?(@project, @workflow)}
        />

        <.error_note :if={@error} id="ticket-new-error">{@error}</.error_note>

        <.button
          type="submit"
          variant="primary"
          size="xl"
          fill
          disabled={not Admission.ready?(@workflow)}
        >
          Admit it
        </.button>
      </.form>
    </Layouts.app>
    """
  end
end
