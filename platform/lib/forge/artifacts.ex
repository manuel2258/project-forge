defmodule Forge.Artifacts do
  @moduledoc """
  Artifacts and their immutable versions, the questions extracted from documents, the
  answers people give, and approvals. Every write goes through a multi with its event.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Forge.Artifacts.{Answer, Approval, Artifact, Question, Version}
  alias Forge.{Events, Repo}
  alias ForgeCore.Document

  @answers ForgeCore.Workflow.answers_artifact()

  @type author :: Events.actor()

  # -- writing versions ---------------------------------------------------------------------

  @doc """
  Adds the steps that record a new version of `name` on the ticket to `multi`, under keys
  `{key, :artifact}`, `{key, :version}`, `{key, :questions}` and `{key, :event}`.
  Documents must parse and their questions are extracted, unless `attrs.parse` is false
  (the ticket body and `answers.md` are prose the platform never reads back as structure).
  `attrs.content_hash` overrides the computed hash, for blobs whose content lives elsewhere.
  """
  @spec put_version(
          Multi.t(),
          term(),
          String.t(),
          String.t(),
          :document | :blob | :presentation,
          author(),
          map()
        ) ::
          Multi.t()
  def put_version(multi, key, ticket_id, name, kind, author, attrs) do
    multi
    |> Multi.run({key, :artifact}, fn repo, _ ->
      get_or_create_artifact(repo, ticket_id, name, kind)
    end)
    |> Multi.run({key, :parsed}, fn _repo, _ ->
      if Map.get(attrs, :parse, true), do: parse_if_document(kind, attrs), else: {:ok, nil}
    end)
    |> Multi.run({key, :version}, fn repo, changes ->
      artifact = changes[{key, :artifact}]
      document = changes[{key, :parsed}]
      next = next_version(repo, artifact.id)

      version_attrs =
        attrs
        |> Map.take([:content, :blob_uri])
        |> Map.merge(%{
          artifact_id: artifact.id,
          version: next,
          author: Events.encode_actor(author),
          content_hash: Map.get(attrs, :content_hash) || hash(attrs),
          meta: (document && document.front_matter) || Map.get(attrs, :meta, %{})
        })

      repo.insert(Version.changeset(%Version{}, version_attrs))
    end)
    |> Multi.run({key, :questions}, fn repo, changes ->
      version = changes[{key, :version}]

      case changes[{key, :parsed}] do
        nil -> {:ok, []}
        document -> insert_questions(repo, version.id, document.questions)
      end
    end)
    |> Events.log({key, :event}, "artifact.version_written", author, fn changes ->
      version = changes[{key, :version}]

      %{
        ticket_id: ticket_id,
        job_id: job_id(author),
        payload: %{"artifact" => name, "version" => version.version, "version_id" => version.id}
      }
    end)
  end

  @doc "Records one version in its own transaction."
  @spec record_version(String.t(), String.t(), :document | :blob | :presentation, author(), map()) ::
          {:ok, Version.t()} | {:error, term()}
  def record_version(ticket_id, name, kind, author, attrs) do
    Multi.new()
    |> put_version(:write, ticket_id, name, kind, author, attrs)
    |> Repo.transaction()
    |> case do
      {:ok, changes} -> {:ok, changes[{:write, :version}]}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  defp get_or_create_artifact(repo, ticket_id, name, kind) do
    case repo.one(from a in Artifact, where: a.ticket_id == ^ticket_id and a.name == ^name) do
      nil ->
        repo.insert(
          Artifact.changeset(%Artifact{}, %{ticket_id: ticket_id, name: name, kind: kind})
        )

      %Artifact{kind: ^kind} = artifact ->
        {:ok, artifact}

      %Artifact{kind: other} ->
        {:error, {:kind_mismatch, name, other}}
    end
  end

  defp parse_if_document(:document, %{content: content}) when is_binary(content) do
    case Document.parse(content) do
      {:ok, document} -> {:ok, document}
      {:error, errors} -> {:error, {:invalid_document, errors}}
    end
  end

  defp parse_if_document(:document, _attrs), do: {:error, :document_requires_content}
  defp parse_if_document(_kind, _attrs), do: {:ok, nil}

  defp next_version(repo, artifact_id) do
    (repo.one(from v in Version, where: v.artifact_id == ^artifact_id, select: max(v.version)) ||
       0) + 1
  end

  defp insert_questions(repo, version_id, questions) do
    Enum.reduce_while(questions, {:ok, []}, fn question, {:ok, acc} ->
      attrs = Question.attrs_from_core(question, version_id)

      case repo.insert(Question.changeset(%Question{}, attrs)) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp hash(%{content: content}) when is_binary(content),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, content), case: :lower)

  defp hash(%{blob_uri: uri}) when is_binary(uri), do: "uri:" <> uri
  defp hash(_), do: "none"

  # -- reading --------------------------------------------------------------------------------

  @spec latest(String.t(), String.t()) :: Version.t() | nil
  def latest(ticket_id, name) do
    Repo.one(
      from v in Version,
        join: a in assoc(v, :artifact),
        where: a.ticket_id == ^ticket_id and a.name == ^name,
        order_by: [desc: v.version],
        limit: 1
    )
  end

  @spec versions(String.t(), String.t()) :: [Version.t()]
  def versions(ticket_id, name) do
    Repo.all(
      from v in Version,
        join: a in assoc(v, :artifact),
        where: a.ticket_id == ^ticket_id and a.name == ^name,
        order_by: v.version
    )
  end

  @spec get_version!(String.t()) :: Version.t()
  def get_version!(id), do: Repo.get!(Version, id)

  @spec list(String.t()) :: [Artifact.t()]
  def list(ticket_id),
    do: Repo.all(from a in Artifact, where: a.ticket_id == ^ticket_id, order_by: a.name)

  # -- questions and answers ----------------------------------------------------------------

  @doc """
  Unanswered questions on a ticket, blocking first. A question is identified by its
  artifact and key: it counts on the latest version of the artifact only, and it is answered
  once any version of that artifact received an answer for the key. An agent that keeps a
  question block after resuming therefore does not re-ask it.
  """
  @spec open_questions(String.t()) :: [Question.t()]
  def open_questions(ticket_id) do
    answered = answered_by_artifact(ticket_id)

    Repo.all(
      from q in Question,
        where: q.artifact_version_id in subquery(latest_version_ids(ticket_id)),
        order_by: [desc: q.blocking, asc: q.inserted_at],
        preload: [artifact_version: :artifact]
    )
    |> Enum.reject(fn q ->
      MapSet.member?(Map.get(answered, q.artifact_version.artifact_id, MapSet.new()), q.key)
    end)
  end

  @doc "Open blocking questions on the ticket, whichever version or author carries them."
  @spec open_blocking_questions(String.t()) :: [Question.t()]
  def open_blocking_questions(ticket_id),
    do: ticket_id |> open_questions() |> Enum.filter(& &1.blocking)

  @doc "Keys answered anywhere on the ticket, for the worker to treat as no longer blocking."
  @spec answered_keys(String.t()) :: [String.t()]
  def answered_keys(ticket_id) do
    ticket_id
    |> answered_by_artifact()
    |> Map.values()
    |> Enum.flat_map(&MapSet.to_list/1)
    |> Enum.uniq()
  end

  defp answered_by_artifact(ticket_id) do
    from(ans in Answer,
      join: q in assoc(ans, :question),
      join: v in assoc(q, :artifact_version),
      join: a in assoc(v, :artifact),
      where: a.ticket_id == ^ticket_id,
      select: {v.artifact_id, q.key}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {artifact_id, keys} -> {artifact_id, MapSet.new(keys)} end)
  end

  defp latest_version_ids(ticket_id) do
    from v in Version,
      join: a in assoc(v, :artifact),
      where: a.ticket_id == ^ticket_id,
      distinct: v.artifact_id,
      order_by: [asc: v.artifact_id, desc: v.version],
      select: v.id
  end

  @spec get_question!(String.t()) :: Question.t()
  def get_question!(id), do: Repo.get!(Question, id) |> Repo.preload(artifact_version: :artifact)

  @doc "Finds an open question on a ticket by its key."
  @spec find_open_question(String.t(), String.t()) :: Question.t() | nil
  def find_open_question(ticket_id, key) do
    Enum.find(open_questions(ticket_id), &(&1.key == key))
  end

  @doc """
  Answers a question: writes the answer row and a new version of the ticket's `answers.md`
  document listing every answer so far, in one transaction. Returns the answer.
  """
  @spec answer(Question.t(), String.t(), map()) :: {:ok, Answer.t()} | {:error, term()}
  def answer(%Question{} = question, user_id, attrs) do
    question = Repo.preload(question, artifact_version: :artifact)
    ticket_id = question.artifact_version.artifact.ticket_id
    choice = Map.get(attrs, :choice)
    text = Map.get(attrs, :text)

    content = render_answers(ticket_id, [{question, choice, text}])

    Multi.new()
    |> put_version(:answers, ticket_id, @answers, :document, {:user, user_id}, %{
      content: content,
      parse: false
    })
    |> Multi.insert(:answer, fn changes ->
      Answer.changeset(%Answer{}, %{
        question_id: question.id,
        user_id: user_id,
        choice: choice,
        text: text,
        artifact_version_id: changes[{:answers, :version}].id
      })
    end)
    |> Events.log(:event, "question.answered", {:user, user_id}, fn changes ->
      %{
        ticket_id: ticket_id,
        payload: %{
          "question_id" => question.id,
          "key" => question.key,
          "answer_id" => changes.answer.id
        }
      }
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{answer: answer}} -> {:ok, answer}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  @doc "Renders the ticket's answers so far, plus `pending` ones being written, as a document."
  @spec render_answers(String.t(), [{Question.t(), String.t() | nil, String.t() | nil}]) ::
          String.t()
  def render_answers(ticket_id, pending \\ []) do
    existing =
      Repo.all(
        from ans in Answer,
          join: q in assoc(ans, :question),
          join: v in assoc(q, :artifact_version),
          join: a in assoc(v, :artifact),
          where: a.ticket_id == ^ticket_id,
          order_by: ans.inserted_at,
          select: {q, ans.choice, ans.text}
      )

    entries =
      Enum.map_join(existing ++ pending, "\n", fn {question, choice, text} ->
        answer = [choice, text] |> Enum.reject(&is_nil/1) |> Enum.join(" — ")
        "## #{question.key}\n\nQ: #{question.text}\n\nA: #{answer}\n"
      end)

    "# Answers\n\nDecisions a person made on this ticket, oldest first.\n\n" <> entries
  end

  @doc """
  Records the branch head as a version of the `changeset` artifact, so approvals can attach
  to the exact commit that was reviewed.
  """
  @spec put_changeset(Multi.t(), term(), String.t(), author(), String.t()) :: Multi.t()
  def put_changeset(multi, key, ticket_id, author, head_sha) do
    put_version(multi, key, ticket_id, ForgeCore.Workflow.changeset_artifact(), :blob, author, %{
      blob_uri: "git:" <> head_sha,
      content_hash: "git:" <> head_sha
    })
  end

  # -- approvals ------------------------------------------------------------------------------

  @spec put_approval(
          Multi.t(),
          term(),
          Version.t(),
          String.t(),
          :approved | :rejected,
          map(),
          String.t() | nil
        ) ::
          Multi.t()
  def put_approval(multi, key, %Version{} = version, user_id, decision, transition, comment) do
    multi
    |> Multi.insert(
      key,
      Approval.changeset(%Approval{}, %{
        artifact_version_id: version.id,
        user_id: user_id,
        decision: decision,
        transition: transition,
        comment: comment
      })
    )
  end

  @spec approvals(String.t()) :: [Approval.t()]
  def approvals(version_id),
    do:
      Repo.all(
        from ap in Approval,
          where: ap.artifact_version_id == ^version_id,
          order_by: ap.inserted_at
      )

  # -- helpers --------------------------------------------------------------------------------

  defp job_id({:job, id}), do: id
  defp job_id(_), do: nil
end
