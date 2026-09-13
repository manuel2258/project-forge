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
    notify({:provider_create, opts})
    {:ok, %{provider_id: "fake-" <> opts.worker_id, address: "127.0.0.1"}}
  end

  @impl Forge.Provider
  def destroy(provider_id) do
    notify({:provider_destroy, provider_id})
    :ok
  end

  @impl Forge.Provider
  def status(provider_id) do
    notify({:provider_status, provider_id})
    {:ok, :running}
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
