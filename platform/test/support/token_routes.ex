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
    {:get, "/api/v1/tickets"} => :token_read,
    {:post, "/api/v1/projects/:project/tickets"} => :token_write,
    {:get, "/api/v1/tickets/:project/:number"} => :token_read,
    {:get, "/api/v1/tickets/:project/:number/events"} => :token_read,
    {:get, "/api/v1/tickets/:project/:number/review"} => :token_read,
    {:get, "/api/v1/tickets/:project/:number/jobs/:job_id"} => :token_read,
    {:get, "/api/v1/tickets/:project/:number/artifacts"} => :token_read,
    {:get, "/api/v1/tickets/:project/:number/artifacts/:name"} => :token_read,
    {:get, "/api/v1/tickets/:project/:number/artifacts/:name/:version/raw"} => :token_read,
    {:post, "/api/v1/tickets/:project/:number/artifacts/:name"} => :token_write,
    {:post, "/api/v1/tickets/:project/:number/answers"} => :token_write,
    {:post, "/api/v1/tickets/:project/:number/approve"} => :token_write,
    {:post, "/api/v1/tickets/:project/:number/transition"} => :token_write,
    {:post, "/api/v1/tickets/:project/:number/retry"} => :token_write,
    {:post, "/api/v1/tickets/:project/:number/cancel"} => :token_write,
    {:post, "/api/v1/tickets/:project/:number/restore"} => :token_write,
    {:get, "/api/v1/projects/:project/proposals"} => :token_read,
    {:post, "/api/v1/proposals/:version_id/accept"} => :token_write,
    {:post, "/api/v1/proposals/:version_id/decline"} => :token_write
  }

  def all, do: @routes
end
