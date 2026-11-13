defmodule ForgeWeb.Frame do
  @moduledoc """
  What the frame draws on every signed-in page, and keeping it current (`docs/design/ui.md`
  § The frame): the queue button's count, the usage lines, and which of the frame's drop panels is
  open — the title menu, the object's details, the usage panel.

  Mounted by every signed-in `live_session` after `ForgeWeb.UserAuth`, so a page renders
  `Layouts.app` with `frame={@frame}` and `capacity={@capacity}` and reads nothing itself.

  **The count is kept current from one topic.** `Forge.Events` broadcasts `{:queue_changed,
  project_id}` on `"queue"` whenever a ticket changes or a conversation changes in a way that can
  move a queue — not for each block of a streaming reply (`Forge.Events.notify_chat/2`). Every
  open page on the node hears every one, so the handler matches the project against the viewer's
  own **before it reads anything** (`CLAUDE.md` § Rules), and then recounts at most once a
  second: the first change is counted at once, and any more within the second are one recount at
  its end. The set
  of the viewer's projects, and a node admin's waiting accounts — which no ticket event announces
  — are read again on the minute tick that redraws the usage lines.

  **The title menu's figures are read when it opens**, not on mount: they cost a read only for the
  person who asked to see them (`docs/design/ui.md` § The title menu).

  Its events are `frame:*`, handled here for every page by a hook; they change nothing on the
  server but which panel this page draws.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias Forge.{Conversations, Events, Projects, Queue, Workers}
  alias ForgeWeb.Capacity

  @refresh :timer.minutes(1)
  @recount :timer.seconds(1)

  def on_mount(:signed_in, _params, _session, socket) do
    if connected?(socket) do
      Events.subscribe_queue()
      Process.send_after(self(), :capacity_tick, @refresh)
    end

    user = socket.assigns.current_scope.user

    {:cont,
     socket
     |> Capacity.own()
     |> assign(:frame, %{
       count: Queue.count(user),
       projects: projects(user),
       open: nil,
       menu: nil,
       throttled: false,
       dirty: false,
       follow: nil
     })
     |> attach_hook(:frame, :handle_info, &info/2)
     |> attach_hook(:frame, :handle_event, &event/3)}
  end

  defp projects(user), do: user |> Projects.list() |> MapSet.new(& &1.id)

  # Before any read: a change in a project the viewer is not in is dropped here, on the message
  # alone. The membership set is the one the tick last read.
  defp info({:queue_changed, project_id}, socket) do
    if MapSet.member?(socket.assigns.frame.projects, project_id),
      do: {:halt, changed(socket)},
      else: {:halt, socket}
  end

  defp info(:frame_recount, socket) do
    frame = socket.assigns.frame

    if frame.dirty do
      Process.send_after(self(), :frame_recount, @recount)
      {:halt, socket |> put(dirty: false) |> recount()}
    else
      {:halt, put(socket, throttled: false)}
    end
  end

  defp info(:capacity_tick, socket) do
    Process.send_after(self(), :capacity_tick, @refresh)
    user = socket.assigns.current_scope.user

    {:halt,
     socket
     |> Capacity.redraw()
     |> put(projects: projects(user))
     |> recount()}
  end

  defp info(_message, socket), do: {:cont, socket}

  # Leading edge: the first change in a second is counted at once, the rest of that second are one
  # recount at its end.
  defp changed(%{assigns: %{frame: %{throttled: true}}} = socket), do: put(socket, dirty: true)

  defp changed(socket) do
    Process.send_after(self(), :frame_recount, @recount)
    socket |> put(throttled: true) |> recount()
  end

  @doc """
  Has `reload` run over the page's socket each time the frame recounts the queue — on a change in
  one of the viewer's projects, and on the minute tick that reads a node admin's waiting accounts
  again — so that a page drawing the queue's count itself reads it again on the same signals as
  the queue button, and the two never disagree (`docs/design/ui.md` § What the queue counts). The
  frame's hook halts those messages, so the page would not otherwise hear them.

  **The button's count is then the page's** — `count` over the reloaded socket — rather than a
  second read of the queue: the page has just read it to draw it.
  """
  @spec follow(
          Phoenix.LiveView.Socket.t(),
          (Phoenix.LiveView.Socket.t() -> Phoenix.LiveView.Socket.t()),
          (Phoenix.LiveView.Socket.t() -> non_neg_integer())
        ) :: Phoenix.LiveView.Socket.t()
  def follow(socket, reload, count) when is_function(reload, 1) and is_function(count, 1),
    do: put(socket, follow: {reload, count})

  defp recount(%{assigns: %{frame: %{follow: nil}}} = socket),
    do: put(socket, count: count(socket))

  defp recount(%{assigns: %{frame: %{follow: {reload, count}}}} = socket) do
    socket = reload.(socket)
    put(socket, count: count.(socket))
  end

  defp count(socket), do: Queue.count(socket.assigns.current_scope.user)

  defp event("frame:" <> _ = event, params, socket), do: {:halt, dispatch(event, params, socket)}
  defp event(_event, _params, socket), do: {:cont, socket}

  # The menu's figures are read here and only here, when somebody asked to see them.
  defp dispatch("frame:menu", _params, socket) do
    if socket.assigns.frame.open == :menu,
      do: put(socket, open: nil, menu: nil),
      else: put(socket, open: :menu, menu: menu(socket.assigns.current_scope.user))
  end

  defp dispatch("frame:details", _params, socket), do: toggle(socket, :details)
  defp dispatch("frame:usage", _params, socket), do: toggle(socket, :usage)
  defp dispatch("frame:close", _params, socket), do: put(socket, open: nil, menu: nil)

  defp dispatch(_unknown, _params, socket), do: socket

  defp toggle(socket, panel) do
    open = if socket.assigns.frame.open == panel, do: nil, else: panel
    put(socket, open: open, menu: nil)
  end

  defp put(socket, changes),
    do: assign(socket, :frame, Map.merge(socket.assigns.frame, Map.new(changes)))

  # Each destination's state, scoped as the page it leads to is: the viewer's projects, the
  # viewer's conversations, the viewer's machines.
  defp menu(user) do
    projects = Projects.list(user)

    waiting =
      user
      |> Queue.items()
      |> Enum.filter(&Queue.waiting?/1)
      |> Enum.uniq_by(& &1.project.id)
      |> length()

    # A destroyed machine is neither, and counted by neither.
    machines = Workers.list(user)

    %{
      projects: length(projects),
      waiting: waiting,
      chats: Conversations.counts(user),
      busy: Enum.count(machines, &(&1.status == :busy)),
      idle: Enum.count(machines, &(&1.status in [:ready, :idle])),
      accounts: if(user.node_admin, do: Queue.waiting_accounts(user))
    }
  end
end
