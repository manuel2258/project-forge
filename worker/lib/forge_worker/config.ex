defmodule ForgeWorker.Config do
  @moduledoc """
  What cloud-init wrote and the machine can see about itself. The worker learns its identity
  and the platform's address from its environment, because that is what a provider can inject
  at creation and what `docs/design/worker-tier.md` § The worker image relies on.
  """

  @reserve 2 * 1024 * 1024 * 1024

  @doc "Whether this machine has been told what it is. Nothing starts until it has."
  @spec configured?() :: boolean()
  def configured?, do: worker_id() != nil and token() != nil and platform_url() != nil

  @spec worker_id() :: String.t() | nil
  def worker_id, do: get(:worker_id, "FORGE_WORKER_ID")

  @spec token() :: String.t() | nil
  def token, do: get(:token, "FORGE_WORKER_TOKEN")

  @doc "The platform, as `http://host:port`. The socket and the store are both under it."
  @spec platform_url() :: String.t() | nil
  def platform_url, do: get(:platform_url, "FORGE_PLATFORM_URL")

  @doc """
  The websocket URI. Carries `worker_id` and no credential.

  The token goes in a header (`socket_headers/0`) and never in the URL: a URL is recorded by
  every proxy, access log and tracing span on the path, and this token is long lived and grants
  the channel for the life of the machine. See `docs/design/worker-channel.md` § Authentication.
  """
  @spec socket_uri() :: String.t()
  def socket_uri do
    uri = URI.parse(platform_url())
    scheme = if uri.scheme == "https", do: "wss", else: "ws"
    query = URI.encode_query(%{"worker_id" => worker_id()})

    %URI{uri | scheme: scheme, path: "/worker/websocket", query: query} |> URI.to_string()
  end

  @doc """
  The credential, as the headers the websocket handshake carries.

  `x-forge-worker-token` rather than `authorization`, because Phoenix's socket transport passes
  only `x-` prefixed headers through to `connect/3` — `:x_headers` in the endpoint's
  `connect_info` is literally "headers with an x- prefix". The store, which is an ordinary HTTP
  request and not a socket handshake, uses `Authorization: Bearer`.
  """
  @spec socket_headers() :: [{String.t(), String.t()}]
  def socket_headers, do: [{"x-forge-worker-token", token() || ""}]

  @doc "Where job directories and worktrees live on this machine."
  @spec root() :: String.t()
  def root, do: get(:root, "FORGE_ROOT") || "/var/lib/forge"

  @doc """
  Memory this machine offers to jobs: what it has, less a reserve for the system and the Nix
  daemon. The platform schedules against this figure, so a machine that overstates it is one
  that lets a build kill its neighbours.
  """
  @spec memory_budget() :: non_neg_integer()
  def memory_budget do
    case get(:memory_budget, "FORGE_MEMORY_BUDGET") do
      nil -> max(total_memory() - reserve(), 0)
      value when is_integer(value) -> value
      value -> String.to_integer(value)
    end
  end

  defp reserve, do: Application.get_env(:forge_worker, :memory_reserve, @reserve)

  # MemTotal is in kibibytes. A machine that cannot tell us offers nothing rather than
  # guessing high: the platform then assigns it nothing, which is visible, rather than
  # overcommitting it, which is not.
  defp total_memory do
    with {:ok, meminfo} <- File.read("/proc/meminfo"),
         [_line, kb] <- Regex.run(~r/MemTotal:\s+(\d+) kB/, meminfo) do
      String.to_integer(kb) * 1024
    else
      _other -> 0
    end
  end

  defp get(key, env) do
    case Application.get_env(:forge_worker, key) do
      nil -> System.get_env(env)
      value -> value
    end
  end
end
