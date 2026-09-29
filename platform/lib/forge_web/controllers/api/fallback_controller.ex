defmodule ForgeWeb.Api.FallbackController do
  @moduledoc "Maps context errors to JSON error responses."

  use ForgeWeb, :controller

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

  def call(conn, {:error, {:no_version, name}}),
    do: error(conn, :conflict, "no_version", "#{name} has no version to approve")

  def call(conn, {:error, {:no_job_in, state}}),
    do: error(conn, :conflict, "no_job_in_state", "no job runs in #{state}")

  def call(conn, {:error, {:not_retryable, status}}),
    do: error(conn, :conflict, "not_retryable", "a #{status} ticket cannot be run again")

  def call(conn, {:error, {:not_cancellable, status}}),
    do: error(conn, :conflict, "not_cancellable", "a #{status} ticket cannot be cancelled")

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
