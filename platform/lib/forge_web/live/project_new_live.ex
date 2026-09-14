defmodule ForgeWeb.ProjectNewLive do
  @moduledoc """
  Registering a project, and then telling the operator the one thing they now have to do.

  The repository this makes is empty, so the project cannot take a ticket until a
  `.forge/workflow.yml` is pushed to it. Redirecting to the board here would leave that to be
  discovered later as a parse error naming a file nobody has seen. So the view has a second
  state: the clone URL and what to put in it. See `docs/design/ui.md` § Creating things.
  """

  use ForgeWeb, :live_view

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

    case Projects.register_named(name, branch) do
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
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:board} measure="26rem">
      <.link navigate={~p"/board"} class="font-mono text-[12.5px] opacity-60 hover:opacity-100">
        ‹ Board
      </.link>

      <%= if @created do %>
        <h1 class="mt-4 text-2xl font-semibold -tracking-[.025em]">
          {@created.name} is registered
        </h1>
        <p class="mt-3 text-sm/[1.55] opacity-80">
          Its repository is empty, so it cannot take a ticket yet. Clone it, add a workflow at
          <code class="font-mono text-[12.5px]">.forge/workflow.yml</code>
          with the prompts it names under <code class="font-mono text-[12.5px]">.forge/</code>, and push to <code class="font-mono text-[12.5px]">{@created.default_branch}</code>.
        </p>

        <h2 class="mt-6 font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Clone it</h2>
        <div class="mt-2 rounded-box bg-base-200 px-4 py-3">
          <p class="font-mono text-[12.5px] break-all">git clone {@clone_url}</p>
        </div>
        <p class="mt-2 text-sm/[1.55] opacity-60">
          It asks for a credential. Issue one with
          <code class="font-mono text-[12.5px]">mix forge.git.token {@created.name} --write</code>
          and give it as the password.
        </p>

        <div class="mt-6 flex flex-col gap-2">
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
          The platform hosts the repository. It is created empty and you push to it.
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
