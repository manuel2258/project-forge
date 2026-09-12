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
    pipe_through [:browser, :require_authenticated_user]

    live_session :operator, on_mount: [{ForgeWeb.UserAuth, :require_authenticated}] do
      live "/", QueueLive
      live "/board", BoardLive
      live "/tickets/:project/:number", TicketLive
      live "/tickets/:project/:number/jobs/:job_id", JobLive
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
    get "/tickets/:project/:number/jobs/:job_id", TicketController, :job
    get "/tickets/:project/:number/artifacts/:name", TicketController, :artifact
    post "/tickets/:project/:number/artifacts/:name", TicketController, :edit
    post "/tickets/:project/:number/answers", TicketController, :answer
    post "/tickets/:project/:number/approve", TicketController, :approve
    post "/tickets/:project/:number/transition", TicketController, :transition
  end

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
    end
  end

  ## Authentication routes

  scope "/", ForgeWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{ForgeWeb.UserAuth, :require_authenticated}] do
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
end
