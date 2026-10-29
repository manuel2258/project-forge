defmodule ForgeWeb.ChatsLive do
  @moduledoc """
  Every conversation in the projects you are in: the live ones in a section above, then the rest,
  each ordered by when it was last used, newest first.

  This is for finding one again — the one about the parser last week, the one still running that
  you closed the tab on. It is not a queue: a conversation that needs you is already in the
  queue, with its questions as a form to answer, and does not wait for you to come looking
  (`docs/design/ui.md` § Space, measure and targets).

  Conversations are kept for ever, so this list only grows. The live section is what keeps it
  useful: those are the ones costing something and holding a machine. The order and the sections
  are `ForgeWeb.Conversations`' and one rule for every list of conversations
  (`docs/design/ui.md` § Chats is a destination on both).

  **The list follows what is said.** It is woken by `{:chat_changed, ...}` for a project its
  viewer is in and by a change to a ticket of one, and by nothing else: a message in somebody
  else's project costs this page nothing.

  **The two controls here follow from that.** Starting one is offered because this is where a
  person comes looking for conversations, and it is the only surface that must ask which project
  — every other one is already about a project (`docs/design/ui.md` § Creating things). Ending
  one is offered because a live row is a machine running, and until it was here the only way to
  stop one was to open it first. Neither deletes a conversation, which is kept for ever
  (`docs/design/conversations.md` § Lifetime) — but ending one deletes its branch unless the
  branch would not merge cleanly, and the confirm says so in the page's own words.
  """

  use ForgeWeb, :live_view

  alias Forge.{Conversations, Events, Jobs, Operator}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Events.subscribe()
      Events.subscribe_chats()
    end

    {:ok, socket |> assign(page_title: "Chats") |> load()}
  end

  defp load(socket) do
    user = socket.assigns.current_scope.user

    assign(socket,
      summaries: Conversations.summaries(for: user),
      # The projects the list was read for. `summaries(for:)` scopes with the same call, so what a
      # message is filtered by and what is then read are one model of "the viewer's projects".
      project_ids: MapSet.new(Forge.Projects.list(user), & &1.id),
      now: DateTime.utc_now()
    )
  end

  # A chat said something, started, ended or moved: reload only for a project of the viewer's,
  # decided from the message before anything is read.
  @impl true
  def handle_info({:chat_changed, _id, project_id, _ticket_id}, socket) do
    if MapSet.member?(socket.assigns.project_ids, project_id),
      do: {:noreply, load(socket)},
      else: {:noreply, socket}
  end

  # A project chat's changes are also broadcast with no ticket, alongside the `chat_changed` that
  # redraws this page, so there is nothing here for it.
  def handle_info({:ticket_changed, nil}, socket), do: {:noreply, socket}

  # What draws a workflow step's chat the moment its ticket enters the step: the engine tells the
  # ticket's pages and not the chats. Read the ticket's project, one indexed read, and reload only
  # for one the viewer is in.
  def handle_info({:ticket_changed, id}, socket) do
    case Forge.Repo.get(Forge.Tickets.Ticket, id) do
      %{project_id: project_id} ->
        if MapSet.member?(socket.assigns.project_ids, project_id),
          do: {:noreply, load(socket)},
          else: {:noreply, socket}

      nil ->
        {:noreply, socket}
    end
  end

  # The id comes off the wire, so the chat is read and then authorised — being able to see a
  # conversation in your own list is not the same as the row this id names being in it
  # (`docs/design/identity.md` § Sequencing).
  @impl true
  def handle_event("end-chat", %{"id" => id}, socket) do
    with %Jobs.Job{kind: :chat} = chat <- Jobs.get(id),
         :ok <- Operator.close_chat(chat, socket.assigns.current_scope.user) do
      {:noreply, load(socket)}
    else
      _other -> {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      capacity={@capacity}
      active={:chats}
      measure="34rem"
    >
      <header class="flex flex-wrap items-baseline gap-x-4 gap-y-2">
        <h1 class="text-2xl font-semibold -tracking-[.025em]">Chats</h1>
        <.link
          navigate={~p"/chats/new"}
          class="ml-auto flex min-h-[46px] items-center rounded-field border border-base-300 px-3 text-sm hover:border-base-content/30"
        >
          New chat
        </.link>
      </header>

      <p class="mt-2 text-sm/[1.55] opacity-60">
        A conversation that needs you is in the queue. This is for finding one again.
      </p>

      <ForgeWeb.Conversations.list
        summaries={@summaries}
        now={@now}
        ending="end-chat"
        empty="No conversations yet."
      />
    </Layouts.app>
    """
  end
end
