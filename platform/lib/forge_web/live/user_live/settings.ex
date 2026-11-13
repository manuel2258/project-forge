defmodule ForgeWeb.UserLive.Settings do
  use ForgeWeb, :live_view

  on_mount {ForgeWeb.UserAuth, :require_sudo_mode}

  alias Forge.{Accounts, Credentials, Harness, Projects}
  alias ForgeWeb.Format

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} capacity={@capacity}>
      <div class="text-center">
        <.header>
          Account Settings
          <:subtitle>Manage your account email address and password settings</:subtitle>
        </.header>
      </div>

      <.form for={@email_form} id="email_form" phx-submit="update_email" phx-change="validate_email">
        <.input
          field={@email_form[:email]}
          type="email"
          label="Email"
          autocomplete="username"
          spellcheck="false"
          required
        />
        <.button variant="primary" phx-disable-with="Changing...">Change Email</.button>
      </.form>

      <div class="divider" />

      <.form
        for={@password_form}
        id="password_form"
        action={~p"/users/update-password"}
        method="post"
        phx-change="validate_password"
        phx-submit="update_password"
        phx-trigger-action={@trigger_submit}
      >
        <input
          name={@password_form[:email].name}
          type="hidden"
          id="hidden_user_email"
          spellcheck="false"
          value={@current_email}
        />
        <.input
          field={@password_form[:password]}
          type="password"
          label="New password"
          autocomplete="new-password"
          spellcheck="false"
          required
        />
        <.input
          field={@password_form[:password_confirmation]}
          type="password"
          label="Confirm new password"
          autocomplete="new-password"
          spellcheck="false"
        />
        <.button variant="primary" phx-disable-with="Saving...">
          Save Password
        </.button>
      </.form>

      <div class="divider" />

      <.credentials
        credentials={@credentials}
        funds={@funds}
        spent={@spent}
        detail={@detail}
        in_use={@in_use}
        windows={@windows}
        projects={@projects}
        form={@credential_form}
        seq={@credential_seq}
        error={@credential_error}
      />
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)
      |> load_credentials()
      |> reset_credential_form()

    {:ok, socket}
  end

  # -- inference credentials --------------------------------------------------------------------
  #
  # Yours and nobody else's: every call below takes the acting user, and `Forge.Credentials`
  # reads the row scoped to them before it does anything (`docs/design/credentials.md`). This page
  # is behind sudo mode like the rest of it, which is right for the one place a token is typed.
  #
  # **The secret never enters this LiveView's assigns.** `Credentials.list/1` does not load the
  # column, and the form below is assigned from params with the secret dropped — on every change
  # and on a failed submit alike. The input is `phx-update="ignore"` so that re-rendering the form
  # without a value does not wipe what the person typed, and its id carries a sequence so that a
  # successful add replaces it with an empty one.

  # Spend and limits are read with the list, so they are as of the last action on this page rather
  # than live; a revoked credential's spend is still its own, so it is read for those too.
  defp load_credentials(socket) do
    user = socket.assigns.current_scope.user
    credentials = Credentials.list(user)
    ids = Enum.map(credentials, & &1.id)

    assign(socket,
      credentials: credentials,
      funds: Map.new(credentials, &{&1.id, Credentials.projects(&1)}),
      spent: Credentials.used_today(ids),
      detail: Credentials.detail_today(ids),
      windows: Credentials.windows(ids),
      in_use: Credentials.in_use(ids),
      projects: Projects.list(user)
    )
  end

  defp reset_credential_form(socket) do
    harness = List.first(Harness.names())
    kind = harness |> Harness.kinds() |> List.first() |> then(&(&1 && elem(&1, 0)))

    socket
    |> assign(:credential_form, credential_form(%{"harness" => harness, "kind" => kind}))
    |> assign(:credential_seq, (socket.assigns[:credential_seq] || 0) + 1)
    |> assign(:credential_error, nil)
  end

  defp credential_form(params), do: to_form(Map.delete(params, "secret"), as: :credential)

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        info = "A link to confirm your email change has been sent to the new address."
        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  # Changing the harness changes the kinds it offers. What arrives is every field of the form,
  # the secret included, and all of it but the secret is kept.
  def handle_event("credential-change", %{"credential" => params}, socket) do
    params =
      case Harness.kinds(params["harness"]) do
        [] -> params
        kinds -> Map.update(params, "kind", nil, &kind_for(&1, kinds))
      end

    {:noreply, assign(socket, :credential_form, credential_form(params))}
  end

  def handle_event("add-credential", %{"credential" => params}, socket) do
    attrs = %{
      name: params["name"],
      harness: params["harness"],
      kind: params["kind"],
      secret: params["secret"],
      daily_limit: limit(blank(params["daily_limit"])),
      expires_on: blank(params["expires_on"])
    }

    case Credentials.create(socket.assigns.current_scope.user, attrs) do
      {:ok, _credential} ->
        {:noreply, socket |> load_credentials() |> reset_credential_form()}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:credential_form, credential_form(params))
         |> assign(:credential_error, errors(changeset))}
    end
  end

  # The id is the client's, and `Credentials` answers `:not_found` for one that is not the
  # caller's — which is why neither of these distinguishes the two.
  def handle_event("check-credential", %{"id" => id}, socket) do
    Credentials.recheck(socket.assigns.current_scope.user, id)
    {:noreply, load_credentials(socket)}
  end

  def handle_event("revoke-credential", %{"id" => id}, socket) do
    Credentials.revoke(socket.assigns.current_scope.user, id)
    {:noreply, load_credentials(socket)}
  end

  # Both reach a project's pool, and both are refused unless the caller owns the credential *and*
  # is a member of that project — `Credentials.assign/3` reads both, whatever ids arrive.
  def handle_event("assign-credential", %{"credential" => id, "project" => project_id}, socket) do
    case Credentials.assign(socket.assigns.current_scope.user, id, project_id) do
      {:ok, _assignment} ->
        {:noreply, socket |> load_credentials() |> assign(:credential_error, nil)}

      {:error, :not_a_member} ->
        {:noreply, assign(socket, :credential_error, "you are not in that project")}

      {:error, _reason} ->
        {:noreply, assign(socket, :credential_error, "could not assign it")}
    end
  end

  def handle_event("unassign-credential", %{"credential" => id, "project" => project_id}, socket) do
    Credentials.unassign(socket.assigns.current_scope.user, id, project_id)
    {:noreply, load_credentials(socket)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end

  # The kind chosen, while the harness takes it; otherwise that harness's first.
  defp kind_for(kind, kinds) do
    if List.keymember?(kinds, kind, 0), do: kind, else: kinds |> List.first() |> elem(0)
  end

  # What the credential used today, in windows with the weighted tokens counted behind them, and
  # its daily limit in the same unit, which is shown and never enforced. The day is
  # `Forge.Spend.day/1`'s, in UTC. (A Claude API key's dollar figure and the tokens by kind are drawn beside it.)
  defp spend(used, limit) do
    used = used || 0
    windows = Format.windows(used)
    counted = "#{ForgeCore.Usage.format(used)} weighted tokens"
    today = if windows, do: "#{windows} today (#{counted})", else: "#{counted} today"

    case limit do
      nil -> today
      limit -> "#{today} of #{ForgeCore.Usage.format(limit)}/day, not enforced"
    end
  end

  # The tokens counted behind today's figure, by kind, when any run had them.
  defp kinds_line(%{tokens: tokens}) do
    if line = Format.kinds(tokens), do: "by kind: " <> line
  end

  defp kinds_line(_none), do: nil

  # Only a Claude API key is billed in dollars, so only its row carries the figure.
  defp dollars_line(%{kind: "api_key", harness: "claude_code"}, %{
         claude_cost_usd: %Decimal{} = cost
       }),
       do: "Claude Code's figure: $#{Decimal.round(cost, 2)} today"

  defp dollars_line(_credential, _detail), do: nil

  # Five-hour, then the week, then anything else the provider names, as it names it.
  defp ordered(windows) do
    Enum.sort_by(windows, fn {type, _window} ->
      {Enum.find_index(["five_hour", "seven_day"], &(&1 == type)) || 2, type}
    end)
  end

  defp window_line(type, window) do
    figure = if is_number(window.utilization), do: " #{round(window.utilization * 100)}%"
    "#{window_label(type)}#{figure} · resets #{reset(window.resets_at)}"
  end

  defp window_label("five_hour"), do: "5h"
  defp window_label("seven_day"), do: "week"
  defp window_label(type), do: type

  # The time alone within a day, the weekday with it beyond: a weekly reset is days away.
  defp reset(at) do
    if DateTime.diff(at, DateTime.utc_now()) < 86_400,
      do: Calendar.strftime(at, "%H:%M UTC"),
      else: Calendar.strftime(at, "%a %H:%M UTC")
  end

  # A limit typed as `4M` or `800k` is read as `ForgeCore.Usage.parse/1` reads a budget; what does
  # not parse is passed on as typed, so the changeset refuses it as an invalid number.
  defp limit(nil), do: nil

  defp limit(text) do
    case ForgeCore.Usage.parse(text) do
      {:ok, tokens} -> tokens
      {:error, _} -> text
    end
  end

  defp blank(nil), do: nil
  defp blank(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  # Field and message only. A changeset's values are never rendered: the one that matters here is
  # sealed, and an error that quoted its field's value is how a secret reaches a page.
  defp errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  attr :credentials, :list, required: true
  attr :funds, :map, required: true
  attr :spent, :map, required: true
  attr :detail, :map, default: %{}
  attr :windows, :map, required: true
  attr :in_use, :any, required: true
  attr :projects, :list, required: true
  attr :form, :any, required: true
  attr :seq, :integer, required: true
  attr :error, :string, default: nil

  defp credentials(assigns) do
    ~H"""
    <section id="credentials">
      <h2 class="text-lg font-semibold">Inference credentials</h2>
      <p class="mt-1 text-sm/[1.55] opacity-60">
        The tokens your agents authenticate with. Yours and nobody else's: a job spends one only
        when you have assigned it to that job's project, and a project with several picks between
        them per job. Each is tried against the provider when you add it — a Codex credential only
        for its shape, its first job being the check — and the token is never shown again.
      </p>

      <%!-- Rows separated by a rule, not boxed: a row is not something to tap, and § The
            affordance rule reserves the border for what is. --%>
      <ul class="mt-4 flex flex-col">
        <li
          :for={credential <- @credentials}
          id={"credential-#{credential.id}"}
          class={[
            "flex min-h-[52px] flex-wrap items-center gap-x-4 gap-y-1 border-b border-base-300 py-2",
            Credentials.revoked?(credential) && "opacity-50"
          ]}
        >
          <%!-- Cut to the row, whole in its title, as names are everywhere else (`ui.md`): the name
                is the owner's and as long as they typed. --%>
          <span class="max-w-full truncate text-sm font-medium" title={credential.name}>
            {credential.name}
          </span>
          <span class="font-mono text-[12.5px] opacity-60">
            {Harness.label(credential.harness)} · {Harness.kind_label(
              credential.harness,
              credential.kind
            )}
          </span>
          <span class="font-mono text-[12.5px] opacity-60">{status(credential)}</span>
          <span
            :if={detail(credential, @in_use)}
            class={[
              "font-mono text-[12.5px]",
              if(expiring?(credential), do: "text-warning", else: "opacity-60")
            ]}
          >
            {detail(credential, @in_use)}
          </span>
          <span class="font-mono text-[12.5px] opacity-60">
            {spend(Map.get(@spent, credential.id), credential.daily_limit)}
          </span>
          <span
            :if={kinds_line(Map.get(@detail, credential.id))}
            id={"credential-#{credential.id}-tokens"}
            class="font-mono text-[12.5px] opacity-60"
          >
            {kinds_line(Map.get(@detail, credential.id))}
          </span>
          <%!-- Claude Code's own dollar figure, for the one kind billed in dollars; read by no cap. --%>
          <span
            :if={dollars_line(credential, Map.get(@detail, credential.id))}
            id={"credential-#{credential.id}-dollars"}
            class="font-mono text-[12.5px] opacity-60"
          >
            {dollars_line(credential, Map.get(@detail, credential.id))}
          </span>
          <%!-- One line per window the provider has reported, drawn by capacity.md's rules: a
                figure only when one was given, the reset always, warning colour only while it
                blocks. --%>
          <span
            :for={{type, window} <- ordered(Map.get(@windows, credential.id, %{}))}
            id={"credential-#{credential.id}-#{type}"}
            class={[
              "font-mono text-[12.5px]",
              if(window.limited, do: "text-warning", else: "opacity-60")
            ]}
          >
            {window_line(type, window)}{if window.limited, do: " · rate-limited"}
          </span>
          <div :if={not Credentials.revoked?(credential)} class="ml-auto flex items-center gap-4">
            <button
              :if={not checked_by_shape?(credential)}
              type="button"
              phx-click="check-credential"
              phx-value-id={credential.id}
              class="min-h-[46px] text-sm text-primary hover:underline"
            >
              Check again
            </button>
            <button
              type="button"
              phx-click="revoke-credential"
              phx-value-id={credential.id}
              data-confirm={"Revoke #{credential.name}? No job will start on it again, and the token is deleted."}
              class="min-h-[46px] text-sm text-error hover:underline"
            >
              Revoke
            </button>
          </div>
          <.funds
            :if={not Credentials.revoked?(credential)}
            credential={credential}
            assigned={Map.get(@funds, credential.id, [])}
            projects={@projects}
          />
        </li>
        <li :if={@credentials == []} class="text-sm opacity-60">
          None yet, so none of your projects can run a job on your account.
        </li>
      </ul>

      <p :if={@error} class="mt-4 text-sm text-error">{@error}</p>

      <.form
        for={@form}
        id="credential-form"
        phx-change="credential-change"
        phx-submit="add-credential"
        class="mt-4 flex flex-col gap-2"
      >
        <.input field={@form[:name]} type="text" label="Name" autocomplete="off" />
        <.input
          field={@form[:harness]}
          type="select"
          label="Harness"
          options={for h <- Harness.names(), do: {Harness.label(h), h}}
        />
        <.input
          field={@form[:kind]}
          type="select"
          label="Kind"
          options={for {kind, label} <- Harness.kinds(@form.params["harness"]), do: {label, kind}}
        />
        <p
          :if={@form.params["kind"] == "chatgpt_login"}
          id="login-howto"
          class="text-sm/[1.55] opacity-70"
        >
          Make one for forge alone: <code class="font-mono">CODEX_HOME=$(mktemp -d) codex login --device-auth</code>,
          then paste that folder's <code class="font-mono">auth.json</code>. It must be a login made
          for forge alone: Codex renews a login by itself, and a copy that something else renewed
          first stops working. A job that takes it can keep using the account until you sign that
          login out at OpenAI; revoking it here only stops forge using it.
        </p>
        <p
          :if={@form.params["kind"] == "access_token"}
          id="token-howto"
          class="text-sm/[1.55] opacity-70"
        >
          Created in your workspace's settings by an admin of the workspace: a fixed token with an
          expiry its creator chose.
        </p>
        <%!-- Written out rather than `<.input>`, which renders the field's value into the page:
              this one never has a value on the server to render, and must not grow one. A login
              is pasted into a box of several lines, so that a phone can add one. **The kind is in
              the id**: an ignored element is never patched, so the box for another kind has to be
              another element. --%>
        <div
          class="fieldset mb-2"
          id={"credential-secret-#{@seq}-#{@form.params["kind"]}"}
          phx-update="ignore"
        >
          <label for={"credential-secret-input-#{@seq}"}>
            <span class="label mb-1">
              {if @form.params["kind"] == "chatgpt_login", do: "Login (auth.json)", else: "Token"}
            </span>
            <textarea
              :if={@form.params["kind"] == "chatgpt_login"}
              name="credential[secret]"
              id={"credential-secret-input-#{@seq}"}
              rows="6"
              autocomplete="off"
              spellcheck="false"
              class="w-full textarea font-mono text-xs"
            ></textarea>
            <input
              :if={@form.params["kind"] != "chatgpt_login"}
              type="password"
              name="credential[secret]"
              id={"credential-secret-input-#{@seq}"}
              autocomplete="off"
              class="w-full input"
            />
          </label>
        </div>
        <.input
          :if={@form.params["kind"] == "access_token"}
          field={@form[:expires_on]}
          type="date"
          label="Expires on (optional: warned about, never enforced)"
        />
        <.input
          field={@form[:daily_limit]}
          type="text"
          label="Daily limit, weighted tokens (optional, not enforced)"
          placeholder="4M"
          autocomplete="off"
        />
        <.button variant="primary" phx-disable-with="Checking...">Add credential</.button>
      </.form>
    </section>
    """
  end

  attr :credential, :map, required: true
  attr :assigned, :list, required: true
  attr :projects, :list, required: true

  # Which projects' jobs this credential may pay for. A project with none cannot run a job at all
  # (`docs/design/credentials.md` § How a job picks), so a credential funding nothing says so.
  defp funds(assigns) do
    ~H"""
    <div class="flex w-full flex-wrap items-center gap-2 text-sm">
      <span class="opacity-60">Funds</span>
      <span
        :for={project <- @assigned}
        class="flex items-center gap-1 rounded-field border border-base-300 pl-2 font-mono text-[12.5px]"
      >
        {project.name}
        <button
          type="button"
          phx-click="unassign-credential"
          phx-value-credential={@credential.id}
          phx-value-project={project.id}
          class="min-h-[46px] min-w-[46px] opacity-60 hover:opacity-100"
          aria-label={"Stop funding #{project.name}"}
        >
          ×
        </button>
      </span>
      <span :if={@assigned == []} class="opacity-60">no project yet</span>
      <form
        :if={@projects != []}
        phx-submit="assign-credential"
        class="ml-auto flex items-center gap-2"
      >
        <input type="hidden" name="credential" value={@credential.id} />
        <select
          name="project"
          aria-label="Project"
          class="h-[46px] rounded-field border border-base-300 bg-base-100 px-2 text-sm"
        >
          <option :for={project <- @projects} value={project.id}>{project.name}</option>
        </select>
        <button type="submit" class="min-h-[46px] text-sm text-primary hover:underline">
          Assign
        </button>
      </form>
    </div>
    """
  end

  defp status(credential) do
    cond do
      Credentials.revoked?(credential) -> "revoked"
      credential.check_error -> "not checked: #{credential.check_error}"
      checked_by_shape?(credential) -> "not checked with OpenAI: the first job is the check"
      true -> "#{length(credential.models || [])} models"
    end
  end

  # A Codex credential is checked by its shape alone, so there is nothing to check again and nothing
  # the provider said (`docs/design/credentials.md` § Checked on save).
  defp checked_by_shape?(credential),
    do: Forge.Harness.traits(credential.harness, credential.kind).checked == :shape

  # What this kind of credential says of itself, as much as there is: a login's account and plan,
  # when Codex last renewed it, and whether a job holds it now; a token's expiry.
  defp detail(%{kind: "chatgpt_login"} = credential, in_use) do
    [
      credential.account_id && "account #{credential.account_id}",
      credential.plan && "#{credential.plan} plan",
      credential.renewed_at && "renewed #{Calendar.strftime(credential.renewed_at, "%Y-%m-%d")}",
      if(MapSet.member?(in_use, credential.id), do: "in use", else: "free")
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp detail(%{kind: "access_token", expires_on: %Date{} = on}, _in_use) do
    case Date.diff(on, Date.utc_today()) do
      days when days < 0 -> "expired"
      0 -> "expires today"
      1 -> "1 day left"
      days -> "#{days} days left"
    end
  end

  defp detail(_credential, _in_use), do: nil

  # In the last seven days, and after: the only warning there is, since nothing is enforced.
  defp expiring?(%{kind: "access_token", expires_on: %Date{} = on}),
    do: Date.diff(on, Date.utc_today()) <= 7

  defp expiring?(_credential), do: false
end
