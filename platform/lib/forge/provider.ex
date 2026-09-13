defmodule Forge.Provider do
  @moduledoc """
  Where machines come from. One implementation in the PoC — a local VM under QEMU — and a
  Hetzner one in the closing step, behind the same three callbacks. See
  `docs/design/worker-tier.md` § The provider driver.

  Nothing above this module knows the provider. A module outside `Forge.Provider.*` that
  matches on `"local"` is the bug these callbacks exist to prevent, and the second
  implementation is the test of whether it worked.

  The store is not here. `docs/vision.md` gives a provider three jobs — create a machine,
  destroy it, and somewhere to put bytes — and the third is `Forge.Storage`'s, behind its own
  behaviour, because the operator's blobs are served by the platform either way.
  """

  @typedoc """
  What a machine is created with. `harness_env` is what the machine needs to run an agent at
  all — the credential above everything — which is the machine's rather than any job's and so
  is injected here rather than carried in an assignment; `docs/design/worker-tier.md` § The
  worker image says why.
  """
  @type opts :: %{
          required(:worker_id) => String.t(),
          required(:token) => String.t(),
          required(:platform_url) => String.t(),
          optional(:harness_env) => [{String.t(), String.t()}],
          optional(:size) => String.t()
        }

  @type machine :: %{provider_id: String.t(), address: String.t() | nil}

  @callback create(opts()) :: {:ok, machine()} | {:error, term()}
  @callback destroy(String.t()) :: :ok | {:error, term()}
  @callback status(String.t()) :: {:ok, :pending | :running | :gone} | {:error, term()}

  @spec create(opts()) :: {:ok, machine()} | {:error, term()}
  def create(opts), do: impl().create(opts)

  @spec destroy(String.t()) :: :ok | {:error, term()}
  def destroy(provider_id), do: impl().destroy(provider_id)

  @spec status(String.t()) :: {:ok, :pending | :running | :gone} | {:error, term()}
  def status(provider_id), do: impl().status(provider_id)

  @doc "The name this implementation records on the worker row."
  @spec name() :: String.t()
  def name, do: config(:name, "local")

  defp impl, do: config(:impl, Forge.Provider.LocalVm)

  @doc false
  def config(key, default),
    do: :forge |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
end
