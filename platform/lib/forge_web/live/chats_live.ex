defmodule ForgeWeb.ChatsLive do
  @moduledoc """
  Every conversation in the projects you are in, live ones first.

  This is for finding one again — the one about the parser last week, the one still running that
  you closed the tab on. It is not a queue: a conversation that needs you is already in the
  queue, with its question and its answer rows, and does not wait for you to come looking
  (`docs/design/ui.md` § Space, measure and targets).

  Conversations are kept for ever, so this list only grows. Live first is what keeps it useful:
  that is the one costing something and holding a machine.
  """

  use ForgeWeb, :live_view

  alias Forge.{Conversations, Events}

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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:chats} measure="34rem">
      <header class="flex flex-wrap items-baseline justify-between gap-3">
        <h1 class="text-2xl font-semibold -tracking-[.025em]">Chats</h1>
        <span :if={@live > 0} class="font-mono text-[12.5px] opacity-60">{@live} live</span>
      </header>

      <p class="mt-2 text-sm/[1.55] opacity-60">
        A conversation that needs you is in the queue. This is for finding one again.
      </p>

      <ForgeWeb.Conversations.list
        summaries={@summaries}
        now={@now}
        empty="No conversations yet. Start one from a project or a ticket."
      />
    </Layouts.app>
    """
  end
end
