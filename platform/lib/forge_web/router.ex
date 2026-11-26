defmodule ForgeWeb.Router do
  use ForgeWeb, :router
  use Plug.ErrorHandler

  import ForgeWeb.UserAuth

  # Documents are agent-written: no remote images or scripts, whatever the sanitizer lets
  # through. Inline script and style are what the generated layout and LiveView need.
  @csp "default-src 'self'; img-src 'self' data:; script-src 'self' 'unsafe-inline'; " <>
         "style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; " <>
         "base-uri 'self'; form-action 'self'"

  # A request that staged files and ended in an exception leaves them for nobody: `before_send` does
  # not run when Phoenix renders the error (`ForgeWeb.Plugs.ApiFiles.discard_after_error/1`).
  @impl Plug.ErrorHandler
  def handle_errors(_conn, _error), do: ForgeWeb.Plugs.ApiFiles.discard_after_error()

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ForgeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"content-security-policy" => @csp}

    plug :fetch_current_scope_for_user
  end

  # What a phone's installed forge fetches before anybody is known: the service worker's script
  # and the offline page. **No session, no CSRF token, no user**, so what the device stores of
  # them holds nothing of the person's (`docs/design/ui.md` § The installed app).
  pipeline :device do
    plug :put_secure_browser_headers, %{"content-security-policy" => @csp}
  end

  # The device's one read about its own person (`GET /push/waiting`): the session, to know who asks,
  # without the browser pipeline's flash, CSRF token, `accepts` and root layout. **No
  # `fetch_live_flash`**: a request through it clears a pending flash, and the service worker makes
  # this one in the background — when a push arrives, or a page it was asked about comes into view —
  # so it can land between a redirect and the page that is to draw the toast the redirect left
  # (`Logged out`, `Welcome back`), and take it.
  pipeline :device_session do
    plug :fetch_session
    plug :put_secure_browser_headers, %{"content-security-policy" => @csp}
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug ForgeWeb.Plugs.ApiAuth
  end

  # The MCP endpoint (`docs/design/api-and-ui.md` § MCP): the API's bearers, and no `accepts` — an MCP
  # client asks for `application/json` and `text/event-stream` and is answered the first. A foreign
  # `Origin` is refused before any credential is read.
  pipeline :mcp do
    plug ForgeWeb.Plugs.McpOrigin
    plug ForgeWeb.Plugs.ApiAuth
  end

  scope "/", ForgeWeb do
    pipe_through :device

    get "/sw.js", DeviceController, :service_worker
    get "/offline", DeviceController, :offline
  end

  # The device's one read about its own person. In `:device_session` for the session, and behind no
  # redirecting plug: a signed-out fetch is answered with a 401 and nothing, not a login page.
  scope "/", ForgeWeb do
    pipe_through :device_session

    get "/push/waiting", DeviceController, :waiting
  end

  scope "/", ForgeWeb do
    pipe_through [:browser, :require_authenticated_user, :require_approved_user]

    # `ForgeWeb.Frame` reads what the frame draws on every page — the queue count, the usage
    # lines over the viewer's own credentials — and keeps it current; a page about one project
    # switches the lines to that project's pool once it has allowed the viewer.
    live_session :operator,
      on_mount: [{ForgeWeb.UserAuth, :require_approved}, {ForgeWeb.Frame, :signed_in}] do
      live "/", QueueLive
      live "/workers", WorkersLive
      live "/workers/:id", WorkerLive
      live "/templates", TemplatesLive
      live "/projects", ProjectsLive
      # Before /tickets/:project/:number, or "new" is read as a project name.
      live "/projects/new", ProjectNewLive
      live "/projects/:name", ProjectLive
      live "/projects/:name/settings", ProjectSettingsLive
      # The repository the project holds, read-only. See docs/design/ui.md
      # § The project's repository.
      live "/projects/:name/repo", RepoLive
      live "/projects/:name/repo/commits/:sha", RepoCommitLive
      # A project's releases, read-only. See docs/design/ui.md § A project's releases.
      live "/projects/:name/releases", ReleasesLive
      live "/projects/:name/releases/:id", ReleaseLive
      live "/tickets/new", TicketNewLive
      live "/tickets/:project/:number", TicketLive
      live "/tickets/:project/:number/jobs/:job_id", JobLive
      live "/chats", ChatsLive
      live "/chats/new", ChatNewLive
      live "/chats/:id", ChatLive
      live "/usage", UsageLive
    end

    # A page an agent wrote, in a live session of its own with no frame: the bar the page view
    # draws is forge's own and the frame under it is the page's (`docs/design/ui.md` § Pages).
    # A live session of its own is also what forces a full page load on the way in, so the page
    # never shares a document with another screen of forge.
    live_session :page, on_mount: [{ForgeWeb.UserAuth, :require_approved}] do
      live "/tickets/:project/:number/pages/:name", PageLive
      live "/chats/:id/pages/:name", PageLive
    end

    # Not a LiveView: this serves bytes, and every artifact name in the product links to it.
    # See docs/design/ui.md § Addressable artifact versions.
    get "/tickets/:project/:number/artifacts/:name/:version", ArtifactController, :show
    # A conversation's own artifacts, by the same rule: the address names the scope.
    get "/chats/:id/artifacts/:name/:version", ArtifactController, :chat
    # The page's way of sending a file to attach: staged here, claimed by the act it rides on.
    # See docs/design/attachments.md § Staging, claiming and the sweep.
    post "/projects/:name/uploads", UploadController, :create
    delete "/projects/:name/uploads/:id", UploadController, :delete
  end

  # Account governance, and the only thing `node_admin` unlocks. Not under the operator scope:
  # a node admin is not a member of any project and this page shows none.
  scope "/", ForgeWeb do
    pipe_through [:browser, :require_authenticated_user, :require_approved_user]

    live_session :node_admin,
      on_mount: [{ForgeWeb.UserAuth, :require_node_admin}, {ForgeWeb.Frame, :signed_in}] do
      live "/accounts", AccountsLive
    end
  end

  # A pending account is authenticated but not approved, so it is the one page behind
  # `require_authenticated_user` that must not also require approval.
  scope "/", ForgeWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :pending, on_mount: [{ForgeWeb.UserAuth, :require_authenticated}] do
      live "/users/pending", UserLive.Pending
    end
  end

  scope "/mcp", ForgeWeb do
    pipe_through :mcp

    post "/", McpController, :post
    get "/", McpController, :not_allowed
    delete "/", McpController, :not_allowed
  end

  scope "/api/v1", ForgeWeb.Api do
    pipe_through :api

    get "/me", TicketController, :me
    get "/queue", TicketController, :queue
    get "/projects", ProjectController, :index
    post "/projects", ProjectController, :create
    get "/projects/:project", ProjectController, :show
    get "/tickets", TicketController, :index
    post "/projects/:project/tickets", TicketController, :create
    get "/tickets/:project/:number", TicketController, :show
    get "/tickets/:project/:number/events", TicketController, :events
    get "/tickets/:project/:number/review", TicketController, :review
    get "/tickets/:project/:number/jobs/:job_id", TicketController, :job
    get "/tickets/:project/:number/artifacts", TicketController, :artifacts
    get "/tickets/:project/:number/artifacts/:name/:version/raw", TicketController, :raw
    get "/tickets/:project/:number/artifacts/:name", TicketController, :artifact
    get "/tickets/:project/:number/pages", PageController, :index
    get "/tickets/:project/:number/pages/:name/data", PageController, :data
    get "/tickets/:project/:number/pages/:name/data/:key", PageController, :show
    put "/tickets/:project/:number/pages/:name/data/:key", PageController, :put
    delete "/tickets/:project/:number/pages/:name/data/:key", PageController, :delete
    post "/tickets/:project/:number/artifacts/:name", TicketController, :edit
    delete "/tickets/:project/:number/attachments/:file", TicketController, :withdraw
    delete "/tickets/:project/:number/attachments/:file/:version", TicketController, :withdraw
    post "/tickets/:project/:number/answers", TicketController, :answer
    post "/tickets/:project/:number/approve", TicketController, :approve
    post "/tickets/:project/:number/transition", TicketController, :transition
    post "/tickets/:project/:number/retry", TicketController, :retry
    post "/tickets/:project/:number/jobs/:job_id/extend", TicketController, :extend
    post "/tickets/:project/:number/cancel", TicketController, :cancel
    post "/tickets/:project/:number/restore", TicketController, :restore
    post "/tickets/:project/:number/hold", TicketController, :hold
    post "/tickets/:project/:number/release", TicketController, :release
    post "/tickets/:project/:number/stop", TicketController, :stop
    post "/tickets/:project/:number/take-over", TicketController, :take_over
    post "/tickets/:project/:number/hand-back", TicketController, :hand_back
    post "/tickets/:project/:number/keep-work", TicketController, :keep_work
    post "/tickets/:project/:number/clear-warm-build", TicketController, :clear_warm_build
    post "/tickets/:project/:number/title", TicketController, :title
    post "/tickets/:project/:number/milestone", TicketController, :milestone
    post "/tickets/:project/:number/move", TicketController, :move
    get "/projects/:project/milestones", MilestoneController, :index
    post "/projects/:project/milestones", MilestoneController, :create
    post "/projects/:project/milestones/:id", MilestoneController, :update
    post "/projects/:project/milestones/:id/current", MilestoneController, :current
    post "/projects/:project/milestones/:id/close", MilestoneController, :close
    post "/projects/:project/milestones/:id/reopen", MilestoneController, :reopen
    post "/projects/:project/milestones/:id/move", MilestoneController, :move
    get "/projects/:project/schedules", ScheduleController, :index
    post "/projects/:project/schedules/on", ScheduleController, :on
    post "/projects/:project/schedules/off", ScheduleController, :off
    post "/projects/:project/schedules/dismiss", ScheduleController, :dismiss
    get "/projects/:project/proposals", TicketController, :proposals
    post "/proposals/:version_id/accept", TicketController, :accept_proposal
    post "/proposals/:version_id/decline", TicketController, :decline_proposal
  end

  # The worker's door to the blob store. No session and no pipeline: the short-lived token in
  # the `authorization` header authorises exactly one key and one verb, and nothing else here
  # does (`docs/design/storage.md` § The token is a header).
  # See docs/design/storage.md.
  scope "/store", ForgeWeb do
    get "/*key", StoreController, :show
    put "/*key", StoreController, :update
  end

  # The worker's door to the project's archive. No session: the job's own git token authorises it,
  # and only for the project that token was minted for (`docs/design/archive.md` § The door and
  # its grant). `GET` and nothing else.
  scope "/archive", ForgeWeb do
    get "/", ArchiveController, :root
    get "/tickets/:number", ArchiveController, :ticket
    get "/tickets/:number/:ref", ArchiveController, :show
  end

  # A running job's door to the live store of its ticket's pages (`docs/design/pages.md` § How a
  # running job reaches the store).
  # No session: the job's own git token authorises it, the scope is the token's job row's and never
  # the path's.
  scope "/job/pages", ForgeWeb do
    get "/", JobPagesController, :index
    get "/:name/data", JobPagesController, :data
    get "/:name/data/:key", JobPagesController, :show
    put "/:name/data/:key", JobPagesController, :put
    delete "/:name/data/:key", JobPagesController, :delete
  end

  # A page's own files, for the sandboxed frame. No session and no pipeline: a sandboxed document
  # has an opaque origin and sends no cookie, so the path carries a signed token over the viewer and
  # the page version, and the controller asks again whether that viewer still reaches the project
  # (`docs/design/pages.md` § Serving a page's files).
  scope "/page-files", ForgeWeb do
    get "/:token/:file", PageFileController, :show
  end

  # Liveness for a container runtime and a proxy. Forwarded from the router rather than mounted
  # on the endpoint, though it needs nothing the router does: a way in that `Router.__routes__/0`
  # cannot enumerate is a way in `AuthorizationInventoryTest` cannot make anybody classify, and
  # this one is reachable with no credential at all. It is piped through nothing, and logs
  # nothing: see `ForgeWeb.Endpoint.log_level/1`.
  forward "/health", ForgeWeb.Plugs.Health, [], log: false

  # The platform's repositories, over git's own smart HTTP, with a per-job token as the Basic
  # auth password. See docs/design/worker-tier.md § Git.
  forward "/git", ForgeWeb.Plugs.GitHttp

  # Enable LiveDashboard in development
  if Application.compile_env(:forge, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ForgeWeb.Telemetry
      # The login page links here for the magic link. Without it that link 404s, which looks
      # like the mail failed rather than like the route was missing.
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", ForgeWeb do
    pipe_through [:browser, :require_authenticated_user, :require_approved_user]

    live_session :require_authenticated_user,
      on_mount: [{ForgeWeb.UserAuth, :require_approved}, {ForgeWeb.Frame, :signed_in}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", ForgeWeb do
    pipe_through [:browser]

    # The session carries how this device last signed in (`ForgeWeb.SignIn`), checked, so the
    # login page opens on that way in.
    live_session :current_user,
      on_mount: [{ForgeWeb.UserAuth, :mount_current_scope}],
      session: {ForgeWeb.SignIn, :session, []} do
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  # OIDC, both legs. No credential by definition: the first sends the browser to an issuer and
  # the second is where it comes back, and everything the second decides it decides from the
  # token rather than from who is asking. `docs/design/identity.md` § Authentication.
  #
  # `:browser` is what gives them the session that `state`, `nonce` and the PKCE verifier live
  # in between the two. Both are GETs, so `protect_from_forgery` has nothing to check and the
  # `state` parameter is what stands in for it.
  scope "/auth", ForgeWeb do
    pipe_through [:browser]

    get "/oidc/:provider", OidcController, :request
    get "/oidc/:provider/callback", OidcController, :callback
  end
end
