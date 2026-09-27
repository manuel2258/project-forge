defmodule ForgeWeb.Operator.Actions do
  @moduledoc """
  The LiveView events behind the operator cards, shared by every page that shows them.
  Each calls `Forge.Operator` as the logged-in user and reports the result as a flash.
  """

  import Phoenix.LiveView, only: [put_flash: 3]

  require Logger

  alias Forge.{Artifacts, Operator, Tickets}

  @doc "Handles an operator event; returns `{:handled, socket}` or `:unknown`."
  def handle(event, params, socket) do
    case act(event, params, socket) do
      :unknown -> :unknown
      {:ok, message} -> {:handled, put_flash(socket, :info, message)}
      {:error, reason} -> {:handled, put_flash(socket, :error, "Failed: #{describe(reason)}")}
    end
  rescue
    Ecto.NoResultsError -> {:handled, put_flash(socket, :error, "That ticket no longer exists.")}
  end

  defp act("answer", %{"ticket" => id, "key" => key, "choice" => choice}, socket) do
    with {:ok, _} <- Operator.answer(ticket(id), user(socket), key, %{choice: choice}) do
      {:ok, "Answered #{key}: #{choice}"}
    end
  end

  # The fast path answers every open blocking question on one artifact version with its own
  # recommendation. The choices are read from the questions here rather than sent by the client,
  # so a stale page cannot answer something other than what it showed.
  defp act("answer_all", %{"ticket" => id, "version" => version_id}, socket) do
    ticket = ticket(id)

    questions =
      ticket.id
      |> Artifacts.open_questions()
      |> Enum.filter(&(&1.artifact_version_id == version_id and &1.blocking and &1.default))

    result =
      Enum.reduce_while(questions, {:ok, 0}, fn question, {:ok, count} ->
        case Operator.answer(ticket, user(socket), question.key, %{choice: question.default}) do
          {:ok, _} -> {:cont, {:ok, count + 1}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with {:ok, count} <- result do
      {:ok, "Accepted #{count} #{if count == 1, do: "recommendation", else: "recommendations"}"}
    end
  end

  defp act("answer_text", %{"ticket" => id, "key" => key, "text" => text}, socket) do
    with {:ok, _} <- Operator.answer(ticket(id), user(socket), key, %{text: text}) do
      {:ok, "Answered #{key}"}
    end
  end

  defp act("decide", %{"ticket" => id, "decision" => decision} = params, socket) do
    decision = if decision == "rejected", do: :rejected, else: :approved
    comment = blank_to_nil(params["comment"])

    with {:ok, ticket} <- Operator.decide(ticket(id), user(socket), decision, comment) do
      {:ok, "#{decision}; now in #{ticket.state}"}
    end
  end

  defp act("transition", %{"ticket" => id, "to" => to}, socket) do
    with {:ok, ticket} <- Operator.transition(ticket(id), user(socket), to) do
      {:ok, "Moved to #{ticket.state}"}
    end
  end

  # A document a human state declares, written from the ticket's Decide tab. The same write the
  # API's `POST …/artifacts/:name` makes (`docs/design/workflow-grammar-v1.md` § Semantics).
  defp act("write_document", %{"ticket" => id, "name" => name, "content" => content}, socket) do
    with {:ok, ticket} <- Operator.edit(ticket(id), user(socket), name, content) do
      {:ok, "Saved #{name}; #{ticket.state} is where it waits"}
    end
  end

  defp act(_event, _params, _socket), do: :unknown

  defp ticket(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Tickets.get!(id)
      :error -> raise Ecto.NoResultsError, queryable: Forge.Tickets.Ticket
    end
  end

  defp user(socket), do: socket.assigns.current_scope.user
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp describe({:job_live, state}), do: "a job for #{state} is still live"
  defp describe({:no_open_question, key}), do: "no open question #{key}"
  defp describe({:invalid_document, errors}), do: ForgeCore.Error.format(errors)
  defp describe(:nothing_pending), do: "nothing awaits approval"
  defp describe(:no_such_transition), do: "no such transition"

  defp describe({:ambiguous, outcomes}),
    do: "ambiguous; pick an outcome: #{Enum.join(outcomes, ", ")}"

  defp describe(other) do
    Logger.error("operator action failed: #{inspect(other)}")
    "something went wrong; see the server log"
  end
end
