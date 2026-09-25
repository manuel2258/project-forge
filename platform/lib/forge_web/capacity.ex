defmodule ForgeWeb.Capacity do
  @moduledoc """
  The top bar's gauge: which credentials it draws, and keeping it current
  (`docs/design/credentials.md` § Showing the windows, `docs/design/ui.md` § The capacity gauge in
  the top bar).

  Mounted on every approved page with the viewer's own credentials. A page about one project
  switches it to that project's pool with `project/2`, **after** it has decided the viewer may see
  the project — this module reads nothing about who is asking, so calling it first would draw a
  pool the viewer was about to be refused.

  Redrawn every minute while the page is open, because the countdown is to a moment and a report
  may have arrived; not on every event, because nothing about the gauge is urgent.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias Forge.Credentials

  @refresh :timer.minutes(1)

  def on_mount(:own, _params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :capacity_tick, @refresh)

    {:cont,
     socket
     |> draw(:own)
     |> attach_hook(:capacity, :handle_info, &tick/2)}
  end

  @doc "Draws the gauge over `project`'s pool: for a page about that project, once it is allowed."
  @spec project(Phoenix.LiveView.Socket.t(), %{id: String.t()}) :: Phoenix.LiveView.Socket.t()
  def project(socket, %{id: id}), do: draw(socket, {:project, id})

  defp tick(:capacity_tick, socket) do
    Process.send_after(self(), :capacity_tick, @refresh)
    {:halt, draw(socket, socket.assigns.capacity_of)}
  end

  defp tick(_message, socket), do: {:cont, socket}

  defp draw(socket, of) do
    socket
    |> assign(:capacity_of, of)
    |> assign(:capacity, Credentials.gauge(ids(socket, of)))
  end

  defp ids(socket, :own), do: Credentials.owned_ids(socket.assigns.current_scope.user)
  defp ids(_socket, {:project, id}), do: Credentials.pool_ids(id)
end
