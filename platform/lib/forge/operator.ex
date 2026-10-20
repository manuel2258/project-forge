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

  alias Forge.Access
  alias Forge.Accounts.Scope
  alias Forge.Accounts.User
  alias Forge.Artifacts
  alias Forge.Conversations
  alias Forge.Engine
  alias Forge.Events
  alias Forge.Jobs
  alias Forge.Jobs.Job
  alias Forge.Projects
  alias Forge.Projects.Project
  alias Forge.Proposals
  alias Forge.Tickets
  alias Forge.Tickets.Ticket

  @doc """
  Answers the open question `key`. The waiting job of the ticket's current state resumes in
  the same transaction once no blocking question on the ticket remains open, whoever wrote
  the document that carries it.
  """
  @spec answer(Ticket.t(), User.t(), String.t(), map()) :: {:ok, Ticket.t()} | {:error, term()}
  def answer(%Ticket{} = ticket, %User{} = user, key, attrs) do
    with :ok <- allow(ticket, user, :use),
         %{} = question <-
           Artifacts.find_open_question(ticket.id, key) || {:error, {:no_open_question, key}},
         {:ok, _answer} <-
           Forge.Repo.transact(fn -> answer_and_resume(ticket, question, user, attrs) end) do
      notify(ticket)
    end
  end

  defp answer_and_resume(ticket, question, user, attrs) do
    with {:ok, answer} <- Artifacts.answer(question, user.id, attrs),
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
  @spec answer_all(Ticket.t(), User.t(), String.t(), %{String.t() => map()}) ::
          {:ok, Ticket.t()} | {:error, term()}
  def answer_all(%Ticket{} = ticket, %User{} = user, version_id, answers) when is_map(answers) do
    with :ok <- allow(ticket, user, :use),
         {:ok, _answers} <-
           Forge.Repo.transact(fn -> answer_all_and_resume(ticket, user, version_id, answers) end) do
      notify(ticket)
    end
  end

  # Read inside the transaction that writes, so what is checked is what is answered.
  defp answer_all_and_resume(ticket, user, version_id, answers) do
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
           |> Artifacts.answer_all(user.id),
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

  @doc "Decides the pending transition."
  @spec decide(Ticket.t(), User.t(), :approved | :rejected, String.t() | nil) ::
          {:ok, Ticket.t()} | {:error, term()}
  def decide(%Ticket{} = ticket, %User{} = user, decision, comment)
      when decision in [:approved, :rejected] do
    with :ok <- allow(ticket, user, :use),
         {:ok, ticket} <- Engine.decide(ticket, user.id, decision, comment) do
      notify(ticket)
    end
  end

  @doc "Takes a declared transition by hand. Options: `:outcome`, `:comment`."
  @spec transition(Ticket.t(), User.t(), String.t(), keyword()) ::
          {:ok, Ticket.t()} | {:error, term()}
  def transition(%Ticket{} = ticket, %User{} = user, to, opts \\ []) do
    with :ok <- allow(ticket, user, :use),
         {:ok, ticket} <- Engine.choose(ticket, user.id, to, opts) do
      notify(ticket)
    end
  end

  @doc """
  Runs the ticket's current state again (`Forge.Engine.retry/2`): after a failure, or after a
  success whose documents a person wants done afresh.
  """
  @spec retry(Ticket.t(), User.t()) :: {:ok, Ticket.t()} | {:error, term()}
  def retry(%Ticket{} = ticket, %User{} = user) do
    with :ok <- allow(ticket, user, :use),
         {:ok, ticket} <- Engine.retry(ticket, user.id) do
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
  @spec cancel(Ticket.t(), User.t()) :: {:ok, Ticket.t()} | {:error, term()}
  def cancel(%Ticket{} = ticket, %User{} = user) do
    with :ok <- allow(ticket, user, :use),
         {:ok, ticket} <- Engine.cancel(ticket, user.id) do
      notify(ticket)
    end
  end

  @doc "Brings a cancelled ticket back, stuck in the state it was in (`Forge.Engine.restore/2`)."
  @spec restore(Ticket.t(), User.t()) :: {:ok, Ticket.t()} | {:error, term()}
  def restore(%Ticket{} = ticket, %User{} = user) do
    with :ok <- allow(ticket, user, :use),
         {:ok, ticket} <- Engine.restore(ticket, user.id) do
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
  @spec edit(Ticket.t(), User.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, Ticket.t()} | {:error, term()}
  def edit(%Ticket{} = ticket, %User{} = user, name, content, base \\ nil) do
    with :ok <- allow(ticket, user, :use),
         {:ok, _version} <-
           Forge.Repo.transact(fn -> write_version(ticket, user, name, content, base) end) do
      notify(ticket)
    end
  end

  # Read inside the transaction that writes, so what is checked is what is overwritten.
  defp write_version(ticket, user, name, content, base) do
    with :ok <- current?(ticket, name, base) do
      Artifacts.record_version(ticket.id, name, :document, {:user, user.id}, %{content: content})
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
  """
  @spec admit(Project.t(), User.t(), map()) :: {:ok, Ticket.t()} | {:error, term()}
  def admit(%Project{} = project, %User{} = user, attrs) do
    with :ok <- allow(project, user, :use) do
      Tickets.admit(project, attrs, {:user, user.id})
    end
  end

  ## Conversations

  @doc "Opens a conversation on a project."
  @spec open_chat(Project.t(), User.t(), String.t(), keyword()) ::
          {:ok, Job.t()} | {:error, term()}
  def open_chat(%Project{} = project, %User{} = user, text, opts \\ []) do
    with :ok <- allow(project, user, :use) do
      Conversations.open(project, text, Keyword.put_new(opts, :actor, {:user, user.id}))
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
    with :ok <- allow(chat, user, :use), do: Conversations.send(chat, text, opts)
  end

  @doc """
  Answers the questions of a conversation's last reply, as one message
  (`Forge.Conversations.answer_text/2`). `reply` is the `Forge.Conversations.reply_ref/1` of the
  reply the form was drawn for: when the last reply is another one, nothing is sent and the
  answer is `{:error, :stale}`, because the conversation moved on while the form was open.
  """
  @spec answer_chat(Job.t(), User.t(), String.t(), %{String.t() => map()}) ::
          {:ok, term()} | {:error, term()}
  def answer_chat(%Job{kind: :chat} = chat, %User{} = user, reply, answers) do
    with :ok <- allow(chat, user, :use),
         messages = Conversations.messages(chat.id),
         true <-
           (reply != nil and Conversations.reply_ref(messages) == reply) || {:error, :stale},
         {:ok, text} <-
           Conversations.answer_text(Conversations.questions(List.last(messages)), answers) do
      Conversations.send(chat, text)
    end
  end

  @doc "Interrupts a running conversation."
  @spec stop_chat(Job.t(), User.t()) :: :ok | {:error, term()}
  def stop_chat(%Job{kind: :chat} = chat, %User{} = user) do
    with :ok <- allow(chat, user, :use), do: Conversations.stop(chat)
  end

  @doc "Ends a conversation."
  @spec close_chat(Job.t(), User.t(), String.t()) :: :ok | {:error, term()}
  def close_chat(%Job{kind: :chat} = chat, %User{} = user, reason \\ "closed") do
    with :ok <- allow(chat, user, :use), do: Conversations.close(chat, reason)
  end

  @doc "Reopens an ended conversation."
  @spec reopen_chat(Job.t(), User.t()) :: {:ok, Job.t()} | {:error, term()}
  def reopen_chat(%Job{kind: :chat} = chat, %User{} = user) do
    with :ok <- allow(chat, user, :use), do: Conversations.reopen(chat)
  end

  @doc "Merges a conversation's branch."
  @spec merge_chat(Job.t(), User.t()) :: {:ok, term()} | {:error, term()}
  def merge_chat(%Job{kind: :chat} = chat, %User{} = user) do
    with :ok <- allow(chat, user, :use),
         {:ok, %{sha: sha, already: already}} = merged <- Forge.Merge.perform_chat(chat, user) do
      # What the merge did to the project's open tickets (`Forge.Merge.Watch`). Nothing moved when
      # the branch was already there.
      unless already,
        do: Forge.Merge.Watch.after_merge(chat.project_id, sha, %{"chat" => chat.id})

      merged
    end
  end

  ## Project settings — the admin's, not the member's

  @doc "Sets the project's default model."
  @spec set_model(Project.t(), User.t(), String.t() | nil) ::
          {:ok, Project.t()} | {:error, term()}
  def set_model(%Project{} = project, %User{} = user, model) do
    with :ok <- allow(project, user, :manage), do: Projects.set_model(project, model)
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

  @doc "Mints a git token for the project's repository."
  @spec issue_token(Project.t(), User.t(), keyword()) ::
          {:ok, String.t(), Forge.Git.Token.t()} | {:error, term()}
  def issue_token(%Project{} = project, %User{} = user, opts) do
    with :ok <- allow(project, user, :manage), do: Forge.Git.Tokens.issue(project, opts)
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
         true <- Enum.any?(Forge.Git.Tokens.list(project), &(&1.id == token_id)) do
      Forge.Git.Tokens.revoke(token_id)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  @doc """
  Accepts a ticket proposal, admitting it as a ticket.

  Unlike every other operation here it does not return the ticket it was about — it returns the
  ticket it *made*, which is a different one. A proposal belongs to the job that wrote it rather
  than to a ticket, and a project chat's proposal has no ticket anywhere near it.
  """
  @spec accept_proposal(String.t(), User.t(), String.t() | nil, String.t() | nil) ::
          {:ok, Ticket.t()} | {:error, term()}
  def accept_proposal(version_id, %User{} = user, comment \\ nil, ticket_type \\ nil) do
    with :ok <- allow_proposal(version_id, user),
         {:ok, %Ticket{} = ticket} <-
           Proposals.accept(version_id, user.id, comment, ticket_type) do
      # Both: the ticket the proposal came out of has a page that lists it, and the ticket it
      # became has one of its own that nobody is looking at yet.
      notify_origin(version_id)
      notify(ticket)
    end
  end

  @doc "Declines a ticket proposal. Recorded, so the next job does not propose it again."
  @spec decline_proposal(String.t(), User.t(), String.t() | nil) ::
          {:ok, Forge.Proposals.Decision.t()} | {:error, term()}
  def decline_proposal(version_id, %User{} = user, comment \\ nil) do
    with :ok <- allow_proposal(version_id, user),
         {:ok, decision} <- Proposals.decline(version_id, user.id, comment) do
      notify_origin(version_id)
      {:ok, decision}
    end
  end

  # Every operation above resolves to a project the same way the objects do: a ticket carries
  # one, a proposal reaches one through the job that wrote it. There is no object here that
  # cannot answer, which is why the check is always the same two lines.
  defp allow(%Ticket{} = ticket, %User{} = user, capability),
    do: allow(Tickets.project_of(ticket), user, capability)

  defp allow(%Job{project_id: project_id}, %User{} = user, capability),
    do: allow(Projects.get!(project_id), user, capability)

  defp allow(%Project{} = project, %User{} = user, capability) do
    scope = Scope.for_project(Scope.for_user(user), project)
    Access.ensure(scope, capability)
  end

  defp allow_proposal(version_id, %User{} = user) do
    case Proposals.get(version_id) do
      %{job: %{project_id: project_id}} when is_binary(project_id) ->
        scope = Scope.for_project(Scope.for_user(user), Forge.Projects.get!(project_id))
        # `:not_found`, not `:forbidden`: a proposal in someone else's project has to answer the
        # same way as one that does not exist, or the refusal itself says it exists.
        if Access.can?(scope, :use), do: :ok, else: {:error, :not_found}

      _absent ->
        # Let the operation report it. It already says not_found, and duplicating that here
        # would mean two places deciding what a missing proposal looks like.
        :ok
    end
  end

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
