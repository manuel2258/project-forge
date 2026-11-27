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

  # `Forge.Engine.decide/4`'s rule, not the API's: a reject needs a note, so the next job is told
  # why (`docs/design/ui.md` § The decision row).
  def call(conn, {:error, :note_required}),
    do:
      error(
        conn,
        :unprocessable_entity,
        "note_required",
        "a rejection needs a comment saying why"
      )

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

  def call(conn, {:error, {:updating, state}}),
    do:
      error(
        conn,
        :conflict,
        "updating",
        "#{state} is bringing the branch up to date; the ticket moves on by itself"
      )

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

  # What a person did about a job that ran out (`Forge.Jobs.Extensions`): a job or ticket that is
  # not in a state to be extended is the state of things and the client's to resolve (409), and a
  # figure, a note or a raise that is wrong is the request's (422), in the words the page says.
  def call(conn, {:error, {:not_extendable, _why} = reason}),
    do: error(conn, :conflict, "not_extendable", Forge.Jobs.Extensions.explain(reason))

  def call(conn, {:error, reason})
      when elem(reason, 0) in [
             :invalid_tokens,
             :invalid_turns,
             :invalid_timeout,
             :invalid_note,
             :invalid_raise,
             :note_too_long,
             :raise_short
           ],
      do:
        error(
          conn,
          :unprocessable_entity,
          Atom.to_string(elem(reason, 0)),
          Forge.Jobs.Extensions.explain(reason)
        )

  def call(conn, {:error, :raise_not_needed}),
    do:
      error(
        conn,
        :unprocessable_entity,
        "raise_not_needed",
        Forge.Jobs.Extensions.explain(:raise_not_needed)
      )

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

  # What a jump can be refused for (`Forge.Engine.refusal/1` has the words). The state a request
  # named is not a state of the workflow: the client's mistake. What it lacks is a conflict with
  # the ticket as it stands. `is_jump` and `is_edge` are not here: they answer a page's press drawn
  # before the ticket moved (`Forge.Engine.choose/4`'s `:jump` option), which a request names no
  # kind for.
  def call(conn, {:error, {:unknown_state, _name} = reason}),
    do: error(conn, :unprocessable_entity, "unknown_state", Forge.Engine.refusal(reason))

  def call(conn, {:error, {:missing_input, _name} = reason}),
    do: error(conn, :conflict, "missing_input", Forge.Engine.refusal(reason))

  def call(conn, {:error, {:merge_impossible, reason} = refusal})
      when reason in [:no_changeset, :no_commit_message],
      do: error(conn, :conflict, "merge_impossible", Forge.Engine.refusal(refusal))

  def call(conn, {:error, {:reopen_conflict, _paths} = reason}),
    do: error(conn, :conflict, "reopen_conflict", Forge.Engine.refusal(reason))

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

  # Schedules (`docs/design/schedules.md`): what a switch or a dismissal can be refused for. The
  # state of the file or of the schedule, and the client's to resolve.
  def call(conn, {:error, reason})
      when reason in [:schedule_gone, :schedule_unreadable, :already_on, :already_off, :no_alert],
      do: error(conn, :conflict, Atom.to_string(reason), ForgeWeb.SchedulesView.explain(reason))

  # What the operation refused a caller who may reach the project but not do this: a schedule's
  # switch, or the one who may not withdraw a file (`Forge.Attachments.withdraw/5`).
  def call(conn, {:error, :forbidden}),
    do: error(conn, :forbidden, "forbidden", "you are not allowed to do this")

  # A file that passes a limit refuses the whole request (`docs/design/attachments.md` § The API):
  # each is named with the limit it passed, in the words a page says it in.
  def call(conn, {:error, {:attachments_refused, refused}}) do
    detail =
      Enum.map(refused, fn {file, limit} ->
        %{file: file, limit: Atom.to_string(limit), detail: limit_words(limit)}
      end)

    error(conn, :unprocessable_entity, "attachments_refused", detail)
  end

  # Hold, milestones and order (`docs/design/workflow-grammar-v1.md` § Holding a ticket). The
  # state of the ticket or the milestone and so the client's to resolve are 409; a request that
  # names something that cannot be is 422.
  def call(conn, {:error, :start_or_hold}),
    do:
      error(
        conn,
        :unprocessable_entity,
        "start_or_hold",
        "say whether to start the ticket now or put it on hold: on_hold is true or false"
      )

  # Outside work (`docs/design/outside-work.md` § Outside work): what the request says that cannot
  # go together. A start commit that is no good is `bad_start_commit`, with the ticket types'
  # refusals (`Admission`).
  def call(conn, {:error, reason})
      when reason in [
             :outside_work_starts,
             :start_commit_without_outside_work,
             :outside_work_needs_a_name
           ],
      do:
        error(
          conn,
          :unprocessable_entity,
          Atom.to_string(reason),
          ForgeWeb.Operator.Actions.describe(reason)
        )

  def call(conn, {:error, :milestone}),
    do:
      error(
        conn,
        :unprocessable_entity,
        "milestone",
        "an open milestone of this project is needed"
      )

  def call(conn, {:error, :already_on_hold}),
    do: error(conn, :conflict, "already_on_hold", "the ticket is already on hold")

  def call(conn, {:error, :not_on_hold}),
    do: error(conn, :conflict, "not_on_hold", "the ticket is not on hold")

  def call(conn, {:error, {:not_holdable, status}}),
    do: error(conn, :conflict, "not_holdable", "a #{status} ticket cannot be put on hold")

  def call(conn, {:error, {:not_releasable, status}}),
    do: error(conn, :conflict, "not_releasable", "a #{status} ticket cannot be released")

  def call(conn, {:error, :running_choice}),
    do:
      error(
        conn,
        :unprocessable_entity,
        "running_choice",
        "a run of the ticket's state is going: send running as \"stop\" or \"finish\""
      )

  def call(conn, {:error, :bad_running}),
    do:
      error(
        conn,
        :unprocessable_entity,
        "bad_running",
        "running is \"stop\" or \"finish\""
      )

  # Names the holder (a token by its name, a person by id) and since when, so a person or an agent
  # knows whom to ask.
  def call(conn, {:error, {:already_taken_over, who, since}}),
    do:
      error(
        conn,
        :conflict,
        "already_taken_over",
        "the ticket is already taken over by #{holder(who)} since " <> DateTime.to_iso8601(since)
      )

  # The three refusals of keeping a job's work (`Forge.Engine.keep_work/4`): the stop was left,
  # nothing was kept, or the two sets of commits clash — which names the paths, and leaves the
  # ticket stuck with its other ways out.
  def call(conn, {:error, :stale_stop}),
    do:
      error(
        conn,
        :conflict,
        "stale_stop",
        "the ticket is no longer stopped for that job's moved branch"
      )

  def call(conn, {:error, :keep_push_failed}),
    do:
      error(
        conn,
        :conflict,
        "keep_push_failed",
        "the branch moved again or refused the merge; nothing was written, look again and retry"
      )

  def call(conn, {:error, :nothing_kept}),
    do: error(conn, :conflict, "nothing_kept", "no work of that job was kept")

  def call(conn, {:error, {:kept_work_conflicts, paths}}),
    do:
      error(
        conn,
        :conflict,
        "kept_work_conflicts",
        "the job's work clashes with the commits that arrived in " <> Enum.join(paths, ", ")
      )

  def call(conn, {:error, :not_taken_over}),
    do: error(conn, :conflict, "not_taken_over", "the ticket is not taken over")

  def call(conn, {:error, :bad_step}),
    do: error(conn, :unprocessable_entity, "bad_step", "to is the name of a workflow step")

  def call(conn, {:error, :bad_note}),
    do: error(conn, :unprocessable_entity, "bad_note", "the note is not valid text")

  def call(conn, {:error, {:handback_note_too_long, limit}}),
    do:
      error(
        conn,
        :unprocessable_entity,
        "note_too_long",
        "the note is longer than #{limit} characters"
      )

  def call(conn, {:error, :nothing_running}),
    do: error(conn, :conflict, "nothing_running", "no run of the ticket's state is going")

  def call(conn, {:error, {:no_state, state}}),
    do:
      error(
        conn,
        :unprocessable_entity,
        "no_state",
        "the workflow now on the default branch has no state #{state}"
      )

  def call(conn, {:error, :branch_moved}),
    do:
      error(
        conn,
        :conflict,
        "branch_moved",
        "the ticket's branch has moved since it was admitted, so it cannot be refreshed"
      )

  def call(conn, {:error, :changed}),
    do: error(conn, :conflict, "changed", "the ticket changed while this was made; try again")

  def call(conn, {:error, :release_title}),
    do:
      error(
        conn,
        :unprocessable_entity,
        "release_title",
        "a release's title is its version, set by the release itself"
      )

  def call(conn, {:error, :blank}),
    do: error(conn, :unprocessable_entity, "blank", "the title cannot be empty")

  def call(conn, {:error, {:not_open, status}}),
    do: error(conn, :conflict, "not_open", "a #{status} ticket keeps its place and milestone")

  def call(conn, {:error, :moved}),
    do: error(conn, :conflict, "moved", "the ticket moved to another order while this was made")

  def call(conn, {:error, :not_in_order}),
    do: error(conn, :unprocessable_entity, "not_in_order", "that is not in this order")

  def call(conn, {:error, :closed}),
    do: error(conn, :conflict, "closed", "the milestone is closed")

  def call(conn, {:error, :already_closed}),
    do: error(conn, :conflict, "already_closed", "the milestone is already closed")

  def call(conn, {:error, :not_closed}),
    do: error(conn, :conflict, "not_closed", "the milestone is not closed")

  # A changeset is a commit, not bytes. Where its diff is, is the whole of the answer.
  def call(conn, {:error, :not_a_file}),
    do:
      error(
        conn,
        :unprocessable_entity,
        "not_a_file",
        "this version is a commit, not a file; its diff is GET /api/v1/tickets/:project/:number/review"
      )

  # Looking into a ticket's command copy (`Forge.Explore.refusal/3`): a code of its own for each, the
  # sentence for it, and what a client needs to act on it (`explorable_until`, `why`, `replaced_by`).
  def call(conn, {:error, {:explore, code, extra}}) do
    body = %{
      reason: Atom.to_string(code),
      detail: ForgeCore.Explore.sentence(code)
    }

    conn
    |> put_status(explore_status(code))
    |> json(%{error: Map.merge(body, extra)})
  end

  def call(conn, {:error, {:bad_request, detail}}),
    do: error(conn, :bad_request, "bad_request", detail)

  # Anything not mapped above is a platform fault, not a client error: log it, say nothing
  # about it to the client.
  def call(conn, {:error, reason}) do
    Logger.error("api request failed: #{inspect(reason)}")
    error(conn, :internal_server_error, "internal", nil)
  end

  defp explore_status(:machine_not_answering), do: :gateway_timeout
  defp explore_status(:machine_not_connected), do: :service_unavailable
  defp explore_status(:machine_outdated), do: :conflict
  defp explore_status(:copy_gone), do: :not_found
  defp explore_status(:path_refused), do: :bad_request
  defp explore_status(:path_not_found), do: :not_found
  defp explore_status(code) when code in [:not_a_folder, :not_a_file], do: :conflict
  defp explore_status(:not_text), do: :unprocessable_entity
  defp explore_status(_failed), do: :bad_gateway

  defp holder({:api, _id, name}), do: "the token #{name}"
  defp holder({:user, id}), do: "user #{id}"
  defp holder(_gone), do: "someone no longer here"

  defp limit_words(limit) when limit in [:file_bytes, :per_act, :pool_files, :pool_bytes],
    do: Forge.Attachments.limit_text(limit)

  defp limit_words(_other), do: "it could not be kept"

  defp error(conn, status, reason, detail) do
    conn
    |> put_status(status)
    |> json(%{error: %{reason: reason, detail: detail}})
  end
end
