defmodule ForgeWeb.ProjectSettingsLive do
  @moduledoc """
  A project's credentials: issued here, listed here, revoked here.

  This page exists because the product's own instructions were unfollowable without a terminal.
  The project page hands out a clone URL and says to push a `.forge/workflow.yml`, and until now
  `mix forge.git.token` was the only way to get the credential for either.

  **A token is shown once.** Only its hash is kept — the same as the worker token and the
  operator's API tokens — so afterwards a row can say what a token may do and when it was last
  used, and never what it is. See `docs/design/ui.md` § Project settings.
  """

  use ForgeWeb, :live_view

  import ForgeWeb.Operator.Components

  alias Forge.Git.{Tokens, Url}
  alias Forge.{Projects, Tickets, Workers}
  alias ForgeWeb.Format

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    project = Projects.by_name(name) || raise Ecto.NoResultsError, queryable: Projects.Project

    {:ok,
     socket
     |> assign(
       project: project,
       page_title: "#{project.name} settings",
       # The secret, held only until the operator navigates away. It is never in a flash and
       # never in the URL: both outlive the moment it is useful.
       issued: nil,
       show_spent: false,
       error: nil
     )
     |> assign(form: to_form(%{"scope" => "read", "ticket" => "", "minutes" => "90"}, as: :token))
     |> load()}
  end

  defp load(%{assigns: %{project: project}} = socket) do
    now = DateTime.utc_now()
    tokens = Tokens.list(project)

    assign(socket,
      model_form: to_form(%{"model" => project.model || ""}, as: :project),
      offered: Workers.offered(),
      tokens: Enum.map(tokens, &decorate(&1, now)),
      live_count: Enum.count(tokens, &Tokens.live?(&1, now)),
      tickets: Tickets.list(project),
      mirror: Projects.mirror(project),
      clone_url: Url.for(project),
      now: now
    )
  end

  defp decorate(token, now) do
    %{
      token: token,
      live: Tokens.live?(token, now),
      held_by_job: is_binary(token.job_id),
      capability: capability(token)
    }
  end

  # What it may do, which is the only thing about a token worth reading.
  defp capability(%{write: true, ref: ref}) when is_binary(ref), do: "write " <> ref
  defp capability(%{write: true}), do: "write"
  defp capability(_token), do: "read"

  @impl true
  def handle_event("validate", %{"token" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: :token), error: nil)}
  end

  def handle_event("issue", %{"token" => params}, socket) do
    case scope(socket.assigns, params) do
      {:ok, opts} ->
        {:ok, secret, token} = Tokens.issue(socket.assigns.project, opts)

        {:noreply,
         socket
         |> assign(issued: %{url: Url.with_token(socket.assigns.project, secret), token: token})
         |> load()}

      {:error, message} ->
        {:noreply, assign(socket, form: to_form(params, as: :token), error: message)}
    end
  end

  def handle_event("model", %{"project" => %{"model" => model}}, socket) do
    case Projects.set_model(socket.assigns.project, model) do
      {:ok, project} ->
        {:noreply, socket |> assign(project: project) |> put_flash(:info, "Saved.") |> load()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not save that.")}
    end
  end

  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, issued: nil)}

  def handle_event("toggle-spent", _params, socket),
    do: {:noreply, update(socket, :show_spent, &(not &1))}

  def handle_event("revoke", %{"id" => id}, socket) do
    case Tokens.revoke(id) do
      {:ok, _token} ->
        {:noreply, socket |> assign(error: nil) |> load()}

      {:error, :held_by_job} ->
        {:noreply,
         assign(socket,
           error: "that token belongs to a running job; the engine revokes it when the job ends"
         )}

      {:error, :not_found} ->
        {:noreply, load(socket)}
    end
  end

  # Exactly three shapes, because they are the three an operator has a use for. A job-scoped
  # token is the engine's to mint — see docs/design/git-hosting.md § Issuing a token.
  #
  # The default branch is the one that reaches what every job builds on, so it is its own choice
  # in the dropdown rather than a ref typed into a box: what may be minted is the project's own
  # default branch and nothing else, and `Forge.Git.Token` refuses anything wider anyway.
  defp scope(assigns, %{"scope" => "default"} = params) do
    with {:ok, minutes} <- minutes(params) do
      {:ok,
       [
         ref: Tokens.default_ref(assigns.project),
         write: true,
         ttl_minutes: minutes
       ]}
    end
  end

  defp scope(assigns, %{"scope" => "write"} = params) do
    with {:ok, minutes} <- minutes(params),
         %{} = ticket <- Enum.find(assigns.tickets, &(to_string(&1.number) == params["ticket"])) do
      {:ok,
       [
         ticket_id: ticket.id,
         ref: "refs/heads/" <> ticket.branch,
         write: true,
         ttl_minutes: minutes
       ]}
    else
      nil -> {:error, "choose the ticket whose branch this token may write"}
      other -> other
    end
  end

  defp scope(_assigns, params) do
    with {:ok, minutes} <- minutes(params), do: {:ok, [ttl_minutes: minutes]}
  end

  defp minutes(%{"minutes" => value}) do
    case Integer.parse(String.trim(value || "")) do
      {n, ""} when n > 0 and n <= 10_080 -> {:ok, n}
      _other -> {:error, "minutes must be a whole number of minutes, up to a week"}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:board} measure="48rem">
      <.link
        navigate={~p"/projects/#{@project.name}"}
        class="font-mono text-[12.5px] opacity-60 hover:opacity-100"
      >
        ‹ {@project.name}
      </.link>

      <h1 class="mt-4 text-2xl font-semibold -tracking-[.025em]">Settings</h1>

      <%!-- Once, and only here: the row below will never be able to show it again. --%>
      <section :if={@issued} class="mt-6 rounded-box border border-success p-4" id="issued">
        <h2 class="font-mono text-[11px] tracking-[.14em] uppercase text-success">
          Copy this now
        </h2>
        <p class="mt-2 text-sm/[1.55] opacity-80">
          Only its hash is kept, so this is the one time it can be shown.
          It {capability(@issued.token)}, until {@issued.token.expires_at}.
        </p>
        <.copyable id="issued-url" value={@issued.url} label="Clone URL, token included" />
        <p class="mt-2 text-sm/[1.55] opacity-60">
          Usable as-is, or give the token alone as the password when git asks.
        </p>
        <button
          type="button"
          phx-click="dismiss"
          class="mt-3 flex min-h-[46px] items-center text-sm text-primary hover:underline"
        >
          Done
        </button>
      </section>

      <section class="mt-8">
        <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Issue a token</h2>
        <p class="mt-2 text-sm/[1.55] opacity-70">
          For <span class="font-mono text-[12.5px] break-all">{@clone_url}</span>. The username is
          ignored; the token is the password.
        </p>

        <.form
          for={@form}
          id="token-form"
          phx-change="validate"
          phx-submit="issue"
          class="mt-4 flex flex-col gap-4"
        >
          <.input
            field={@form[:scope]}
            type="select"
            label="May"
            options={[
              {"read every branch", "read"},
              {"write one ticket's branch", "write"},
              {"write #{@project.default_branch}, the default branch", "default"}
            ]}
          />

          <p :if={@form[:scope].value == "default"} class="text-sm/[1.55] opacity-70">
            This is what a repository is seeded with and what a
            <code class="font-mono text-[12.5px]">.forge/workflow.yml</code>
            is changed with. It is fast-forward only, like the platform's own merge, and every
            other credential — a job's included — is refused that branch.
          </p>

          <.input
            :if={@form[:scope].value == "write"}
            field={@form[:ticket]}
            type="select"
            label="Ticket"
            prompt="choose one"
            options={Enum.map(@tickets, &{"##{&1.number} #{&1.title}", &1.number})}
          />

          <p :if={@form[:scope].value == "write" and @tickets == []} class="text-sm text-warning">
            This project has no tickets yet, so there is no branch to write.
          </p>

          <.input field={@form[:minutes]} type="number" label="Minutes" min="1" max="10080" />

          <p :if={@error} class="text-sm text-error">{@error}</p>

          <button
            type="submit"
            class="min-h-[52px] rounded-field bg-base-content px-4 text-sm font-medium text-base-100"
          >
            Issue it
          </button>
        </.form>
      </section>

      <section class="mt-10">
        <div class="flex flex-wrap items-baseline justify-between gap-3">
          <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
            Tokens · {@live_count} live
          </h2>
          <button
            type="button"
            phx-click="toggle-spent"
            class="flex min-h-[46px] items-center text-sm text-primary hover:underline"
          >
            {if @show_spent, do: "Hide spent", else: "Show expired and revoked"}
          </button>
        </div>

        <p :if={@tokens == []} class="mt-3 text-sm opacity-60">
          None yet. One issued above appears here, described but never shown again.
        </p>

        <table :if={@tokens != []} class="mt-3 w-full text-left text-[12.5px]">
          <thead class="font-mono text-[11px] tracking-[.14em] uppercase opacity-50">
            <tr class="border-b border-base-300">
              <th class="py-2 pr-3 font-normal">May</th>
              <th class="py-2 pr-3 font-normal">Expires</th>
              <th class="py-2 pr-3 font-normal">Last used</th>
              <th class="py-2 font-normal"></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={row <- @tokens}
              :if={@show_spent or row.live}
              class={["border-b border-base-300/60 align-top", row.live || "opacity-50"]}
            >
              <td class="py-3 pr-3 font-mono">
                <div class="break-all">{row.capability}</div>
                <div :if={row.held_by_job} class="text-[11px] opacity-50">held by a job</div>
              </td>
              <td class="py-3 pr-3 font-mono">
                {if row.live,
                  do: "in " <> Format.ago(DateTime.utc_now(), row.token.expires_at),
                  else: spent(row.token, @now)}
              </td>
              <td class="py-3 pr-3 font-mono opacity-70">
                {(row.token.last_used_at && Format.ago(row.token.last_used_at, @now)) || "never"}
              </td>
              <td class="py-3 text-right">
                <button
                  :if={row.live and not row.held_by_job}
                  type="button"
                  phx-click="revoke"
                  phx-value-id={row.token.id}
                  data-confirm="Revoke this token? Anything using it stops working."
                  class="min-h-[46px] text-sm text-primary hover:underline"
                >
                  Revoke
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </section>

      <section class="mt-10">
        <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Model</h2>
        <p class="mt-2 text-sm/[1.55] opacity-70">
          What this project's work runs on when a workflow state does not name one of its own.
          Left empty, it is the machine's — the platform-wide setting.
        </p>

        <.form for={@model_form} id="model-form" phx-submit="model" class="mt-4 flex flex-col gap-4">
          <ForgeWeb.Operator.Components.model_field
            field={@model_form[:model]}
            offered={@offered}
            label="Default model"
            fallback="the machine's"
          />
          <button
            type="submit"
            class="min-h-[52px] rounded-field bg-base-content px-4 text-sm font-medium text-base-100"
          >
            Save it
          </button>
        </.form>
      </section>

      <section class="mt-10">
        <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Repository</h2>
        <dl class="mt-3 flex flex-col gap-2 text-[12.5px]">
          <.fact label="default branch" value={@project.default_branch} />
          <.fact label="mirror" value={@mirror || "none"} />
        </dl>
        <p class="mt-3 text-sm/[1.55] opacity-60">
          The mirror is set with <code class="font-mono text-[12.5px]">mix forge.project.mirror {@project.name} URL</code>.
        </p>
      </section>
    </Layouts.app>
    """
  end

  defp spent(%{revoked_at: at}, now) when not is_nil(at), do: "revoked " <> Format.ago(at, now)
  defp spent(%{expires_at: at}, now), do: "expired " <> Format.ago(at, now)
end
