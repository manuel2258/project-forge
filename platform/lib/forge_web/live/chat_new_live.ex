defmodule ForgeWeb.ChatNewLive do
  @moduledoc """
  Starting a conversation, about a project or about one of its tickets.

  A pushed view with a back affordance, like the other two create views, and for the same reason
  (`docs/design/ui.md` § Creating things): reached from the thing it is about, it says which that
  is rather than asking. The project select appears only on the bare `/chats/new`, which is what
  the chats page links to — the same shape a ticket has, and for the same reason: that page is
  every project at once and has no project to carry.

  **The first message is the form, and everything else on it is optional.** What you type is
  delivered as the first turn rather than stored as a title: a conversation has no title, and
  inventing one would be a second record of what the first message already is. The model and the
  resources sit under it because both are fixed for the life of the process — a conversation that
  wants different ones is one you close and open again.
  """

  use ForgeWeb, :live_view

  alias Forge.{Jobs, Operator, Projects, Secrets, Tickets, Workers}

  alias ForgeCore.Workflow.Resources

  @impl true
  def mount(params, _session, socket) do
    projects = Projects.list(socket.assigns.current_scope.user)
    named = params["project"]
    {project, ticket} = named_or_first(socket, projects, named, params["ticket"])
    defaults = Jobs.default_resources()

    {:ok,
     socket
     |> assign(
       page_title: "New chat",
       projects: projects,
       project: project,
       ticket: ticket,
       # Named in the address and real: then it is stated rather than asked, exactly as a
       # ticket's is.
       fixed: is_binary(named) and project != nil,
       error: nil,
       offered: Workers.offered(project && project.id),
       secret_names: secret_names(project),
       defaults: defaults,
       # Empty means the platform's, which is what each placeholder says. All three are fixed
       # when the harness process starts, so this is the only moment they can be chosen. The
       # first message may arrive in the address — *Ask about this* on a ticket's Changes — and
       # is only put in the box: nothing starts until Start (`docs/design/ui.md` § Changes).
       form:
         to_form(
           %{
             "project" => project && project.name,
             "text" => text(params["text"]),
             "model" => "",
             "effort" => "",
             # What the project runs on, which is what leaving it alone means; the select offers
             # the other (`docs/design/conversations.md` § What it asks for).
             "harness" => (project && project.harness) || ForgeCore.Harness.default()
           },
           as: :chat
         )
     )}
  end

  # Only text: `?text[a]=b` is a map, and a box cannot hold one.
  defp text(text) when is_binary(text), do: text
  defp text(_absent_or_not_text), do: ""

  # A named project is resolved through `Access` so that naming one you are not in is a 404 and
  # not a form you can submit; an unnamed one falls to the first you are in, the way the bare
  # ticket route does. A ticket only makes sense against the project it belongs to, so it is
  # read only when the project came from the address.
  defp named_or_first(_socket, projects, nil, _ticket), do: {List.first(projects), nil}

  defp named_or_first(socket, _projects, name, number) do
    {project, _scope} = ForgeWeb.Access.project_by_name!(socket.assigns.current_scope, name)
    {project, ticket(project, number)}
  end

  defp ticket(_project, nil), do: nil

  defp ticket(project, number) do
    case Integer.parse(number) do
      {n, ""} -> Tickets.get_by_number!(project, n)
      _other -> nil
    end
  end

  @impl true
  def handle_event("validate", %{"chat" => params}, socket) do
    socket = assign(socket, form: to_form(params, as: :chat), error: nil)

    if socket.assigns.fixed or params["project"] == name_of(socket.assigns.project) do
      {:noreply, socket}
    else
      project = Enum.find(socket.assigns.projects, &(&1.name == params["project"]))

      # The models are the chosen project's pool's, and the secrets its own, so choosing another
      # project changes both. The effort levels are the workers', not the project's, but they are
      # read in the same call, so they are as fresh as the model list is.
      {:noreply,
       assign(socket,
         project: project,
         offered: Workers.offered(project && project.id),
         secret_names: secret_names(project)
       )}
    end
  end

  def handle_event("open", %{"chat" => params}, socket) do
    socket = assign(socket, form: to_form(params, as: :chat))

    cond do
      is_nil(socket.assigns.project) ->
        {:noreply, assign(socket, error: "choose a project")}

      String.trim(params["text"] || "") == "" ->
        {:noreply, assign(socket, error: "say something to start with")}

      true ->
        open(socket, params)
    end
  end

  defp open(socket, params) do
    %{project: project, ticket: ticket} = socket.assigns

    with {:ok, memory} <- memory(params["memory"]),
         {:ok, cores} <- cores(params["cores"]) do
      start(socket, project, ticket, String.trim(params["text"]), memory, cores,
        model: params["model"],
        effort: params["effort"],
        harness: params["harness"]
      )
    else
      {:error, message} -> {:noreply, assign(socket, error: message)}
    end
  end

  defp start(socket, project, ticket, text, memory, cores, chosen) do
    case Operator.open_chat(project, socket.assigns.current_scope.user, text,
           ticket: ticket,
           model: chosen[:model],
           effort: chosen[:effort],
           harness: chosen[:harness],
           memory: memory,
           cores: cores,
           secrets: picked(socket.assigns.form.params["secrets"])
         ) do
      {:ok, chat} ->
        {:noreply, push_navigate(socket, to: ~p"/chats/#{chat.id}")}

      # Deleted since the page was drawn, or never this project's: `Conversations.open/3` refuses
      # rather than starting without it, and the page says which.
      {:error, {:unknown_secrets, names}} ->
        {:noreply,
         assign(socket,
           error: "no secret named #{Enum.join(names, ", ")} in this project any more",
           secret_names: secret_names(project)
         )}

      # The ticket is not this project's. **An equivalent mutant: no test can reach this clause**,
      # because the form resolves the ticket from the project it is already on
      # (`Tickets.get_by_number!/2`), so `Conversations.open/3` is never handed a mismatched pair
      # from here. It is written anyway because the catch-all below shows a person `inspect/1`
      # output, and a reason with no sentence is the class this very commit fixed for
      # `{:merge_impossible, _}` — worth a line before the next caller makes it reachable.
      {:error, :ticket_not_in_project} ->
        {:noreply,
         assign(socket,
           error: "that ticket belongs to another project",
           secret_names: secret_names(project)
         )}

      {:error, reason} ->
        {:noreply, assign(socket, error: "could not start it: #{inspect(reason)}")}
    end
  end

  # The ticked boxes, by name; none ticked is none held (`docs/design/secrets.md` § Conversations).
  # As the form sent them: `Conversations.open/3` is what refuses a name that is not one.
  defp picked(names) when is_list(names), do: names
  defp picked(_none), do: []

  defp secret_names(nil), do: []
  defp secret_names(project), do: Secrets.names(project.id)

  # Blank is nil and means the platform's default, exactly as it does on the templates page. A
  # figure that is not one is refused here rather than quietly becoming the default: a person
  # who typed `2 gigs` asked for something, and starting a conversation on 1 GiB instead would
  # be the silent substitution `CLAUDE.md` calls the guard's job to prevent.
  defp memory(value) do
    case String.trim(value || "") do
      "" -> {:ok, nil}
      text -> parse_memory(text)
    end
  end

  # A size, and one a conversation can run in: `2` is two bytes, which is a size and the one that
  # took a machine down, so it is refused by name rather than started.
  defp parse_memory(text) do
    case Resources.parse_bytes(text) do
      {:ok, bytes} -> enough(bytes)
      _other -> {:error, "memory has to be a size, like 2GiB"}
    end
  end

  defp enough(bytes) do
    if Resources.enough_memory?(bytes),
      do: {:ok, bytes},
      else: {:error, Resources.memory_refused()}
  end

  defp cores(value) do
    case String.trim(value || "") do
      "" -> {:ok, nil}
      text -> parse_cores(text)
    end
  end

  defp parse_cores(text) do
    case Integer.parse(text) do
      {n, ""} when n > 0 -> {:ok, n}
      _other -> {:error, "cores has to be a whole number above zero"}
    end
  end

  defp name_of(nil), do: nil
  defp name_of(project), do: project.name

  @impl true
  def render(assigns) do
    assigns = assign(assigns, machine_open: machine_open?(assigns.form))

    ~H"""
    <%!-- The queue's measure: the first message is prose, not a form field. --%>
    <Layouts.app
      section="Chats"
      flash={@flash}
      current_scope={@current_scope}
      frame={@frame}
      capacity={@capacity}
      title="New chat"
      subline={@project && "in #{@project.name}"}
      context={{where(@fixed, @project, @ticket), back(@fixed, @project, @ticket)}}
      measure="34rem"
    >
      <p class="mt-2 text-sm/[1.55] text-ink-2">{about(@ticket)}</p>

      <p :if={@projects == []} class="mt-4 text-sm/[1.55] text-ink-2">
        You are not in a project yet. A conversation is always about one.
      </p>

      <.form
        :if={@projects != []}
        for={@form}
        id="chat-form"
        phx-change="validate"
        phx-submit="open"
        class="chat-new"
      >
        <%!-- Reached from a project, the project is not a question and nothing here asks it:
              the view holds it and `open` reads it from there, so there is not even a hidden
              field to disagree with. The select survives for the bare /chats/new, which the
              chats page links to — that page is every project at once. See
              docs/design/ui.md § Creating things. --%>
        <.input
          :if={not @fixed}
          field={@form[:project]}
          type="select"
          label="Project"
          options={Enum.map(@projects, &{&1.name, &1.name})}
        />

        <%!-- Picked here and only here, none by default, and fixed for the life of the process
              like the model (`docs/design/secrets.md` § Conversations). What it holds, anyone
              in the project can read through it, and the sentence says so where the choice is
              made. Each is a chip: a checkbox drawn as its name. --%>
        <fieldset :if={@secret_names != []} id="chat-secrets" class="chat-new-secrets">
          <legend class="text-sm font-medium">Secrets it may hold</legend>
          <div class="chat-chips">
            <label :for={name <- @secret_names} class="chat-chip">
              <input
                type="checkbox"
                name="chat[secrets][]"
                value={name}
                checked={name in picked(@form.params["secrets"])}
              />
              <span aria-hidden="true" class="chat-chip-tick">✓</span>
              <span>{name}</span>
            </label>
          </div>
          <p class="mt-2 text-[12.5px]/[1.5] text-ink-2">
            Set in its environment by name. Anyone in this project can ask it what they are.
          </p>
        </fieldset>

        <%!-- The model, the effort and the machine, folded to one line because they are rarely
              changed (`12d`): all fixed when the harness process starts, so a conversation that
              wants different ones is one you close and open again. Blank is the platform's own
              figure, which is an agent's and not a build's (`docs/design/conversations.md`
              § What it asks for) — so a conversation that will compile something says so here,
              before it is placed on a machine too small. Open whenever any of them holds
              something, so a refusal is never folded out of sight. --%>
        <%!-- The harness is chosen here, like the model and the effort, and fixed when its process
              starts; it defaults to the project's (`docs/design/conversations.md` § What it asks
              for). Not folded: it decides which model and effort the fold offers. --%>
        <fieldset id="chat-harness" class="chat-new-harness">
          <legend class="text-sm font-medium">Harness</legend>
          <.segmented
            id="chat-harness-switch"
            name="chat[harness]"
            value={@form[:harness].value}
            options={for h <- Forge.Harness.names(), do: {Forge.Harness.label(h), h}}
          />
        </fieldset>

        <details
          id="chat-machine-fold"
          class="chat-new-machine"
          open={@machine_open}
          phx-mounted={ForgeWeb.Actions.keep_open()}
        >
          <summary>
            <span>{machine_line(@form, @defaults)}</span>
            <span class="text-link">Change ▾</span>
          </summary>
          <div class="chat-new-machine-fields">
            <%!-- Claude Code's are offered from what the workers and credentials say; nothing
                  lists Codex's models, so Codex's is typed, and empty is Codex's own. --%>
            <ForgeWeb.Operator.Components.model_field
              :if={@form[:harness].value != "codex"}
              field={@form[:model]}
              offered={@offered}
              fallback={(@project && @project.model) || "the platform's"}
            />

            <ForgeWeb.Operator.Components.effort_field
              :if={@form[:harness].value != "codex"}
              field={@form[:effort]}
              offered={@offered}
              fallback={(@project && @project.effort) || "the platform's"}
            />

            <.input
              :if={@form[:harness].value == "codex"}
              field={@form[:model]}
              type="text"
              label="Model"
              placeholder={(@project && @project.codex_model) || "Codex's own default"}
              autocomplete="off"
            />

            <ForgeWeb.Operator.Components.effort_field
              :if={@form[:harness].value == "codex"}
              offered={%{@offered | efforts: @offered.codex_efforts}}
              field={@form[:effort]}
              label="Effort"
              fallback={(@project && @project.codex_effort) || "Codex's own default"}
            />

            <div class="flex flex-wrap items-end gap-3">
              <.input
                field={@form[:memory]}
                type="text"
                label="Memory"
                placeholder={Resources.humanize(@defaults.memory)}
                autocomplete="off"
              />
              <.input
                field={@form[:cores]}
                type="number"
                label="Cores"
                placeholder={to_string(@defaults.cores)}
              />
            </div>
          </div>
        </details>

        <%!-- Last, directly above *Start the chat*: it is the field a person finishes on, and
              Enter sends from it — first, it sent before the secrets and the machine below it
              were reached (UX pass, B18). --%>
        <ForgeWeb.Conversations.message_box
          id="chat_text"
          name="chat[text]"
          value={@form[:text].value}
          rows="5"
          label="First thing to say"
        />

        <.error_note :if={@error} id="chat-form-error">{@error}</.error_note>
      </.form>

      <%!-- What it costs and what it holds, before it is started rather than after: a
            conversation takes a machine for as long as it is open. --%>
      <p class="mt-6 text-sm/[1.55] text-ink-3">
        It waits for a free worker, and holds it until you end the conversation or it goes idle.
        Its work goes to a branch of its own, which you can merge from its page.
      </p>

      <:composer :if={@projects != []}>
        <div class="chat-new-dock">
          <.button type="submit" form="chat-form" variant="primary" fill>Start the chat</.button>
        </div>
      </:composer>
    </Layouts.app>
    """
  end

  # The folded line: what it will run on, the platform's figures where nothing is typed.
  defp machine_line(form, defaults) do
    memory = blank(form[:memory].value) || Resources.humanize(defaults.memory)
    cores = blank(form[:cores].value) || to_string(defaults.cores)
    "Machine · #{memory} · #{cores} #{if cores == "1", do: "core", else: "cores"}"
  end

  defp machine_open?(form),
    do: Enum.any?([:model, :effort, :memory, :cores], &(blank(form[&1].value) != nil))

  defp blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp blank(_value), do: nil

  # Where the ‹ goes: back where you came from. Off the bare route there is no project in the
  # address even when one is selected below, so it goes to the list that linked here.
  defp back(false, _project, _ticket), do: ~p"/chats"
  defp back(_fixed, project, nil), do: ~p"/projects/#{project.name}"
  defp back(_fixed, project, ticket), do: ~p"/tickets/#{project.name}/#{ticket.number}"

  defp where(false, _project, _ticket), do: "Chats"
  defp where(_fixed, project, nil), do: project.name
  defp where(_fixed, project, ticket), do: "#{project.name}##{ticket.number} · #{ticket.title}"

  defp about(nil), do: "About the repository as a whole. It sees the default branch at its head."

  defp about(ticket),
    do:
      "About ##{ticket.number}. It starts from the ticket's branch as it stands, " <>
        "with the ticket's documents as context."
end
