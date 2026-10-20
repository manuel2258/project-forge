defmodule ForgeWeb.AuthorizationInventoryTest do
  @moduledoc """
  Every way into the platform, and what guards it.

  A table in a note is a claim; this is the same table with a way to fail. It enumerates the
  router's routes and every LiveView `handle_event` from source, and asserts each one is
  recorded below with the guard it carries. **A new route or a new action fails this test until
  somebody classifies it**, which is the point: the holes this branch shipped were all surfaces
  that existed without anyone deciding what guarded them.

  The classification itself is checked by the tests that exercise each guard — `privilege_test`,
  `membership_scoping_test`, `approval_gate_test`, `scoping_test`, `worker_channel_test`. This
  file only asserts that nothing has appeared which none of those cover.
  """

  use ExUnit.Case, async: true

  # How a surface is reached and what it must satisfy.
  #
  #   :public          — no credential. The login pages and the log-out.
  #   :self            — authenticated; acts only on the caller's own account, or on what it
  #                      owns — a machine, a template, a credential.
  #   :pending_ok      — authenticated but deliberately reachable before approval.
  #   :approved        — authenticated and approved; no project involved.
  #   :member          — approved, and a member of the project the surface is about.
  #   :manage          — approved, and an *admin* of that project.
  #   :node_admin      — the account-governance flag.
  #   :token           — a platform-issued credential, no session (git, blob store, worker).
  #   :local           — changes nothing on the server; page state only.
  @routes %{
    # Operator surfaces: :browser + require_authenticated_user + require_approved_user,
    # live_session :operator (on_mount :require_approved), then membership per page.
    "/" => :member,
    "/board" => :member,
    # The caller's own machines only (`Workers.list/1`); what reaches a project is the assignment
    # actions below.
    "/workers" => :approved,
    # One of the caller's own machines, read scoped to them (`Workers.owned/2`): anybody else's is
    # not here, as a missing one is not.
    "/workers/:id" => :self,
    # Own credentials and own templates only; the assignment actions below are what reach a
    # project, and those are guarded by membership in `Forge.Provisioning`.
    "/templates" => :self,
    # The caller's own projects only (`Projects.summaries/1` reads `Projects.list/1`).
    "/projects" => :member,
    "/projects/new" => :approved,
    "/projects/:name" => :member,
    "/projects/:name/settings" => :member,
    # The repository a project holds, read-only. Every member reads the whole of it, which is
    # the scope a read token already gives them (`docs/design/git-hosting.md`).
    "/projects/:name/repo" => :member,
    "/projects/:name/repo/commits/:sha" => :member,
    "/tickets/new" => :member,
    "/tickets/:project/:number" => :member,
    "/tickets/:project/:number/review" => :member,
    "/tickets/:project/:number/jobs/:job_id" => :member,
    "/tickets/:project/:number/artifacts/:name/:version" => :member,
    "/chats" => :member,
    "/chats/new" => :member,
    "/chats/:id" => :member,
    "/chats/:id/artifacts/:name/:version" => :member,

    # Account governance, the only thing the node-wide flag unlocks.
    "/accounts" => :node_admin,

    # The one page an unapproved account may see.
    "/users/pending" => :pending_ok,

    # The caller's own account.
    "/users/settings" => :self,
    "/users/settings/confirm-email/:token" => :self,
    "/users/update-password" => :self,

    # No credential by definition.
    # Liveness, answered to anyone: it carries nothing and reads nothing (`ForgeWeb.Plugs.Health`).
    "/health" => :public,
    "/users/log-in" => :public,
    "/users/log-in/:token" => :public,
    "/users/log-out" => :public,
    # The two legs of an OIDC login. The callback provisions an account, so it is the one public
    # route that creates a row — and what it creates is *pending*, which is why that is not a
    # hole: `docs/design/identity.md` § Approval is the perimeter, not authentication.
    "/auth/oidc/:provider" => :public,
    "/auth/oidc/:provider/callback" => :public,

    # Bearer token, refused for pending and suspended accounts, then scoped per project.
    "/api/v1/me" => :self,
    "/api/v1/queue" => :member,
    "/api/v1/projects" => :approved,
    "/api/v1/tickets" => :member,
    "/api/v1/projects/:project/tickets" => :member,
    "/api/v1/tickets/:project/:number" => :member,
    "/api/v1/tickets/:project/:number/events" => :member,
    "/api/v1/tickets/:project/:number/review" => :member,
    "/api/v1/tickets/:project/:number/jobs/:job_id" => :member,
    "/api/v1/tickets/:project/:number/artifacts/:name" => :member,
    "/api/v1/tickets/:project/:number/answers" => :member,
    "/api/v1/tickets/:project/:number/approve" => :member,
    "/api/v1/tickets/:project/:number/transition" => :member,
    "/api/v1/tickets/:project/:number/retry" => :member,
    "/api/v1/tickets/:project/:number/cancel" => :member,
    "/api/v1/tickets/:project/:number/restore" => :member,
    "/api/v1/projects/:project/proposals" => :member,
    "/api/v1/proposals/:version_id/accept" => :member,
    "/api/v1/proposals/:version_id/decline" => :member,

    # No session at all: a credential that names one key and one verb, or one ref of one repo.
    "/store/*key" => :token,
    "/git" => :token
  }

  # Sockets are the endpoint's, not the router's. The LiveView one carries the session and every
  # route behind it sits in a `live_session` with an `on_mount`; the worker one authenticates a
  # machine in its handshake and is the only way in that no person holds.
  # `:dev_only` is compile-gated out of any build that is not code-reloading, which the test
  # below asserts rather than assumes — an ungated developer socket in a release would be a way
  # in that nothing else on this list guards.
  @sockets %{
    "/live" => :session,
    "/worker" => :token,
    "/phoenix/live_reload/socket" => :dev_only
  }

  # Every `handle_event` a client can push, and what refuses it. `:local` means the handler
  # changes page state and touches nothing else — those still have to be listed, because the way
  # to smuggle one in is to look boring.
  @actions %{
    {"accounts_live.ex", "approve"} => :node_admin,
    {"accounts_live.ex", "suspend"} => :node_admin,
    {"accounts_live.ex", "reinstate"} => :node_admin,
    {"accounts_live.ex", "promote"} => :node_admin,
    {"accounts_live.ex", "demote"} => :node_admin,
    {"accounts_live.ex", "delete"} => :node_admin,
    {"chat_live.ex", "send"} => :member,
    {"chat_live.ex", "force"} => :member,
    # The question form's draft is the page's alone; its Send goes through
    # `Operator.answer_chat/4`, which resolves the chat off the wire and checks membership.
    {"chat_live.ex", "form:change"} => :local,
    {"chat_live.ex", "form:open"} => :local,
    {"chat_live.ex", "chat:questions:send"} => :member,
    {"chat_live.ex", "stop"} => :member,
    {"chat_live.ex", "close"} => :member,
    {"chat_live.ex", "reopen"} => :member,
    {"chat_live.ex", "merge"} => :member,
    {"chat_live.ex", "draft"} => :local,
    {"chat_live.ex", "ask"} => :local,
    {"chat_live.ex", "more"} => :local,
    {"chat_live.ex", "notices"} => :local,
    {"chat_new_live.ex", "open"} => :member,
    {"chat_new_live.ex", "validate"} => :local,
    # The id is the client's, so the chat is read and then authorised: being able to see the
    # list is not being able to end a row named by an id somebody supplied.
    {"chats_live.ex", "end-chat"} => :member,
    {"job_live.ex", "more"} => :local,
    {"job_live.ex", "notices"} => :local,
    # Navigates to a conversation with the reference in the address; sends nothing.
    {"ticket_live.ex", "ask"} => :local,
    {"ticket_live.ex", "more"} => :local,
    {"ticket_live.ex", "notices"} => :local,
    {"project_new_live.ex", "create"} => :approved,
    {"project_new_live.ex", "validate"} => :local,
    {"project_settings_live.ex", "issue"} => :manage,
    {"project_settings_live.ex", "revoke"} => :manage,
    {"project_settings_live.ex", "model"} => :manage,
    {"project_settings_live.ex", "add-member"} => :manage,
    {"project_settings_live.ex", "remove-member"} => :manage,
    # Same check as `issue`/`revoke`/`model`/`add-member`/`remove-member` above:
    # `Projects.put_mirror/5` and `delete_mirror/3` both call `manageable/2`.
    # The version id is the client's; `Operator.accept_proposal/4` and `decline_proposal/3` resolve
    # it to its project and refuse a non-member (`allow_proposal/2`).
    {"project_live.ex", "decide_proposal"} => :member,
    # Both resolve inside the project and ask for `:manage` in `Forge.Operator`; the value is
    # passed through and never assigned (`docs/design/secrets.md` § Surfaces).
    {"project_settings_live.ex", "set-secret"} => :manage,
    {"project_settings_live.ex", "delete-secret"} => :manage,
    {"project_settings_live.ex", "add-mirror"} => :manage,
    {"project_settings_live.ex", "remove-mirror"} => :manage,
    {"project_settings_live.ex", "dismiss"} => :local,
    {"project_settings_live.ex", "toggle-spent"} => :local,
    {"project_settings_live.ex", "validate"} => :local,
    # The repository view holds three things: which branch, which directory has been read, and
    # which file has been opened. Each is the page's own state, read out of the repository the
    # mount already allowed, and reaches no context and no database.
    {"repo_live.ex", "branch"} => :local,
    {"repo_live.ex", "expand"} => :local,
    {"repo_live.ex", "open"} => :local,
    {"queue_live.ex", "push:subscribe"} => :self,
    {"queue_live.ex", "push:unsubscribe"} => :self,
    {"queue_live.ex", "push:error"} => :local,
    {"ticket_new_live.ex", "create"} => :member,
    {"ticket_new_live.ex", "validate"} => :local,
    {"workers_live.ex", "toggle-destroyed"} => :local,
    {"workers_live.ex", "new-machine"} => :local,
    {"workers_live.ex", "cancel-new"} => :local,
    {"workers_live.ex", "dismiss-minted"} => :local,
    # Mints a permanent machine whose owner is the session's user — no owner is read off the
    # wire — and, when a project is chosen, `Workers.mint/2` checks membership as `assign/3` does,
    # before the row exists (`docs/design/identity.md` § Minting a permanent machine).
    {"workers_live.ex", "mint"} => :self,
    {"workers_live.ex", "edit"} => :local,
    {"workers_live.ex", "cancel-edit"} => :local,
    # Sets what a machine offers the gate: the caller's own machine only, read scoped to them by
    # `Workers.set_offer/3` whatever id arrives — and a machine the platform *made* is refused,
    # because it is replaced rather than corrected (`docs/design/identity.md` § Workers).
    {"workers_live.ex", "save"} => :self,
    # Both reach a project, and both are refused unless the caller owns the machine *and* is a
    # member of that project — `Workers.assign/3` and `unassign/3`.
    {"workers_live.ex", "assign"} => :member,
    {"workers_live.ex", "unassign"} => :member,
    # Ends one of the caller's own machines: `Workers.retire_by_owner/2` reads the row scoped to
    # them whatever id arrives, and never forces (`docs/design/provisioning.md` § Whose account).
    {"workers_live.ex", "destroy"} => :self,
    {"templates_live.ex", "add-credential"} => :self,
    {"templates_live.ex", "delete-credential"} => :self,
    {"templates_live.ex", "add-template"} => :self,
    {"templates_live.ex", "delete-template"} => :self,
    # Own templates only, and each reads the row scoped to the caller before touching it — the
    # id is the client's in all three. For `save-template` and `enable-template` the scoped read
    # is the context's (`Provisioning.update_template/3`, `enable/2`), not the page's.
    {"templates_live.ex", "edit-template"} => :self,
    {"templates_live.ex", "save-template"} => :self,
    {"templates_live.ex", "enable-template"} => :self,
    # Closes a form. Nothing on the server changes but what this page is showing.
    {"templates_live.ex", "cancel-edit"} => :local,
    {"templates_live.ex", "credential-provider"} => :local,
    {"templates_live.ex", "template-provider"} => :local,
    # Both reach a project, and both are refused unless the caller owns the template *and* is a
    # member of that project — `docs/design/provisioning.md` § Whose account.
    {"templates_live.ex", "assign"} => :member,
    {"templates_live.ex", "unassign"} => :member,
    {"user_live/confirmation.ex", "submit"} => :public,
    {"user_live/login.ex", "submit_magic"} => :public,
    {"user_live/login.ex", "submit_password"} => :public,
    # Inference credentials. Each reads the row scoped to the caller before acting on it — the id
    # is the client's — and `credential-change` only re-renders the form, with the typed secret
    # dropped (`docs/design/credentials.md`).
    {"user_live/settings.ex", "add-credential"} => :self,
    {"user_live/settings.ex", "check-credential"} => :self,
    {"user_live/settings.ex", "revoke-credential"} => :self,
    {"user_live/settings.ex", "credential-change"} => :local,
    # Both reach a project's pool, and both are refused unless the caller owns the credential *and*
    # is a member of that project — `Credentials.assign/3` and `unassign/3`.
    {"user_live/settings.ex", "assign-credential"} => :member,
    {"user_live/settings.ex", "unassign-credential"} => :member,
    {"user_live/settings.ex", "update_email"} => :self,
    {"user_live/settings.ex", "update_password"} => :self,
    {"user_live/settings.ex", "validate_email"} => :self,
    {"user_live/settings.ex", "validate_password"} => :self,

    # Dispatched rather than matched: the queue, the ticket and the review page hand every event
    # they do not match to `ForgeWeb.Operator.Actions`, which hands the question form's to
    # `ForgeWeb.Operator.QuestionForm`. Each that writes goes through `Forge.Operator`, and each
    # takes its ticket or chat off the wire, which the operation resolves before it checks.
    {"operator/actions.ex", "decide"} => :member,
    {"operator/actions.ex", "transition"} => :member,
    {"operator/actions.ex", "cancel-ticket"} => :member,
    {"operator/actions.ex", "restore-ticket"} => :member,
    {"operator/actions.ex", "retry"} => :member,
    {"operator/actions.ex", "repin"} => :member,
    {"operator/actions.ex", "integrate"} => :member,
    {"operator/actions.ex", "write_document"} => :member,
    # A card's draft is the page's alone, the same as a question form's: nothing is written
    # until the form it sits in is submitted, and that submit carries its own guard.
    {"project_live.ex", "draft:change"} => :local,
    {"operator/question_form.ex", "form:change"} => :local,
    {"operator/question_form.ex", "form:open"} => :local,
    {"operator/question_form.ex", "questions:send"} => :member,
    {"operator/question_form.ex", "chat:questions:send"} => :member
  }

  # Worker channel messages. Each addresses a job by an id off the wire, so each must resolve it
  # against the socket's own worker — except the two that act on the socket's worker directly.
  @channel %{
    "ready" => :socket_worker,
    "heartbeat" => :socket_worker,
    # Writes only the socket's own worker's registry value, and nothing in the database: the
    # figures a machine reports about itself, for the workers page
    # (`docs/design/worker-channel.md` § Live figures).
    "stats" => :socket_worker,
    # A line in the socket's own worker's log, bounded field by field and addressed by the socket,
    # never by the payload (`docs/design/worker-log.md` § The `log` message).
    "log" => :socket_worker,
    # Marks the socket's own worker and requeues the jobs running on it, found by the socket's
    # worker id and never by one in the payload (`docs/design/worker-channel.md` § An unhealthy
    # machine).
    "unhealthy" => :socket_worker,
    "event" => :owns_job,
    "result" => :owns_job,
    "turn" => :owns_job,
    "hibernated" => :owns_job,
    "failed" => :owns_job
  }

  test "every route is recorded with the guard it carries" do
    actual = ForgeWeb.Router.__routes__() |> Enum.map(& &1.path) |> MapSet.new()
    recorded = @routes |> Map.keys() |> MapSet.new()

    unrecorded = MapSet.difference(actual, recorded)
    stale = MapSet.difference(recorded, actual)

    assert MapSet.to_list(unrecorded) == [],
           "new route(s) with no recorded guard: #{inspect(MapSet.to_list(unrecorded))}"

    assert MapSet.to_list(stale) == [],
           "recorded route(s) that no longer exist: #{inspect(MapSet.to_list(stale))}"
  end

  test "every socket is recorded with the guard it carries" do
    actual =
      ~r/socket "([^"]+)"/
      |> Regex.scan(File.read!("lib/forge_web/endpoint.ex"))
      |> Enum.map(fn [_, path] -> path end)
      |> MapSet.new()

    assert MapSet.equal?(actual, @sockets |> Map.keys() |> MapSet.new()),
           "sockets changed: #{inspect(MapSet.to_list(actual))}"

    # Everything recorded `:dev_only` must be behind `code_reloading?`, and must not be mounted
    # in this (non-reloading) build.
    src = File.read!("lib/forge_web/endpoint.ex")
    gated = src |> String.split("if code_reloading? do") |> List.last()

    for {path, :dev_only} <- @sockets do
      assert gated =~ path, "#{path} is not behind code_reloading?"
    end

    refute Enum.any?(
             ForgeWeb.Endpoint.__sockets__(),
             fn socket -> elem(socket, 0) == "/phoenix/live_reload/socket" end
           )
  end

  test "every LiveView action is recorded with the guard it carries" do
    actual =
      "lib/forge_web/live/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        name = Path.relative_to(path, "lib/forge_web/live")

        # A page's own handlers, and the ones the operator modules dispatch to by name — with the
        # head split over lines too, as `mix format` lays out a long one. `project_live`'s
        # `decide_proposal` was written that way and went unrecorded until this allowed for it.
        # A head matching a variable (`def handle_event(event, …) when event in […]`) names no
        # event, and is what no scan of source can see: write each event as its own head.
        ~r/(?:def handle_event|defp act|defp dispatch)\(\s*"([^"]+)"/
        |> Regex.scan(File.read!(path))
        |> Enum.map(fn [_, event] -> {name, event} end)
      end)
      |> MapSet.new()

    recorded = @actions |> Map.keys() |> MapSet.new()

    unrecorded = MapSet.difference(actual, recorded)
    stale = MapSet.difference(recorded, actual)

    assert MapSet.to_list(unrecorded) == [],
           "new LiveView action(s) with no recorded guard: #{inspect(MapSet.to_list(unrecorded))}"

    assert MapSet.to_list(stale) == [],
           "recorded action(s) that no longer exist: #{inspect(MapSet.to_list(stale))}"
  end

  test "every worker channel message is recorded, and the job-addressed ones resolve ownership" do
    src = File.read!("lib/forge_web/channels/worker_channel.ex")

    actual =
      ~r/def handle_in\("([^"]+)"/
      |> Regex.scan(src)
      |> Enum.map(fn [_, m] -> m end)
      |> MapSet.new()

    assert MapSet.equal?(actual, @channel |> Map.keys() |> MapSet.new()),
           "worker channel messages changed: #{inspect(MapSet.to_list(actual))}"

    # The claim that matters: a handler taking `job_id` from the payload calls `owns/2`. This is
    # what was missing, and it is cheap to lose again in a refactor.
    for {message, :owns_job} <- @channel do
      body =
        ~r/def handle_in\("#{Regex.escape(message)}".*?(?=\n  def |\n  @impl|\z)/s
        |> Regex.run(src)
        |> hd()

      assert body =~ "owns(socket, job_id)",
             "worker channel #{message}/ addresses a job by id without resolving ownership"
    end
  end
end
