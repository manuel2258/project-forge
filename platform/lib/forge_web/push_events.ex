defmodule ForgeWeb.PushEvents do
  @moduledoc """
  This browser's push subscription, from whichever page draws its button — the queue's *Notify
  me* and the switch on You (`docs/design/ui.md` § Push follows the queue, § You). The
  `PushSubscribe` hook sends the same three events from either, so they are handled here once.

  The subscription is the caller's own: `Forge.Push` stores it against the user in the socket and
  no other. Done, it is a toast; refused, the words stay under the button that was pressed
  (`push_error`), never a toast (§ Errors stay where you acted).
  """

  import Phoenix.Component, only: [assign: 3]

  alias Forge.Push
  alias ForgeWeb.Toast

  @doc "What a page that draws the button needs: the key the browser subscribes with, no error."
  @spec init(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def init(socket) do
    socket
    |> assign(:push_key, Push.enabled?() && Push.public_key())
    |> assign(:push_error, nil)
  end

  @doc "Handles a `push:*` event; any other one of that prefix changes nothing."
  @spec handle(String.t(), map(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def handle("push:subscribe", %{"endpoint" => _} = subscription, socket) do
    case Push.subscribe(socket.assigns.current_scope.user, subscription) do
      {:ok, _} ->
        socket
        |> assign(:push_error, nil)
        |> Toast.put("This browser will be notified of blocking questions.")

      {:error, _} ->
        assign(socket, :push_error, "Could not save the subscription.")
    end
  end

  def handle("push:unsubscribe", %{"endpoint" => endpoint}, socket) do
    Push.unsubscribe(socket.assigns.current_scope.user, endpoint)

    socket
    |> assign(:push_error, nil)
    |> Toast.put("Notifications off for this browser.")
  end

  def handle("push:error", %{"reason" => reason}, socket) when is_binary(reason),
    do: assign(socket, :push_error, "Notifications unavailable: #{reason}")

  def handle(_event, _params, socket), do: socket
end
