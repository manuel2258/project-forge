defmodule ForgeWeb.Api.FallbackController do
  @moduledoc "Maps context errors to JSON error responses."

  use ForgeWeb, :controller

  alias ForgeWeb.Operator.Admission

  require Admission

  require Logger

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
    error(conn, :unprocessable_entity, "invalid", errors)
  end

  def call(conn, {:error, errors}) when is_list(errors) do
    error(conn, :unprocessable_entity, "invalid_workflow", ForgeCore.Error.format(errors))
  end

  def call(conn, {:error, :nothing_pending}),
    do: error(conn, :conflict, "nothing_pending", "no transition awaits approval")

  # The state of the ticket and so the client's to resolve, not a platform fault: decide the
  # pending transition and the next one becomes reachable (`workflow-grammar-v1.md` § Approval).
  def call(conn, {:error, :pending_approval}),
    do:
      error(
        conn,
        :conflict,
        "pending_approval",
        "a decision on another transition is pending; decide that one first"
      )

  # Likewise a ticket in the merge queue: a person takes it out, then the next one is reachable.
  def call(conn, {:error, :queued}),
    do:
      error(
        conn,
        :conflict,
        "queued",
        "the ticket is in the merge queue; take it out of the queue first"
      )

  def call(conn, {:error, :no_such_transition}),
    do: error(conn, :unprocessable_entity, "no_such_transition", nil)

  # Reaching git and not finding the ref is the client's next step, not a platform fault: the
  # repository may not be pushed yet, or `default_branch` may name a branch that is not there.
  def call(conn, {:error, {:unknown_ref, ref}}),
    do:
      error(
        conn,
        :unprocessable_entity,
        "unknown_ref",
        "#{ref} does not name a commit in the project's repository"
      )

  def call(conn, {:error, {:no_workflow_file, path}}),
    do: error(conn, :unprocessable_entity, "no_workflow_file", "#{path} is not in the repository")

  # Ticket types (`docs/design/ticket-types.md` § Admission): the code says which, the detail is
  # the sentence the ticket form says it in.
  def call(conn, {:error, reason}) when Admission.type_reason(reason),
    do:
      error(
        conn,
        :unprocessable_entity,
        Atom.to_string(elem(reason, 0)),
        Admission.explain(reason)
      )

  def call(conn, {:error, :document_requires_content}),
    do:
      error(
        conn,
        :unprocessable_entity,
        "document_requires_content",
        "a document artifact needs content, as a string"
      )

  def call(conn, {:error, {:kind_mismatch, name, kind}}),
    do:
      error(conn, :conflict, "kind_mismatch", "#{name} already exists on this ticket as #{kind}")

  def call(conn, {:error, {:job_live, state}}),
    do: error(conn, :conflict, "job_live", "a job for #{state} is pending, running or waiting")

  def call(conn, {:error, {:step_live, state}}),
    do:
      error(
        conn,
        :conflict,
        "step_live",
        "#{state} is a conversation with a person; it ends with Accept, not by a transition"
      )

  def call(conn, {:error, {:no_version, name}}),
    do: error(conn, :conflict, "no_version", "#{name} has no version to approve")

  def call(conn, {:error, {:no_job_in, state}}),
    do: error(conn, :conflict, "no_job_in_state", "no job runs in #{state}")

  def call(conn, {:error, {:not_retryable, status}}),
    do: error(conn, :conflict, "not_retryable", "a #{status} ticket cannot be run again")

  def call(conn, {:error, {:not_cancellable, status}}),
    do: error(conn, :conflict, "not_cancellable", "a #{status} ticket cannot be cancelled")

  def call(conn, {:error, {:release_open, ticket} = reason}),
    do: error(conn, :conflict, "release_open", Admission.explain(reason) <> " (#{ticket.title})")

  def call(conn, {:error, {:not_cancelled, _status}}),
    do: error(conn, :conflict, "not_cancelled", "only a cancelled ticket can be restored")

  def call(conn, {:error, {:not_active, :cancelled}}),
    do: error(conn, :conflict, "cancelled", "the ticket is cancelled; restore it first")

  def call(conn, {:error, {:no_open_question, key}}),
    do: error(conn, :not_found, "no_open_question", key)

  def call(conn, {:error, {:not_an_option, key, choice}}),
    do:
      error(
        conn,
        :unprocessable_entity,
        "not_an_option",
        "#{inspect(choice)} is not an option of #{key}"
      )

  def call(conn, {:error, {:invalid_answer, key}}),
    do: error(conn, :unprocessable_entity, "invalid_answer", "#{key}: choice and text are text")

  def call(conn, {:error, {:empty_answer, key}}),
    do: error(conn, :unprocessable_entity, "empty_answer", "#{key} needs a choice or text")

  def call(conn, {:error, {:invalid_document, errors}}),
    do: error(conn, :unprocessable_entity, "invalid_document", ForgeCore.Error.format(errors))

  def call(conn, {:error, {:ambiguous, outcomes}}),
    do:
      error(
        conn,
        :unprocessable_entity,
        "ambiguous_transition",
        "pass outcome: one of #{Enum.join(outcomes, ", ")}"
      )

  def call(conn, {:error, :already_decided}),
    do:
      error(
        conn,
        :conflict,
        "already_decided",
        "this version of the proposal has been accepted or declined"
      )

  # A proposal a person edited into something with no title. It is the client's mistake and
  # answerable, not a platform fault — `docs/open-questions.md` § Message reliability records
  # answering these with 500 as the shape of failure worth avoiding. Tagged rather than a bare
  # list of errors, which the clause above already answers as a workflow that does not parse.
  def call(conn, {:error, {:invalid_proposal, errors}}),
    do: error(conn, :unprocessable_entity, "invalid_proposal", ForgeCore.Error.format(errors))

  def call(conn, {:error, :not_found}), do: error(conn, :not_found, "not_found", nil)

  # A changeset is a commit, not bytes. Where its diff is, is the whole of the answer.
  def call(conn, {:error, :not_a_file}),
    do:
      error(
        conn,
        :unprocessable_entity,
        "not_a_file",
        "this version is a commit, not a file; its diff is GET /api/v1/tickets/:project/:number/review"
      )

  def call(conn, {:error, {:bad_request, detail}}),
    do: error(conn, :bad_request, "bad_request", detail)

  # Anything not mapped above is a platform fault, not a client error: log it, say nothing
  # about it to the client.
  def call(conn, {:error, reason}) do
    Logger.error("api request failed: #{inspect(reason)}")
    error(conn, :internal_server_error, "internal", nil)
  end

  defp error(conn, status, reason, detail) do
    conn
    |> put_status(status)
    |> json(%{error: %{reason: reason, detail: detail}})
  end
end
