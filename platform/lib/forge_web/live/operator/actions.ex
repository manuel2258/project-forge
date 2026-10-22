defmodule ForgeWeb.Operator.Actions do
  @moduledoc """
  The LiveView events behind the operator cards, shared by every page that shows them.
  Each calls `Forge.Operator` as the logged-in user and reports the result as a flash.
  """

  import Phoenix.LiveView, only: [put_flash: 3]

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
  def handle(event, params, socket) do
    with :unknown <- QuestionForm.handle(event, params, socket),
         :unknown <- Drafts.handle(event, params, socket) do
      act_on(event, params, socket)
    end
  rescue
    Ecto.NoResultsError -> {:handled, put_flash(socket, :error, "That ticket no longer exists.")}
  end

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
         socket |> refused(params, reason) |> put_flash(:error, "Failed: #{describe(reason)}")}
    end
  end

  # A refusal leaves what was typed, and a stale document's base moves to the version that
  # overtook it — so the Save that was refused once goes through when it is made again. Without
  # that the base stayed the overtaken version and every later Save was refused in the same
  # words: the text safe in the box, and no gesture that would send it. The refusal is the
  # warning; repeating the gesture is the decision to write over what arrived
  # (`docs/design/ui.md` § A reconnect is not a reload).
  defp refused(socket, params, {:stale_document, _name, version}),
    do: Drafts.put(socket, params["draft"], "base", to_string(version))

  defp refused(socket, _params, _reason), do: socket

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
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp describe({:job_live, state}), do: "a job for #{state} is still live"
  defp describe({:invalid_document, errors}), do: ForgeCore.Error.format(errors)
  defp describe(:nothing_pending), do: "nothing awaits approval"

  defp describe({:stale_document, name, version}),
    do:
      "#{name} is at v#{version} now, written since this page was drawn; nothing was saved. " <>
        "What you typed is still in the box — save again to write it over v#{version}"

  defp describe(:no_such_transition), do: "no such transition"
  defp describe({:no_version, name}), do: "#{name} has no version to approve"
  defp describe({:no_job_in, state}), do: "no job runs in #{state}"
  defp describe({:not_retryable, status}), do: "a #{status} ticket cannot be run again"
  defp describe({:not_cancellable, status}), do: "a #{status} ticket cannot be cancelled"
  defp describe({:not_cancelled, _status}), do: "only a cancelled ticket can be restored"
  defp describe({:not_active, :cancelled}), do: "the ticket is cancelled; restore it first"
  defp describe({:not_repinnable, status}), do: "a #{status} ticket cannot be re-pinned"
  defp describe(:already_pinned), do: "the ticket is already pinned at the default branch's head"
  defp describe(:pending_approval), do: "decide the pending approval first"
  defp describe(:merges_cleanly), do: "it merges cleanly now, so there is nothing to integrate"

  defp describe({:merge_conflict, paths}),
    do: "it conflicts with the default branch in #{Enum.join(paths, ", ")}"

  # Its sibling, which fell to the catch-all and so told a person to read the server log for a
  # refusal that has a reason to hand.
  defp describe({:merge_impossible, reason}) when is_binary(reason),
    do: "the merge could not be attempted: #{reason}"

  defp describe({:merge_impossible, reason}),
    do: "the merge could not be attempted: #{inspect(reason)}"

  defp describe({:no_state, state}),
    do: "the default branch's workflow has no state #{state}; move the ticket first"

  defp describe({:ticket_type_gone, _name, path}),
    do: "#{path} is not on the default branch any more, so there is nothing to re-pin to"

  defp describe(reason) when Admission.type_reason(reason), do: Admission.explain(reason)

  defp describe(errors) when is_list(errors),
    do: "the default branch's workflow does not parse: " <> ForgeCore.Error.format(errors)

  defp describe({:ambiguous, outcomes}),
    do: "ambiguous; pick an outcome: #{Enum.join(outcomes, ", ")}"

  defp describe(other) do
    Logger.error("operator action failed: #{inspect(other)}")
    "something went wrong; see the server log"
  end
end
