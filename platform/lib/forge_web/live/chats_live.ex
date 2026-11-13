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
  — every other one is already about a project (`docs/design/ui.md` § Creating things): the dock's
  composer, with a picker of the viewer's projects beside it (`12c`). Ending
  one is offered because a live row is a machine running, and until it was here the only way to
  stop one was to open it first. Neither deletes a conversation, which is kept for ever
  (`docs/design/conversations.md` § Lifetime) — but ending one deletes its branch unless the
  branch would not merge cleanly, and the confirm says so in the page's own words.
  """

  use ForgeWeb, :live_view

  alias Forge.{Conversations, Events, Jobs, Operator, Projects}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Events.subscribe()
      Events.subscribe_chats()
    end

    {:ok,
     socket
     |> assign(page_title: "Chats", start: %{"project" => nil, "text" => ""}, start_error: nil)
     |> load()}
  end

  defp load(socket) do
    user = socket.assigns.current_scope.user
    projects = Projects.list(user)

    assign(socket,
      summaries: Conversations.summaries(for: user),
      projects: projects,
      # The projects the list was read for. `summaries(for:)` scopes with the same call, so what a
      # message is filtered by and what is then read are one model of "the viewer's projects".
      project_ids: MapSet.new(projects, & &1.id),
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

  # The dock's composer, as it is typed: held by the page so that a reconnect gives it back
  # (`docs/design/ui.md` § A reconnect is not a reload).
  @impl true
  def handle_event("start:change", params, socket) do
    {:noreply, assign(socket, start: start_params(params), start_error: nil)}
  end

  # Starting a chat in place (`12c`). The project's name comes off the wire, so it is looked up
  # among the viewer's own projects and nowhere else: a name of a project they are not in finds
  # nothing and is refused here, as one that does not exist is — and `Operator.open_chat/4`
  # checks membership again behind it.
  def handle_event("chat:start", params, socket) do
    start = start_params(params)
    text = String.trim(start["text"])
    project = Enum.find(socket.assigns.projects, &(&1.name == start["project"]))

    cond do
      is_nil(project) ->
        {:noreply, assign(socket, start: start, start_error: "Choose one of your projects.")}

      text == "" ->
        {:noreply, assign(socket, start: start, start_error: "Say what the chat is about first.")}

      true ->
        case Operator.open_chat(project, socket.assigns.current_scope.user, text) do
          {:ok, chat} ->
            {:noreply, push_navigate(socket, to: ~p"/chats/#{chat.id}")}

          # Only a refusal of membership reaches here, which the lookup above has already made:
          # an equivalent mutant today, said in a sentence rather than as `inspect/1` all the same.
          {:error, _reason} ->
            {:noreply,
             assign(socket, start: start, start_error: "The chat could not be started there.")}
        end
    end
  end

  # The id comes off the wire, so the chat is read and then authorised — being able to see a
  # conversation in your own list is not the same as the row this id names being in it
  # (`docs/design/identity.md` § Sequencing).
  def handle_event("end-chat", %{"id" => id}, socket) do
    with %Jobs.Job{kind: :chat} = chat <- Jobs.get(id),
         :ok <- Operator.close_chat(chat, socket.assigns.current_scope.user) do
      {:noreply, load(socket)}
    else
      _other -> {:noreply, socket}
    end
  end

  # Only text, whatever the wire sent.
  defp start_params(params) do
    %{
      "project" => if(is_binary(params["project"]), do: params["project"]),
      "text" => if(is_binary(params["text"]), do: params["text"], else: "")
    }
  end

  defp subline(summaries) do
    live = Enum.count(summaries, & &1.live)
    "#{live} live · #{length(summaries)} in all"
  end

  # The project the picker shows: what was picked, else the project of the conversation used
  # last, else the first — the one a person most likely means.
  defp picked(%{"project" => name}, _summaries, _projects) when is_binary(name), do: name
  defp picked(_start, [summary | _], _projects), do: summary.project.name
  defp picked(_start, [], [project | _]), do: project.name
  defp picked(_start, [], []), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      frame={@frame}
      capacity={@capacity}
      title="Chats"
      subline={subline(@summaries)}
      top_level={:chats}
      context={{"+ New", ~p"/chats/new"}}
      measure="40rem"
    >
      <ForgeWeb.Conversations.list
        summaries={@summaries}
        now={@now}
        ending="end-chat"
        empty="No conversations yet."
      />

      <:composer :if={@projects != []}>
        <.form
          for={%{}}
          id="chat-start"
          phx-change="start:change"
          phx-submit="chat:start"
          class="chat-start"
        >
          <.error_note :if={@start_error} id="chat-start-error" class="chat-start-error">
            {@start_error}
          </.error_note>
          <div class="chat-start-row">
            <label class="chat-start-project">
              <span class="sr-only">Project</span>
              <select id="chat-start-project" name="project">
                <option
                  :for={project <- @projects}
                  value={project.name}
                  selected={project.name == picked(@start, @summaries, @projects)}
                >
                  {project.name}
                </option>
              </select>
            </label>
            <.composer
              id="chat-start-text"
              name="text"
              value={@start["text"]}
              placeholder="Start a chat"
              phx-debounce="200"
            />
          </div>
        </.form>
      </:composer>
    </Layouts.app>
    """
  end
end
