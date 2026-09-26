defmodule ForgeWeb.Router do
  use ForgeWeb, :router

  import ForgeWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ForgeWeb.Layouts, :root}
    plug :protect_from_forgery
    # Documents are agent-written: no remote images or scripts, whatever the sanitizer lets
    # through. Inline script and style are what the generated layout and LiveView need.
    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; img-src 'self' data:; script-src 'self' 'unsafe-inline'; " <>
          "style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; " <>
          "base-uri 'self'; form-action 'self'"
    }

    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug ForgeWeb.Plugs.ApiAuth
  end

  scope "/", ForgeWeb do
    pipe_through [:browser, :require_authenticated_user, :require_approved_user]

    # `ForgeWeb.Capacity` draws the top bar's window gauge over the viewer's own credentials; a
    # page about one project switches it to that project's pool once it has allowed the viewer.
    live_session :operator,
      on_mount: [{ForgeWeb.UserAuth, :require_approved}, {ForgeWeb.Capacity, :own}] do
      live "/", QueueLive
      live "/board", BoardLive
      live "/workers", WorkersLive
      live "/templates", TemplatesLive
      # Before /tickets/:project/:number, or "new" is read as a project name.
      live "/projects/new", ProjectNewLive
      live "/projects/:name", ProjectLive
      live "/projects/:name/settings", ProjectSettingsLive
      live "/tickets/new", TicketNewLive
      live "/tickets/:project/:number", TicketLive
      live "/tickets/:project/:number/review", ReviewLive
      live "/tickets/:project/:number/jobs/:job_id", JobLive
      live "/chats", ChatsLive
      live "/chats/new", ChatNewLive
      live "/chats/:id", ChatLive
    end

    # Not a LiveView: this serves bytes, and every artifact name in the product links to it.
    # See docs/design/ui.md § Addressable artifact versions.
    get "/tickets/:project/:number/artifacts/:name/:version", ArtifactController, :show
    # A conversation's own artifacts, by the same rule: the address names the scope.
    get "/chats/:id/artifacts/:name/:version", ArtifactController, :chat
  end

  # Account governance, and the only thing `node_admin` unlocks. Not under the operator scope:
  # a node admin is not a member of any project and this page shows none.
  scope "/", ForgeWeb do
    pipe_through [:browser, :require_authenticated_user, :require_approved_user]

    live_session :node_admin,
      on_mount: [{ForgeWeb.UserAuth, :require_node_admin}, {ForgeWeb.Capacity, :own}] do
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

  scope "/api/v1", ForgeWeb.Api do
    pipe_through :api

    get "/me", TicketController, :me
    get "/queue", TicketController, :queue
    get "/projects", ProjectController, :index
    post "/projects", ProjectController, :create
    get "/tickets", TicketController, :index
    post "/projects/:project/tickets", TicketController, :create
    get "/tickets/:project/:number", TicketController, :show
    get "/tickets/:project/:number/events", TicketController, :events
    get "/tickets/:project/:number/review", TicketController, :review
    get "/tickets/:project/:number/jobs/:job_id", TicketController, :job
    get "/tickets/:project/:number/artifacts/:name", TicketController, :artifact
    post "/tickets/:project/:number/artifacts/:name", TicketController, :edit
    post "/tickets/:project/:number/answers", TicketController, :answer
    post "/tickets/:project/:number/approve", TicketController, :approve
    post "/tickets/:project/:number/transition", TicketController, :transition
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
      on_mount: [{ForgeWeb.UserAuth, :require_approved}, {ForgeWeb.Capacity, :own}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", ForgeWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{ForgeWeb.UserAuth, :mount_current_scope}] do
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
