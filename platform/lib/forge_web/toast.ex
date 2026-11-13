defmodule ForgeWeb.Toast do
  @moduledoc """
  The toast after an action that succeeded (`docs/design/ui.md` § Toasts): what happened and
  what it started, *Approved changeset v1* · *merging started*.

  It is the `:info` flash, so it survives a redirect like any flash; `Layouts.toasts/1` draws it,
  splitting title from detail on the first newline. **Only for a success**: a failure is never a
  toast (§ Errors stay where you acted), and the `:error` flash is not drawn as one.
  """

  alias Forge.{MergeQueue, Projects, Tickets}
  alias Forge.Tickets.Ticket
  alias ForgeCore.Workflow

  @doc """
  Put the toast on a conn or a socket: `title`, and an optional `detail` under it.
  """
  @spec put(Plug.Conn.t() | Phoenix.LiveView.Socket.t(), String.t(), String.t() | nil) ::
          Plug.Conn.t() | Phoenix.LiveView.Socket.t()
  def put(conn_or_socket, title, detail \\ nil)

  def put(%Plug.Conn{} = conn, title, detail),
    do: Phoenix.Controller.put_flash(conn, :info, message(title, detail))

  def put(%Phoenix.LiveView.Socket{} = socket, title, detail),
    do: Phoenix.LiveView.put_flash(socket, :info, message(title, detail))

  @doc """
  The second line for a ticket that has just moved: **what the move started** (`ui.md` § Toasts) —
  *implementing started* where the state runs a job or a command, *in the merge queue* where it
  waits its turn there, *merged into main* where entering the state merged it — and *moved to
  `<state>`* where nothing starts. Read after the move, so it says what the ticket did rather than
  what the transition named (UX pass, A31).
  """
  @spec started(Ticket.t()) :: String.t()
  def started(%Ticket{} = ticket) do
    state =
      case Tickets.parsed_workflow(ticket) do
        {:ok, workflow} -> Workflow.state(workflow, ticket.state)
        {:error, _errors} -> nil
      end

    cond do
      MergeQueue.queued?(ticket) ->
        "in the merge queue"

      runs?(state) ->
        "#{ticket.state} started"

      merged?(state, ticket) ->
        "merged into #{Projects.get!(ticket.project_id).default_branch}"

      true ->
        "moved to #{ticket.state}"
    end
  end

  defp runs?(%{prompt: prompt}) when is_binary(prompt), do: true
  defp runs?(%{invoke: [_ | _]}), do: true
  defp runs?(_state), do: false

  defp merged?(%{on_enter: actions}, %{status: :done}), do: :merge in actions
  defp merged?(_state, _ticket), do: false

  @doc """
  The title and the detail of a flash message: the detail is everything after the first
  newline, or nil.
  """
  @spec split(String.t()) :: {String.t(), String.t() | nil}
  def split(message) do
    case String.split(message, "\n", parts: 2) do
      [title, detail] -> {title, blank_to_nil(String.trim(detail))}
      [title] -> {title, nil}
    end
  end

  defp message(title, nil), do: title
  defp message(title, detail), do: title <> "\n" <> detail

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text
end
