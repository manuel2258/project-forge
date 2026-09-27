defmodule Forge.Provider.Fake do
  @moduledoc """
  A provider that creates nothing. It is what the platform's tests run against, and what the
  operator runs against while developing on a machine that cannot boot a virtual machine —
  which is every machine without KVM, including the one this milestone was written on.

  Calls are recorded in the watching process's mailbox, the way `Forge.Push.TestSender` does
  it, so a test can assert on what the platform asked the provider for.
  """

  @behaviour Forge.Provider

  @impl Forge.Provider
  def create(opts) do
    case :persistent_term.get({__MODULE__, :refuse}, nil) do
      nil -> created(opts)
      reason -> {:error, reason}
    end
  end

  defp created(opts) do
    notify({:provider_create, opts})

    case :persistent_term.get({__MODULE__, :during_create}, nil) do
      nil -> :ok
      during -> during.(opts)
    end

    {:ok, %{provider_id: "fake-" <> opts.worker_id, address: "127.0.0.1"}}
  end

  @doc """
  Runs `fun` with the create's options while the create is under way, before it answers — which
  is what a real provider's slow `POST /servers` leaves room for, and what a person pressing
  Destroy during it does.
  """
  @spec during_create((map() -> any())) :: :ok
  def during_create(fun), do: :persistent_term.put({__MODULE__, :during_create}, fun)

  # **The credential is carried in the message**, because the defect this exists to catch is a
  # destroy sent without one: the Hetzner driver refused before reaching the API, the platform
  # threw the refusal away, and the machine went on billing under a row that said destroyed.
  # A test that only asserts *a* destroy happened cannot see that.
  @impl Forge.Provider
  def destroy(provider_id, credential \\ nil) do
    notify({:provider_destroy, provider_id, credential})

    case :persistent_term.get({__MODULE__, :refuse_destroy}, nil) do
      nil -> :ok
      reason -> {:error, reason}
    end
  end

  @impl Forge.Provider
  def status(provider_id, _credential \\ nil) do
    notify({:provider_status, provider_id})
    {:ok, :running}
  end

  # Two shapes so that a test about choosing between them has something to choose.
  @impl Forge.Provider
  def shapes(credential) do
    notify({:provider_shapes, credential})

    {:ok,
     [
       %{size: "small", memory: 2 * 1024 * 1024 * 1024, cores: 2, price_hourly: nil},
       %{size: "large", memory: 8 * 1024 * 1024 * 1024, cores: 8, price_hourly: nil}
     ]}
  end

  @impl Forge.Provider
  def credential_fields, do: [%{key: "token", label: "API token"}]

  # Nothing unless a test says otherwise with `requiring/1`, so a page test can draw the form
  # for a provider that needs an image without a network behind it.
  @impl Forge.Provider
  def required_template_fields, do: :persistent_term.get({__MODULE__, :requires}, [])

  @doc "Makes `required_template_fields/0` answer `fields` until `allow/0`."
  @spec requiring([:size | :image]) :: :ok
  def requiring(fields), do: :persistent_term.put({__MODULE__, :requires}, fields)

  @impl Forge.Provider
  def list(credential) do
    notify({:provider_list, credential})
    {:ok, :persistent_term.get({__MODULE__, :instances}, [])}
  end

  @impl Forge.Provider
  def images(credential) do
    notify({:provider_images, credential})

    {:ok,
     :persistent_term.get({__MODULE__, :images}, [
       %{id: "snapshot-1", name: "forge-worker", status: "available", build: nil, protocol: nil}
     ])}
  end

  @doc """
  What `images/1` will list until `allow/0`, so a page test can offer labelled and unlabelled
  snapshots.
  """
  @spec listing([map()]) :: :ok
  def listing(images), do: :persistent_term.put({__MODULE__, :images}, images)

  @doc "What `list/1` will say the provider is holding, so reconciliation can be driven."
  @spec holding([map()]) :: :ok
  def holding(instances), do: :persistent_term.put({__MODULE__, :instances}, instances)

  @doc """
  Makes the next creates fail with `reason`, so a caller's handling of a refusal can be driven.

  A driver refusing is not an exotic case — no image configured, a server type withdrawn, a
  token revoked — and until this existed nothing in the suite could reach that path.
  """
  @spec refuse(term()) :: :ok
  def refuse(reason), do: :persistent_term.put({__MODULE__, :refuse}, reason)

  @doc """
  Makes the next destroys fail with `reason`.

  A destroy that fails is the case the leak was made of — a machine the platform cannot end —
  and until this existed nothing in the suite could reach it.
  """
  @spec refuse_destroy(term()) :: :ok
  def refuse_destroy(reason), do: :persistent_term.put({__MODULE__, :refuse_destroy}, reason)

  @doc """
  Stops refusing, both kinds, stops requiring template fields and lists the default images
  again. Called on exit by anything that called `refuse/1`, `refuse_destroy/1`, `requiring/1` or
  `listing/1` or `during_create/1`.
  """
  @spec allow() :: :ok
  def allow do
    :persistent_term.erase({__MODULE__, :refuse})
    :persistent_term.erase({__MODULE__, :refuse_destroy})
    :persistent_term.erase({__MODULE__, :requires})
    :persistent_term.erase({__MODULE__, :images})
    :persistent_term.erase({__MODULE__, :during_create})
    :ok
  end

  @doc "Tells the fake which process receives `{:provider_*, ...}` messages."
  @spec watch(pid()) :: :ok
  def watch(pid \\ self()), do: :persistent_term.put({__MODULE__, :pid}, pid)

  defp notify(message) do
    case :persistent_term.get({__MODULE__, :pid}, nil) do
      nil -> :ok
      pid -> send(pid, message)
    end

    :ok
  end
end
