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

  # A project registered but never pushed to has no commit to pin a ticket against. That is
  # the client's next step, not a platform fault.
  def call(conn, {:error, :unknown_ref}),
    do:
      error(
        conn,
        :unprocessable_entity,
        "unknown_ref",
        "the project's default branch has no commit; push the repository first"
      )

  def call(conn, {:error, {:job_live, state}}),
    do: error(conn, :conflict, "job_live", "a job for #{state} is pending, running or waiting")

  def call(conn, {:error, {:no_open_question, key}}),
    do: error(conn, :not_found, "no_open_question", key)

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
