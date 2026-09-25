defmodule Forge.Artifacts do
  @moduledoc """
  Artifacts and their immutable versions, the questions extracted from documents, the
  answers people give, and approvals. Every write goes through a multi with its event.
  """

  import Ecto.Query, only: [from: 2, dynamic: 2]

  alias Ecto.Multi
  alias Forge.Artifacts.{Answer, Approval, Artifact, Question, Version}
  alias Forge.{Events, Repo, Storage}
  alias ForgeCore.Document

  @answers ForgeCore.Workflow.answers_artifact()

  @type author :: Events.actor()

  @typedoc """
  What an artifact belongs to: a ticket, or a conversation.

  A bare id means `{:ticket, id}`, which is what a bare id has meant since the product had
  artifacts at all — the ticket is still the scope almost everything here is about. It is one
  model with a shorthand, not two: every path below resolves to a scope before it touches a row,
  and the database has the matching CHECK.
  """
  @type scope :: {:ticket, String.t()} | {:job, String.t()} | String.t()

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
          scope(),
          String.t(),
          :document | :blob | :presentation,
          author(),
          map()
        ) ::
          Multi.t()
  def put_version(multi, key, scope, name, kind, author, attrs) do
    scope = scope(scope)

    multi
    |> Multi.run({key, :artifact}, fn repo, _ ->
      get_or_create_artifact(repo, scope, name, kind)
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
        ticket_id: ticket_of(scope),
        job_id: job_id(author) || job_of(scope),
        payload: %{"artifact" => name, "version" => version.version, "version_id" => version.id}
      }
    end)
  end

  defp scope(id) when is_binary(id), do: {:ticket, id}
  defp scope({kind, _id} = scope) when kind in [:ticket, :job], do: scope

  # One head per scope rather than a nil-valued comparison: `a.ticket_id == ^nil` compiles to
  # `= NULL`, which matches nothing, so every lookup on the chat side would miss and create a
  # second artifact of the same name — until the unique index refused it.
  defp scope_query({:ticket, id}, name),
    do: from(a in Artifact, where: a.ticket_id == ^id and a.name == ^name)

  defp scope_query({:job, id}, name),
    do: from(a in Artifact, where: a.job_id == ^id and a.name == ^name)

  defp ticket_of({:ticket, id}), do: id
  defp ticket_of({:job, _id}), do: nil

  defp job_of({:job, id}), do: id
  defp job_of({:ticket, _id}), do: nil

  # The columns a row of this scope carries. Exactly one is set, which the CHECK also says.
  defp scope_attrs({:ticket, id}), do: %{ticket_id: id, job_id: nil}
  defp scope_attrs({:job, id}), do: %{ticket_id: nil, job_id: id}

  @doc "Records one version in its own transaction."
  @spec record_version(scope(), String.t(), :document | :blob | :presentation, author(), map()) ::
          {:ok, Version.t()} | {:error, term()}
  def record_version(scope, name, kind, author, attrs) do
    Multi.new()
    |> put_version(:write, scope, name, kind, author, attrs)
    |> Repo.transaction()
    |> case do
      {:ok, changes} -> {:ok, changes[{:write, :version}]}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  defp get_or_create_artifact(repo, scope, name, kind) do
    case repo.one(scope_query(scope, name)) do
      nil ->
        attrs = scope |> scope_attrs() |> Map.merge(%{name: name, kind: kind})
        repo.insert(Artifact.changeset(%Artifact{}, attrs))

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

  @doc """
  The latest version of every document in one scope, with its name, newest artifact first. A bare
  id is a ticket, as everywhere here.

  This is the context a conversation opens with (`docs/design/conversations.md` § Context). On a
  ticket it is every document the ticket has — more than any one job is handed, which is the
  inputs its state declares. In a conversation's own scope it is what that conversation wrote,
  which a reopen would otherwise lose from view: a reopen is a cold start, and a cold start
  clears `out/`. Documents only — a blob is in the store and a changeset is a commit, and neither
  is something to inline into a prompt.
  """
  @spec latest_documents(scope()) :: [
          %{name: String.t(), version: pos_integer(), content: String.t()}
        ]
  def latest_documents(scope) do
    latest =
      from v in Version,
        group_by: v.artifact_id,
        select: %{artifact_id: v.artifact_id, version: max(v.version)}

    Repo.all(
      from v in Version,
        join: a in assoc(v, :artifact),
        as: :artifact,
        join: l in subquery(latest),
        on: l.artifact_id == v.artifact_id and l.version == v.version,
        where: ^in_scope(scope(scope)),
        where: a.kind == :document and not is_nil(v.content),
        # `artifact_versions` has no `updated_at` — a version is immutable, so its schema says
        # `updated_at: false`. Ordering by one compiled fine and failed at the database, on the
        # only path that reaches this: a ticket chat being assigned.
        order_by: [desc: v.inserted_at, asc: a.name],
        select: %{name: a.name, version: v.version, content: v.content}
    )
  end

  defp in_scope({:ticket, id}), do: dynamic([artifact: a], a.ticket_id == ^id)
  defp in_scope({:job, id}), do: dynamic([artifact: a], a.job_id == ^id)

  @doc """
  Every version of `name` in one scope, oldest first. A bare id is a ticket, as everywhere here;
  `{:job, id}` is a conversation's own. The address of a version names its scope
  (`docs/design/ui.md` § Addressable artifact versions), so nothing here looks in another one.
  """
  @spec versions(scope(), String.t()) :: [Version.t()]
  def versions(scope, name) do
    artifact_ids = from a in scope_query(scope(scope), name), select: a.id

    Repo.all(
      from v in Version,
        where: v.artifact_id in subquery(artifact_ids),
        order_by: v.version
    )
  end

  @doc "The artifact called `name` in a scope, or nil."
  @spec find(scope(), String.t()) :: Artifact.t() | nil
  def find(scope, name), do: Repo.one(scope_query(scope(scope), name))

  @doc """
  The newest version of `name` in a scope that `job_id` wrote, or nil — whatever anyone else has
  written since.

  What a conversation re-reports every turn is compared against this rather than against the
  artifact's latest: on a ticket that may be a job's or a person's since, and comparing against
  it would write the conversation's stale copy back over theirs (`docs/design/conversations.md`
  § Commits).
  """
  @spec latest_written(scope(), String.t(), String.t()) :: Version.t() | nil
  def latest_written(scope, name, job_id) do
    # The scope is an equivalent mutant, kept because a version's address is its scope: every
    # name a job writes is written in exactly one. Its documents go to its ticket's scope — or,
    # for a project chat, its own — and its proposals to its own under `proposal-`, a prefix no
    # document may take. So asked by author and name alone, the answer is the same version, and
    # no test can put one name by one author in a second scope.
    artifact_ids = from a in scope_query(scope(scope), name), select: a.id

    Repo.one(
      from v in Version,
        # The kind as well as the id says whose it is. No test can tell the kind away: a
        # person's id and a job's are both random UUIDs, and one never equals the other — an
        # equivalent mutant, kept because an author is the pair and not the id.
        where:
          v.artifact_id in subquery(artifact_ids) and
            fragment("?->>'kind'", v.author) == "job" and
            fragment("?->>'id'", v.author) == ^job_id,
        order_by: [desc: v.version],
        limit: 1
    )
  end

  @spec get_version!(String.t()) :: Version.t()
  def get_version!(id), do: Repo.get!(Version, id)

  @doc """
  The bytes of one version, wherever they live. A document carries its own text; a blob is in
  the store; a changeset is a commit and is not a file at all — `docs/design/ui.md`
  § Addressable artifact versions says the changeset links to the review page instead.

  `file://` is the milestone 1 form, written before the store existed and still present on old
  rows because `artifact_versions` is append-only. It is served, but only from inside the
  platform's own data directory: the path comes from a database column, and a column that can
  name any absolute path on the host is a file-read primitive waiting for its first bug.
  """
  @spec content(Version.t()) ::
          {:ok, binary()} | {:error, :not_a_file | :not_found | :outside_data_dir}
  def content(%Version{content: text}) when is_binary(text), do: {:ok, text}

  def content(%Version{blob_uri: "store:" <> _rest = uri}) do
    case Storage.key_from_uri(uri) do
      {:ok, key} -> Storage.get(key)
      :error -> {:error, :not_found}
    end
  end

  def content(%Version{blob_uri: "file://" <> path}), do: read_inside_data_dir(path)
  def content(%Version{blob_uri: "git:" <> _sha}), do: {:error, :not_a_file}
  def content(%Version{}), do: {:error, :not_found}

  defp read_inside_data_dir(path) do
    root = Path.expand(Forge.Jobs.config(:data_dir, "tmp/forge"))
    full = Path.expand(path)

    cond do
      not inside?(full, root) -> {:error, :outside_data_dir}
      linked?(full, root) -> {:error, :outside_data_dir}
      true -> read(full)
    end
  end

  defp inside?(full, root), do: full == root or String.starts_with?(full, root <> "/")

  # `Path.expand/1` is lexical — it collapses `..` and knows nothing about symlinks, while
  # `File.read/1` follows them. Without this, a link *inside* the data directory pointing
  # anywhere on the host passes the prefix check and its target is served: the confinement above
  # would have been decorative. Nothing the platform writes under the data directory is ever a
  # link, so one found on the way down is refused rather than resolved.
  defp linked?(full, root) do
    full
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.reduce_while(root, fn segment, dir ->
      candidate = Path.join(dir, segment)

      case File.lstat(candidate) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, :symlink}
        _other -> {:cont, candidate}
      end
    end)
    |> Kernel.==(:symlink)
  end

  defp read(full) do
    case File.read(full) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  @doc """
  Whether this exact version carries an approval.

  Approval attaches to a version, never to an artifact: a human edit creating v3 does not carry
  v2's approval, and `docs/design/ui.md` forbids the product from ever implying otherwise.
  """
  @spec approved?(Version.t() | nil) :: boolean()
  def approved?(nil), do: false
  def approved?(%Version{id: id}), do: id |> approvals() |> Enum.any?(&(&1.decision == :approved))

  @doc """
  Artifact names the pinned workflow can ever approve: every name in any transition's `approve`.

  The UI marks approval state only for these. An artifact no transition approves would otherwise
  sit marked `unapproved` for ever, which reads as a job for the operator and is not one — see
  `docs/design/ui.md` § Semantics that must not be lost.
  """
  @spec approvable(ForgeCore.Workflow.t() | nil) :: MapSet.t()
  def approvable(nil), do: MapSet.new()

  def approvable(%ForgeCore.Workflow{transitions: transitions}),
    do: transitions |> Enum.flat_map(& &1.approve) |> MapSet.new()

  @spec list(String.t()) :: [Artifact.t()]
  def list(ticket_id),
    do: Repo.all(from a in Artifact, where: a.ticket_id == ^ticket_id, order_by: a.name)

  @doc """
  Every version a job wrote, as `{artifact, version}`, by name.

  The job page needs what the run actually produced, not what its spec declared: a job that
  ended `error` for a missing output declared it and did not write it, and the difference
  between those two lists is the whole story of that job.
  """
  @spec written_by(String.t()) :: [{Artifact.t(), Version.t()}]
  def written_by(job_id) do
    Repo.all(
      from v in Version,
        join: a in assoc(v, :artifact),
        where: fragment("?->>'id'", v.author) == ^job_id,
        order_by: [a.name, v.version],
        select: {a, v}
    )
  end

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

  @doc """
  Every question a person answered on this ticket, oldest first, with the answer and the exact
  artifact version the question was asked against.
  """
  @spec answered(String.t()) :: [
          %{
            question: Question.t(),
            answer: Answer.t(),
            artifact: String.t(),
            version: pos_integer()
          }
        ]
  def answered(ticket_id) do
    Repo.all(
      from ans in Answer,
        join: q in assoc(ans, :question),
        join: v in assoc(q, :artifact_version),
        join: a in assoc(v, :artifact),
        where: a.ticket_id == ^ticket_id,
        order_by: ans.inserted_at,
        select: %{question: q, answer: ans, artifact: a.name, version: v.version}
    )
  end

  @doc "Renders the ticket's answers so far, plus `pending` ones being written, as a document."
  @spec render_answers(String.t(), [{Question.t(), String.t() | nil, String.t() | nil}]) ::
          String.t()
  def render_answers(ticket_id, pending \\ []) do
    existing =
      Enum.map(answered(ticket_id), &{&1.question, &1.answer.choice, &1.answer.text})

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
