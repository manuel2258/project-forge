defmodule Forge.Operator do
  @moduledoc """
  The human operations, each existing once and reachable from the API, the pages and the
  Mix tasks. Every function takes the acting user, returns `{:ok, ticket}` or
  `{:error, reason}`, and notifies subscribers of the ticket on success.

  ## The guard lives here

  This is the single place every human action passes, so it is where membership is checked and
  the only place it needs to be — `docs/design/identity.md` § Where the guard lives. A page that
  hides a button is cosmetics; a page that forgets to is not a hole, because the operation
  refuses anyway. `{:error, :forbidden}` is what a non-member gets, for every one of these.

  That was a claim before it was true. A review found seven human writes reaching their context
  directly — a conversation answered from the queue with an id off the wire, the settings
  handlers, admission — and their only guard was a LiveView mount, which is the page again. They
  live here now. The contexts keep their unguarded functions for the engine and for the command
  line, which is past every gate there is.
  """

  require Logger

  alias Forge.Access
  alias Forge.Accounts.Scope
  alias Forge.Accounts.User
  alias Forge.Actor
  alias Forge.Artifacts
  alias Forge.Attachments
  alias Forge.Attachments.Batch
  alias Forge.Conversations
  alias Forge.Engine
  alias Forge.Events
  alias Forge.Git.Token
  alias Forge.Jobs
  alias Forge.Jobs.Job
  alias Forge.Milestones
  alias Forge.Projects
  alias Forge.Projects.Project
  alias Forge.Proposals
  alias Forge.Repo
  alias Forge.Tickets
  alias Forge.Tickets.Ticket

  @typedoc """
  Who acts. A project token with API write may do the operations that say so; the rest take a
  `%User{}` only, so a token cannot reach them by construction (`docs/design/identity.md`
  § Where the guard lives).
  """
  @type actor :: User.t() | Token.t()

  @doc """
  Answers the open question `key`. The waiting job of the ticket's current state resumes in
  the same transaction once no blocking question on the ticket remains open, whoever wrote
  the document that carries it.
  """
  @spec answer(Ticket.t(), actor(), String.t(), map(), keyword()) ::
          {:ok, Ticket.t()} | {:error, term()}
  def answer(%Ticket{} = ticket, actor, key, attrs, opts \\ []) do
    with :ok <- allow(ticket, actor, :use),
         %{} = question <-
           Artifacts.find_open_question(ticket.id, key) || {:error, {:no_open_question, key}},
         {:ok, _answer} <- attached_answer(ticket, question, actor, attrs, opts) do
      notify(ticket)
    end
  end

  # **Files ride on the act they came with** (`docs/design/attachments.md` § Staging, claiming and
  # the sweep). The guard of the act has already run — a person who may not act never reaches the
  # claim. `opts[:attachments]` is a `Forge.Attachments.Batch`, or absent, in which case this is
  # `act` and nothing else, so a ticket with no files is exactly what it was.
  #
  # A whole request (the API's) is checked against the limits first (`Attachments.preflight/4`) and
  # refused before anything is done. After that there are two orders, because two things must hold:
  # the files are in the pool **before the job the act makes can be assigned** (a file attached to an
  # answer must reach the run that asked), and a refusal after the act's git work cannot take back
  # what it pushed (a merge pushed, then the approval rolled back):
  #
  # - **An act that makes the ticket** (`{:new, project_id}`: admit, accept) runs with its claim in
  #   one transaction. Nothing there pushes after commit, and the ticket does not exist until the
  #   transaction does, so the first job cannot be assigned before the files are in.
  # - **An act on a ticket** runs in its own transaction, as it always did, **under the ticket's
  #   assignment lock** (`Attachments.hold/2`), and the claim follows in a transaction of its own,
  #   lenient. The scheduler skips a pending job of a ticket whose lock is held, so the job the act
  #   makes is not assigned until the claim has committed — or the act has failed. A file that cannot
  #   be had because a race filled the pool in between is *not received* and the act stands.
  #
  # `target` is `{:ticket, id}`, the pool the files go into, or `{:new, project_id}` for an act that
  # makes the ticket (its pool is the new ticket's). `where` says what the act wrote that the files
  # are anchored to: `{:events, types}` — the first event of one of these types by this actor after
  # the act began — or `{:version, fun}`, a version `fun` finds in the result.
  defp attach(opts, actor, kind, target, where, act) do
    case Keyword.get(opts, :attachments) do
      %Batch{} = batch ->
        if Batch.empty?(batch),
          do: act.(),
          else: attach_batch(batch, actor, kind, target, where, act)

      _none ->
        act.()
    end
  end

  defp attach_batch(batch, actor, kind, {:new, project_id} = target, where, act) do
    with :ok <- Attachments.preflight(batch, actor, project_id, nil) do
      Repo.transact(fn -> act_and_claim(batch, actor, kind, target, where, act) end)
    end
  end

  defp attach_batch(batch, actor, kind, {:ticket, ticket_id} = pool, where, act) do
    Attachments.hold(ticket_id, fn ->
      with :ok <- Attachments.preflight(batch, actor, Attachments.project_of(pool), pool),
           mark = Attachments.mark(),
           {:ok, result} <- act.() do
        claim_after(batch, actor, kind, pool, anchor(where, result, mark))
        {:ok, result}
      end
    end)
  end

  defp pool_of({:new, _project_id}, %Ticket{id: id}), do: {:ticket, id}
  defp pool_of(pool, _result), do: pool

  # An act that makes the ticket: the act and the claim in the transaction the caller opened, so a
  # claim that fails — `{:error, _}` — rolls the admission or the acceptance back with it, and the
  # ticket (so its first job) does not exist until the files are in. Matching the claim's result is
  # an equivalent mutant for the suite: a claim fails inside a nested transaction (`record_version/5`),
  # which marks the caller's transaction rolled back, so the admission goes whether or not the result
  # is matched; it is matched so that the code says what happens.
  defp act_and_claim(batch, actor, kind, target, where, act) do
    mark = Attachments.mark()

    with {:ok, result} <- act.(),
         anchor = anchor(where, result, mark),
         {:ok, _claimed} <-
           Attachments.claim(
             pool_of(target, result),
             actor,
             %{batch | whole?: false},
             kind,
             anchor
           ) do
      {:ok, result}
    end
  end

  # The act has happened; what the files do now cannot undo it. A claim that fails is said in the log
  # and the files stay staged for the sweep, so a person is never told an act failed that did not.
  defp claim_after(batch, actor, kind, pool, anchor) do
    # Equivalent mutant: dropping `whole?: false` changes nothing the suite can see, because the
    # preflight has refused every whole request this claim would refuse but for a race with another
    # writer between the two, which needs two connections.
    lenient = %{batch | whole?: false}

    case Repo.transact(fn -> Attachments.claim(pool, actor, lenient, kind, anchor) end) do
      {:ok, _claimed} ->
        :ok

      {:error, reason} ->
        Logger.error("files not attached to #{inspect(pool)}: #{inspect(reason)}")
    end
  rescue
    error -> Logger.error("files not attached to #{inspect(pool)}: #{Exception.message(error)}")
  end

  defp anchor({:events, types}, _result, mark), do: {:events_after, mark, types}
  defp anchor({:version, fun}, result, _mark), do: {:version, fun.(result)}

  defp attached_answer(ticket, question, actor, attrs, opts) do
    answered = fn ->
      Forge.Repo.transact(fn -> answer_and_resume(ticket, question, actor, attrs) end)
    end

    attach(opts, actor, :answer, {:ticket, ticket.id}, {:events, ["question.answered"]}, answered)
  end

  defp answer_and_resume(ticket, question, actor, attrs) do
    with {:ok, answer} <- Artifacts.answer(question, Actor.of(actor), attrs),
         :ok <- resume_if_unblocked(ticket) do
      {:ok, answer}
    end
  end

  @doc """
  Answers a document's questions together: `answers` maps each key to `%{choice:, text:}`, for
  questions on the artifact version `version_id`. One transaction writes them all and resumes the
  waiting job once, so the job reads every answer the person gave rather than whichever landed
  first (`docs/design/job-prompt.md` § Answering a document's questions at once).

  Refused whole, writing nothing:

  - `{:error, :stale}` — a key is not an open question on that version: the document has a newer
    version, or someone answered it meanwhile. Half of what a person sent is not what they sent.
  - `{:error, {:unanswered, keys}}` — a blocking question on the version has no answer. The page
    disables Send until each is locked; this is the operation saying so as well.
  - `{:error, :no_answers}` — nothing to send.
  - whatever `Forge.Artifacts.answer_all/2` refuses: an empty answer, a choice that is no label.
  """
  @spec answer_all(Ticket.t(), actor(), String.t(), %{String.t() => map()}, keyword()) ::
          {:ok, Ticket.t()} | {:error, term()}
  def answer_all(%Ticket{} = ticket, actor, version_id, answers, opts \\ [])
      when is_map(answers) do
    with :ok <- allow(ticket, actor, :use),
         {:ok, _answers} <- attached_answers(ticket, actor, version_id, answers, opts) do
      notify(ticket)
    end
  end

  defp attached_answers(ticket, actor, version_id, answers, opts) do
    answered = fn ->
      Forge.Repo.transact(fn -> answer_all_and_resume(ticket, actor, version_id, answers) end)
    end

    attach(opts, actor, :answer, {:ticket, ticket.id}, {:events, ["question.answered"]}, answered)
  end

  # Read inside the transaction that writes, so what is checked is what is answered.
  defp answer_all_and_resume(ticket, actor, version_id, answers) do
    open =
      ticket.id
      |> Artifacts.open_questions()
      |> Enum.filter(&(&1.artifact_version_id == version_id))

    by_key = Map.new(open, &{&1.key, &1})

    with :ok <- all_open(answers, by_key),
         :ok <- blocking_answered(open, answers),
         {:ok, written} <-
           answers
           |> Enum.map(fn {key, attrs} -> {by_key[key], attrs} end)
           |> Enum.sort_by(fn {question, _attrs} -> question.line end)
           |> Artifacts.answer_all(Actor.of(actor)),
         :ok <- resume_if_unblocked(ticket) do
      {:ok, written}
    end
  end

  defp all_open(answers, _by_key) when answers == %{}, do: {:error, :no_answers}

  defp all_open(answers, by_key) do
    if Enum.all?(Map.keys(answers), &Map.has_key?(by_key, &1)), do: :ok, else: {:error, :stale}
  end

  defp blocking_answered(open, answers) do
    case for(q <- open, q.blocking, not Map.has_key?(answers, q.key), do: q.key) do
      [] -> :ok
      keys -> {:error, {:unanswered, keys}}
    end
  end

  # The two facts a waiting job is held by, from the functions `Forge.Conversations` asks too
  # when it refuses a chat the document holding one of those questions: the refusal and the
  # resume have to agree on what holds a job.
  defp resume_if_unblocked(%Ticket{id: ticket_id} = ticket) do
    waiting = Jobs.waiting_job(ticket)

    cond do
      waiting == nil -> :ok
      Artifacts.open_blocking_questions(ticket_id) != [] -> :ok
      true -> with({:ok, _job} <- Jobs.resume(waiting), do: :ok)
    end
  end

  @doc """
  Decides the pending transition — on exactly the versions in `seen` (`%{name => version}`) when
  the caller drew them, else on the latest (`Forge.Engine.decide/5`).
  """
  @spec decide(
          Ticket.t(),
          actor(),
          :approved | :rejected,
          String.t() | nil,
          %{String.t() => pos_integer()} | nil,
          keyword()
        ) :: {:ok, Ticket.t()} | {:error, term()}
  def decide(%Ticket{} = ticket, actor, decision, comment, seen \\ nil, opts \\ [])
      when decision in [:approved, :rejected] do
    with :ok <- allow(ticket, actor, :use),
         {:ok, ticket} <-
           attach(
             opts,
             actor,
             :note,
             {:ticket, ticket.id},
             {:events, ["approval.approved", "approval.rejected"]},
             fn -> Engine.decide(ticket, Actor.of(actor), decision, comment, seen) end
           ) do
      notify(ticket)
    end
  end

  @doc "Moves a ticket to a state by hand: a declared transition, or a jump when none leads there. Options: `:outcome`, `:comment`, `:approving`, `:jump` (`Forge.Engine.choose/4`)."
  @spec transition(Ticket.t(), actor(), String.t(), keyword()) ::
          {:ok, Ticket.t()} | {:error, term()}
  def transition(%Ticket{} = ticket, actor, to, opts \\ []) do
    {files, opts} = Keyword.split(opts, [:attachments])

    with :ok <- allow(ticket, actor, :use),
         {:ok, ticket} <-
           attach(
             files,
             actor,
             :note,
             {:ticket, ticket.id},
             {:events, ["transition.taken"]},
             fn ->
               Engine.choose(ticket, Actor.of(actor), to, opts)
             end
           ) do
      notify(ticket)
    end
  end

  @doc """
  Runs the ticket's current state again (`Forge.Engine.retry/3`): after a failure, or after a
  success whose documents a person wants done afresh. `opts` are the person's `:note` and `:raise`
  of the ticket's cap.

  **The guard is asked twice**: here, so a refusal costs nothing, and again inside the engine's
  transaction straight after it locks the ticket — what is checked is what is acted on
  (`docs/design/identity.md`).
  """
  @spec retry(Ticket.t(), actor(), keyword()) :: {:ok, Ticket.t()} | {:error, term()}
  def retry(%Ticket{} = ticket, actor, opts \\ []) do
    {files, opts} = Keyword.split(opts, [:attachments])

    with :ok <- allow(ticket, actor, :use),
         {:ok, ticket} <-
           attached_retry(ticket, actor, files, opts) do
      notify(ticket)
    end
  end

  defp attached_retry(ticket, actor, files, opts) do
    retried = fn ->
      Engine.retry(
        ticket,
        Actor.of(actor),
        Keyword.put(opts, :allow, fn -> allow(ticket, actor, :use) end)
      )
    end

    attach(files, actor, :note, {:ticket, ticket.id}, {:events, ["ticket.retried"]}, retried)
  end

  @doc """
  Reopens the job of `ticket` that ran out of budget with what the person gives it
  (`Forge.Engine.extend/5`): `attrs` are `tokens`, `turns`, `note` and `raise`. Any project member
  may, or a project token with write access — the guard every write passes — checked again inside
  the transaction that acts.
  """
  @spec extend(Ticket.t(), actor(), String.t(), map(), keyword()) ::
          {:ok, Ticket.t()} | {:error, term()}
  def extend(%Ticket{} = ticket, actor, job_id, attrs, opts \\ []) do
    with :ok <- allow(ticket, actor, :use),
         {:ok, ticket} <-
           attach(opts, actor, :note, {:ticket, ticket.id}, {:events, ["job.extended"]}, fn ->
             Engine.extend(ticket, job_id, Actor.of(actor), attrs,
               allow: fn -> allow(ticket, actor, :use) end
             )
           end) do
      notify(ticket)
    end
  end

  @doc """
  Sends a ticket whose changeset no longer merges down its merging state's conflict route, before
  anybody approves it (`Forge.Engine.integrate/2`).
  """
  @spec integrate(Ticket.t(), User.t()) :: {:ok, Ticket.t()} | {:error, term()}
  def integrate(%Ticket{} = ticket, %User{} = user) do
    with :ok <- allow(ticket, user, :use),
         {:ok, ticket} <- Engine.integrate(ticket, user.id) do
      notify(ticket)
    end
  end

  @doc """
  Takes a ticket out of the merge queue (`Forge.Engine.take_out/2`): an unapproval, allowed to
  whoever may approve on the project, and a person only — a token cannot reach it.
  """
  @spec take_out(Ticket.t(), User.t()) :: {:ok, Ticket.t()} | {:error, term()}
  def take_out(%Ticket{} = ticket, %User{} = user) do
    with :ok <- allow(ticket, user, :use),
         {:ok, ticket} <- Engine.take_out(ticket, user.id) do
      notify(ticket)
    end
  end

  @doc "Re-pins a ticket's workflow to the default branch as it is now (`Forge.Engine.repin/2`)."
  @spec repin(Ticket.t(), User.t()) :: {:ok, Ticket.t()} | {:error, term()}
  def repin(%Ticket{} = ticket, %User{} = user) do
    with :ok <- allow(ticket, user, :use),
         {:ok, ticket} <- Engine.repin(ticket, user.id) do
      notify(ticket)
    end
  end

  @doc """
  Cancels a ticket (`Forge.Engine.cancel/2`): its live jobs end and it is hidden everywhere a ticket
  is listed. Not a deletion; `restore/2` undoes it.
  """
  @spec cancel(Ticket.t(), actor()) :: {:ok, Ticket.t()} | {:error, term()}
  def cancel(%Ticket{} = ticket, actor) do
    with :ok <- allow(ticket, actor, :use),
         {:ok, ticket} <- Engine.cancel(ticket, Actor.of(actor)) do
      notify(ticket)
    end
  end

  @doc "Brings a cancelled ticket back, stuck in the state it was in (`Forge.Engine.restore/2`)."
  @spec restore(Ticket.t(), actor()) :: {:ok, Ticket.t()} | {:error, term()}
  def restore(%Ticket{} = ticket, actor) do
    with :ok <- allow(ticket, actor, :use),
         {:ok, ticket} <- Engine.restore(ticket, Actor.of(actor)) do
      notify(ticket)
    end
  end

  @doc """
  Writes a new version of a document, authored by the user.

  `base` is the version the writer had in front of them, as a string — `"0"` for a document with
  no version yet, and `nil` from a caller with no page that could have gone stale, which is the
  API and the mix task. A write whose base is not the latest version any more is refused whole
  rather than landing on top of whatever arrived in between (`docs/design/ui.md` § A reconnect is
  not a reload). It guards an accident, not a member who means it: anybody who may write here may
  reload and write the same content again.
  """
  @spec edit(Ticket.t(), actor(), String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, Ticket.t()} | {:error, term()}
  def edit(%Ticket{} = ticket, actor, name, content, base \\ nil, opts \\ []) do
    with :ok <- allow(ticket, actor, :use),
         :ok <- not_reserved(name),
         {:ok, _version} <-
           attached_version(ticket, actor, name, content, base, opts) do
      notify(ticket)
    end
  end

  # A person's document may not take a name the platform keeps for something else — the files
  # people attach, the proposals, the transcripts. `attachments/x.png` written as a document would
  # make attaching `x.png` fail on a kind mismatch ever after (`docs/design/attachments.md`
  # § The pool).
  defp not_reserved(name) do
    case ForgeCore.Workflow.reserved_name_error(name) do
      nil -> :ok
      why -> {:error, {:invalid_document, [ForgeCore.Error.new(name, why)]}}
    end
  end

  defp attached_version(ticket, actor, name, content, base, opts) do
    written = fn ->
      Forge.Repo.transact(fn -> write_version(ticket, actor, name, content, base) end)
    end

    attach(opts, actor, :document, {:ticket, ticket.id}, {:version, & &1.id}, written)
  end

  # Read inside the transaction that writes, so what is checked is what is overwritten.
  defp write_version(ticket, actor, name, content, base) do
    with :ok <- current?(ticket, name, base) do
      Artifacts.record_version(ticket.id, name, :document, Actor.of(actor), %{content: content})
    end
  end

  defp current?(_ticket, _name, nil), do: :ok

  defp current?(ticket, name, base) do
    case Artifacts.latest(ticket.id, name) do
      nil ->
        if base == "0", do: :ok, else: {:error, {:stale_document, name, 0}}

      %{version: v} ->
        if to_string(v) == base, do: :ok, else: {:error, {:stale_document, name, v}}
    end
  end

  @doc """
  Admits a ticket into a project. A member's write, like the rest of the work.

  **`attrs[:on_hold]` must be given, true or false**: a person admitting a ticket chooses between
  starting it now and putting it on hold, and there is no default at any person's door
  (`docs/design/ui.md` § Creating things). Missing, or anything but a boolean, is
  `{:error, :start_or_hold}`, and nothing is written. `attrs[:milestone_id]` is optional: the
  ticket goes to the bottom of that open milestone of this project (`{:error, :milestone}` for
  any other), or of the no-milestone order.
  """
  @spec admit(Project.t(), actor(), map()) :: {:ok, Ticket.t()} | {:error, term()}
  def admit(%Project{} = project, actor, attrs) do
    {files, attrs} = Map.pop(attrs, :attachments)

    with :ok <- allow(project, actor, :use),
         :ok <- start_or_hold(attrs),
         {:ok, ticket} <-
           attach(
             [attachments: files],
             actor,
             :ticket,
             {:new, project.id},
             {:version, &ticket_version/1},
             fn -> Tickets.admit(project, attrs, Actor.of(actor)) end
           ) do
      # `Tickets.admit/3` told subscribers inside the transaction that holds the files, before they
      # were committed; this is the one they can read.
      Events.notify(ticket.id)
      {:ok, ticket}
    end
  end

  # The version of the ticket's text the admission wrote: files attached to a ticket are attached to it.
  defp ticket_version(%Ticket{id: id}),
    do: Artifacts.latest(id, ForgeCore.Workflow.ticket_artifact()).id

  defp start_or_hold(%{on_hold: on_hold}) when is_boolean(on_hold), do: :ok
  defp start_or_hold(_attrs), do: {:error, :start_or_hold}

  ## Schedules

  @doc """
  Switches a project's schedule on (`docs/design/schedules.md`): from now on it admits tickets in
  the name of `user`, who must be an admin of the project. **A project admin's own act, by session
  or by their own user token, and no project token's, whatever its access**: the function takes a
  `%User{}` only, so a token cannot reach it by construction, and the capability asked is
  `:manage`, which a member does not hold. `type` is the ticket type whose file declares it, nil
  for the single `.forge/workflow.yml`.

  Refused with `:schedule_gone`, `:schedule_unreadable` or `:already_on`, writing nothing.
  """
  @spec switch_schedule_on(Project.t(), User.t(), String.t() | nil, String.t()) ::
          {:ok, Forge.Schedules.Schedule.t()} | {:error, term()}
  def switch_schedule_on(%Project{} = project, %User{} = user, type, name) do
    with :ok <- allow(project, user, :manage) do
      Forge.Schedules.switch_on(project, user, type, name)
    end
  end

  @doc "Switches a schedule off. A project admin's, on the same terms as switching it on."
  @spec switch_schedule_off(Project.t(), User.t(), String.t() | nil, String.t()) ::
          {:ok, Forge.Schedules.Schedule.t()} | {:error, term()}
  def switch_schedule_off(%Project{} = project, %User{} = user, type, name) do
    with :ok <- allow(project, user, :manage) do
      Forge.Schedules.switch_off(project, user, type, name)
    end
  end

  @doc """
  Dismisses the queue item of a schedule that failed or switched itself off. Any member may, as
  anyone may answer a question, and so may a project token with API write: `:use`. Recorded with
  who.
  """
  @spec dismiss_schedule(Project.t(), actor(), String.t() | nil, String.t()) ::
          {:ok, Forge.Schedules.Schedule.t()} | {:error, term()}
  def dismiss_schedule(%Project{} = project, actor, type, name) do
    with :ok <- allow(project, actor, :use) do
      Forge.Schedules.dismiss(project, Actor.of(actor), type, name)
    end
  end

  ## Hold, titles and milestones

  @doc """
  Puts an open ticket on hold (`Forge.Engine.hold/2`). A member's write, a release ticket's
  included; a write-enabled token may too.
  """
  @spec hold(Ticket.t(), actor()) :: {:ok, Ticket.t()} | {:error, term()}
  def hold(%Ticket{} = ticket, actor) do
    with :ok <- allow(ticket, actor, :use),
         {:ok, held} <- Engine.hold(ticket, Actor.of(actor)) do
      notify(held)
    end
  end

  @doc "Releases a ticket on hold (`Forge.Engine.release/2`)."
  @spec release(Ticket.t(), actor()) :: {:ok, Ticket.t()} | {:error, term()}
  def release(%Ticket{} = ticket, actor) do
    with :ok <- allow(ticket, actor, :use),
         {:ok, released} <- Engine.release(ticket, Actor.of(actor)) do
      notify(released)
    end
  end

  @doc "Stops the run a held ticket is still finishing (`Forge.Engine.stop_now/2`)."
  @spec stop_now(Ticket.t(), actor()) :: {:ok, Ticket.t()} | {:error, term()}
  def stop_now(%Ticket{} = ticket, actor) do
    with :ok <- allow(ticket, actor, :use),
         {:ok, stopped} <- Engine.stop_now(ticket, Actor.of(actor)) do
      notify(stopped)
    end
  end

  @doc """
  Clears the ticket's warm build (`Forge.WarmBuilds.clear/2`): no command of the ticket starts from
  a copy kept before it, wherever it runs. Any member of the ticket's project may, and so may a
  project token that may write; a job's own token is refused before it gets here.
  """
  @spec clear_warm_build(Ticket.t(), actor()) :: {:ok, Ticket.t()} | {:error, term()}
  def clear_warm_build(%Ticket{} = ticket, actor) do
    with :ok <- allow(ticket, actor, :use),
         {:ok, cleared} <- Forge.WarmBuilds.clear(ticket, Actor.of(actor)) do
      notify(cleared)
    end
  end

  @doc "Changes a ticket's title (`Forge.Tickets.retitle/3`); a release's is refused."
  @spec retitle(Ticket.t(), actor(), String.t()) :: {:ok, Ticket.t()} | {:error, term()}
  def retitle(%Ticket{} = ticket, actor, title) when is_binary(title) do
    with :ok <- allow(ticket, actor, :use),
         {:ok, retitled} <- Tickets.retitle(ticket, title, Actor.of(actor)) do
      notify(retitled)
    end
  end

  @doc """
  Puts an open ticket in an open milestone of its project, or in none (`nil`)
  (`Forge.Milestones.set_ticket_milestone/3`).
  """
  @spec set_milestone(Ticket.t(), actor(), String.t() | nil) ::
          {:ok, Ticket.t()} | {:error, term()}
  def set_milestone(%Ticket{} = ticket, actor, milestone_id) do
    with :ok <- allow(ticket, actor, :use),
         {:ok, placed} <-
           Milestones.set_ticket_milestone(ticket, milestone_id, Actor.of(actor)) do
      notify(placed)
    end
  end

  @doc "Moves an open ticket in its order (`Forge.Milestones.move_ticket/3`)."
  @spec move_ticket(Ticket.t(), actor(), Milestones.to()) :: {:ok, Ticket.t()} | {:error, term()}
  def move_ticket(%Ticket{} = ticket, actor, to) do
    with :ok <- allow(ticket, actor, :use),
         {:ok, _moved} <- Milestones.move_ticket(ticket, to, Actor.of(actor)) do
      notify(ticket)
    end
  end

  @doc "Creates a milestone of the project."
  @spec create_milestone(Project.t(), actor(), map()) ::
          {:ok, Milestones.Milestone.t()} | {:error, term()}
  def create_milestone(%Project{} = project, actor, attrs) do
    with :ok <- allow(project, actor, :use) do
      Milestones.create(project, attrs, Actor.of(actor))
    end
  end

  @doc "Renames and describes a milestone of the project."
  @spec update_milestone(Project.t(), actor(), String.t(), map()) ::
          {:ok, Milestones.Milestone.t()} | {:error, term()}
  def update_milestone(%Project{id: project_id} = project, actor, id, attrs) do
    with :ok <- allow(project, actor, :use) do
      Milestones.update(project_id, id, attrs, Actor.of(actor))
    end
  end

  @doc "Marks a milestone as the project's current one, or `nil` unmarks."
  @spec set_current_milestone(Project.t(), actor(), String.t() | nil) ::
          {:ok, Milestones.Milestone.t() | nil} | {:error, term()}
  def set_current_milestone(%Project{id: project_id} = project, actor, id) do
    with :ok <- allow(project, actor, :use) do
      Milestones.set_current(project_id, id, Actor.of(actor))
    end
  end

  @doc "Closes a milestone of the project."
  @spec close_milestone(Project.t(), actor(), String.t()) ::
          {:ok, Milestones.Milestone.t()} | {:error, term()}
  def close_milestone(%Project{id: project_id} = project, actor, id) do
    with :ok <- allow(project, actor, :use) do
      Milestones.close(project_id, id, Actor.of(actor))
    end
  end

  @doc "Reopens a closed milestone of the project."
  @spec reopen_milestone(Project.t(), actor(), String.t()) ::
          {:ok, Milestones.Milestone.t()} | {:error, term()}
  def reopen_milestone(%Project{id: project_id} = project, actor, id) do
    with :ok <- allow(project, actor, :use) do
      Milestones.reopen(project_id, id, Actor.of(actor))
    end
  end

  @doc "Moves a milestone in the project's order."
  @spec move_milestone(Project.t(), actor(), String.t(), Milestones.to()) ::
          {:ok, term()} | {:error, term()}
  def move_milestone(%Project{id: project_id} = project, actor, id, to) do
    with :ok <- allow(project, actor, :use) do
      Milestones.move(project_id, id, to, Actor.of(actor))
    end
  end

  @doc """
  Starts the project's release (`docs/design/ticket-types.md` § Releases), with `note`, which may
  be empty, as its body. A project admin's: there is no token clause, so the page is the one door.
  """
  @spec start_release(Project.t(), User.t(), String.t() | nil) ::
          {:ok, Ticket.t()} | {:error, term()}
  def start_release(%Project{} = project, %User{} = user, note) do
    with :ok <- allow(project, user, :manage) do
      Forge.ReleaseTickets.start(project, note, Actor.of(user))
    end
  end

  ## Conversations

  @doc "Opens a conversation on a project."
  @spec open_chat(Project.t(), User.t(), String.t(), keyword()) ::
          {:ok, Job.t()} | {:error, term()}
  def open_chat(%Project{} = project, %User{} = user, text, opts \\ []) do
    with :ok <- allow(project, user, :use) do
      # Set outright, not `put_new`: this function has just checked who the person is, and an
      # actor a caller proposed would be the one thing in the event nobody verified. No path
      # reaches it with one today — `chat_new_live.ex` is the only caller and builds these opts
      # from literals — which is why this is a principle rather than a fix.
      Conversations.open(project, text, Keyword.put(opts, :actor, {:user, user.id}))
    end
  end

  @doc """
  Sends the next message in a conversation.

  The chat carries its own project, so a caller holding nothing but an id off the wire — which
  is what the queue's answer buttons send — still has to be a member of the project that chat
  belongs to.
  """
  @spec send_chat(Job.t(), User.t(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def send_chat(%Job{kind: :chat} = chat, %User{} = user, text, opts \\ []) do
    with :ok <- allow(chat, user, :use),
         do: Conversations.send(chat, text, Keyword.put(opts, :actor, {:user, user.id}))
  end

  @doc """
  Answers the questions of a conversation's last reply, as one message
  (`Forge.Conversations.answer_text/2`). `reply` is the `Forge.Conversations.reply_ref/1` of the
  reply the form was drawn for: when the last reply is another one, nothing is sent and the
  answer is `{:error, :stale}`, because the conversation moved on while the form was open.
  """
  @spec answer_chat(Job.t(), User.t(), String.t(), %{String.t() => map()}, keyword()) ::
          {:ok, term()} | {:error, term()}
  def answer_chat(%Job{kind: :chat} = chat, %User{} = user, reply, answers, opts \\ []) do
    with :ok <- allow(chat, user, :use),
         messages = List.wrap(Conversations.last_said(chat.id)),
         true <-
           (reply != nil and Conversations.reply_ref(messages) == reply) || {:error, :stale},
         {:ok, text} <-
           Conversations.answer_text(Conversations.questions(List.last(messages)), answers) do
      Conversations.send(chat, text, Keyword.put(opts, :actor, {:user, user.id}))
    end
  end

  @doc "Interrupts a running conversation."
  @spec stop_chat(Job.t(), User.t()) :: :ok | {:error, term()}
  def stop_chat(%Job{kind: :chat} = chat, %User{} = user) do
    with :ok <- allow(chat, user, :use), do: Conversations.stop(chat)
  end

  @doc """
  The button on a queued message: interrupts the turn in flight so that this message is taken now,
  and only if it is still queued (`Forge.Conversations.interrupt/2`). **The same check as Stop**: a
  person who may use the conversation.
  """
  @spec interrupt_chat(Job.t(), User.t(), String.t()) :: :ok | {:error, term()}
  def interrupt_chat(%Job{kind: :chat} = chat, %User{} = user, message_id) do
    with :ok <- allow(chat, user, :use), do: Conversations.interrupt(chat, message_id)
  end

  @doc """
  A person's *End* of a conversation (`Forge.Conversations.close/2`): refused for a workflow
  step's conversation, whoever asks, and for one already ended.
  """
  @spec close_chat(Job.t(), User.t()) :: :ok | {:error, term()}
  def close_chat(%Job{kind: :chat} = chat, %User{} = user) do
    with :ok <- allow(chat, user, :use),
         do: Conversations.close(chat, actor: {:user, user.id})
  end

  @doc """
  Accepts a chat step: the person ends the step their conversation is, and the ticket takes the
  edge for `outcome` (`Forge.Engine.accept/5`, `docs/design/conversations.md` § A conversation
  that is a step).

  **Who may press it is who may decide a transition by hand** (`:use` on the project), and **the
  standing of the person is read from the database when it is pressed**, not taken from the
  struct the page mounted with: a suspension since the page drew is a refusal. `seen` is the
  version of each document as the page drew it.
  """
  @spec accept_step(Job.t(), User.t(), String.t() | nil, %{String.t() => pos_integer()}) ::
          {:ok, Ticket.t()} | {:error, term()}
  def accept_step(%Job{kind: :chat} = chat, %User{id: user_id}, outcome, seen) do
    with {:ok, user} <- standing(user_id),
         :ok <- allow(chat, user, :use),
         {:ok, chat} <- step_chat(chat),
         {:ok, ticket} <-
           Engine.accept(Tickets.get!(chat.ticket_id), chat, user.id, outcome, seen) do
      notify(ticket)
    end
  end

  defp standing(user_id) do
    case Forge.Accounts.get_user(user_id) do
      %User{} = user ->
        if User.active?(user), do: {:ok, user}, else: {:error, User.standing(user)}

      nil ->
        {:error, :forbidden}
    end
  end

  # The row as it is now: the struct a page holds was read when it mounted.
  defp step_chat(%Job{id: id}) do
    chat = Repo.get!(Job, id)
    if Job.step?(chat), do: {:ok, chat}, else: {:error, :not_a_step}
  end

  @doc "Merges a conversation's branch."
  @spec merge_chat(Job.t(), User.t()) :: {:ok, term()} | {:error, term()}
  def merge_chat(%Job{kind: :chat} = chat, %User{} = user) do
    with :ok <- allow(chat, user, :use),
         {:ok, %{sha: sha, already: already}} = merged <- Forge.Merge.perform_chat(chat, user) do
      # What the merge did to the project's open tickets (`Forge.Merge.Watch`). Nothing moved when
      # the branch was already there.
      unless already do
        # Recorded so that an update step can say whose merge it brought in
        # (`Forge.Update`); a ticket's merge records `ticket.merged`.
        Forge.Events.append("chat.merged", {:user, user.id}, %{
          project_id: chat.project_id,
          job_id: chat.id,
          payload: %{"chat" => chat.id, "sha" => sha}
        })

        Forge.Merge.Watch.after_merge(chat.project_id, sha, %{"chat" => chat.id})
      end

      merged
    end
  end

  ## Project settings — the admin's, not the member's

  @doc "Sets the project's default model."
  @spec set_model(Project.t(), User.t(), String.t() | nil) ::
          {:ok, Project.t()} | {:error, term()}
  def set_model(%Project{} = project, %User{} = user, model),
    do: set_defaults(project, user, %{model: model})

  @doc "Sets the project's default effort."
  @spec set_effort(Project.t(), User.t(), String.t() | nil) ::
          {:ok, Project.t()} | {:error, term()}
  def set_effort(%Project{} = project, %User{} = user, effort),
    do: set_defaults(project, user, %{effort: effort})

  @doc """
  Sets the project's default model and effort in one write, or neither — project settings' one
  Save (`Forge.Projects.set_defaults/3`). A project admin's.
  """
  @spec set_defaults(Project.t(), User.t(), map()) :: {:ok, Project.t()} | {:error, term()}
  def set_defaults(%Project{} = project, %User{} = user, attrs) do
    with :ok <- allow(project, user, :manage), do: Projects.set_defaults(project, attrs, user)
  end

  @doc "Sets the project's default harness."
  @spec set_harness(Project.t(), User.t(), String.t()) :: {:ok, Project.t()} | {:error, term()}
  def set_harness(%Project{} = project, %User{} = user, harness) do
    with :ok <- allow(project, user, :manage), do: Projects.set_harness(project, harness, user)
  end

  @doc "Sets Codex's default model for the project."
  @spec set_codex_model(Project.t(), User.t(), String.t() | nil) ::
          {:ok, Project.t()} | {:error, term()}
  def set_codex_model(%Project{} = project, %User{} = user, model) do
    with :ok <- allow(project, user, :manage),
         do: Projects.set_codex_model(project, model, user)
  end

  @doc "Sets Codex's default effort for the project."
  @spec set_codex_effort(Project.t(), User.t(), String.t() | nil) ::
          {:ok, Project.t()} | {:error, term()}
  def set_codex_effort(%Project{} = project, %User{} = user, effort) do
    with :ok <- allow(project, user, :manage),
         do: Projects.set_codex_effort(project, effort, user)
  end

  @doc """
  Sets one of the project's secrets: a new one, or a new version of the live one with that name.
  A project admin's (`docs/design/secrets.md` § What a secret is).
  """
  @spec set_secret(Project.t(), User.t(), term(), term()) ::
          {:ok, Forge.Secrets.Secret.t()} | {:error, term()}
  def set_secret(%Project{} = project, %User{} = user, name, value) do
    with :ok <- allow(project, user, :manage), do: Forge.Secrets.set(project, user, name, value)
  end

  @doc """
  Deletes one of the project's secrets, destroying its value. The id is the client's, so
  `Forge.Secrets.delete/3` resolves it within this project, as `revoke_token/3` does a token.
  """
  @spec delete_secret(Project.t(), User.t(), term()) ::
          {:ok, Forge.Secrets.Secret.t()} | {:error, term()}
  def delete_secret(%Project{} = project, %User{} = user, id) do
    with :ok <- allow(project, user, :manage), do: Forge.Secrets.delete(project, user, id)
  end

  @doc """
  Issues a project token: one secret for git and the JSON API (`docs/design/git-hosting.md`
  § One project token, two doors). A project admin's.

  `opts` are `Forge.Git.Tokens.issue/2`'s. The issuer is set here from the acting user, and a
  `:job_id` is dropped: a job's token is the engine's to mint, and what a caller proposed is the one
  thing nobody has verified. Logs `token.issued` with the token's id, name and accesses, never the
  secret.
  """
  @spec issue_token(Project.t(), User.t(), keyword()) ::
          {:ok, String.t(), Forge.Git.Token.t()} | {:error, term()}
  def issue_token(%Project{} = project, %User{} = user, opts) do
    opts = opts |> Keyword.delete(:job_id) |> Keyword.put(:issued_by_id, user.id)

    with :ok <- allow(project, user, :manage),
         {:ok, secret, token} <- Forge.Git.Tokens.issue(project, opts) do
      log_token("token.issued", user, project, token)
      {:ok, secret, token}
    end
  end

  @doc """
  Revokes one of the project's git tokens.

  The token is resolved *within the project* and not by id alone. An id is the only thing the
  settings page sends, and a bare `Repo.get` would let any project's admin revoke any token on
  the node given its UUID.
  """
  @spec revoke_token(Project.t(), User.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def revoke_token(%Project{} = project, %User{} = user, token_id) do
    with :ok <- allow(project, user, :manage),
         true <- Enum.any?(Forge.Git.Tokens.list(project), &(&1.id == token_id)),
         {:ok, token} <- Forge.Git.Tokens.revoke(token_id) do
      log_token("token.revoked", user, project, token)
      {:ok, token}
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  # What was granted and to whom, by id and name; the secret is not in the token row and so cannot
  # be here.
  defp log_token(type, %User{id: user_id}, %Project{id: project_id}, token) do
    Events.append(type, {:user, user_id}, %{
      project_id: project_id,
      payload: %{
        "token_id" => token.id,
        "name" => token.name,
        "git" => to_string(token.git_access),
        "api" => to_string(token.api_access),
        "expires_at" => DateTime.to_iso8601(token.expires_at)
      }
    })
  end

  @doc """
  Accepts a ticket proposal, admitting it as a ticket.

  Unlike every other operation here it does not return the ticket it was about — it returns the
  ticket it *made*, which is a different one. A proposal belongs to the job that wrote it rather
  than to a ticket, and a project chat's proposal has no ticket anywhere near it.
  """
  @spec accept_proposal(String.t(), actor(), String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, Ticket.t()} | {:error, term()}
  def accept_proposal(version_id, actor, comment \\ nil, ticket_type \\ nil, opts \\ []) do
    # As `admit/3`, start or hold is the person's to say and nothing is written without it. A
    # proposal that is not there is still `:not_found` whatever else was left out, so it is the
    # one case that is not asked.
    {files, opts} = Keyword.split(opts, [:attachments])

    with :ok <- allow_proposal(version_id, actor),
         :ok <- if(Proposals.get(version_id), do: start_or_hold(Map.new(opts)), else: :ok),
         {:ok, %Ticket{} = ticket} <-
           attach(
             files,
             actor,
             :ticket,
             {:new, proposal_project(version_id)},
             {:version, &ticket_version/1},
             fn -> Proposals.accept(version_id, Actor.of(actor), comment, ticket_type, opts) end
           ) do
      # Both: the ticket the proposal came out of has a page that lists it, and the ticket it
      # became has one of its own that nobody is looking at yet.
      notify_origin(version_id)
      notify(ticket)
    end
  end

  @doc "Declines a ticket proposal. Recorded, so the next job does not propose it again."
  @spec decline_proposal(String.t(), actor(), String.t() | nil) ::
          {:ok, Forge.Proposals.Decision.t()} | {:error, term()}
  def decline_proposal(version_id, actor, comment \\ nil) do
    with :ok <- allow_proposal(version_id, actor),
         {:ok, decision} <- Proposals.decline(version_id, Actor.of(actor), comment) do
      notify_origin(version_id)
      {:ok, decision}
    end
  end

  @doc """
  Declines several proposals with one shared reason (`docs/design/ui.md` § Proposals), **refused
  whole**: every id is resolved and checked for the actor first — membership, as for one, and all
  of them in one project — and only then is anything written, in one transaction. One the actor
  may not decline, one in another project, or one that does not exist answers `:not_found` for
  the lot, as one alone would; one someone decided meanwhile answers `:already_decided` and rolls
  the others back.
  """
  @spec decline_proposals([String.t()], actor(), String.t() | nil) ::
          {:ok, [Forge.Proposals.Decision.t()]} | {:error, term()}
  def decline_proposals(version_ids, actor, reason \\ nil)
  def decline_proposals([], _actor, _reason), do: {:ok, []}

  def decline_proposals(version_ids, actor, reason) when is_list(version_ids) do
    with :ok <- allow_proposals(version_ids, actor),
         {:ok, decisions} <- Proposals.decline_all(version_ids, Actor.of(actor), reason) do
      Enum.each(version_ids, &notify_origin/1)
      {:ok, decisions}
    end
  end

  # Every one found, every one in the same project, and that project the actor's to use. Asked
  # before `decline_all/3` writes anything: a guard per write inside the loop would have declined
  # the first few and then refused.
  defp allow_proposals(version_ids, actor) do
    found = Enum.map(version_ids, &Proposals.get/1)

    with false <- Enum.any?(found, &is_nil/1),
         [project_id] <- found |> Enum.map(& &1.job.project_id) |> Enum.uniq(),
         true <- Access.can?(scope_of(actor, Forge.Projects.get!(project_id)), :use) do
      :ok
    else
      _missing_mixed_or_not_theirs -> {:error, :not_found}
    end
  end

  @doc """
  Reopens a declined proposal (`docs/design/ticket-proposals.md` § Deciding): anyone who may
  decline it may, through the same guard — a proposal in a project the actor is not in answers as
  one that does not exist. Only a declined one; anything else is `:not_declined`.
  """
  @spec reopen_proposal(String.t(), actor()) :: {:ok, term()} | {:error, term()}
  def reopen_proposal(version_id, actor) do
    with :ok <- allow_proposal(version_id, actor),
         {:ok, version} <- Proposals.reopen(version_id, Actor.of(actor)) do
      notify_origin(version_id)
      {:ok, version}
    end
  end

  # Every operation above resolves to a project the same way the objects do: a ticket carries
  # one, a proposal reaches one through the job that wrote it. There is no object here that
  # cannot answer, which is why the check is always the same two lines.
  defp allow(%Ticket{} = ticket, actor, capability),
    do: allow(Tickets.project_of(ticket), actor, capability)

  defp allow(%Job{project_id: project_id}, %User{} = user, capability),
    do: allow(Projects.get!(project_id), user, capability)

  defp allow(%Project{} = project, %User{} = user, capability) do
    scope = Scope.for_project(Scope.for_user(user), project)
    Access.ensure(scope, capability)
  end

  defp allow(%Project{} = project, %Token{} = token, capability) do
    Access.ensure(Scope.for_token(token, project), capability)
  end

  defp proposal_project(version_id) do
    case Proposals.get(version_id) do
      %{job: %{project_id: project_id}} -> project_id
      _absent -> nil
    end
  end

  defp allow_proposal(version_id, actor) do
    case Proposals.get(version_id) do
      %{job: %{project_id: project_id}} when is_binary(project_id) ->
        project = Forge.Projects.get!(project_id)
        # `:not_found`, not `:forbidden`: a proposal in someone else's project has to answer the
        # same way as one that does not exist, or the refusal itself says it exists.
        if Access.can?(scope_of(actor, project), :use), do: :ok, else: {:error, :not_found}

      _absent ->
        # Let the operation report it. It already says not_found, and duplicating that here
        # would mean two places deciding what a missing proposal looks like.
        :ok
    end
  end

  defp scope_of(%User{} = user, project), do: Scope.for_project(Scope.for_user(user), project)
  defp scope_of(%Token{} = token, project), do: Scope.for_token(token, project)

  @doc """
  Writes one key of a page's store as a person or a project token (`docs/design/pages.md` § Who
  may write). `op` is `{:set, value}` or `:delete`; `opts[:counter]` is `:any` for a person's
  last-write-wins and **required** (an integer, or `nil` for a key expected to be absent) from a
  token, which never overwrites what it has not read — a token's write without one is
  `{:error, :counter_required}`.

  The page must be one the actor reaches: a member of its project, or a token with write access to
  it. A page in another project answers `{:error, :not_found}` and not `:forbidden`, so the answer
  does not say it exists. A done or cancelled ticket and an ended chat refuse in `Forge.Pages`.
  """
  @spec write_page(Forge.Pages.Page.t(), actor(), String.t(), {:set, term()} | :delete, keyword()) ::
          {:ok, term()} | {:error, term()}
  def write_page(%Forge.Pages.Page{} = page, actor, key, op, opts \\ []) do
    with :ok <- allow_page(page, actor),
         :ok <- counter_for(actor, opts) do
      writer = page_writer(actor)

      case op do
        {:set, value} -> Forge.Pages.put(page, key, value, writer, opts)
        :delete -> Forge.Pages.delete(page, key, writer, opts)
      end
    end
  end

  @doc """
  Switches outside addresses on or off for a person on a page, for them alone
  (`docs/design/pages.md`). Only a person who reaches the page: a token has no viewing to switch.
  """
  @spec set_page_outside(Forge.Pages.Page.t(), actor(), boolean(), keyword()) ::
          {:ok, boolean()} | {:error, term()}
  def set_page_outside(%Forge.Pages.Page{} = page, actor, on?, _opts \\ [])
      when is_boolean(on?) do
    with %User{id: user_id} <- actor || {:error, :forbidden},
         :ok <- allow_page(page, actor) do
      Forge.Pages.set_outside(user_id, page, on?)
    else
      %Token{} -> {:error, :forbidden}
      {:error, _reason} = error -> error
    end
  end

  # A page outside the actor's reach is one that does not exist.
  defp allow_page(%Forge.Pages.Page{project_id: project_id}, actor) do
    if Access.can?(scope_of(actor, Projects.get!(project_id)), :use),
      do: :ok,
      else: {:error, :not_found}
  end

  # Equivalent mutant: letting a token name `:any` changes nothing observable, because the doors
  # build `opts` from a request's `counter` field, which parses to an integer or nil and never to
  # `:any` (`ForgeWeb.PageData`), so the `!= :any` test never has `:any` to refuse.
  defp counter_for(%Token{}, opts),
    do:
      if(Keyword.has_key?(opts, :counter) and opts[:counter] != :any,
        do: :ok,
        else: {:error, :counter_required}
      )

  defp counter_for(%User{}, _opts), do: :ok

  defp page_writer(%User{id: id}), do: {:user, id}
  defp page_writer(%Token{id: id}), do: {:token, id}

  # A proposal's page is its origin ticket's, when it has one. A project chat's has none, and
  # nothing needs telling.
  defp notify_origin(version_id) do
    case Proposals.get(version_id) do
      %{job: %{ticket_id: ticket_id}} when is_binary(ticket_id) -> Events.notify(ticket_id)
      _other -> :ok
    end
  end

  defp notify(%Ticket{id: id}) do
    ticket = Tickets.get!(id)
    Events.notify(ticket.id)
    {:ok, ticket}
  end
end
