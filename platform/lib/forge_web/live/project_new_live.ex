defmodule ForgeWeb.ProjectNewLive do
  @moduledoc """
  Registering a project, and then telling the operator the one thing they now have to do.

  The repository this makes has no workflow, so the project cannot take a ticket until one
  exists. Redirecting to the project here would leave that to be discovered later as a parse error
  naming a file nobody has seen. So the view has a second state: what to do about it.

  **It used to say "clone it and push a workflow", which at the time the product refused to do.**
  `pre-receive` accepts a write to the default branch from the platform's own merge and from a
  credential minted for exactly that branch, and from nothing else — a job's names its own branch.
  The way in for a new project is still a conversation: it writes the workflow on its own branch
  and a person merges it, which is the same route every other change takes. An existing repository
  is the case no branch and no conversation can serve, and the default-branch token in settings is
  what serves it.

  The form is two fields, each error under its own, with the clone URL the name will make shown
  as it is typed (`11c`). On a wide screen the page is the projects table with the form in the
  column beside it (`11e`), and the next steps take that column's place (`11d`).

  See `docs/design/ui.md` § Creating things.
  """

  use ForgeWeb, :live_view

  import ForgeWeb.Operator.Components

  alias Forge.Git.Url
  alias Forge.Projects
  alias Forge.Projects.Project
  alias ForgeWeb.ProjectRows

  @name_rule "lowercase letters, digits, - or _, starting with a letter or digit."

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "New project", created: nil, error: nil)
     |> assign_form(%{"name" => "", "default_branch" => "main"}, [])
     |> load_rows()}
  end

  # The projects table this form opens beside on a wide screen. Read on a phone too, where CSS
  # hides it: the page does not know its width.
  defp load_rows(socket) do
    assign(socket,
      rows: Projects.summaries(socket.assigns.current_scope.user),
      now: DateTime.utc_now()
    )
  end

  defp assign_form(socket, params, errors) do
    assign(socket,
      form: to_form(params, as: :project, errors: Enum.map(errors, &sentence/1)),
      preview: preview(params["name"], errors)
    )
  end

  # The naming rule's refusal said as the whole rule, in a sentence: it takes the hint's place
  # under the field, so it carries everything the hint said.
  defp sentence({:name, {"lowercase letters, digits, - or _", opts}}),
    do: {:name, {"Not a valid name: " <> @name_rule, opts}}

  defp sentence(error), do: error

  defp name_hint,
    do: "#{String.capitalize(@name_rule)} It is the repository's name and the project's address."

  # The clone URL the name would make, built by the same function the created project's is, so
  # the preview cannot promise a different address. **Always drawn, at one height**: blank, it is
  # the address with `<name>` in it; refused, it is struck and says so. A block that appeared on
  # the first keystroke pushed *Create it* down under the finger (ux/c.md C2).
  defp preview(name, errors) do
    malformed =
      Enum.any?(errors, fn {field, {_msg, opts}} ->
        field == :name and opts[:validation] == :format
      end)

    case {String.trim(name || ""), malformed} do
      {"", _refused} -> {:blank, Url.for(%Project{name: "<name>"})}
      {name, true} -> {:invalid, Url.for(%Project{name: name})}
      {name, false} -> {:ok, Url.for(%Project{name: name})}
    end
  end

  # The name and the branch checked as they are typed, by the changeset that refuses them on
  # submit — one model for the check and the operation. A blank field is not refused while it is
  # being typed; the submit says so, as before.
  defp typed_errors(params) do
    attrs = %{
      name: String.trim(params["name"] || ""),
      default_branch: String.trim(params["default_branch"] || ""),
      repo_path: "-"
    }

    %Project{}
    |> Project.changeset(attrs)
    |> Map.fetch!(:errors)
    |> Enum.reject(fn {_field, {_msg, opts}} -> opts[:validation] == :required end)
  end

  @impl true
  def handle_event("validate", %{"project" => params}, socket) do
    {:noreply, socket |> assign_form(params, typed_errors(params)) |> assign(error: nil)}
  end

  def handle_event("create", %{"project" => params}, socket) do
    name = String.trim(params["name"] || "")
    branch = String.trim(params["default_branch"] || "")
    branch = if branch == "", do: "main", else: branch

    case Projects.register_named(name, branch, socket.assigns.current_scope.user) do
      {:ok, project} ->
        {:noreply, socket |> assign(created: project, clone_url: Url.for(project)) |> load_rows()}

      # Each error under the field it belongs to (`11c`); the form is a map's, and its errors
      # are the changeset's, so `input/1` draws them where it draws any field's.
      {:error, %Ecto.Changeset{errors: errors}} ->
        {:noreply, socket |> assign_form(params, errors) |> assign(error: nil)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign_form(params, [])
         |> assign(error: "could not create it: #{inspect(reason)}")}
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
      title={if @created, do: @created.name, else: "New project"}
      subline={
        if @created,
          do: "registered · no workflow yet",
          else: "the platform hosts the repository"
      }
      context={
        if @created,
          do: {@created.name, ~p"/projects/#{@created.name}"},
          else: {"Projects", ~p"/projects"}
      }
      back={{"Projects", ~p"/projects"}}
      measure={nil}
    >
      <%!-- Drawn on a wide screen only (`11e`): the column below is what a phone sees. --%>
      <div class="project-new-table">
        <ProjectRows.table rows={@rows} now={@now} />
      </div>

      <:aside>
        <div id="project-new" class="project-new">
          <div class="project-new-head">
            <h2>{if @created, do: "#{@created.name} is registered", else: "New project"}</h2>
            <.link navigate={~p"/projects"} class="project-new-close" aria-label="Close">×</.link>
          </div>
          <%= if @created do %>
            <.next_steps
              created={@created}
              clone_url={@clone_url}
              row={Enum.find(@rows, &(&1.project.id == @created.id))}
            />
          <% else %>
            <.form
              for={@form}
              id="project-form"
              phx-change="validate"
              phx-submit="create"
              class="project-new-form"
            >
              <.input
                field={@form[:name]}
                type="text"
                label="Name"
                autocomplete="off"
                mono
                required
                hint={name_hint()}
              />
              <.input field={@form[:default_branch]} type="text" label="Default branch" mono />

              <div
                id="clone-preview"
                class={["project-preview", "project-preview--#{elem(@preview, 0)}"]}
                data-preview={elem(@preview, 0)}
              >
                <.eyebrow>You will get</.eyebrow>
                <span class="project-preview-url">{elem(@preview, 1)}</span>
                <span class="project-preview-note">
                  {if elem(@preview, 0) == :invalid,
                    do: "Not a valid name, so no address.",
                    else: "You become its first administrator."}
                </span>
              </div>

              <.notice :if={@error} id="project-error" tone="danger">{@error}</.notice>

              <div class="project-dock">
                <.button type="submit" variant="primary" size="xl" fill>Create it</.button>
              </div>
              <p class="project-new-small">
                The repository is created empty; the next screen says how work reaches it.
              </p>
            </.form>
          <% end %>
        </div>
      </:aside>
    </Layouts.app>
    """
  end

  attr :created, :map, required: true
  attr :clone_url, :string, required: true
  attr :row, :map, default: nil, doc: "the project's row in `Projects.summaries/1`"

  # What to do next (`11d`), in this order: somewhere to run, while it has none; a conversation
  # that writes the workflow; working in it by hand; and where the first ticket is admitted once
  # the workflow is merged. "Somewhere to run" is the projects page's own answer
  # (`ProjectRows.runs_nothing?/1`), so the two never disagree: a chat opened on a project that
  # can run nothing sits there with nothing to run it (ux/c.md C3).
  #
  # **The not-stranded arm is unreachable from this page today**: a project is created with no
  # template, machine or credential, and its row is read straight after, so `stranded` is always
  # true here and making it so is an equivalent mutant; so is `row != nil`, since `load_rows/1`
  # runs after the insert. The question is asked rather than assumed so that the day a project is
  # created with an assignment, this page stops telling it to get one.
  defp next_steps(assigns) do
    assigns =
      assign(assigns, stranded: assigns.row != nil and ProjectRows.runs_nothing?(assigns.row))

    ~H"""
    <p class="project-new-lede">
      It has no workflow yet, so it cannot take a ticket. A workflow is
      <code>.forge/workflow.yml</code>
      in the repository, with the prompts it names under <code>.forge/</code>.
    </p>

    <div :if={@stranded} id="run-somewhere" class="project-step">
      <.notice tone="warning" title="Give it somewhere to run first">
        Nothing runs on it yet: it has {ProjectRows.missing(@row)}. The chat below needs both.
      </.notice>
      <div class="project-step-links">
        <.link :if={ProjectRows.no_machine?(@row)} navigate={~p"/templates"} class="project-link">
          Assign a template ›
        </.link>
        <.link
          :if={@row.credentials == 0}
          navigate={~p"/users/settings#credentials"}
          class="project-link"
        >
          Add a credential to its pool ›
        </.link>
      </div>
    </div>

    <%!-- The way in for an empty project: a conversation writes the workflow on its own
          branch and you merge it. "Clone it and push a workflow", which this page used to
          say, was an instruction nothing could carry out — a credential named one branch and
          it was never the default one. Importing a repository that already exists is the one
          case that needs the branch itself, and settings mints the credential. --%>
    <div class="project-step">
      <.button
        id="set-up-in-chat"
        variant={if @stranded, do: "outline", else: "primary"}
        size="xl"
        chevron
        navigate={~p"/chats/new?project=#{@created.name}"}
        class="project-step-primary"
      >
        Set it up in a chat
      </.button>
      <p>
        It sees the empty repository, asks what the project is, and writes the workflow on its
        own branch. You read the diff and merge it.
        <span :if={@stranded} id="chat-needs">It runs once the project has somewhere to run.</span>
      </p>
    </div>

    <div class="project-step">
      <.copyable id="clone-url" value={@clone_url} label="Or work in it yourself" />
      <p>
        Cloning needs a token.
        <.link navigate={~p"/projects/#{@created.name}/settings"} class="project-link">
          Issue one in settings ›
        </.link>
        An admin token also writes <code>{@created.default_branch}</code>, fast-forward only, for
        importing a repository that already exists.
      </p>
    </div>

    <%!-- Not a button to the ticket form: until a workflow is merged that form can only say "not
          ready", the opposite of what this page has just said to do. --%>
    <p id="first-ticket" class="project-new-small">
      Once the workflow is merged, the first ticket is admitted from the project's + New.
      <.link navigate={~p"/projects/#{@created.name}"} class="project-link">
        Open {@created.name} ›
      </.link>
    </p>
    """
  end
end
