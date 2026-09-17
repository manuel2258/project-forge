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
  #   :self            — authenticated; acts only on the caller's own account.
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
    "/workers" => :approved,
    "/projects/new" => :approved,
    "/projects/:name" => :member,
    "/projects/:name/settings" => :member,
    "/tickets/new" => :member,
    "/tickets/:project/:number" => :member,
    "/tickets/:project/:number/review" => :member,
    "/tickets/:project/:number/jobs/:job_id" => :member,
    "/tickets/:project/:number/artifacts/:name/:version" => :member,
    "/chats" => :member,
    "/chats/new" => :member,
    "/chats/:id" => :member,

    # Account governance, the only thing the node-wide flag unlocks.
    "/accounts" => :node_admin,

    # The one page an unapproved account may see.
    "/users/pending" => :pending_ok,

    # The caller's own account.
    "/users/settings" => :self,
    "/users/settings/confirm-email/:token" => :self,
    "/users/update-password" => :self,

    # No credential by definition.
    "/users/log-in" => :public,
    "/users/log-in/:token" => :public,
    "/users/log-out" => :public,

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
    {"chat_live.ex", "send"} => :member,
    {"chat_live.ex", "force"} => :member,
    {"chat_live.ex", "answer"} => :member,
    {"chat_live.ex", "stop"} => :member,
    {"chat_live.ex", "close"} => :member,
    {"chat_live.ex", "reopen"} => :member,
    {"chat_live.ex", "merge"} => :member,
    {"chat_live.ex", "draft"} => :local,
    {"chat_new_live.ex", "open"} => :member,
    {"chat_new_live.ex", "validate"} => :local,
    {"job_live.ex", "more"} => :local,
    {"job_live.ex", "notices"} => :local,
    {"project_new_live.ex", "create"} => :approved,
    {"project_new_live.ex", "validate"} => :local,
    {"project_settings_live.ex", "issue"} => :manage,
    {"project_settings_live.ex", "revoke"} => :manage,
    {"project_settings_live.ex", "model"} => :manage,
    {"project_settings_live.ex", "add-member"} => :manage,
    {"project_settings_live.ex", "remove-member"} => :manage,
    {"project_settings_live.ex", "dismiss"} => :local,
    {"project_settings_live.ex", "toggle-spent"} => :local,
    {"project_settings_live.ex", "validate"} => :local,
    {"queue_live.ex", "chat:answer"} => :member,
    {"queue_live.ex", "push:subscribe"} => :self,
    {"queue_live.ex", "push:unsubscribe"} => :self,
    {"queue_live.ex", "push:error"} => :local,
    {"ticket_new_live.ex", "create"} => :member,
    {"ticket_new_live.ex", "validate"} => :local,
    {"workers_live.ex", "toggle-destroyed"} => :local,
    {"user_live/confirmation.ex", "submit"} => :public,
    {"user_live/login.ex", "submit_magic"} => :public,
    {"user_live/login.ex", "submit_password"} => :public,
    {"user_live/settings.ex", "update_email"} => :self,
    {"user_live/settings.ex", "update_password"} => :self,
    {"user_live/settings.ex", "validate_email"} => :self,
    {"user_live/settings.ex", "validate_password"} => :self
  }

  # Worker channel messages. Each addresses a job by an id off the wire, so each must resolve it
  # against the socket's own worker — except the two that act on the socket's worker directly.
  @channel %{
    "ready" => :socket_worker,
    "heartbeat" => :socket_worker,
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

        ~r/def handle_event\("([^"]+)"/
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
