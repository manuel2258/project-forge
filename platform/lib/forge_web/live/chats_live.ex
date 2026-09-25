defmodule ForgeWeb.ChatsLive do
  @moduledoc """
  Every conversation in the projects you are in, live ones first.

  This is for finding one again — the one about the parser last week, the one still running that
  you closed the tab on. It is not a queue: a conversation that needs you is already in the
  queue, with its question and its answer rows, and does not wait for you to come looking
  (`docs/design/ui.md` § Space, measure and targets).

  Conversations are kept for ever, so this list only grows. Live first is what keeps it useful:
  that is the one costing something and holding a machine.

  **The two controls here follow from that.** Starting one is offered because this is where a
  person comes looking for conversations, and it is the only surface that must ask which project
  — every other one is already about a project (`docs/design/ui.md` § Creating things). Ending
  one is offered because a live row is a machine running, and until it was here the only way to
  stop one was to open it first. Neither deletes anything: a conversation is kept for ever
  (`docs/design/conversations.md` § Lifetime).
  """

  use ForgeWeb, :live_view

  alias Forge.{Conversations, Events, Jobs, Operator}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe()
    {:ok, socket |> assign(page_title: "Chats") |> load()}
  end

  defp load(socket) do
    summaries = Conversations.summaries(for: socket.assigns.current_scope.user)

    assign(socket,
      summaries: summaries,
      live: Enum.count(summaries, & &1.live),
      now: DateTime.utc_now()
    )
  end

  @impl true
  def handle_info({:ticket_changed, _id}, socket), do: {:noreply, load(socket)}

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
        <span :if={@live > 0} class="font-mono text-[12.5px] opacity-60">{@live} live</span>
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
