defmodule ForgeWeb.Operator.Actions do
  @moduledoc """
  The LiveView events behind the operator cards, shared by every page that shows them.
  Each calls `Forge.Operator` as the logged-in user and reports the result as a flash.
  """

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Forge.{Operator, Tickets}

  @doc "Handles an operator event; returns `{:handled, socket}` or `:unknown`."
  def handle(event, params, socket) do
    case act(event, params, socket) do
      :unknown -> :unknown
      {:ok, message} -> {:handled, put_flash(socket, :info, message)}
      {:error, reason} -> {:handled, put_flash(socket, :error, "Failed: #{describe(reason)}")}
    end
  end

  defp act("answer", %{"ticket" => id, "key" => key, "choice" => choice}, socket) do
    with {:ok, _} <- Operator.answer(ticket(id), user(socket), key, %{choice: choice}) do
      {:ok, "Answered #{key}: #{choice}"}
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

  defp act(_event, _params, _socket), do: :unknown

  defp ticket(id), do: Tickets.get!(id)
  defp user(socket), do: socket.assigns.current_scope.user
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp describe({:job_live, state}), do: "a job for #{state} is still live"
  defp describe({:no_open_question, key}), do: "no open question #{key}"
  defp describe({:invalid_document, errors}), do: ForgeCore.Error.format(errors)
  defp describe(:nothing_pending), do: "nothing awaits approval"
  defp describe(:no_such_transition), do: "no such transition"
  defp describe(other), do: inspect(other)
end
