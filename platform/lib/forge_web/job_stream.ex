defmodule ForgeWeb.JobStream do
  @moduledoc """
  A job's event log as a page holds it while the job runs: read once when the page loads, then
  kept current from the job's own topic (`Forge.Events.notify_job/2`) instead of read again for
  every event — which, for a conversation, was the log, the diff and the documents several times
  a sentence.

  Three pages hold one: a conversation's, a ticket's (its current job, on Activity) and a job's.
  What they share is here, so an event is added to each the same way.

  **An event is added by its place, not by when it arrived.** Events are numbered as they are
  written (`seq`), and two written in different transactions can be committed — and so announced
  — in the other order. A page that dropped everything numbered below the last it held dropped
  the one that came second. So an event already held is skipped, and any other is put where its
  number says, whichever order the two were heard in.
  """

  alias Forge.Events.Event

  @doc "How many entries a stream shows at first, and how many more each `more` adds."
  @spec page() :: pos_integer()
  def page, do: 50

  @doc """
  What a page holding a stream starts with: one page of it shown, and the harness's notices
  behind their count (`ForgeWeb.WorkScreen.activity/1` draws from both).
  """
  @spec init(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def init(socket), do: Phoenix.Component.assign(socket, shown: page(), notices: false)

  @doc """
  The stream's own events, which every page holding one answers the same way: `more` shows the
  next page, and `notices` shows or hides the harness's notices.

  Each page names both in `handle_event/3` clauses of its own that hand them here, rather than
  one clause guarded by a list kept in this module: an event a page takes is then in the page's
  source, where `ForgeWeb.AuthorizationInventoryTest` reads every action from.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("more", _params, socket),
    do: {:noreply, Phoenix.Component.update(socket, :shown, &(&1 + page()))}

  def handle_event("notices", _params, socket),
    do: {:noreply, Phoenix.Component.update(socket, :notices, &(not &1))}

  @doc """
  Adds an event heard on the job's topic to the log a page holds: `{:ok, events}`, in `seq`
  order, or `:seen` when the log has it already — read with the log, and broadcast as well.
  """
  @spec add([Event.t()], Event.t()) :: {:ok, [Event.t()]} | :seen
  def add(events, %Event{seq: seq} = event) do
    cond do
      Enum.any?(events, &(&1.seq == seq)) -> :seen
      events == [] or seq > List.last(events).seq -> {:ok, events ++ [event]}
      true -> {:ok, Enum.sort_by([event | events], & &1.seq)}
    end
  end

  @doc """
  Whether an event is the harness's stream — what the agent said and did, and what the harness
  reported — which a page adds to the log it holds. Anything else on a job's topic (a turn
  ending, a wait, a message sent) changes more than the stream, and the page reloads.
  """
  @spec streamed?(Event.t()) :: boolean()
  def streamed?(%Event{type: "job.harness." <> _rest}), do: true
  def streamed?(%Event{}), do: false

  @doc """
  Whether an event may have come with a change to the job's branch: a call's result, since the
  agent commits and pushes with a call. A page showing the branch looks again shortly after one
  (`catch_up/2`) rather than on every event.
  """
  @spec may_have_moved?(Event.t()) :: boolean()
  def may_have_moved?(%Event{type: "job.harness.tool_result"}), do: true
  def may_have_moved?(%Event{}), do: false

  # Long enough that a burst of results is one look at the branch; short enough that a commit
  # reads as having just happened.
  @catch_up_after 1_000

  @doc """
  Schedules one `:catch_up` message to the page after an event that may have moved the branch,
  unless one is already due. The page answers it by reading again what the branch holds.
  """
  @spec catch_up(Phoenix.LiveView.Socket.t(), Event.t()) :: Phoenix.LiveView.Socket.t()
  def catch_up(socket, event) do
    if may_have_moved?(event) and not Map.get(socket.assigns, :catching_up, false) do
      Process.send_after(self(), :catch_up, @catch_up_after)
      Phoenix.Component.assign(socket, :catching_up, true)
    else
      socket
    end
  end
end
