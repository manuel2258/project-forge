defmodule ForgeWeb.Operator.StepAccept do
  @moduledoc """
  The events behind the Accept area of a chat step, shared by the conversation's page and the
  ticket's Decide tab so the two cannot differ (`docs/design/ui.md` § The Accept area).

  What the person has picked and whether the confirm is open are held by the page, and the form
  that draws them carries both as fields with a `phx-change`, so a rejoin gives them back
  (`docs/design/ui.md` § A reconnect is not a reload). **What Accept is told it was shown is what
  the form's hidden fields carry** — the version of each document at the time of the draw — and
  not what the page holds now, which may be newer: that is how Accept never approves a version
  nobody saw.
  """

  alias Forge.{Operator, Steps}
  alias Phoenix.Component

  @doc "The assigns a page starts with: nothing picked, no confirm open, nothing refused."
  @spec init(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def init(socket),
    do: Component.assign(socket, step_pick: nil, step_confirming: false, step_error: nil)

  @doc """
  Handles `step:pick`, `step:review`, `step:cancel` and `step:accept`. Returns `{:noreply,
  socket}` for the caller to return; `reload` is called after Accept and after every refusal of
  it, so the page draws what is true now — a newer version, a ticket that has moved.
  """
  @spec handle_event(
          String.t(),
          map(),
          Phoenix.LiveView.Socket.t(),
          (Phoenix.LiveView.Socket.t() ->
             Phoenix.LiveView.Socket.t())
        ) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("step:pick", params, socket, _reload) do
    {:noreply,
     Component.assign(socket,
       step_pick: blank_to_nil(params["outcome"]),
       step_confirming: params["confirming"] == "true"
     )}
  end

  def handle_event("step:review", _params, socket, _reload),
    do: {:noreply, Component.assign(socket, step_confirming: true)}

  def handle_event("step:cancel", _params, socket, _reload),
    do: {:noreply, Component.assign(socket, step_confirming: false)}

  # No step on the page: the ticket left it before this press arrived, or the page is a plain
  # conversation's and the event was sent by hand. The page redraws; nothing is accepted.
  def handle_event("step:accept", _params, %{assigns: %{step: nil}} = socket, reload),
    do: {:noreply, socket |> Component.assign(step_confirming: false) |> reload.()}

  def handle_event("step:accept", params, socket, reload) do
    chat = socket.assigns.step.chat
    user = socket.assigns.current_scope.user
    outcome = blank_to_nil(params["outcome"]) || socket.assigns.step_pick

    case Operator.accept_step(chat, user, outcome, seen(params["seen"])) do
      {:ok, _ticket} ->
        {:noreply,
         socket
         |> Component.assign(step_pick: nil, step_confirming: false, step_error: nil)
         |> reload.()}

      {:error, reason} ->
        {:noreply,
         socket
         |> Component.assign(step_confirming: false, step_error: Steps.refusal(reason))
         |> reload.()}
    end
  end

  # `%{"refinement.md" => "3"}` off the wire; a document the page drew as not written sends "".
  defp seen(%{} = fields) do
    for {name, value} <- fields, {version, ""} <- [Integer.parse(to_string(value))], into: %{} do
      {name, version}
    end
  end

  defp seen(_none), do: %{}

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value
end
