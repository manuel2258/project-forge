defmodule ForgeWeb.ProjectNewLive do
  @moduledoc """
  Registering a project, and then telling the operator the one thing they now have to do.

  The repository this makes has no workflow, so the project cannot take a ticket until one
  exists. Redirecting to the board here would leave that to be discovered later as a parse error
  naming a file nobody has seen. So the view has a second state: what to do about it.

  **It used to say "clone it and push a workflow", which at the time the product refused to do.**
  `pre-receive` accepts a write to the default branch from the platform's own merge and from a
  credential minted for exactly that branch, and from nothing else — a job's names its own branch.
  The way in for a new project is still a conversation: it writes the workflow on its own branch
  and a person merges it, which is the same route every other change takes. An existing repository
  is the case no branch and no conversation can serve, and the default-branch token in settings is
  what serves it.

  See `docs/design/ui.md` § Creating things.
  """

  use ForgeWeb, :live_view

  import ForgeWeb.Operator.Components

  alias Forge.Git.Url
  alias Forge.Projects

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "New project", created: nil, error: nil)
     |> assign(form: to_form(%{"name" => "", "default_branch" => "main"}, as: :project))}
  end

  @impl true
  def handle_event("validate", %{"project" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: :project), error: nil)}
  end

  def handle_event("create", %{"project" => params}, socket) do
    name = String.trim(params["name"] || "")
    branch = String.trim(params["default_branch"] || "")
    branch = if branch == "", do: "main", else: branch

    case Projects.register_named(name, branch, socket.assigns.current_scope.user) do
      {:ok, project} ->
        {:noreply, assign(socket, created: project, clone_url: Url.for(project))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           form: to_form(params, as: :project),
           error: errors(changeset)
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           form: to_form(params, as: :project),
           error: "could not create it: #{inspect(reason)}"
         )}
    end
  end

  defp errors(%Ecto.Changeset{errors: errors}) do
    Enum.map_join(errors, "; ", fn {field, {message, _opts}} -> "#{field} #{message}" end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      capacity={@capacity}
      active={:board}
      measure="26rem"
    >
      <.link navigate={~p"/board"} class="font-mono text-[12.5px] opacity-60 hover:opacity-100">
        ‹ Board
      </.link>

      <%= if @created do %>
        <h1 class="mt-4 text-2xl font-semibold -tracking-[.025em]">
          {@created.name} is registered
        </h1>
        <p class="mt-3 text-sm/[1.55] opacity-80">
          It has no workflow yet, so it cannot take a ticket. A workflow is
          <code class="font-mono text-[12.5px]">.forge/workflow.yml</code>
          in the repository, with the prompts it names under <code class="font-mono text-[12.5px]">.forge/</code>.
        </p>

        <%!-- The way in for an empty project: a conversation writes the workflow on its own
              branch and you merge it. "Clone it and push a workflow", which this page used to
              say, was an instruction nothing could carry out — a credential named one branch and
              it was never {@created.default_branch}. Importing a repository that already exists
              is the one case that needs the branch itself, and settings mints the credential. --%>
        <div class="mt-6">
          <.link
            navigate={~p"/chats/new?project=#{@created.name}"}
            class="flex min-h-[64px] items-center justify-between rounded-box bg-base-content px-5 text-base font-medium text-base-100"
          >
            Set it up in a chat <span aria-hidden="true">›</span>
          </.link>
          <p class="mt-2 text-sm/[1.55] opacity-60">
            It sees the empty repository, asks what the project is, and writes the workflow on a
            branch of its own. You read the diff and merge it.
          </p>
        </div>

        <div class="mt-8">
          <.copyable id="clone-url" value={@clone_url} label="Or work in it yourself" />
        </div>
        <p class="mt-2 text-sm/[1.55] opacity-60">
          Cloning asks for a credential —
          <.link
            navigate={~p"/projects/#{@created.name}/settings"}
            class="text-primary hover:underline"
          >
            issue one in settings ›
          </.link>
          . A credential writes one branch. For work, that is a branch you merge; for importing a
          repository that already exists, settings mints one scoped to {@created.default_branch} itself, fast-forward only.
        </p>

        <div class="mt-8 flex flex-col gap-2">
          <.link
            navigate={~p"/tickets/new?project=#{@created.name}"}
            class="flex h-[52px] items-center justify-between rounded-field border border-base-300 bg-base-200 px-4 text-sm hover:border-base-content/30"
          >
            Admit the first ticket <span aria-hidden="true">›</span>
          </.link>
          <.link
            navigate={~p"/board"}
            class="flex min-h-[46px] items-center text-sm text-primary hover:underline"
          >
            Back to the board ›
          </.link>
        </div>
      <% else %>
        <h1 class="mt-4 text-2xl font-semibold -tracking-[.025em]">New project</h1>
        <p class="mt-2 text-sm/[1.55] opacity-70">
          The platform hosts the repository. It is created empty, and work reaches its default
          branch by being merged there — or, for a repository that already exists, by an import
          pushed with a credential minted for that branch.
        </p>

        <.form
          for={@form}
          id="project-form"
          phx-change="validate"
          phx-submit="create"
          class="mt-6 flex flex-col gap-4"
        >
          <.input field={@form[:name]} type="text" label="Name" autocomplete="off" required />
          <.input field={@form[:default_branch]} type="text" label="Default branch" />

          <p :if={@error} class="text-sm text-error">{@error}</p>

          <button
            type="submit"
            class="h-[52px] rounded-field bg-base-content px-4 text-sm font-medium text-base-100"
          >
            Create it
          </button>
        </.form>
      <% end %>
    </Layouts.app>
    """
  end
end
