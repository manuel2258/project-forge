defmodule ForgeWorker.Config do
  @moduledoc """
  What the config disk or metadata service said (`forge-worker-config.service` in the image)
  and what the machine can see about itself. The worker learns its identity
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

  @doc """
  Cores this machine offers to jobs.

  **No reserve, unlike memory, and that is a decision rather than an omission.** A core held
  back is a core the busiest job on the machine cannot borrow, and the slice hands out
  proportional CPU *shares* rather than quotas precisely so that an agent idle on inference
  donates to whoever is compiling (`docs/decisions.md`). Holding one back for the system would
  be the quota this design refused, paid on every machine whether or not anything is waiting.
  `docs/design/provisioning.md` § Open records that this is unmeasured and says to measure
  before moving it.

  **A machine that cannot tell reports nil, not zero, and the two are opposite instructions.**
  Nil means *unknown*: the platform does not gate it on cores at all
  (`Forge.Workers.fits?/2`), which is what keeps every machine built before this field existed
  taking work. Zero would mean *no capacity*, and a machine that merely could not count its own
  processors would silently stop accepting anything.

  This is the reverse of `memory_budget/0`, which reports zero for the same ignorance and means
  it: overstating memory lets a build kill its neighbours, so not knowing is a reason to offer
  nothing. Overstating cores costs contention, and stranding a machine costs all of it.
  """
  @spec cores() :: pos_integer() | nil
  def cores do
    case get(:cores, "FORGE_CORES") do
      nil -> online_cores()
      value when is_integer(value) -> value
      value -> String.to_integer(value)
    end
  end

  # `:erlang.system_info(:logical_processors_online)` is what the VM was actually given, which
  # on a machine with an affinity mask is smaller than the socket's count and is the honest
  # figure. It returns `:unknown` where the OS will not say.
  #
  # **This whole clause is an equivalent mutant under test and must not have one written for
  # it** — the guard as well as the `:unknown` branch. A running VM always answers with a
  # positive integer, so `> 0`, `>= 0` and `> 1` are indistinguishable here, and so is `and`
  # read as `or`; a mutation pass confirmed all four survive. What the fallback must return is
  # nil, for the reason in `cores/0` above. A test asserting any of it would have to fake the
  # VM, and a test that passes against the broken version is worse than none.
  defp online_cores do
    case :erlang.system_info(:logical_processors_online) do
      count when is_integer(count) and count > 0 -> count
      _unknown -> nil
    end
  end

  @doc """
  The job kinds this machine will take, or nil for "anything".

  `FORGE_ACCEPTS` is a comma-separated list — the same shape as everything else on the config
  disk, which is `KEY=VALUE` lines and has no room for structure. Absent means the machine does
  not restrict itself, which is what every worker did before this existed and what a
  general-purpose machine still wants. A machine bought for one kind of work says so here, and
  the platform will not send it anything else
  (`docs/design/provisioning.md` § What a worker offers).

  Names are passed through rather than checked: the platform knows which kinds exist and drops
  the ones it does not recognise, and a worker that validated against its own list would refuse
  a kind the platform gained in a migration it has not been rebuilt for.
  """
  @spec accepts() :: [String.t()] | nil
  def accepts do
    case get(:accepts, "FORGE_ACCEPTS") do
      nil ->
        nil

      value when is_list(value) ->
        value

      value ->
        case value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
          [] -> nil
          kinds -> kinds
        end
    end
  end

  defp get(key, env) do
    case Application.get_env(:forge_worker, key) do
      nil -> System.get_env(env)
      value -> value
    end
  end
end
