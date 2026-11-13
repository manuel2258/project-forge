defmodule ForgeWeb.Capacity do
  @moduledoc """
  The usage lines' set of credentials, and drawing them (`docs/design/credentials.md` § Showing
  the windows, `docs/design/ui.md` § Usage).

  `ForgeWeb.Frame` draws the viewer's own credentials on every signed-in page and redraws them on
  its minute tick. A page about one project switches the lines to that project's pool with
  `project/2`, **after** it has decided the viewer may see the project — this module reads nothing
  about who is asking, so calling it first would draw a pool the viewer was about to be refused.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Forge.Credentials

  @doc "Draws the viewer's own credentials: every page that is not about one project."
  @spec own(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def own(socket), do: draw(socket, :own)

  @doc "Draws `project`'s pool: for a page about that project, once it is allowed."
  @spec project(Phoenix.LiveView.Socket.t(), %{id: String.t()}) :: Phoenix.LiveView.Socket.t()
  def project(socket, %{id: id}), do: draw(socket, {:project, id})

  @doc "Draws the same set again: a report may have arrived, and a countdown has moved."
  @spec redraw(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def redraw(socket), do: draw(socket, socket.assigns.capacity_of)

  @doc """
  A window's figure as the lines and the panel draw it: the mean as a whole percent, or nil when
  the window is unknown or no credential in the set reported one — which draws no fill, never 0.
  """
  @spec percent(map() | nil) :: non_neg_integer() | nil
  def percent(%{mean: mean}) when is_number(mean), do: round(mean * 100)
  def percent(_window), do: nil

  @doc "The figure as text, `42%`, or `—` when there is none: never a 0 that reads as nothing spent."
  @spec shown(map() | nil) :: String.t()
  def shown(window) do
    case percent(window) do
      nil -> "—"
      percent -> "#{percent}%"
    end
  end

  # The gauge by window, and under `:set` what it was drawn over — `:own` or `{:project, id}` and
  # the credentials' ids — so the usage panel (`ForgeWeb.UsagePanel`) breaks down the same set the
  # line it was opened from averages.
  defp draw(socket, of) do
    socket
    |> assign(:capacity_of, of)
    |> assign(:capacity, gauge(of, socket.assigns.current_scope.user))
  end

  @doc """
  The viewer's own lines, for a page drawn without a socket — the not-found page
  (`ForgeWeb.ErrorHTML`) — which `own/1` draws on one.
  """
  @spec of(Forge.Accounts.User.t()) :: map()
  def of(user), do: gauge(:own, user)

  defp gauge(of, user) do
    ids = ids(of, user)
    ids |> Credentials.gauge() |> Map.put(:set, %{of: of, ids: ids})
  end

  defp ids(:own, user), do: Credentials.owned_ids(user)
  defp ids({:project, id}, _user), do: Credentials.pool_ids(id)
end
