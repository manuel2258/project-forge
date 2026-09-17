defmodule ForgeWeb.ChatNewLive do
  @moduledoc """
  Starting a conversation, about a project or about one of its tickets.

  A pushed view with a back affordance, like the other two create views, and for the same reason
  (`docs/design/ui.md` § Creating things): it is reached from the thing it is about, so it says
  which that is rather than asking. There is no project select here at all — unlike a ticket,
  a conversation is never started from nowhere.

  **The form is one box, because a conversation has one field.** What you type is the first thing
  you say, and it is delivered as the first turn rather than stored as a title: a conversation
  has no title, and inventing one would be a second record of what the first message already is.
  """

  use ForgeWeb, :live_view

  alias Forge.{Operator, Tickets, Workers}

  @impl true
  def mount(%{"project" => name} = params, _session, socket) do
    {project, _scope} = ForgeWeb.Access.project_by_name!(socket.assigns.current_scope, name)
    ticket = ticket(project, params["ticket"])

    {:ok,
     socket
     |> assign(
       page_title: "New chat",
       project: project,
       ticket: ticket,
       error: nil,
       offered: Workers.offered(),
       # Empty means the project's, which is what the placeholder says. The model is fixed when
       # the harness process starts, so this is the only moment it can be chosen.
       form: to_form(%{"text" => "", "model" => ""}, as: :chat)
     )}
  end

  defp ticket(_project, nil), do: nil

  defp ticket(project, number) do
    case Integer.parse(number) do
      {n, ""} -> Tickets.get_by_number!(project, n)
      _other -> nil
    end
  end

  @impl true
  def handle_event("validate", %{"chat" => params}, socket),
    do: {:noreply, assign(socket, form: to_form(params, as: :chat), error: nil)}

  def handle_event("open", %{"chat" => params}, socket) do
    case String.trim(params["text"] || "") do
      "" ->
        {:noreply,
         assign(socket, form: to_form(params, as: :chat), error: "say something to start with")}

      text ->
        open(socket, text, params["model"])
    end
  end

  defp open(socket, text, model) do
    %{project: project, ticket: ticket} = socket.assigns

    case Operator.open_chat(project, socket.assigns.current_scope.user, text,
           ticket: ticket,
           model: model
         ) do
      {:ok, chat} ->
        {:noreply, push_navigate(socket, to: ~p"/chats/#{chat.id}")}

      {:error, reason} ->
        {:noreply, assign(socket, error: "could not start it: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- The queue's measure: the first message is prose, not a form field. --%>
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:board} measure="34rem">
      <.link
        navigate={back(@project, @ticket)}
        class="font-mono text-[12.5px] opacity-60 hover:opacity-100"
      >
        ‹ {where(@project, @ticket)}
      </.link>

      <h1 class="mt-4 text-2xl font-semibold -tracking-[.025em]">New chat</h1>

      <p class="mt-2 text-sm/[1.55] opacity-70">{about(@ticket)}</p>

      <.form
        for={@form}
        id="chat-form"
        phx-change="validate"
        phx-submit="open"
        class="mt-6 flex flex-col gap-4"
      >
        <ForgeWeb.Conversations.message_box
          id="chat_text"
          name="chat[text]"
          value={@form[:text].value}
          rows="5"
          label="First thing to say"
        />

        <%!-- Optional, and only here: the model is fixed when the harness process starts, so a
              conversation that wants a different one is one you close and open again. --%>
        <ForgeWeb.Operator.Components.model_field
          field={@form[:model]}
          offered={@offered}
          fallback={@project.model || "the platform's"}
        />

        <p :if={@error} class="text-sm text-error">{@error}</p>

        <button
          type="submit"
          class="min-h-[52px] rounded-field bg-base-content px-4 text-sm font-medium text-base-100"
        >
          Start it
        </button>
      </.form>

      <%!-- What it costs and what it holds, before it is started rather than after: a
            conversation takes a machine for as long as it is open. --%>
      <p class="mt-6 text-sm/[1.55] opacity-60">
        It waits for a free worker, and holds it until you end the conversation or it goes idle.
        Its work goes to a branch of its own, which you can merge from its page.
      </p>
    </Layouts.app>
    """
  end

  defp back(project, nil), do: ~p"/projects/#{project.name}"
  defp back(project, ticket), do: ~p"/tickets/#{project.name}/#{ticket.number}"

  defp where(project, nil), do: project.name
  defp where(project, ticket), do: "#{project.name}##{ticket.number} · #{ticket.title}"

  defp about(nil), do: "About the repository as a whole. It sees the default branch at its head."

  defp about(ticket),
    do:
      "About ##{ticket.number}. It starts from the ticket's branch as it stands, " <>
        "with the ticket's documents as context."
end
