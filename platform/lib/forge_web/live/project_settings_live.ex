defmodule ForgeWeb.ProjectSettingsLive do
  @moduledoc """
  A project's settings (`docs/design/ui.md` § Project settings): an index of sections, each with a
  one-line state, by `?section=` — tokens, people, the model and effort, secrets, and the branch
  and mirrors.

  This page exists because the product's own instructions were unfollowable without a terminal.
  The project page hands out a clone URL and says to push a `.forge/workflow.yml`, and until it
  existed `mix forge.git.token` was the only way to get the credential for either.

  **A token is shown once.** Only its hash is kept — the same as the worker token and the
  operator's API tokens — so afterwards a row can say what a token may do and when it was last
  used, and never what it is.

  **One page, three arrangements, drawn by CSS from one render.** On a phone the index is the
  page, a section replaces it, and a section's form (`&add=1`) replaces the section. From 768px
  the index is a column on the left; a section's form sits under it on a portrait screen and in
  the right-hand column on a wide one, so there it is always drawn. A bare `/settings` draws the
  first section beside the index from 768px, since a desktop has room for both and nothing to
  choose between.
  """

  use ForgeWeb, :live_view

  import ForgeWeb.Operator.Components,
    only: [breakable: 1, copyable: 1, effort_field: 1, model_field: 1, shown_once: 1]

  alias Forge.Git.{Tokens, Url}
  alias Forge.{Operator, Projects, Secrets, Tickets, Workers}
  alias ForgeWeb.{Format, Toast}

  require Logger

  # A token this close to its end is something to look at: the index row says so in warning.
  @lapsing_days 3

  @admin_sections ~w(tokens people agent secrets repository)
  @member_sections ~w(secrets repository)

  # The sections whose form is a screen of its own on a phone (`&add=1`).
  @adding ~w(tokens secrets repository)

  @member_blank %{"email" => "", "role" => "member"}

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    {project, scope} = ForgeWeb.Access.project_by_name!(socket.assigns.current_scope, name)

    {:ok,
     socket
     |> assign(
       project: project,
       page_title: "#{project.name} settings",
       # The secret, held only until the operator navigates away. It is never in a flash and
       # never in the URL: both outlive the moment it is useful.
       issued: nil,
       show_spent: false,
       error: nil,
       revoke_error: nil,
       member_error: nil,
       # What was typed into Add someone, drawn back after a refusal so it can be corrected
       # rather than typed again; emptied once someone is added.
       member_draft: @member_blank,
       people_error: nil,
       mirror_error: nil,
       mirrors_error: nil,
       defaults_error: nil,
       # The secret form's errors and the name it was sent with — never its value, which this
       # process is not given to keep. The nonce renews the form after a save, so the browser
       # drops the value it was holding rather than leaving it on screen.
       secret_error: nil,
       secret_name: "",
       secret_locked: false,
       secret_nonce: 0,
       # Whether this page may change anything here. The sections are hidden without it, and the
       # operations refuse without it, which is the half that matters.
       manage: Forge.Access.can?(scope, :manage)
     )
     |> assign(form: token_form(), nonce: nonce())
     |> ForgeWeb.Capacity.project(project)
     |> load()
     |> reset_defaults()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    sections = if socket.assigns.manage, do: @admin_sections, else: @member_sections
    section = if params["section"] in sections, do: params["section"]

    {:noreply,
     assign(socket,
       section: section,
       # What the middle draws: the section asked for, or on a desktop the first one.
       shown: section || hd(sections),
       adding: section in @adding and params["add"] == "1"
     )
     |> replacing(section, params["secret"])}
  end

  # Replace value: the secret form with the name filled and locked. Leaving it lets go of the name.
  defp replacing(socket, "secrets", name) when is_binary(name) and name != "",
    do: assign(socket, secret_name: name, secret_locked: true)

  defp replacing(%{assigns: %{secret_locked: true}} = socket, _section, _name),
    do: assign(socket, secret_name: "", secret_locked: false)

  defp replacing(socket, _section, _name), do: socket

  # Nothing that writes is preselected: git reads, the API is off, and the lifetime is short.
  defp token_form,
    do:
      to_form(
        %{"name" => "", "git" => "reader", "ticket" => "", "api" => "none", "days" => "7"},
        as: :token
      )

  # A second submit of the form this page rendered is a no-op: the nonce is spent by the first, so
  # a double click cannot make two tokens.
  defp nonce, do: 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp load(%{assigns: %{project: project, manage: manage}} = socket) do
    now = DateTime.utc_now()
    tokens = Tokens.list(project)
    secrets = Secrets.list(project)
    received_by = Secrets.received_by(project)
    tickets = Tickets.list(project)

    assign(socket,
      offered: Workers.offered(project.id),
      observed: Projects.observed_model(project),
      tickets: tickets,
      tokens: Enum.map(tokens, &decorate(&1, now, project, tickets)),
      members: project |> Projects.members() |> sort_people(socket.assigns.current_scope.user),
      # Mirrors are the admin's: a member's page neither lists nor counts them.
      # Failing first: the one a person came here about (UX pass, D17).
      mirrors:
        if(manage,
          do: project |> Projects.list_mirrors() |> Enum.sort_by(&(&1.last_status != "failed")),
          else: []
        ),
      secrets: secrets,
      # Each row says who receives it — the access list read backwards — the last run that held
      # it, and the live conversations holding it (`docs/design/secrets.md` § Surfaces).
      received_by: received_by,
      unreceived: Enum.count(secrets, &unreceived?(received_by, &1.name)),
      last_held: Secrets.last_held(project, secrets),
      held_by_chats: Secrets.held_by_conversations(project),
      clone_url: Url.for(project),
      now: now
    )
  end

  # The model and effort form, drawn from what is stored: on mount, after a save, on Discard.
  defp reset_defaults(%{assigns: %{project: project}} = socket) do
    assign(socket,
      defaults_form:
        to_form(
          %{
            "harness" => project.harness || ForgeCore.Harness.default(),
            "model" => project.model || "",
            "effort" => project.effort || "",
            "codex_model" => project.codex_model || "",
            "codex_effort" => project.codex_effort || ""
          },
          as: :project
        ),
      defaults_error: nil
    )
  end

  # You first, then the admins, then everyone else, each by address: an order that does not move
  # between two loads of the same page (UX pass, D23).
  defp sort_people(members, me),
    do: Enum.sort_by(members, &{&1.user_id != me.id, &1.role != :admin, &1.user.email})

  defp decorate(token, now, project, tickets) do
    live = Tokens.live?(token, now)
    held_by_job = is_binary(token.job_id)

    %{
      token: token,
      live: live,
      held_by_job: held_by_job,
      # A job's token lives for hours and the engine revokes it: its end is not news.
      lapsing:
        live and not held_by_job and
          DateTime.diff(token.expires_at, now, :second) < @lapsing_days * 86_400,
      capability: capability(token, project, tickets)
    }
  end

  # What it may do, in a sentence, which is the only thing about a token worth reading — in the
  # same words the form offered it with (`git_words/3`), on the list and on the band that shows it
  # once (UX pass, D13: the band said `admin`, the list another phrase, the form "push those").
  defp capability(token, project, tickets),
    do: "Git: #{git_words(token, project, tickets)} · API: #{api_words(token.api_access)}"

  @doc """
  What a token may do in git, in the one set of words the form, the list and the issued band
  share: *read every branch*, *write #1's branch*, *push any open ticket's branch*, *push any open
  ticket's branch and main*.
  """
  @spec git_words(map(), map(), [map()]) :: String.t()
  def git_words(%{git_access: :none}, _project, _tickets), do: "none"
  def git_words(%{git_access: :reader}, _project, _tickets), do: "read every branch"

  def git_words(%{git_access: :branch} = token, _project, tickets) do
    case Enum.find(tickets, &(&1.id == token.ticket_id)) do
      %{number: number} -> "write ##{number}'s branch"
      nil -> "write #{String.replace_prefix(token.ref || "a branch", "refs/heads/", "")}"
    end
  end

  def git_words(%{git_access: :developer}, _project, _tickets),
    do: "push any open ticket's branch"

  def git_words(%{git_access: :admin}, project, _tickets),
    do: "push any open ticket's branch and #{project.default_branch}"

  def git_words(%{git_access: access}, _project, _tickets), do: to_string(access)

  defp api_words(:none), do: "none"
  defp api_words(access), do: to_string(access)

  # Who issued it, and through which door it was last used.
  defp issuer(%{issued_by: %{email: email}}), do: email
  defp issuer(%{job_id: job_id}) when is_binary(job_id), do: "a job"
  # Not recorded: a token the mix task or a release made has no issuer, nor does one issued before
  # issuers were kept, nor one whose issuer's account has since gone — which the row cannot tell apart.
  defp issuer(_token), do: nil

  @impl true
  def handle_event("validate", %{"token" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: :token), error: nil)}
  end

  # The nonce is spent by the first submit; a repeat of the same form is ignored whole.
  def handle_event(
        "issue",
        %{"token" => %{"nonce" => nonce}},
        %{assigns: %{nonce: current}} = socket
      )
      when nonce != current,
      do: {:noreply, socket}

  def handle_event("issue", %{"token" => params}, socket) do
    with {:ok, opts} <- issue_opts(socket.assigns, params),
         {:ok, secret, token} <-
           Operator.issue_token(socket.assigns.project, socket.assigns.current_scope.user, opts) do
      {:noreply,
       socket
       |> assign(
         issued: %{
           url: Url.with_token(socket.assigns.project, secret),
           secret: secret,
           token: token
         },
         form: token_form(),
         nonce: nonce(),
         error: nil
       )
       |> load()
       |> push_patch(to: section_path(socket.assigns.project, "tokens"))}
    else
      # The form is hidden from a member; this is what refuses the event sent by hand.
      {:error, :forbidden} ->
        {:noreply, assign(socket, error: "Only an administrator can do that.")}

      {:error, reason} ->
        {:noreply, assign(socket, form: to_form(params, as: :token), error: message(reason))}
    end
  end

  # What was typed into the model and effort form, held so that a rejoin draws it back
  # (`docs/design/ui.md` § A reconnect is not a reload).
  def handle_event("defaults-change", %{"project" => params}, socket) when is_map(params),
    do: {:noreply, assign(socket, defaults_form: to_form(params, as: :project))}

  def handle_event("defaults-change", _params, socket), do: {:noreply, socket}

  def handle_event("defaults-discard", _params, socket), do: {:noreply, reset_defaults(socket)}

  # One Save for every dial — the harness, Claude Code's model and effort, Codex's model and
  # effort: `Operator.set_defaults/3` writes them all or none. Only the keys the form sent are
  # written, so a hand-sent event naming one leaves the others alone.
  def handle_event("defaults", %{"project" => params}, socket) when is_map(params) do
    %{project: project, current_scope: scope} = socket.assigns

    attrs =
      for {key, field} <- [
            {"harness", :harness},
            {"model", :model},
            {"effort", :effort},
            {"codex_model", :codex_model},
            {"codex_effort", :codex_effort}
          ],
          Map.has_key?(params, key),
          into: %{},
          do: {field, params[key]}

    case Operator.set_defaults(project, scope.user, attrs) do
      {:ok, project} ->
        {:noreply,
         socket
         |> assign(project: project)
         |> reset_defaults()
         |> Toast.put("Saved the agent's defaults.")
         |> load()}

      {:error, :forbidden} ->
        {:noreply, assign(socket, defaults_error: "Only an administrator can do that.")}

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           defaults_form: to_form(params, as: :project),
           defaults_error: "That was not saved, and no setting changed."
         )}
    end
  end

  def handle_event("defaults", _params, socket),
    do: {:noreply, assign(socket, defaults_error: "That was not saved, and no setting changed.")}

  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, issued: nil)}

  def handle_event("add-member", %{"member" => %{"email" => email, "role" => role}}, socket)
      when is_binary(email) and role in ["admin", "member"] do
    socket = assign(socket, member_draft: %{"email" => email, "role" => role})
    %{project: project, current_scope: scope} = socket.assigns

    case Forge.Accounts.get_user_by_email(String.trim(email)) do
      nil ->
        # Not "invited": there are no invitations, and an address nobody has approved is not a
        # person this node knows about yet. Saying so is the whole answer — and it is the answer
        # for a pending account too, which `Projects.put_member/4` refuses below.
        {:noreply, assign(socket, member_error: "No approved account for that address.")}

      user ->
        member(socket, :member_error, fn ->
          Projects.put_member(project, user, String.to_existing_atom(role), scope.user)
        end)
    end
  end

  # A role off the wire that is any other existing atom reached `put_member/4`'s `when` and
  # raised; one that is not an atom at all raised in `to_existing_atom`. Both crash the page.
  def handle_event("add-member", _params, socket),
    do: {:noreply, assign(socket, member_error: "Pick a role.")}

  # A role changed in place, on someone already here: `Projects.put_member/4` is the guard — it
  # refuses a member, and refuses making the last administrator a member whatever the page drew.
  # The id is resolved among this project's members, so the event cannot add anyone.
  def handle_event("set-role", %{"id" => id, "role" => role}, socket)
      when role in ["admin", "member"] do
    %{project: project, current_scope: scope} = socket.assigns

    case Enum.find(Projects.members(project), &(&1.user_id == id)) do
      nil ->
        {:noreply, assign(socket, people_error: "That account is not in this project.")}

      member ->
        member(socket, :people_error, fn ->
          Projects.put_member(project, member.user, String.to_existing_atom(role), scope.user)
        end)
    end
  end

  def handle_event("set-role", _params, socket),
    do: {:noreply, assign(socket, people_error: "Pick a role.")}

  def handle_event("remove-member", %{"id" => id}, socket) do
    %{project: project, current_scope: scope} = socket.assigns

    # `get_user!/1` on an id off the wire raises for any well-formed-but-unknown UUID.
    case Forge.Accounts.get_user(id) do
      nil ->
        {:noreply, assign(socket, people_error: "No such account.")}

      user ->
        member(socket, :people_error, fn -> Projects.remove_member(project, user, scope.user) end)
    end
  end

  def handle_event("toggle-spent", _params, socket),
    do: {:noreply, update(socket, :show_spent, &(not &1))}

  def handle_event("revoke", %{"id" => id}, socket) do
    # Through `Operator`, not `Tokens.revoke/1`: the id is the whole request, so the guard has to
    # both require `:manage` and resolve the token *inside this project*. A bare `Repo.get` let
    # any member revoke an admin's credential, and any project's admin revoke any token on the
    # node given its UUID. `issue` and `model` were routed here and this one was missed.
    case Operator.revoke_token(socket.assigns.project, socket.assigns.current_scope.user, id) do
      {:ok, _token} ->
        {:noreply, socket |> assign(revoke_error: nil) |> load()}

      {:error, :held_by_job} ->
        {:noreply,
         assign(socket,
           revoke_error:
             "That token belongs to a running job; the engine revokes it when the job ends."
         )}

      {:error, reason} when reason in [:not_found, :forbidden] ->
        {:noreply, load(socket)}
    end
  end

  # The guard is `Projects.put_mirror/5`'s, not this handler's — see its moduledoc and
  # `Forge.ProjectsMirrorTest`. This is what refuses the event when it is driven directly,
  # bypassing the `:if={@manage}` section that hides the form from a member.
  def handle_event("add-mirror", %{"mirror" => params}, socket) when is_map(params) do
    project = socket.assigns.project

    opts = [
      refs: blank_to_nil(params["refs"]),
      user: blank_to_nil(params["user"]),
      token: blank_to_nil(params["token"])
    ]

    case Projects.put_mirror(
           project,
           socket.assigns.current_scope.user,
           params["name"],
           params["url"],
           opts
         ) do
      :ok ->
        {:noreply,
         socket
         |> assign(mirror_error: nil)
         |> Toast.put("Mirror saved.")
         |> load()
         |> push_patch(to: section_path(project, "repository"))}

      {:error, reason} ->
        {:noreply, assign(socket, mirror_error: mirror_error(reason))}
    end
  end

  def handle_event("remove-mirror", %{"name" => name}, socket) do
    case Projects.delete_mirror(socket.assigns.project, socket.assigns.current_scope.user, name) do
      :ok ->
        {:noreply, socket |> assign(mirrors_error: nil) |> Toast.put("Mirror removed.") |> load()}

      {:error, reason} ->
        {:noreply, assign(socket, mirrors_error: mirror_error(reason))}
    end
  end

  # `Operator.set_secret/4` is the guard; this refuses the event sent by hand past the hidden form.
  # The value is passed straight through and never assigned: neither the reply nor this process's
  # state carries it, whatever happens (`docs/design/secrets.md` § Surfaces).
  def handle_event("set-secret", %{"secret" => %{} = params}, socket) do
    %{project: project, current_scope: scope} = socket.assigns
    name = params["name"]

    case set_secret(project, scope.user, name, params["value"]) do
      {:ok, secret} ->
        {:noreply,
         socket
         |> assign(secret_error: nil, secret_name: "", secret_locked: false)
         |> update(:secret_nonce, &(&1 + 1))
         |> Toast.put("Saved #{secret.name}, version #{secret.version}.")
         |> load()
         |> push_patch(to: section_path(project, "secrets"))}

      {:error, :forbidden} ->
        {:noreply, assign(socket, secret_error: "Only an administrator can do that.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           secret_error: secret_error(changeset),
           secret_name: if(is_binary(name), do: name, else: "")
         )}

      :failed ->
        {:noreply, assign(socket, secret_error: "That did not work, and nothing was saved.")}
    end
  end

  # Not this page's form: a client may send any shape under the event's name, and a clause that
  # raised on one would be a crash report carrying it.
  def handle_event("set-secret", _params, socket),
    do: {:noreply, assign(socket, secret_error: "That did not work, and nothing was saved.")}

  def handle_event("delete-secret", %{"id" => id}, socket) do
    case Operator.delete_secret(socket.assigns.project, socket.assigns.current_scope.user, id) do
      {:ok, secret} ->
        {:noreply, socket |> Toast.put("Deleted #{secret.name}.") |> load()}

      {:error, :forbidden} ->
        {:noreply, assign(socket, secret_error: "Only an administrator can do that.")}

      {:error, :not_found} ->
        {:noreply, load(socket)}
    end
  end

  def handle_event("delete-secret", _params, socket), do: {:noreply, load(socket)}

  # The one call on this page that holds a value, and so the one whose failure must not escape. A
  # LiveView that raises is logged with its last message, unfiltered — `:filter_parameters` covers
  # the event log and not a crash report — and this one's last message is the form, value and all.
  # So any failure is caught here and logged by its kind, never its reason or stacktrace: a reason
  # can quote what it was given, and a stacktrace's top frame can carry the arguments.
  defp set_secret(project, user, name, value) do
    Operator.set_secret(project, user, name, value)
  catch
    kind, reason ->
      Logger.error("setting a project secret failed: #{failure(kind, reason)}")
      :failed
  end

  defp failure(:error, %{__exception__: true, __struct__: module}), do: inspect(module)
  defp failure(kind, _reason), do: to_string(kind)

  # The changeset's messages, field first. Never the value: a changeset's errors carry the rule
  # broken, and the rule is all a person needs to see.
  defp secret_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{label(field)} #{&1}") end)
    |> Enum.join(" ")
  end

  defp label(:name), do: "The name"
  defp label(:value), do: "The value"

  # Each reason names the rule it broke, because "invalid" sends an operator to read the source.
  defp mirror_error(:scheme), do: "A mirror must be https:// or http://."
  defp mirror_error(:transport_helper), do: "A mirror must be https:// or http://."
  defp mirror_error(:option_like), do: "A mirror must be https:// or http://."
  defp mirror_error(:credentials_in_url), do: "Put the token in its own field, not in the URL."
  defp mirror_error(:no_host), do: "That URL names no host."
  defp mirror_error(:invalid_name), do: "A name may use a-z, 0-9 and hyphens."
  defp mirror_error(:forbidden), do: "Only a project admin may change mirrors."

  # `put_mirror/5` refuses a project whose repository is not at `<repos_dir>/<name>.git`
  # (`register/2` with an arbitrary path, not `register_named/3`): the credential this page
  # would write and the path the hook derives it from disagree, and an authenticated mirror
  # would fail every push with nothing louder than a `lastError`. Naming it here is the loud
  # refusal instead. See `Forge.Projects.put_mirror/5`.
  defp mirror_error(:repo_path_not_standard),
    do:
      "This project's repository is not at the standard path, so a mirror credential would " <>
        "not be found by the push that needs it. It has to be re-registered at the standard " <>
        "path before it can have a mirror."

  defp mirror_error(_other), do: "That did not work."

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # Who is in the project, changed: the error goes where the person acted — `:member_error` under
  # the address they typed, `:people_error` over the rows they pressed in.
  defp member(socket, error_key, fun) do
    case fun.() do
      # The same words as an address with no account at all: a pending account is not a person
      # this project can have yet, and `Projects.put_member/4` is what says so.
      {:error, :not_approved} ->
        {:noreply, assign(socket, error_key, "No approved account for that address.")}

      {:error, :suspended} ->
        {:noreply, assign(socket, error_key, "That account is suspended.")}

      {:error, :last_admin} ->
        {:noreply, assign(socket, error_key, last_admin())}

      {:error, :forbidden} ->
        {:noreply, assign(socket, error_key, "Only an administrator can do that.")}

      {:error, _reason} ->
        {:noreply, assign(socket, error_key, "That did not work.")}

      _ok ->
        {:noreply,
         socket
         |> assign(member_error: nil, people_error: nil, member_draft: @member_blank)
         |> load()}
    end
  end

  # What changing a role asks first, or nil when it is asked nothing: granting admin changes who
  # can change everything on the project (UX pass, D23), and making yourself a member takes that
  # from you.
  defp role_question("admin", member, _me, project),
    do:
      "Make #{member.user.email} an admin of #{project.name}? They can change everything here, people included."

  defp role_question("member", %{user_id: id}, %{id: id}, _project),
    do: "Make yourself a member? You will no longer be able to change these settings."

  defp role_question(_role, _member, _me, _project), do: nil

  # The role changes on a row that are asked first, each with its question.
  defp asked(%{role: :admin}, true, _me, _project), do: []

  defp asked(member, _sole_admin, me, project) do
    for role <- ~w(member admin),
        to_string(member.role) != role,
        question = role_question(role, member, me, project),
        do: {role, question}
  end

  defp last_admin, do: "A project keeps at least one administrator."

  # What the form asks for, as `Forge.Git.Tokens.issue/2` takes it. A job-scoped token is the
  # engine's to mint — see docs/design/git-hosting.md § Issuing a token — and no field here can
  # name one. The default-branch-only shape is no longer offered: `admin` replaces it.
  defp issue_opts(assigns, params) do
    with {:ok, name} <- name(params),
         {:ok, days} <- days(params),
         {:ok, git} <-
           choice(params["git"], ~w(none reader branch developer admin), "git access"),
         {:ok, api} <- choice(params["api"], ~w(none read write), "API access"),
         {:ok, branch} <- branch(assigns, git, params) do
      {:ok, [name: name, days: days, git: git, api: api] ++ branch}
    end
  end

  defp name(params) do
    name = String.trim(params["name"] || "")

    cond do
      name == "" ->
        {:error, "Give the token a name; it is how you will recognise it later."}

      String.length(name) > Forge.Git.Token.name_max() ->
        {:error, "A name is at most 60 characters."}

      true ->
        {:ok, name}
    end
  end

  # The bound is `Tokens.issue/2`'s as well, with the same words, so dropping the check here
  # changes nothing a person can see: an equivalent mutant, kept so the page refuses before it asks.
  defp days(params) do
    case Integer.parse(String.trim(params["days"] || "")) do
      {n, ""} when n >= 1 -> if n <= Tokens.max_days(), do: {:ok, n}, else: too_long()
      _other -> too_long()
    end
  end

  defp too_long, do: {:error, "Days must be a whole number from 1 to #{Tokens.max_days()}."}

  defp choice(value, allowed, what) do
    if value in allowed,
      do: {:ok, String.to_existing_atom(value)},
      else: {:error, "Choose the #{what}."}
  end

  defp branch(assigns, :branch, params) do
    case Enum.find(assigns.tickets, &(to_string(&1.number) == params["ticket"])) do
      nil ->
        {:error, "Choose the ticket whose branch this token may write."}

      ticket ->
        {:ok, [ticket_id: ticket.id, ref: "refs/heads/" <> ticket.branch]}
    end
  end

  defp branch(_assigns, _git, _params), do: {:ok, []}

  defp message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp message({:bad_days, max}), do: "Days must be a whole number from 1 to #{max}."
  defp message(message) when is_binary(message), do: message
  defp message(_reason), do: "That did not work."

  defp section_path(project, nil), do: ~p"/projects/#{project.name}/settings"

  defp section_path(project, section),
    do: ~p"/projects/#{project.name}/settings?section=#{section}"

  defp add_path(project, section),
    do: ~p"/projects/#{project.name}/settings?section=#{section}&add=1"

  defp replace_path(project, name),
    do: ~p"/projects/#{project.name}/settings?#{[section: "secrets", add: "1", secret: name]}"

  # -- the page -------------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        # What a phone draws beside the section: its form instead of it (`form`), or under it
        # (`foot`, people's Add someone); nothing on the index or a section with no form.
        aside: aside(assigns),
        back: back(assigns)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      frame={@frame}
      capacity={@capacity}
      title="Settings"
      subline={"#{@project.name} · you are #{if @manage, do: "an admin", else: "a member"}"}
      context={{@project.name, ~p"/projects/#{@project.name}"}}
      views={ForgeWeb.ProjectLive.strip(@project, %{}, :navigate)}
      measure={nil}
    >
      <:list>
        <.index {assigns} />
      </:list>

      <div id="settings" class="settings" data-aside={@aside}>
        <.link :if={@back} patch={elem(@back, 1)} class="settings-back">‹ {elem(@back, 0)}</.link>
        <div class={["settings-main", is_nil(@section) && "settings-desk"]}>
          <.tokens :if={@shown == "tokens"} {assigns} />
          <.people :if={@shown == "people"} {assigns} />
          <.agent :if={@shown == "agent"} {assigns} />
          <.secrets :if={@shown == "secrets"} {assigns} />
          <.repository :if={@shown == "repository"} {assigns} />
        </div>
      </div>

      <:aside :if={@manage and @shown in ~w(tokens people secrets repository)}>
        <div class={["settings-aside", is_nil(@section) && "settings-desk"]}>
          <.issue_form :if={@shown == "tokens" and is_nil(@issued)} {assigns} />
          <.issued
            :if={@shown == "tokens" and @issued}
            issued={@issued}
            project={@project}
            tickets={@tickets}
          />
          <.add_member :if={@shown == "people"} {assigns} />
          <.set_secret :if={@shown == "secrets"} {assigns} />
          <.add_mirror :if={@shown == "repository"} {assigns} />
        </div>
      </:aside>
    </Layouts.app>
    """
  end

  defp aside(%{section: nil}), do: nil
  defp aside(%{manage: false}), do: nil
  defp aside(%{section: "tokens", issued: issued}) when issued != nil, do: "form"
  defp aside(%{section: "people"}), do: "foot"
  defp aside(%{adding: true}), do: "form"
  defp aside(_assigns), do: nil

  # The phone's way back within the page: from a form to its section, from a section to the index.
  defp back(%{section: nil}), do: nil

  defp back(%{section: "tokens", issued: issued}) when issued != nil, do: nil

  defp back(%{adding: true, section: section, project: project}),
    do: {section_title(section), section_path(project, section)}

  defp back(%{project: project}), do: {"Settings", section_path(project, nil)}

  defp section_title("tokens"), do: "Tokens"
  defp section_title("people"), do: "People"
  defp section_title("agent"), do: "Harness, model and effort"
  defp section_title("secrets"), do: "Secrets"
  defp section_title("repository"), do: "Branch and mirrors"

  # -- the index ------------------------------------------------------------------------------

  defp index(assigns) do
    ~H"""
    <nav id="settings-sections" class="settings-index" data-open={@section && "true"}>
      <%= if @manage do %>
        <div class="settings-group">
          <.eyebrow>Access</.eyebrow>
        </div>
        <.section_row key="tokens" {assigns} />
        <.section_row key="people" {assigns} />
        <div class="settings-group">
          <.eyebrow>Agent</.eyebrow>
        </div>
        <.section_row key="agent" {assigns} />
        <.section_row key="secrets" {assigns} />
        <div class="settings-group">
          <.eyebrow>Repository</.eyebrow>
        </div>
        <.section_row key="repository" {assigns} />
      <% else %>
        <div class="settings-group">
          <.eyebrow>Agent</.eyebrow>
        </div>
        <.section_row key="secrets" {assigns} />
        <div class="settings-group">
          <.eyebrow>Repository</.eyebrow>
        </div>
        <.section_row key="repository" {assigns} />
      <% end %>

      <div class="settings-clone">
        <.copyable id="clone-url" value={@clone_url} label="Clone URL" />
        <p class="settings-note">The username is ignored; a token is the password.</p>
      </div>
    </nav>
    """
  end

  defp section_row(assigns) do
    {state, tone} = state(assigns.key, assigns)
    assigns = assign(assigns, state: state, tone: tone)

    ~H"""
    <.list_row
      id={"section-#{@key}"}
      title={if @key == "repository" and not @manage, do: "Branch", else: section_title(@key)}
      latest={@state}
      latest_tone={@tone}
      selected={@shown == @key}
      patch={section_path(@project, @key)}
    />
    """
  end

  # Each section's one line, and whether it is something to look at.
  defp state("tokens", %{tokens: tokens}) do
    live = Enum.count(tokens, & &1.live)

    case Enum.count(tokens, & &1.lapsing) do
      0 -> {"#{live} live", nil}
      1 -> {"#{live} live · 1 expires within #{@lapsing_days} days", "warning"}
      n -> {"#{live} live · #{n} expire within #{@lapsing_days} days", "warning"}
    end
  end

  defp state("people", %{members: members}) do
    admins = Enum.count(members, &(&1.role == :admin))
    {"#{count(length(members), "person", "people")} · #{count(admins, "admin", "admins")}", nil}
  end

  # The harness the project runs on, then that harness's own model and effort.
  defp state("agent", %{project: project}) do
    {model, effort, fallback} =
      case project.harness do
        "codex" -> {project.codex_model, project.codex_effort, "Codex's"}
        _claude -> {project.model, project.effort, "the machine's"}
      end

    {"#{Forge.Harness.label(project.harness || ForgeCore.Harness.default())} · model: " <>
       "#{model || fallback} · effort: #{effort || fallback}", nil}
  end

  defp state("secrets", %{secrets: []}), do: {"none set", nil}
  defp state("secrets", %{secrets: secrets, unreceived: 0}), do: {"#{length(secrets)} set", nil}

  # A member cannot fix it, so the warning says whom to tell (UX pass, D26).
  defp state("secrets", %{secrets: secrets, unreceived: n, manage: manage}),
    do:
      {"#{length(secrets)} set · #{n} that nothing receives" <>
         if(manage, do: "", else: " — ask an admin"), "warning"}

  defp state("repository", %{project: project, mirrors: mirrors}) do
    case Enum.filter(mirrors, &(&1.last_status == "failed")) do
      [] ->
        {project.default_branch, nil}

      failing ->
        names = Enum.map_join(failing, ", ", & &1.name)
        {"#{project.default_branch} · #{names} #{mirror_word(failing)} failing", "danger"}
    end
  end

  defp mirror_word([_one]), do: "mirror"
  defp mirror_word(_many), do: "mirrors"

  defp count(1, one, _many), do: "1 #{one}"
  defp count(n, _one, many), do: "#{n} #{many}"

  # -- tokens ---------------------------------------------------------------------------------

  # Credentials are the admin's, both halves. The list is not merely a readout: it names every
  # token's id, which is the whole input the revoke button needs.
  defp tokens(assigns) do
    assigns =
      assign(assigns,
        live_count: Enum.count(assigns.tokens, & &1.live),
        spent_count: Enum.count(assigns.tokens, &(not &1.live))
      )

    ~H"""
    <section id="tokens-section" aria-labelledby="tokens-heading">
      <div class="settings-heading">
        <h2 id="tokens-heading">Tokens</h2>
        <span class="settings-count">{@live_count} live</span>
      </div>

      <p :if={@tokens == []} class="settings-note">
        A token lets an outside program — a script, a dashboard, <code>curl</code>
        — read this project's tickets and their documents, push to git, or both. It is shown once
        when issued; after that a row says what it may do and when it was last used, never what it
        is.
      </p>

      <.error_note :if={@revoke_error} class="settings-error">{@revoke_error}</.error_note>

      <table :if={@tokens != []} id="tokens" class="settings-table">
        <thead>
          <tr>
            <th>Token</th>
            <th>It may</th>
            <th class="settings-desk">Expires</th>
            <th>Last used</th>
            <th><span class="sr-only">Revoke</span></th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={row <- @tokens}
            :if={@show_spent or row.live}
            id={"token-#{row.token.id}"}
            class={[not row.live && "settings-spent"]}
          >
            <td>
              <div class="settings-name-line">
                <span class="settings-name">{row.token.name || "a job's token"}</span>
                <span class={["settings-phone", row.lapsing && "settings-warning"]}>
                  {expiry(row, @now)}
                </span>
              </div>
              <div :if={issuer(row.token)} class="settings-sub">
                issued by {issuer(row.token)}
              </div>
            </td>
            <td class="settings-capability">{row.capability}</td>
            <td class={["settings-desk settings-mono", row.lapsing && "settings-warning"]}>
              {expiry(row, @now)}
            </td>
            <td class="settings-sub">
              {(row.token.last_used_at &&
                  "used #{ago(row.token.last_used_at, @now)} via #{row.token.last_used_via || "git"}") ||
                "never used"}
            </td>
            <td class="settings-act">
              <.confirm
                :if={row.live and not row.held_by_job}
                id={"revoke-#{row.token.id}"}
                label="Revoke"
                act="Revoke it"
                sentence="Revoke this token? Anything using it stops working."
                phx-click="revoke"
                phx-value-id={row.token.id}
                phx-disable-with="Revoking…"
              />
              <span :if={row.live and row.held_by_job} class="settings-sub">
                held by a job · revoked when it ends
              </span>
            </td>
          </tr>
        </tbody>
      </table>

      <.button
        :if={@spent_count > 0}
        type="button"
        variant="quiet"
        size="sm"
        phx-click="toggle-spent"
        class="settings-toggle"
      >
        {if @show_spent,
          do: "Hide expired and revoked",
          else: "Show expired and revoked · #{@spent_count}"}
      </.button>

      <.button
        variant="outline"
        size="lg"
        patch={add_path(@project, "tokens")}
        class="settings-phone settings-add"
      >
        + Issue a token
      </.button>
    </section>
    """
  end

  defp expiry(%{live: true, token: token}, now) do
    case Format.ago(now, token.expires_at) do
      "now" -> "in under a minute"
      left -> "in " <> left
    end
  end

  defp expiry(%{token: token}, now), do: spent(token, now)

  defp issue_form(assigns) do
    ~H"""
    <section id="issue" aria-labelledby="issue-heading">
      <h2 id="issue-heading" class="settings-form-title">Issue a token</h2>
      <p class="settings-note">
        For <span class="settings-mono">{breakable(@clone_url)}</span>. The username is
        ignored; the token is the password.
      </p>

      <.form
        for={@form}
        id="token-form"
        phx-change="validate"
        phx-submit="issue"
        class="settings-form"
      >
        <input type="hidden" name="token[nonce]" value={@nonce} />

        <.input field={@form[:name]} type="text" label="Name" maxlength="60" mono />

        <fieldset class="settings-fieldset settings-span">
          <legend class="settings-legend">Git: it may</legend>
          <.choice_row
            :for={{value, words, detail} <- git_choices(@project)}
            id={"token-git-#{value}"}
            name="token[git]"
            value={value}
            label={words}
            detail={@form[:git].value == value && detail}
            selected={@form[:git].value == value}
          />
        </fieldset>

        <.input
          :if={@form[:git].value == "branch"}
          field={@form[:ticket]}
          type="select"
          label="Ticket"
          prompt="choose one"
          options={Enum.map(@tickets, &{"##{&1.number} #{&1.title}", &1.number})}
        />

        <p :if={@form[:git].value == "branch" and @tickets == []} class="settings-warning">
          This project has no tickets yet, so there is no branch to write.
        </p>

        <fieldset class="settings-fieldset">
          <legend class="settings-legend">API: it may</legend>
          <.segmented
            id="token-api"
            name="token[api]"
            value={@form[:api].value}
            options={[{"none", "none"}, {"read", "read"}, {"read and write", "write"}]}
          />
        </fieldset>

        <div class="settings-fieldset">
          <label for="token-days" class="settings-legend">Days it lasts</label>
          <.stepper
            id="token-days"
            name="token[days]"
            value={@form[:days].value}
            min={1}
            max={Tokens.max_days()}
          />
        </div>

        <.error_note :if={@error} id="token-error" class="settings-error settings-span">
          {@error}
        </.error_note>

        <.button
          type="submit"
          variant="primary"
          size="xl"
          fill
          phx-disable-with="Issuing…"
          class="settings-span"
        >
          Issue it
        </.button>
      </.form>
    </section>
    """
  end

  # The five scopes, nothing that writes first. The last is named after the branch it reaches and
  # carries why it is worth choosing on purpose (`docs/design/git-hosting.md` § One project token).
  defp git_choices(project) do
    [
      {"none", "not use git", nil},
      {"reader", "read every branch", nil},
      {"branch", "write one ticket's branch", nil},
      {"developer", "push any open ticket's branch", nil},
      {"admin", "push any open ticket's branch and #{project.default_branch}",
       "The default branch is what every job builds on. It is fast-forward only, like the " <>
         "platform's own merge, and every credential a job holds is refused it."}
    ]
  end

  # Once, and only here: the row will never be able to show it again.
  attr :issued, :map, required: true
  attr :project, :map, required: true
  attr :tickets, :list, required: true

  defp issued(assigns) do
    ~H"""
    <section id="issued" aria-labelledby="issued-heading">
      <.eyebrow>Token issued</.eyebrow>
      <h2 id="issued-heading" class="settings-form-title">{@issued.token.name}</h2>
      <.shown_once id="issued-once" done="dismiss">
        <:note>
          {capability(@issued.token, @project, @tickets)}, until {Calendar.strftime(
            @issued.token.expires_at,
            "%-d %b %Y"
          )}.
        </:note>
        <.copyable id="issued-secret" value={@issued.secret} label="Token" />
        <.copyable
          :if={@issued.token.api_access != :none}
          id="issued-curl"
          value={"curl -H \"Authorization: Bearer #{@issued.secret}\" #{ForgeWeb.Endpoint.url()}/api/v1/tickets"}
          label="Use it on the API"
        />
        <.copyable
          :if={@issued.token.git_access != :none}
          id="issued-url"
          value={@issued.url}
          label="Clone URL, token included"
        />
      </.shown_once>
    </section>
    """
  end

  # -- people ---------------------------------------------------------------------------------

  defp people(assigns) do
    admins = Enum.count(assigns.members, &(&1.role == :admin))
    assigns = assign(assigns, sole_admin: admins == 1)

    ~H"""
    <section id="people" aria-labelledby="people-heading">
      <div class="settings-heading">
        <h2 id="people-heading">People</h2>
        <span class="settings-count">{length(@members)}</span>
      </div>
      <p class="settings-note">
        Everyone here can run the work. Administrators can also change these settings and this
        list.
      </p>

      <.error_note :if={@people_error} id="people-error" class="settings-error">
        {@people_error}
      </.error_note>

      <ul id="members" class="settings-people">
        <li :for={member <- @members} id={"member-#{member.user_id}"} class="settings-person">
          <span class="settings-person-name">
            <span class="settings-mono settings-break">{member.user.email}</span>
            <span :if={member.user_id == @current_scope.user.id} class="settings-sub">· you</span>
          </span>

          <%!-- One control for a role, the add form's member | admin (UX pass, A14), changed in
                place. Granting admin, and giving up your own, are asked first in place: one
                changes who can change everything here, the other locks you out of it (D23). --%>
          <div id={"role-#{member.user_id}"} class="settings-role">
            <div role="radiogroup" aria-label="Role" class="ui-seg ui-seg--sm settings-role-seg">
              <%= for role <- ~w(member admin) do %>
                <button
                  :if={to_string(member.role) == role or (@sole_admin and member.role == :admin)}
                  type="button"
                  role="radio"
                  class="ui-seg-opt"
                  aria-checked={to_string(to_string(member.role) == role)}
                  phx-value-role={role}
                  disabled
                >
                  {role}
                </button>
                <button
                  :if={
                    to_string(member.role) != role and not (@sole_admin and member.role == :admin) and
                      role_question(role, member, @current_scope.user, @project) != nil
                  }
                  type="button"
                  role="radio"
                  class="ui-seg-opt"
                  aria-checked="false"
                  aria-controls={"role-#{member.user_id}-#{role}-confirm"}
                  phx-click={
                    JS.show(to: "#role-#{member.user_id}-#{role}-confirm", display: "flex")
                    |> JS.focus(to: "#role-#{member.user_id}-#{role}-keep")
                  }
                >
                  {role}
                </button>
                <button
                  :if={
                    to_string(member.role) != role and not (@sole_admin and member.role == :admin) and
                      is_nil(role_question(role, member, @current_scope.user, @project))
                  }
                  type="button"
                  role="radio"
                  class="ui-seg-opt"
                  aria-checked="false"
                  phx-click="set-role"
                  phx-value-id={member.user_id}
                  phx-value-role={role}
                >
                  {role}
                </button>
              <% end %>
            </div>
            <.confirm
              :for={{role, question} <- asked(member, @sole_admin, @current_scope.user, @project)}
              id={"role-#{member.user_id}-#{role}"}
              label={role}
              act={if role == "admin", do: "Make them admin", else: "Make me a member"}
              sentence={question}
              tone="neutral"
              class="settings-role-confirm"
              phx-click="set-role"
              phx-value-id={member.user_id}
              phx-value-role={role}
            />
          </div>

          <%= if @sole_admin and member.role == :admin do %>
            <.button
              type="button"
              variant="quiet"
              size="sm"
              disabled
              class="settings-x"
              aria-label={"Remove #{member.user.email}"}
            >
              ×
            </.button>
            <p class="settings-sub settings-person-reason">{last_admin()}</p>
          <% else %>
            <.confirm
              id={"remove-#{member.user_id}"}
              label="×"
              aria_label={"Remove #{member.user.email}"}
              act="Remove them"
              sentence={"Remove #{member.user.email} from #{@project.name}? They can no longer see it or run its work."}
              trigger="quiet"
              class="ui-confirm--inline"
              phx-click="remove-member"
              phx-value-id={member.user_id}
            />
          <% end %>
        </li>
      </ul>
    </section>
    """
  end

  defp add_member(assigns) do
    ~H"""
    <section id="add-someone" aria-labelledby="add-someone-heading">
      <h2 id="add-someone-heading" class="settings-form-title">Add someone</h2>
      <.form
        :let={f}
        for={to_form(@member_draft, as: :member)}
        id="add-member-form"
        phx-submit="add-member"
        class="settings-form"
      >
        <.input
          field={f[:email]}
          type="email"
          label="Address"
          mono
          hint="There are no invitations: the address needs an approved account."
        />
        <%!-- Next to the field it is about (`docs/design/ui.md` § Errors stay where you acted). --%>
        <.error_note :if={@member_error} id="member-error" class="settings-error">
          {@member_error}
        </.error_note>
        <.segmented
          id="member-role"
          name="member[role]"
          value={@member_draft["role"]}
          options={[{"member", "member"}, {"admin", "admin"}]}
        />
        <.button type="submit" variant="primary" size="xl" fill>Add them</.button>
      </.form>
    </section>
    """
  end

  # -- model and effort -----------------------------------------------------------------------

  # Behind `@manage` like every other form here: `Operator.set_defaults/3` refuses a member.
  defp agent(assigns) do
    levels = assigns.offered.efforts
    stored = assigns.defaults_form[:effort].value
    kept = if stored not in [nil, ""] and stored not in levels, do: [{"#{stored} · set", stored}]

    assigns =
      assign(assigns,
        free_effort: levels == [],
        effort_options: [{"the machine's", ""} | Enum.map(levels, &{&1, &1})] ++ (kept || [])
      )

    ~H"""
    <section id="agent" aria-labelledby="agent-heading">
      <div class="settings-heading">
        <h2 id="agent-heading">Harness, model and effort</h2>
      </div>
      <p class="settings-note">
        What this project's work runs on when a workflow state does not name its own. Left on <em>the machine's</em>, the harness picks.
      </p>

      <.form
        for={@defaults_form}
        id="defaults-form"
        phx-change="defaults-change"
        phx-submit="defaults"
        class="settings-form settings-form--single"
      >
        <%!-- Which harness runs the project's work when a workflow state names none, and what a
              new conversation starts on. Each harness keeps its own model and effort below. --%>
        <fieldset id="project-harness" class="settings-fieldset">
          <legend class="settings-legend">Harness</legend>
          <.segmented
            id="project_harness"
            name="project[harness]"
            value={@defaults_form[:harness].value}
            options={for h <- Forge.Harness.names(), do: {Forge.Harness.label(h), h}}
          />
        </fieldset>

        <.eyebrow>Claude Code</.eyebrow>
        <div>
          <.model_field
            field={@defaults_form[:model]}
            offered={@offered}
            label="Model"
            fallback="the machine's"
          />
          <p :if={@observed} id="model-observed" class="settings-sub">
            the machine's · last observed {@observed.model}, {ago(@observed.at, @now)}
          </p>
        </div>

        <.input
          :if={@free_effort}
          field={@defaults_form[:effort]}
          type="text"
          label="Effort"
          autocomplete="off"
          hint="How hard it thinks. No connected worker offers a level; type one, or leave it for the machine's."
        />

        <fieldset :if={not @free_effort} class="settings-fieldset">
          <legend class="settings-legend">Effort</legend>
          <.segmented
            :if={length(@effort_options) <= 4}
            id="project_effort"
            name="project[effort]"
            value={@defaults_form[:effort].value}
            options={@effort_options}
          />
          <div :if={length(@effort_options) > 4} id="project_effort">
            <.choice_row
              :for={{{words, value}, i} <- Enum.with_index(@effort_options)}
              id={"project_effort_#{i}"}
              name="project[effort]"
              value={value}
              label={words}
              selected={to_string(@defaults_form[:effort].value) == value}
            />
          </div>
        </fieldset>

        <%!-- Codex's own dials: nothing lists Codex's models, so the model is typed, and empty
              is Codex's own default; its levels are the connected machines' (a box while none
              offers one). --%>
        <.eyebrow>Codex</.eyebrow>
        <.input
          field={@defaults_form[:codex_model]}
          type="text"
          label="Model"
          placeholder="Codex's own default"
          autocomplete="off"
        />
        <.effort_field
          offered={%{@offered | efforts: @offered.codex_efforts}}
          field={@defaults_form[:codex_effort]}
          label="Effort"
          fallback="Codex's own default"
        />

        <p class="settings-note">
          A workflow state that names its own harness, model or effort keeps it. Saved changes
          apply to jobs that start after them.
        </p>

        <.error_note :if={@defaults_error} id="defaults-error" class="settings-error">
          {@defaults_error}
        </.error_note>

        <div class="settings-dock">
          <.button type="button" size="xl" phx-click="defaults-discard">Discard</.button>
          <.button type="submit" variant="primary" size="xl" fill>Save</.button>
        </div>
      </.form>
    </section>
    """
  end

  # -- secrets --------------------------------------------------------------------------------

  # `docs/design/secrets.md` § Surfaces: the list for every member, because a workflow's author
  # needs the names; setting and deleting for an admin, refused by `Operator.set_secret/4` and
  # `delete_secret/3` without one. No value is ever drawn, because none is ever loaded.
  defp secrets(assigns) do
    ~H"""
    <section id="secrets" aria-labelledby="secrets-heading">
      <div class="settings-heading">
        <h2 id="secrets-heading">Secrets</h2>
        <span class="settings-count">{length(@secrets)}</span>
      </div>
      <p class="settings-note">
        Handed to a job when its state or command names them, and to a chat when the person
        opening it picks them, in its environment. Once set, a value is never shown again, to
        anyone.
      </p>

      <p :if={@secrets == []} class="settings-note">None yet.</p>

      <.error_note :if={not @manage and @secret_error} class="settings-error">
        {@secret_error}
      </.error_note>

      <table :if={@secrets != []} id="secret-rows" class="settings-table">
        <thead>
          <tr>
            <th>Name</th>
            <th>Received by</th>
            <th>Set by</th>
            <th :if={@manage}><span class="sr-only">Delete</span></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={secret <- @secrets} id={"secret-#{secret.id}"}>
            <td>
              <div class="settings-name settings-break">{secret.name}</div>
              <div class="settings-sub">v{secret.version} · set {ago(secret.set_at, @now)}</div>
            </td>
            <td>
              <div class={[unreceived?(@received_by, secret.name) && "settings-warning"]}>
                {ticked(received(@received_by, secret.name))}
              </div>
              <div :if={@held_by_chats[secret.name]} class="settings-sub">
                {chats(@held_by_chats[secret.name])}
              </div>
              <div class="settings-sub">{held(@last_held[secret.id], @now)}</div>
            </td>
            <td class="settings-sub">
              set by {(secret.set_by && secret.set_by.email) || "an account since removed"}
            </td>
            <td :if={@manage} class="settings-act">
              <%!-- Rotating a value is setting it again under the same name: the form, with the
                    name filled and locked (UX pass, D18). Side by side in the row's one slot for
                    acts, the destructive one last (UX re-check #13). --%>
              <div class="ui-row-acts">
                <.button
                  id={"replace-secret-#{secret.id}"}
                  variant="link"
                  size="sm"
                  patch={replace_path(@project, secret.name)}
                >
                  Replace value
                </.button>
                <.confirm
                  id={"delete-secret-#{secret.id}"}
                  label="Delete"
                  act="Delete it"
                  sentence={"Delete #{secret.name}? Its value is destroyed, and a job whose workflow names it stops until it is set again."}
                  class="ui-confirm--inline"
                  phx-click="delete-secret"
                  phx-value-id={secret.id}
                />
              </div>
            </td>
          </tr>
        </tbody>
      </table>

      <.button
        :if={@manage}
        variant="outline"
        size="lg"
        patch={add_path(@project, "secrets")}
        class="settings-phone settings-add"
      >
        + Set a secret
      </.button>
    </section>
    """
  end

  defp set_secret(assigns) do
    ~H"""
    <section id="set-secret" aria-labelledby="set-secret-heading">
      <h2 id="set-secret-heading" class="settings-form-title">
        {if @secret_locked, do: "Replace a value", else: "Set a secret"}
      </h2>
      <.form
        :let={f}
        for={to_form(%{"name" => @secret_name}, as: :secret)}
        id={"secret-form-#{@secret_nonce}"}
        phx-submit="set-secret"
        class="settings-form settings-form--single"
      >
        <.input
          field={f[:name]}
          type="text"
          label="Name"
          placeholder="e.g. SENTRY_DSN"
          readonly={@secret_locked}
          mono
        />
        <%!-- Write-only: rendered empty every time, because nothing keeps a value to render.
              No `phx-change`, so what is typed reaches the server once, on submit. Drawn as dots
              until shown, for a phone over someone's shoulder, and a textarea still, for a value
              of several lines (UX pass, D19). --%>
        <.input
          field={f[:value]}
          id={"secret-value-#{@secret_nonce}"}
          type="textarea"
          label="Value"
          rows="3"
          autocomplete="off"
          spellcheck="false"
          class="settings-masked"
          mono
          hint="Setting a name that exists replaces its value."
        />
        <.button
          type="button"
          variant="quiet"
          size="sm"
          class="settings-reveal"
          aria-controls={"secret-value-#{@secret_nonce}"}
          phx-click={JS.toggle_class("settings-masked", to: "#secret-value-#{@secret_nonce}")}
        >
          Show or hide the value
        </.button>
        <.error_note :if={@secret_error} id="secret-error" class="settings-error">
          {@secret_error}
        </.error_note>
        <.button type="submit" variant="primary" size="xl" fill>Set it</.button>
      </.form>
    </section>
    """
  end

  @doc """
  A sentence whose names are quoted in backticks, as `Forge.Secrets.received_by/1` writes them
  (state `review`): each name drawn in mono, no backtick drawn at all, and **nothing between the
  parts** — a template's line breaks between them read `implementing , state` (UX pass, D18).
  """
  @spec ticked(String.t()) :: Phoenix.HTML.safe()
  def ticked(text) do
    text
    |> String.split("`")
    |> Enum.with_index()
    |> Enum.map(fn
      {part, i} when rem(i, 2) == 1 ->
        ["<code class=\"settings-code\">", escape(part), "</code>"]

      {part, _i} ->
        escape(part)
    end)
    |> IO.iodata_to_binary()
    |> Phoenix.HTML.raw()
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  # The access list read backwards. A name no state or command names is said to be one, because a
  # secret set and listed nowhere is a secret nothing receives — which may be what someone meant,
  # and may be a misspelling.
  defp received(:none, _name), do: "the default branch has no workflow yet"

  defp received(%{names: names, invalid: [nil]}, _name) when names == %{},
    do: "the default branch's workflow is not valid"

  defp received(%{names: names, invalid: invalid}, name) do
    case Map.get(names, name, []) do
      [] -> "no state or command names it"
      by -> Enum.join(by, ", ")
    end <> unread(invalid)
  end

  # In warning, because it may be a misspelling: nothing reads a name a workflow does not name.
  # A workflow that cannot be read says nothing either way, so it is not counted.
  defp unreceived?(:none, _name), do: true
  defp unreceived?(%{names: names, invalid: [nil]}, _name) when names == %{}, do: false
  defp unreceived?(%{names: names}, name), do: Map.get(names, name, []) == []

  # A type whose workflow is refused names nothing that can be read, so the list above may be
  # short by what it would have said.
  defp unread([]), do: ""

  defp unread(types),
    do:
      "; not read: the workflow of #{Enum.map_join(types, ", ", &"`#{&1}`")}, which is not valid"

  defp chats(1), do: "held by 1 live conversation"
  defp chats(count), do: "held by #{count} live conversations"

  defp held(nil, _now), do: "no run has held it"
  defp held(at, now), do: "last held " <> ago(at, now)

  defp spent(%{revoked_at: at}, now) when not is_nil(at), do: "revoked " <> ago(at, now)
  defp spent(%{expires_at: at}, now), do: "expired " <> ago(at, now)

  defp ago(at, now), do: Format.ago_phrase(at, now)

  # -- branch and mirrors ---------------------------------------------------------------------

  # `docs/design/git-hosting.md` § What the mirrors say about themselves: this is where they say
  # it. The project page carries only whether one is failing; this is the list, and the only
  # place a mirror is set or removed.
  defp repository(assigns) do
    ~H"""
    <section id="repository" aria-labelledby="repository-heading">
      <div class="settings-heading">
        <h2 id="repository-heading">{if @manage, do: "Branch and mirrors", else: "Branch"}</h2>
      </div>
      <.fact_list>
        <:fact label="default branch">{@project.default_branch}</:fact>
      </.fact_list>

      <div :if={@manage} id="mirrors-section">
        <div class="settings-heading settings-heading--sub">
          <h3>Mirrors</h3>
          <span class="settings-count">{length(@mirrors)}</span>
        </div>
        <p class="settings-note">
          Every push to <span class="settings-mono">{@project.default_branch}</span>
          is pushed on to each of these. <code>https://</code>
          carries a token safely; <code>http://</code>
          sends it in clear.
        </p>

        <.error_note :if={@mirrors_error} class="settings-error">{@mirrors_error}</.error_note>

        <p :if={@mirrors == []} class="settings-note">
          None yet. One added appears here, with what the last push said.
        </p>

        <table :if={@mirrors != []} id="mirrors" class="settings-table">
          <thead>
            <tr>
              <th>Mirror</th>
              <th>Last push</th>
              <th><span class="sr-only">Remove</span></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={m <- @mirrors} id={"mirror-#{m.name}"}>
              <td>
                <div class="settings-name-line">
                  <span class="settings-name">{m.name}</span>
                  <span class={["settings-mono", mirror_tone(m)]}>{mirror_status(m)}</span>
                </div>
                <div class="settings-sub">{breakable(m.url)}</div>
              </td>
              <td>
                <div :if={m.last_at} class="settings-sub">{when_pushed(m.last_at, @now)}</div>
                <div :if={m.last_status == "failed" and m.last_error} class="settings-danger">
                  {m.last_error}
                </div>
                <div :if={m.last_ok_at} class="settings-sub">
                  last ok {when_pushed(m.last_ok_at, @now)}
                </div>
              </td>
              <td class="settings-act">
                <.confirm
                  id={"remove-mirror-#{m.name}"}
                  label="Remove"
                  act="Remove it"
                  sentence={"Remove the #{m.name} mirror? Nothing further is pushed there."}
                  phx-click="remove-mirror"
                  phx-value-name={m.name}
                />
              </td>
            </tr>
          </tbody>
        </table>

        <.button
          variant="outline"
          size="lg"
          patch={add_path(@project, "repository")}
          class="settings-phone settings-add"
        >
          + Add a mirror
        </.button>
      </div>
    </section>
    """
  end

  # The hook writes an ISO 8601 time; anything else it said is drawn as it said it.
  defp when_pushed(at, now) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _offset} -> ago(at, now)
      _other -> at
    end
  end

  defp mirror_status(%{last_status: "failed"}), do: "✗ failed"
  defp mirror_status(%{last_status: "ok"}), do: "✓ ok"
  defp mirror_status(%{last_status: nil}), do: "never pushed"
  defp mirror_status(%{last_status: status}), do: status

  defp mirror_tone(%{last_status: "failed"}), do: "settings-danger"
  defp mirror_tone(%{last_status: "ok"}), do: "settings-success"
  defp mirror_tone(_mirror), do: "settings-sub"

  defp add_mirror(assigns) do
    ~H"""
    <section id="add-a-mirror" aria-labelledby="add-mirror-heading">
      <h2 id="add-mirror-heading" class="settings-form-title">Add a mirror</h2>
      <.form
        :let={f}
        for={to_form(%{}, as: :mirror)}
        id="add-mirror"
        phx-submit="add-mirror"
        class="settings-form"
      >
        <.input field={f[:name]} type="text" label="Name" placeholder="github" mono />
        <.input field={f[:url]} type="text" label="URL" placeholder="https://host/x/y.git" mono />
        <.input field={f[:refs]} type="text" label="Refs, a glob (optional)" mono />
        <.input field={f[:user]} type="text" label="Username (optional)" mono />
        <%!-- Write-only: nothing here is ever populated from a stored mirror, because
              nothing keeps the token around to populate it with. --%>
        <.input field={f[:token]} type="password" label="Token (optional)" mono />
        <.error_note :if={@mirror_error} id="mirror-error" class="settings-error settings-span">
          {@mirror_error}
        </.error_note>
        <.button type="submit" variant="primary" size="xl" fill class="settings-span">
          Add it
        </.button>
      </.form>
    </section>
    """
  end
end
