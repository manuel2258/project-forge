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
    # A project's releases, read-only: every member reads them, and nothing on them writes.
    "/projects/:name/releases" => :member,
    "/projects/:name/releases/:id" => :member,
    "/tickets/new" => :member,
    "/tickets/:project/:number" => :member,
    "/tickets/:project/:number/jobs/:job_id" => :member,
    # A kept build of the ticket, looked into on the machine that holds it: every member, and
    # the copy is reached only through the ticket named in the address (`Forge.WarmBuilds.copy/2`).
    "/tickets/:project/:number/builds/:job_id" => :member,
    "/tickets/:project/:number/builds/:job_id/download" => :member,
    "/tickets/:project/:number/artifacts/:name/:version" => :member,
    "/chats" => :member,
    "/chats/new" => :member,
    "/chats/:id" => :member,
    "/chats/:id/pages/:name" => :member,
    "/tickets/:project/:number/pages/:name" => :member,
    "/chats/:id/artifacts/:name/:version" => :member,
    "/projects/:name/uploads" => :member,
    "/projects/:name/uploads/:id" => :member,

    # The caller's own credentials' windows; spend in a project they are not in is one unnamed
    # line (`Forge.Usage.breakdown/5`).
    "/usage" => :self,

    # Account governance, the only thing the node-wide flag unlocks.
    "/accounts" => :node_admin,

    # The one page an unapproved account may see.
    "/users/pending" => :pending_ok,

    # The caller's own account.
    "/users/settings" => :self,
    "/users/settings/confirm-email/:token" => :self,
    "/users/update-password" => :self,
    # What a device is told about its own person's queue: answered only for a signed-in, approved
    # session, and a 401 with no body for everybody else (`Forge.Push.state/1`).
    "/push/waiting" => :self,

    # No credential by definition.
    # Liveness, answered to anyone: it carries nothing and reads nothing (`ForgeWeb.Plugs.Health`).
    "/health" => :public,
    # The installed app's service worker and the page it falls back to: rendered with no session
    # and the same for anybody, which is what lets a device keep the second (`ForgeWeb.DeviceController`).
    "/sw.js" => :public,
    "/offline" => :public,
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
    "/api/v1/projects/:project" => :member,
    "/api/v1/projects/:project/tickets" => :member,
    "/api/v1/tickets/:project/:number" => :member,
    "/api/v1/tickets/:project/:number/events" => :member,
    "/api/v1/tickets/:project/:number/review" => :member,
    "/api/v1/tickets/:project/:number/clear-warm-build" => :member,
    "/api/v1/tickets/:project/:number/jobs/:job_id" => :member,
    # A command's log with its times, and the ticket's kept copies explored and downloaded: reads, for
    # every member and a project token of either access; a copy is reached only through its ticket
    # (`ForgeWeb.Api.Builds`).
    "/api/v1/tickets/:project/:number/jobs/:job_id/log" => :member,
    "/api/v1/tickets/:project/:number/builds" => :member,
    "/api/v1/tickets/:project/:number/builds/:job_id/folder" => :member,
    "/api/v1/tickets/:project/:number/builds/:job_id/file" => :member,
    "/api/v1/tickets/:project/:number/builds/:job_id/download" => :member,
    "/api/v1/tickets/:project/:number/artifacts" => :member,
    "/api/v1/tickets/:project/:number/artifacts/:name" => :member,
    "/api/v1/tickets/:project/:number/artifacts/:name/:version/raw" => :member,
    # A page's live store: `Forge.Pages` asks the same reach of a person and a token, and a write
    # asks `:use` again through `Forge.Operator.write_page/5` (`docs/design/pages.md`).
    "/api/v1/tickets/:project/:number/pages" => :member,
    "/api/v1/tickets/:project/:number/pages/:name/data" => :member,
    "/api/v1/tickets/:project/:number/pages/:name/data/:key" => :member,
    "/api/v1/tickets/:project/:number/answers" => :member,
    "/api/v1/tickets/:project/:number/approve" => :member,
    "/api/v1/tickets/:project/:number/transition" => :member,
    "/api/v1/tickets/:project/:number/retry" => :member,
    # Extending a job that ran out: `Forge.Operator.extend/4`, the guard every ticket write passes,
    # asked again inside the engine's transaction after the ticket is locked.
    "/api/v1/tickets/:project/:number/jobs/:job_id/extend" => :member,
    # Withdrawing a file: a person's, and the rule — the attacher or an admin of the project — is
    # `Forge.Attachments.withdraw/5`'s, asked inside the transaction that locks the pool.
    "/api/v1/tickets/:project/:number/attachments/:file" => :member,
    "/api/v1/tickets/:project/:number/attachments/:file/:version" => :member,
    "/api/v1/tickets/:project/:number/cancel" => :member,
    "/api/v1/tickets/:project/:number/restore" => :member,
    # The hold, titles and milestones: `Forge.Operator` guards every one, a project token with API
    # write included (`docs/design/identity.md` § Where the guard lives).
    "/api/v1/tickets/:project/:number/hold" => :member,
    "/api/v1/tickets/:project/:number/release" => :member,
    "/api/v1/tickets/:project/:number/stop" => :member,
    "/api/v1/tickets/:project/:number/take-over" => :member,
    "/api/v1/tickets/:project/:number/hand-back" => :member,
    "/api/v1/tickets/:project/:number/keep-work" => :member,
    "/api/v1/tickets/:project/:number/title" => :member,
    "/api/v1/tickets/:project/:number/milestone" => :member,
    "/api/v1/tickets/:project/:number/move" => :member,
    "/api/v1/projects/:project/milestones" => :member,
    "/api/v1/projects/:project/milestones/:id" => :member,
    "/api/v1/projects/:project/milestones/:id/current" => :member,
    "/api/v1/projects/:project/milestones/:id/close" => :member,
    "/api/v1/projects/:project/milestones/:id/reopen" => :member,
    "/api/v1/projects/:project/milestones/:id/move" => :member,
    # Schedules: reading is any member's; switching is `Operator.switch_schedule_on/4` and `_off/4`,
    # which ask `:manage` of a `%User{}` and take no token; dismissing asks `:use`.
    "/api/v1/projects/:project/schedules" => :member,
    "/api/v1/projects/:project/schedules/on" => :manage,
    "/api/v1/projects/:project/schedules/off" => :manage,
    "/api/v1/projects/:project/schedules/dismiss" => :member,
    "/api/v1/projects/:project/proposals" => :member,
    "/api/v1/proposals/:version_id/accept" => :member,
    "/api/v1/proposals/:version_id/decline" => :member,

    # The MCP endpoint: the API's bearers (`ApiAuth`, a job's token refused), a foreign `Origin` refused,
    # and per tool the API's own rule — a write needs a token with API write, a ticket of another
    # project is a 404 — over `Forge.Operator` (`docs/design/api-and-ui.md` § MCP).
    "/mcp" => :member,

    # No session at all: a credential that names one key and one verb, or one ref of one repo.
    "/store/*key" => :token,
    # A download of a command copy, passed through from the machine that packs it: the stream's own
    # secret, one stream, compared in constant time, never stored (`ForgeWeb.WorkerStreamController`).
    "/worker-streams/:id" => :token,
    "/archive" => :token,
    "/archive/tickets/:number" => :token,
    "/archive/tickets/:number/:ref" => :token,
    # The job's own git token, scoped by its job row: its ticket's pages, or its own chat's.
    "/job/pages" => :token,
    "/job/pages/:name/data" => :token,
    "/job/pages/:name/data/:key" => :token,
    # A signed path over the viewer and the page version, no session; membership is asked again on
    # every request (`ForgeWeb.PageFileController`).
    "/page-files/:token/:file" => :token,
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
    {"page_live.ex", "outside"} => :member,
    {"page_live.ex", "page:all"} => :member,
    {"page_live.ex", "page:batch"} => :member,
    {"page_live.ex", "page:get"} => :member,
    {"page_live.ex", "page:hello"} => :member,
    {"chat_live.ex", "send"} => :member,
    # The question form's draft is the page's alone; its Send goes through
    # `Operator.answer_chat/4`, which resolves the chat off the wire and checks membership.
    {"frame.ex", "frame:menu"} => :local,
    {"frame.ex", "frame:details"} => :local,
    {"frame.ex", "frame:usage"} => :local,
    {"frame.ex", "frame:close"} => :local,
    {"usage_live.ex", "by"} => :local,
    {"chat_live.ex", "form:change"} => :local,
    {"chat_live.ex", "form:open"} => :local,
    {"chat_live.ex", "chat:questions:send"} => :member,
    {"chat_live.ex", "stop"} => :member,
    {"chat_live.ex", "interrupt"} => :member,
    # Withdrawing a file: `Forge.Attachments.withdraw/5` refuses all but the person who attached it
    # and a project admin, inside the transaction that locks the pool.
    {"chat_live.ex", "attachments:withdraw"} => :member,
    {"chat_live.ex", "close"} => :member,
    {"chat_live.ex", "draft"} => :local,
    {"chat_live.ex", "ask"} => :local,
    # The paths are read from the page's own decision, never the wire; it only fills the draft.
    {"chat_live.ex", "rebase:ask"} => :local,
    {"chat_live.ex", "more"} => :local,
    {"chat_live.ex", "notices"} => :local,
    {"chat_live.ex", "talk:more"} => :local,
    {"chat_new_live.ex", "open"} => :member,
    {"chat_new_live.ex", "validate"} => :local,
    # The id is the client's, so the chat is read and then authorised: being able to see the
    # list is not being able to end a row named by an id somebody supplied.
    {"chats_live.ex", "end-chat"} => :member,
    # The project is looked up among the viewer's own, then `Operator.open_chat/4` checks again.
    {"chats_live.ex", "chat:start"} => :member,
    {"chats_live.ex", "start:change"} => :local,
    {"job_live.ex", "more"} => :local,
    {"job_live.ex", "notices"} => :local,
    {"job_live.ex", "log-earlier"} => :local,
    {"explore_live.ex", "more"} => :local,
    {"explore_live.ex", "retry"} => :local,
    {"job_live.ex", "first-failure"} => :local,
    {"job_live.ex", "pane"} => :local,
    {"job_live.ex", "show"} => :local,
    {"ticket_live.ex", "attachments:withdraw"} => :member,
    # Navigates to a conversation with the reference in the address; sends nothing.
    {"ticket_live.ex", "ask"} => :local,
    {"ticket_live.ex", "more"} => :local,
    {"ticket_live.ex", "notices"} => :local,
    # A way forward picked is page state; taking it is `transition` or `retry`, guarded in
    # `Forge.Operator` like every other.
    {"ticket_live.ex", "forward:pick"} => :local,
    {"ticket_live.ex", "forward"} => :member,
    {"project_new_live.ex", "create"} => :approved,
    {"project_new_live.ex", "validate"} => :local,
    {"project_settings_live.ex", "issue"} => :manage,
    {"project_settings_live.ex", "revoke"} => :manage,
    {"project_settings_live.ex", "defaults"} => :manage,
    {"project_settings_live.ex", "set-role"} => :manage,
    {"project_settings_live.ex", "add-member"} => :manage,
    {"project_settings_live.ex", "remove-member"} => :manage,
    # Same check as `issue`/`revoke`/`model`/`effort`/`add-member`/`remove-member` above:
    # `Projects.put_mirror/5` and `delete_mirror/3` both call `manageable/2`.
    # The version id is the client's; `Operator.accept_proposal/4` and `decline_proposal/3` resolve
    # it to its project and refuse a non-member (`allow_proposal/2`).
    {"project_live.ex", "decide_proposal"} => :member,
    # Hands the event to `ForgeWeb.Operator.Actions`, whose "take-out" is `Operator.take_out/2`.
    {"project_live.ex", "take-out"} => :member,
    # `Operator.start_release/3` asks for `:manage`, and the page draws the block for an admin only
    # (`docs/design/ticket-types.md` § Releases).
    {"project_live.ex", "release:start"} => :manage,
    # A schedule switched on or off: `Operator.switch_schedule_on/4` and `_off/4` ask `:manage`, so a
    # member's event pushed by hand is refused there and draws the refusal on the row.
    {"project_live.ex", "schedule:on"} => :manage,
    {"project_live.ex", "schedule:off"} => :manage,
    # The Milestones view: every one is a `Forge.Operator` function asking `:use`, and each ticket
    # or milestone id off the wire is resolved inside this project first
    # (`Forge.Milestones.get/2`, `ticket_of/2`), so another project's answers as one that is not
    # there. The last is the catch-all for a name no clause knows, which does nothing.
    {"project_live.ex", "milestones:create"} => :member,
    {"project_live.ex", "milestones:update"} => :member,
    {"project_live.ex", "milestones:current"} => :member,
    {"project_live.ex", "milestones:close"} => :member,
    {"project_live.ex", "milestones:reopen"} => :member,
    {"project_live.ex", "milestones:move"} => :member,
    {"project_live.ex", "milestones:ticket_move"} => :member,
    {"project_live.ex", "milestones:drag"} => :member,
    {"project_live.ex", "milestones:drag_milestone"} => :member,
    {"project_live.ex", "milestones:place"} => :member,
    {"project_live.ex", "milestones:release"} => :member,
    {"project_live.ex", "milestones:"} => :local,
    # `Operator.open_chat/4` asks for `:use`.
    {"project_live.ex", "chat:start"} => :member,
    # `Operator.decline_proposals/3` resolves every id to its project and refuses the lot unless
    # the actor may use it; `accept_proposal/4` checks each (`allow_proposal/2`).
    {"project_live.ex", "proposals:bulk"} => :member,
    # `Operator.reopen_proposal/2`, through the same `allow_proposal/2` as a decline.
    {"project_live.ex", "proposal:reopen"} => :member,
    # `Operator.send_chat/4` asks for `:use` on the chat's own project.
    {"project_live.ex", "proposal:ask"} => :member,
    # Both resolve inside the project and ask for `:manage` in `Forge.Operator`; the value is
    # passed through and never assigned (`docs/design/secrets.md` § Surfaces).
    {"project_settings_live.ex", "set-secret"} => :manage,
    {"project_settings_live.ex", "delete-secret"} => :manage,
    {"project_settings_live.ex", "add-mirror"} => :manage,
    {"project_settings_live.ex", "remove-mirror"} => :manage,
    {"project_settings_live.ex", "dismiss"} => :local,
    {"project_settings_live.ex", "toggle-spent"} => :local,
    {"project_settings_live.ex", "validate"} => :local,
    {"project_settings_live.ex", "defaults-change"} => :local,
    {"project_settings_live.ex", "defaults-discard"} => :local,
    # The repository view holds three things: which branch, which directory has been read, and
    # which file has been opened. Each is the page's own state, read out of the repository the
    # mount already allowed, and reaches no context and no database.
    {"repo_live.ex", "expand"} => :local,
    {"repo_live.ex", "search"} => :local,
    # A schedule's alert dismissed: `Operator.dismiss_schedule/4` asks `:use` of the project the
    # schedule is in, resolved from its id.
    {"queue_live.ex", "schedule:dismiss"} => :member,
    {"queue_live.ex", "push:subscribe"} => :self,
    {"queue_live.ex", "push:unsubscribe"} => :self,
    {"queue_live.ex", "push:error"} => :local,
    # The pass is the page's own: Later reorders it and a picked way forward is a draft.
    {"queue_live.ex", "queue:later"} => :local,
    {"queue_live.ex", "queue:pick"} => :local,
    # Which step's line is open on the item on screen: the page's own state, dropped whenever it
    # names an item other than the one the pass is on. It reads what that item's ticket already
    # shows to the same members (its runs and their closing words), and writes nothing.
    {"queue_live.ex", "queue:step"} => :local,
    # Taken through `ForgeWeb.Operator.Actions`, which resolves the ticket off the wire and goes
    # through `Forge.Operator`'s membership check (`retry`, `transition`).
    {"queue_live.ex", "queue:way"} => :member,
    # The same operation named by its own event, which the queue refuses an approving way on
    # (`approving: false`): a crafted or older page's event takes the same membership check.
    {"queue_live.ex", "transition"} => :member,
    {"ticket_new_live.ex", "create"} => :member,
    {"ticket_new_live.ex", "validate"} => :local,
    # Which of the form's three submits is the face of the button: a choice in the page's own state.
    {"ticket_new_live.ex", "how"} => :local,
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
    # The owner's switch and *Update now*, on the list and on one machine's page:
    # `Workers.Updates.set_automatic/3` and `update_now/2` read the row with `Workers.owned/2`, the
    # caller's own permanent machine whatever id arrives (`docs/design/identity.md` § Sequencing).
    {"workers_live.ex", "update-auto"} => :self,
    {"workers_live.ex", "update-now"} => :self,
    {"worker_live.ex", "update-auto"} => :self,
    {"worker_live.ex", "update-now"} => :self,
    {"templates_live.ex", "add-credential"} => :self,
    {"templates_live.ex", "delete-credential"} => :self,
    # The caller's own credential, whatever id arrives: `ImageBuilds.set_auto/3` and `build_now/2`
    # read it with `Provisioning.credential/2`, so a node admin or a member is refused and
    # anyone else's id is not found (`docs/design/provisioning.md` § Putting the release's image
    # into an account).
    {"templates_live.ex", "set-auto"} => :self,
    {"templates_live.ex", "build-now"} => :self,
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
    # Which sign-in screen is drawn, and the sent screen folded back to the address field.
    {"user_live/login.ex", "switch-way"} => :local,
    {"user_live/login.ex", "another-address"} => :local,
    # This browser's push subscription, stored against the caller and nobody else (`Forge.Push`).
    {"user_live/settings.ex", "push:subscribe"} => :self,
    {"user_live/settings.ex", "push:unsubscribe"} => :self,
    {"user_live/settings.ex", "push:error"} => :local,
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

    # Dispatched rather than matched: the queue and the ticket hand every event
    # they do not match to `ForgeWeb.Operator.Actions`, which hands the question form's to
    # `ForgeWeb.Operator.QuestionForm`. Each that writes goes through `Forge.Operator`, and each
    # takes its ticket or chat off the wire, which the operation resolves before it checks.
    {"operator/actions.ex", "transition"} => :member,
    {"operator/actions.ex", "cancel-ticket"} => :member,
    {"operator/actions.ex", "restore-ticket"} => :member,
    {"operator/actions.ex", "retry"} => :member,
    {"operator/actions.ex", "extend"} => :member,
    {"operator/actions.ex", "repin"} => :member,
    {"operator/actions.ex", "integrate"} => :member,
    {"operator/actions.ex", "take-out"} => :member,
    {"operator/actions.ex", "keep-work"} => :member,
    {"operator/actions.ex", "write_document"} => :member,
    # The hold and its words (`Forge.Operator.hold/2`, `release/2`, `stop_now/2`, `retitle/3`,
    # `set_milestone/3`), each resolving its ticket off the wire before it asks `:use`.
    {"operator/actions.ex", "hold-ticket"} => :member,
    {"operator/actions.ex", "release-ticket"} => :member,
    {"operator/actions.ex", "stop-now"} => :member,
    # Taking over and handing back (`Forge.Operator.take_over/3`, `hand_back/3`), each resolving
    # its ticket off the wire before it asks `:use`.
    {"operator/actions.ex", "take-over"} => :member,
    {"operator/actions.ex", "hand-back"} => :member,
    {"operator/actions.ex", "retitle"} => :member,
    {"operator/actions.ex", "set-milestone"} => :member,
    # The warm build's clear (`Forge.Operator.clear_warm_build/2`), resolving its ticket off the
    # wire before it asks `:use`.
    {"operator/actions.ex", "clear-warm-build"} => :member,

    # A card's draft is the page's alone, the same as a question form's: nothing is written
    # until the form it sits in is submitted, and that submit carries its own guard.
    {"project_live.ex", "draft:change"} => :local,
    {"project_live.ex", "tickets:filter"} => :local,
    {"project_live.ex", "workflow:type"} => :local,
    {"project_live.ex", "proposals:list"} => :local,
    {"project_live.ex", "proposals:skip"} => :local,
    {"project_live.ex", "proposals:selecting"} => :local,
    {"project_live.ex", "proposals:select"} => :local,
    {"project_live.ex", "proposals:group"} => :local,
    {"operator/drafts.ex", "draft:change"} => :local,
    {"operator/question_form.ex", "form:change"} => :local,
    {"operator/question_form.ex", "form:open"} => :local,
    {"operator/question_form.ex", "questions:send"} => :member,
    {"operator/question_form.ex", "chat:questions:send"} => :member,
    # The decision row (`docs/design/ui.md` § The decision row). Two pages dispatch every
    # `decision:` event to `ForgeWeb.Operator.Decision`; opening, folding and what the panel's form
    # holds are the page's alone, and each press goes through `Forge.Operator` — `decide/4`,
    # `accept_step/4`, `merge_chat/2` — which asks for the project's `:use` and the person's
    # standing as it is when pressed. Approve and Reject read the ticket again by the page's id.
    {"chat_live.ex", "decision:"} => :member,
    {"ticket_live.ex", "decision:"} => :member,
    # Which file the wide Changes pane shows beside the presentation (`ForgeWeb.Changes`): a
    # bounded read of the changeset's commit, on a page whose mount already asked for membership.
    {"ticket_live.ex", "changes:follow"} => :local,
    {"operator/decision.ex", "decision:open"} => :local,
    {"operator/decision.ex", "decision:close"} => :local,
    {"operator/decision.ex", "decision:change"} => :local,
    {"operator/decision.ex", "decision:decide"} => :member,
    {"operator/decision.ex", "decision:accept"} => :member,
    {"operator/decision.ex", "decision:merge"} => :member
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
    "update" => :socket_worker,
    "disk" => :socket_worker,
    # A line in the socket's own worker's log, bounded field by field and addressed by the socket,
    # never by the payload (`docs/design/worker-log.md` § The `log` message).
    "log" => :socket_worker,
    # Marks the socket's own worker and requeues the jobs running on it, found by the socket's
    # worker id and never by one in the payload (`docs/design/worker-channel.md` § An unhealthy
    # machine).
    "unhealthy" => :socket_worker,
    # Held for the machine that was asked: an `explored` answers a ref this connection holds, and
    # nothing in the payload names a job.
    "explored" => :socket_worker,
    "lines" => :owns_job,
    "event" => :owns_job,
    "result" => :owns_job,
    "turn" => :owns_job,
    "delivered" => :owns_job,
    "hibernated" => :owns_job,
    "failed" => :owns_job
  }

  test "every API route is classified for a project token" do
    actual =
      for %{path: "/api/v1" <> _ = path, verb: verb} <- ForgeWeb.Router.__routes__(),
          into: MapSet.new(),
          do: {verb, path}

    recorded = ForgeWeb.TokenRoutes.all() |> Map.keys() |> MapSet.new()

    assert MapSet.to_list(MapSet.difference(actual, recorded)) == [],
           "API route(s) with no token class: classify them in test/support/token_routes.ex"

    assert MapSet.to_list(MapSet.difference(recorded, actual)) == []
  end

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
