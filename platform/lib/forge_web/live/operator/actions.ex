defmodule ForgeWeb.Operator.Actions do
  @moduledoc """
  The LiveView events behind the operator cards, shared by every page that shows them.
  Each calls `Forge.Operator` as the logged-in user. Done, it says so in a toast (the `:info`
  flash); refused, it leaves `:refusal` — the event refused and the words — for the page to draw
  where that event was sent from (`refused/1`, `docs/design/ui.md` § Errors stay where you acted).
  A page that hands events here assigns `refusal: nil` on mount.
  """

  use Phoenix.Component

  import Phoenix.LiveView, only: [put_flash: 3]
  import ForgeWeb.UI.Feedback, only: [error_note: 1]

  require Logger
  require ForgeWeb.Operator.Admission

  alias Forge.{Operator, Tickets}
  alias ForgeWeb.Operator.Admission
  alias ForgeWeb.Operator.Drafts
  alias ForgeWeb.Operator.QuestionForm

  @doc """
  Handles an operator event: `{:handled, socket}` after something was committed, so the page
  reloads; `{:state, socket}` for a change to a question form's draft
  (`ForgeWeb.Operator.QuestionForm`) or a card's (`ForgeWeb.Operator.Drafts`), which needs no
  reload; `:unknown` for anything else.
  """
  # Every event clears the last refusal first: a refusal stays only until the next thing done.
  def handle(event, params, socket) do
    socket = assign(socket, :refusal, nil)

    with :unknown <- QuestionForm.handle(event, params, socket),
         :unknown <- Drafts.handle(event, params, socket) do
      act_on(event, params, socket)
    end
  rescue
    Ecto.NoResultsError -> {:handled, refuse(socket, event, "That ticket no longer exists.")}
  end

  @doc """
  Leaves a refusal of `event` for the page to draw where it was sent from — an event's name, or
  `{:form, id}` for a question card's Send: never a toast, and it stays until the next event
  handled here replaces it.
  """
  @spec refuse(Phoenix.LiveView.Socket.t(), term(), String.t()) :: Phoenix.LiveView.Socket.t()
  def refuse(socket, event, text), do: assign(socket, :refusal, %{at: event, text: text})

  @doc """
  The refusal of one of the events `at`, drawn where they are sent from — the details, a notice,
  the dock — and nothing when the last refusal was another's.
  """
  attr :id, :string, required: true
  attr :refusal, :map, default: nil, doc: "the page's `:refusal` assign"

  attr :at, :list,
    required: true,
    doc: "the events whose refusal belongs here; `:questions` is any question card's Send"

  def refused(assigns) do
    ~H"""
    <.error_note :if={here?(@refusal, @at)} id={@id}>{@refusal.text}</.error_note>
    """
  end

  defp here?(nil, _at), do: false
  defp here?(%{at: {:form, _id} = form}, at), do: form in at or :questions in at
  defp here?(%{at: event}, at), do: event in at

  # A submit that committed forgets the draft its own form named, so the comment on an approval
  # does not come back on the next one and a saved document is drawn from the version just
  # written (`ForgeWeb.Operator.Drafts`). Only on success: a refusal leaves what was typed.
  defp act_on(event, params, socket) do
    case act(event, params, socket) do
      :unknown ->
        :unknown

      {:ok, message} ->
        {:handled, socket |> Drafts.forget(params["draft"]) |> put_flash(:info, message)}

      {:error, reason} ->
        {:handled,
         socket |> keep_typed(params, reason) |> refuse(event, "Failed: #{describe(reason)}")}
    end
  end

  # A refusal leaves what was typed, and a stale document's base moves to the version that
  # overtook it — so the Save that was refused once goes through when it is made again. Without
  # that the base stayed the overtaken version and every later Save was refused in the same
  # words: the text safe in the box, and no gesture that would send it. The refusal is the
  # warning; repeating the gesture is the decision to write over what arrived
  # (`docs/design/ui.md` § A reconnect is not a reload).
  defp keep_typed(socket, params, {:stale_document, _name, version}),
    do: Drafts.put(socket, params["draft"], "base", to_string(version))

  defp keep_typed(socket, _params, _reason), do: socket

  defp act("transition", %{"ticket" => id, "to" => to}, socket) do
    with {:ok, ticket} <- Operator.transition(ticket(id), user(socket), to) do
      {:ok, "Moved to #{ticket.state}"}
    end
  end

  defp act("cancel-ticket", %{"ticket" => id}, socket) do
    with {:ok, _ticket} <- Operator.cancel(ticket(id), user(socket)) do
      {:ok, "Ticket cancelled"}
    end
  end

  defp act("restore-ticket", %{"ticket" => id}, socket) do
    with {:ok, ticket} <- Operator.restore(ticket(id), user(socket)) do
      {:ok, "Restored; stuck in #{ticket.state}"}
    end
  end

  defp act("retry", %{"ticket" => id}, socket) do
    with {:ok, ticket} <- Operator.retry(ticket(id), user(socket)) do
      {:ok, "Running #{ticket.state} again"}
    end
  end

  defp act("repin", %{"ticket" => id}, socket) do
    with {:ok, ticket} <- Operator.repin(ticket(id), user(socket)) do
      {:ok, "Re-pinned at #{String.slice(ticket.workflow_commit, 0, 12)}"}
    end
  end

  # The conflict notice's button: a ticket a merge put in conflict, sent down its merging state's
  # `on_conflict` before anybody approves it (`docs/design/ui.md` § Decide and Timeline).
  defp act("integrate", %{"ticket" => id}, socket) do
    with {:ok, ticket} <- Operator.integrate(ticket(id), user(socket)) do
      {:ok, "Sent to #{ticket.state}"}
    end
  end

  # Taking a ticket out of the merge queue: an unapproval (`docs/design/ui.md` § Decide and
  # Timeline). A ticket that merged or was taken out by someone else meanwhile is refused in words.
  defp act("take-out", %{"ticket" => id}, socket) do
    with {:ok, _ticket} <- Operator.take_out(ticket(id), user(socket)) do
      {:ok, "Taken out of the merge queue; it has to be approved again"}
    end
  end

  # A document a human state declares, written from the ticket's Decide tab. The same write the
  # API's `POST …/artifacts/:name` makes (`docs/design/workflow-grammar-v1.md` § Semantics).
  # `base` is the version the draft in the box was typed against, which the form carries in a
  # hidden field and the draft therefore holds from the moment anything is typed. Without it a
  # draft typed against v3 would land as v5 over somebody else's v4, silently
  # (`docs/design/ui.md` § A reconnect is not a reload).
  defp act("write_document", %{"ticket" => id, "name" => name, "content" => content} = p, socket) do
    with {:ok, ticket} <- Operator.edit(ticket(id), user(socket), name, content, p["base"]) do
      {:ok, "Saved #{name}; #{ticket.state} is where it waits"}
    end
  end

  defp act(_event, _params, _socket), do: :unknown

  defp ticket(id), do: row!(id, &Tickets.get!/1, Forge.Tickets.Ticket)

  @doc """
  The row an id off the wire names, through `get`. One that is not a UUID names nothing and is
  raised as `Ecto.NoResultsError`, which the handlers report as gone — rather than as the cast
  error a page would crash on. Shared with `ForgeWeb.Operator.QuestionForm`, whose ids arrive
  the same way.
  """
  def row!(id, get, schema) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> get.(id)
      :error -> raise Ecto.NoResultsError, queryable: schema
    end
  end

  @doc "The person acting, as every operator event is attributed."
  def user(socket), do: socket.assigns.current_scope.user

  @doc """
  A refusal from `Forge.Operator`, in the words a person acts on. Shared with
  `ForgeWeb.Operator.Decision`, which draws it inside the decision's panel.
  """
  @spec describe(term()) :: String.t()
  def describe({:job_live, state}), do: "a job for #{state} is still live"
  def describe({:step_live, state}), do: "#{state} is a conversation; Accept it to move on"
  def describe({:invalid_document, errors}), do: ForgeCore.Error.format(errors)
  def describe(:nothing_pending), do: "nothing awaits approval"

  def describe(:note_required),
    do: "a reject needs a note saying what should change; the next job reads it"

  def describe({:stale_document, name, version}),
    do:
      "#{name} is at v#{version} now, written since this page was drawn; nothing was saved. " <>
        "What you typed is still in the box — save again to write it over v#{version}"

  def describe(:no_such_transition), do: "no such transition"
  def describe({:no_version, name}), do: "#{name} has no version to approve"
  def describe({:no_job_in, state}), do: "no job runs in #{state}"
  def describe({:not_retryable, status}), do: "a #{status} ticket cannot be run again"
  def describe({:not_cancellable, status}), do: "a #{status} ticket cannot be cancelled"
  def describe({:release_open, _ticket} = reason), do: Admission.explain(reason)
  def describe({:not_cancelled, _status}), do: "only a cancelled ticket can be restored"
  def describe({:not_active, :cancelled}), do: "the ticket is cancelled; restore it first"
  def describe({:not_repinnable, status}), do: "a #{status} ticket cannot be re-pinned"
  def describe(:already_pinned), do: "the ticket is already pinned at the default branch's head"
  def describe(:pending_approval), do: "decide the pending approval first"
  def describe(:queued), do: "the ticket is in the merge queue; take it out first"
  def describe(:merging), do: "it is being merged right now, which cannot be taken back"

  def describe({:not_queued, {:merged, _}}),
    do: "it has already merged, so there is nothing to take out"

  def describe({:not_queued, {:taken_out, _}}),
    do: "someone has already taken it out of the merge queue"

  def describe({:not_queued, {:left, reason}}),
    do: "it is no longer in the merge queue (#{reason})"

  def describe({:not_queued, nil}), do: "it is not in the merge queue"
  def describe(:merges_cleanly), do: "it merges cleanly now, so there is nothing to integrate"

  def describe({:merge_conflict, paths}),
    do: "it conflicts with the default branch in #{Enum.join(paths, ", ")}"

  # Its sibling, which fell to the catch-all and so told a person to read the server log for a
  # refusal that has a reason to hand.
  def describe({:merge_impossible, reason}) when is_binary(reason),
    do: "the merge could not be attempted: #{reason}"

  def describe({:merge_impossible, reason}),
    do: "the merge could not be attempted: #{inspect(reason)}"

  def describe({:no_state, state}),
    do: "the default branch's workflow has no state #{state}; move the ticket first"

  def describe({:ticket_type_gone, _name, path}),
    do: "#{path} is not on the default branch any more, so there is nothing to re-pin to"

  def describe(reason) when Admission.type_reason(reason), do: Admission.explain(reason)

  def describe(errors) when is_list(errors),
    do: "the default branch's workflow does not parse: " <> ForgeCore.Error.format(errors)

  def describe({:ambiguous, outcomes}),
    do: "ambiguous; pick an outcome: #{Enum.join(outcomes, ", ")}"

  def describe(other) do
    Logger.error("operator action failed: #{inspect(other)}")
    "something went wrong; see the server log"
  end
end
