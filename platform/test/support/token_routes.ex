defmodule ForgeWeb.TokenRoutes do
  @moduledoc """
  What a **project token** may do at each `/api/v1` route, which the inventory's `:member` cannot
  say: a token is a member of one project only when its API access is write, and never of what is
  a person's.

  - `:token_read` — a token with API read or write; another project's token gets 404.
  - `:token_write` — only a token with API write; read gets 403 *before* any lookup.
  - `:token_never` — no token, whatever it can do: 403.

  `ForgeWeb.AuthorizationInventoryTest` fails on a route missing from here, and
  `ForgeWeb.Api.ProjectTokenTest` drives every class against a token that must be refused.
  """

  @routes %{
    {:get, "/api/v1/me"} => :token_read,
    {:get, "/api/v1/queue"} => :token_never,
    {:get, "/api/v1/projects"} => :token_read,
    {:post, "/api/v1/projects"} => :token_never,
    {:delete, "/api/v1/tickets/:project/:number/attachments/:file"} => :token_never,
    {:delete, "/api/v1/tickets/:project/:number/attachments/:file/:version"} => :token_never,
    {:get, "/api/v1/tickets"} => :token_read,
    {:get, "/api/v1/projects/:project"} => :token_read,
    {:post, "/api/v1/projects/:project/tickets"} => :token_write,
    {:get, "/api/v1/tickets/:project/:number"} => :token_read,
    {:get, "/api/v1/tickets/:project/:number/events"} => :token_read,
    {:get, "/api/v1/tickets/:project/:number/review"} => :token_read,
    {:get, "/api/v1/tickets/:project/:number/jobs/:job_id"} => :token_read,
    # A command's log, and a ticket's kept copies looked into on their machines: every one a read, so a
    # token of either access reaches all of them (`ForgeWeb.Api.BuildController`).
    {:get, "/api/v1/tickets/:project/:number/jobs/:job_id/log"} => :token_read,
    {:get, "/api/v1/tickets/:project/:number/builds"} => :token_read,
    {:get, "/api/v1/tickets/:project/:number/builds/:job_id/folder"} => :token_read,
    {:get, "/api/v1/tickets/:project/:number/builds/:job_id/file"} => :token_read,
    {:get, "/api/v1/tickets/:project/:number/builds/:job_id/download"} => :token_read,
    {:get, "/api/v1/tickets/:project/:number/artifacts"} => :token_read,
    {:get, "/api/v1/tickets/:project/:number/artifacts/:name"} => :token_read,
    {:get, "/api/v1/tickets/:project/:number/artifacts/:name/:version/raw"} => :token_read,
    {:post, "/api/v1/tickets/:project/:number/artifacts/:name"} => :token_write,
    {:get, "/api/v1/tickets/:project/:number/pages"} => :token_read,
    {:get, "/api/v1/tickets/:project/:number/pages/:name/data"} => :token_read,
    {:get, "/api/v1/tickets/:project/:number/pages/:name/data/:key"} => :token_read,
    {:put, "/api/v1/tickets/:project/:number/pages/:name/data/:key"} => :token_write,
    {:delete, "/api/v1/tickets/:project/:number/pages/:name/data/:key"} => :token_write,
    {:post, "/api/v1/tickets/:project/:number/answers"} => :token_write,
    {:post, "/api/v1/tickets/:project/:number/approve"} => :token_write,
    {:post, "/api/v1/tickets/:project/:number/transition"} => :token_write,
    {:post, "/api/v1/tickets/:project/:number/retry"} => :token_write,
    {:post, "/api/v1/tickets/:project/:number/jobs/:job_id/extend"} => :token_write,
    {:post, "/api/v1/tickets/:project/:number/cancel"} => :token_write,
    {:post, "/api/v1/tickets/:project/:number/restore"} => :token_write,
    {:post, "/api/v1/tickets/:project/:number/hold"} => :token_write,
    {:post, "/api/v1/tickets/:project/:number/release"} => :token_write,
    {:post, "/api/v1/tickets/:project/:number/stop"} => :token_write,
    {:post, "/api/v1/tickets/:project/:number/take-over"} => :token_write,
    {:post, "/api/v1/tickets/:project/:number/hand-back"} => :token_write,
    {:post, "/api/v1/tickets/:project/:number/keep-work"} => :token_write,
    {:post, "/api/v1/tickets/:project/:number/clear-warm-build"} => :token_write,
    {:post, "/api/v1/tickets/:project/:number/title"} => :token_write,
    {:post, "/api/v1/tickets/:project/:number/milestone"} => :token_write,
    {:post, "/api/v1/tickets/:project/:number/move"} => :token_write,
    {:get, "/api/v1/projects/:project/milestones"} => :token_read,
    {:post, "/api/v1/projects/:project/milestones"} => :token_write,
    {:post, "/api/v1/projects/:project/milestones/:id"} => :token_write,
    {:post, "/api/v1/projects/:project/milestones/:id/current"} => :token_write,
    {:post, "/api/v1/projects/:project/milestones/:id/close"} => :token_write,
    {:post, "/api/v1/projects/:project/milestones/:id/reopen"} => :token_write,
    {:post, "/api/v1/projects/:project/milestones/:id/move"} => :token_write,
    {:get, "/api/v1/projects/:project/schedules"} => :token_read,
    {:post, "/api/v1/projects/:project/schedules/on"} => :token_never,
    {:post, "/api/v1/projects/:project/schedules/off"} => :token_never,
    {:post, "/api/v1/projects/:project/schedules/dismiss"} => :token_write,
    {:get, "/api/v1/projects/:project/proposals"} => :token_read,
    {:post, "/api/v1/proposals/:version_id/accept"} => :token_write,
    {:post, "/api/v1/proposals/:version_id/decline"} => :token_write
  }

  def all, do: @routes
end
