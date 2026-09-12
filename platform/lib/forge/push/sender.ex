defmodule Forge.Push.Sender do
  @moduledoc "Delivers one push message; swapped for a test double in tests."

  @callback deliver(subscription_json :: String.t(), payload :: String.t()) ::
              :ok | {:error, :expired} | {:error, term()}
end

defmodule Forge.Push.Sender.WebPush do
  @moduledoc "Delivers through the web_push_elixir library with the configured VAPID keys."

  @behaviour Forge.Push.Sender

  @impl true
  def deliver(subscription_json, payload) do
    case WebPushElixir.send_notification(subscription_json, payload) do
      {:ok, _response} -> :ok
      {:error, :expired} -> {:error, :expired}
      {:error, reason} -> {:error, reason}
    end
  end
end
