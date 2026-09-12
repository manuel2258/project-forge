defmodule Forge.Push.TestSender do
  @moduledoc "Records pushes in the test process's mailbox instead of sending them."

  @behaviour Forge.Push.Sender

  @impl true
  def deliver(subscription_json, payload) do
    subscription = Jason.decode!(subscription_json)
    payload = Jason.decode!(payload)

    case subscription["endpoint"] do
      "https://push.example/expired" ->
        {:error, :expired}

      "https://push.example/broken" ->
        {:error, {:http_error, 500, "boom"}}

      _ ->
        if pid = test_pid(), do: send(pid, {:push, subscription["endpoint"], payload})
        :ok
    end
  end

  @doc "Tells the sender which process receives `{:push, endpoint, payload}` messages."
  def watch(pid \\ self()), do: :persistent_term.put({__MODULE__, :pid}, pid)
  defp test_pid, do: :persistent_term.get({__MODULE__, :pid}, nil)
end
