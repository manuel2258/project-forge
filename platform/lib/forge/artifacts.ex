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
      if Map.get(attrs, :parse, true), do: parse_if_prose(kind, attrs), else: {:ok, nil}
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

  @git_prefix "git:"

  @doc """
  The commit a version points at, or nil when it does not point at one.

  `changeset` is a blob whose `blob_uri` is the commit it was taken at, and before this the
  prefix was spelled out at six call sites across `platform/lib` — three of them reading the sha
  back out, each with its own fallback for a `blob_uri` that is not one. One definition, read
  here and written by `put_changeset/5`.
  """
  @spec commit(Version.t() | nil) :: String.t() | nil
  def commit(%Version{blob_uri: @git_prefix <> sha}), do: sha
  def commit(_version), do: nil

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

  # A presentation is parsed exactly as a document is, and for the whole of the reason the
  # grammar gives: it differs only in the kind it is recorded under
  # (`docs/design/workflow-grammar-v1.md` § Semantics). Without it the front matter would not
  # reach `meta` and — the part that matters — `insert_questions/3` is the only writer of question
  # rows anywhere, so a blocking question in a presentation would park its job with nothing on any
  # surface to answer, and no transition out while the job is live.
  defp parse_if_prose(kind, %{content: content})
       when kind in [:document, :presentation] and is_binary(content) do
    case Document.parse(content) do
      {:ok, document} -> {:ok, document}
      {:error, errors} -> {:error, {:invalid_document, errors}}
    end
  end

  defp parse_if_prose(kind, _attrs) when kind in [:document, :presentation],
    do: {:error, :document_requires_content}

  defp parse_if_prose(_kind, _attrs), do: {:ok, nil}

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
  which a reopen would otherwise lose from view: every reopen, resumed or cold, clears `out/`. Documents only — a blob is in the store and a changeset is a commit, and neither
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

  @doc """
  Every artifact of a ticket with all its versions, oldest first, as `{artifact, [version]}` and
  in two queries however many there are — the listing the API serves for a ticket with hundreds of
  versions, where one query per artifact would be hundreds of round trips.
  """
  @spec versions_for_ticket(String.t()) :: [{Artifact.t(), [Version.t()]}]
  def versions_for_ticket(ticket_id) do
    # The `a.ticket_id` filter only bounds the cost: grouping by artifact and looking up each of the
    # ticket's own artifacts below would answer the same without it, so dropping it is an
    # equivalent mutant.
    by_artifact =
      Repo.all(
        from v in Version,
          join: a in assoc(v, :artifact),
          where: a.ticket_id == ^ticket_id,
          order_by: [asc: v.artifact_id, asc: v.version]
      )
      |> Enum.group_by(& &1.artifact_id)

    for artifact <- list(ticket_id), do: {artifact, Map.get(by_artifact, artifact.id, [])}
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
  def content(%Version{blob_uri: @git_prefix <> _sha}), do: {:error, :not_a_file}
  def content(%Version{}), do: {:error, :not_found}

  @doc """
  A version as the addressable-version route serves it (`docs/design/ui.md` § Addressable artifact
  versions): `{:text, bytes}` for a document, or a blob that is text no larger than a document
  may be; `{:bytes, bytes}` for a small blob that is not text; and `{:file, path}` for a larger
  blob, fetched from the store into `path` rather than read into memory — a build, a package. The
  caller chooses `path` (a `Plug.Upload.random_file/1`, which Plug deletes when the request dies)
  and removes the file once it is sent.
  """
  @spec served(Version.t(), Path.t()) ::
          {:text, binary()} | {:bytes, binary()} | {:file, Path.t()} | {:error, term()}
  def served(%Version{blob_uri: "store:" <> _rest = uri} = version, path) do
    with {:ok, key} <- key(uri),
         {:ok, %{size: size}} <- Storage.stat(key) do
      if size <= ForgeCore.Document.max_bytes(),
        do: small(version),
        else: fetched(key, path)
    end
  end

  def served(%Version{} = version, _path), do: small(version)

  defp small(version) do
    with {:ok, bytes} <- content(version) do
      if ForgeCore.Document.text?(bytes), do: {:text, bytes}, else: {:bytes, bytes}
    end
  end

  defp fetched(key, path) do
    case Storage.fetch(key, path) do
      {:ok, _info} -> {:file, path}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  A version read as text an agent or a page can hold: whole when it is at most `head + tail` bytes,
  and otherwise its first `head` and last `tail` bytes with how much was cut named between them.
  Bytes that are not UTF-8, and NUL, which Postgres will not store in JSON, become U+FFFD.

  What a state that reads a command's log is handed as its input (`docs/design/workflow-grammar-v1.md`
  § Inputs), and what the ticket page shows of a failed command's log. Both ends, not one: a build
  says what it was doing at the top and why it stopped at the bottom. Read with two ranged reads
  (`Forge.Storage.read_range/3`) and nothing else: the ticket page asks this on every load, and
  `Storage.stat/1` hashes the whole object, which for a large build log is seconds.
  """
  @spec excerpt(Version.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def excerpt(%Version{blob_uri: "store:" <> _rest = uri}, head, tail) do
    with {:ok, key} <- key(uri),
         {:ok, %{size: size, bytes: bytes}} <- Storage.read_range(key, 0, head + tail) do
      if size <= head + tail,
        do: {:ok, printable(bytes)},
        else: with_tail(key, size, binary_part(bytes, 0, head), tail)
    end
  end

  def excerpt(%Version{} = version, _head, _tail) do
    with {:ok, bytes} <- content(version), do: {:ok, printable(bytes)}
  end

  defp with_tail(key, size, first, tail) do
    with {:ok, %{bytes: last}} <- Storage.read_range(key, size - tail, tail) do
      {:ok, cut(size, lines(first, &up_to_last_line/1), lines(last, &from_first_line/1))}
    end
  end

  # Cut on line boundaries where the log has lines, so neither end starts or stops half way
  # through one — unless the cut would leave nothing to show. A log that ends in one line longer
  # than the tail, or with its only newline at the very end, is the shape a build's failure
  # often has, and the line it ended on is the one worth reading: that end is kept as the bytes
  # fall rather than cut away to the marker alone.
  defp lines(bytes, cut) do
    kept = cut.(bytes)
    if String.trim(kept) == "", do: bytes, else: kept
  end

  defp up_to_last_line(bytes) do
    case :binary.matches(bytes, "\n") do
      [] -> bytes
      matches -> binary_part(bytes, 0, elem(List.last(matches), 0) + 1)
    end
  end

  defp from_first_line(bytes) do
    case :binary.match(bytes, "\n") do
      :nomatch -> bytes
      {at, 1} -> binary_part(bytes, at + 1, byte_size(bytes) - at - 1)
    end
  end

  defp cut(size, first, last) do
    gone = size - byte_size(first) - byte_size(last)
    first = if first == "" or String.ends_with?(first, "\n"), do: first, else: first <> "\n"
    printable(first) <> "[… #{gone} bytes cut, of #{size} …]\n" <> printable(last)
  end

  defp printable(bytes), do: bytes |> String.replace_invalid() |> String.replace(<<0>>, "\uFFFD")

  defp key(uri) do
    case Storage.key_from_uri(uri) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, :not_found}
    end
  end

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
  @spec answer(Question.t(), Forge.Actor.t() | String.t(), map()) ::
          {:ok, Answer.t()} | {:error, term()}
  def answer(%Question{} = question, who, attrs) do
    with {:ok, [answer]} <- answer_all([{question, attrs}], who), do: {:ok, answer}
  end

  @doc """
  Answers several questions on one ticket at once: an answer row and a `question.answered` event
  each, and **one** new version of `answers.md` holding them all, in one transaction. Returns the
  answers in the order given.

  Each answer is a `choice`, a `text`, or both — a note beside the choice. A blank text is no
  text. A `choice` must be one of the question's labels: the pages only offer those, and the API
  and `mix forge.answer` take whatever they are sent, so the rule lives here where every answer
  passes (`docs/design/job-prompt.md` § Answering a document's questions at once).
  """
  @spec answer_all([{Question.t(), map()}], Forge.Actor.t() | String.t()) ::
          {:ok, [Answer.t()]} | {:error, term()}
  def answer_all([_ | _] = entries, who) do
    actor = Forge.Actor.of(who)

    entries = Enum.map(entries, fn {question, attrs} -> entry(question, attrs) end)

    with :ok <- valid_answers(entries) do
      [{first, _choice, _text} | _rest] = entries
      ticket_id = first.artifact_version.artifact.ticket_id
      content = render_answers(ticket_id, entries)

      entries
      |> Enum.with_index()
      |> Enum.reduce(
        put_version(Multi.new(), :answers, ticket_id, @answers, :document, actor, %{
          content: content,
          parse: false
        }),
        fn {entry, index}, multi -> put_answer(multi, index, entry, ticket_id, actor) end
      )
      |> Repo.transaction()
      |> case do
        {:ok, changes} -> {:ok, Enum.map(0..(length(entries) - 1), &changes[{:answer, &1}])}
        {:error, _step, reason, _} -> {:error, reason}
      end
    end
  end

  defp entry(question, attrs) do
    {Repo.preload(question, artifact_version: :artifact), Answer.blank(Map.get(attrs, :choice)),
     Answer.blank(Map.get(attrs, :text))}
  end

  defp valid_answers(entries), do: Enum.find_value(entries, :ok, &invalid_answer/1)

  defp invalid_answer({question, choice, text}) do
    cond do
      # A client sends JSON, which can put an object where text is meant; `answers.md` is text.
      not (text?(choice) and text?(text)) ->
        {:error, {:invalid_answer, question.key}}

      is_nil(choice) and is_nil(text) ->
        {:error, {:empty_answer, question.key}}

      choice && not ForgeCore.Document.Question.offers?(question, choice) ->
        {:error, {:not_an_option, question.key, choice}}

      true ->
        nil
    end
  end

  defp text?(value), do: is_nil(value) or is_binary(value)

  defp put_answer(multi, index, {question, choice, text}, ticket_id, actor) do
    multi
    |> Multi.insert({:answer, index}, fn changes ->
      Answer.changeset(
        %Answer{},
        Map.merge(Forge.Actor.columns(actor), %{
          question_id: question.id,
          choice: choice,
          text: text,
          artifact_version_id: changes[{:answers, :version}].id
        })
      )
    end)
    |> Events.log({:event, index}, "question.answered", actor, fn changes ->
      %{
        ticket_id: ticket_id,
        payload: %{
          "question_id" => question.id,
          "key" => question.key,
          "answer_id" => changes[{:answer, index}].id
        }
      }
    end)
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
            version: pos_integer(),
            token_name: String.t() | nil
          }
        ]
  def answered(ticket_id) do
    Repo.all(
      from ans in Answer,
        join: q in assoc(ans, :question),
        join: v in assoc(q, :artifact_version),
        join: a in assoc(v, :artifact),
        left_join: t in assoc(ans, :token),
        where: a.ticket_id == ^ticket_id,
        order_by: ans.inserted_at,
        select: %{
          question: q,
          answer: ans,
          artifact: a.name,
          version: v.version,
          token_name: t.name
        }
    )
  end

  @doc "Renders the ticket's answers so far, plus `pending` ones being written, as a document."
  @spec render_answers(String.t(), [{Question.t(), String.t() | nil, String.t() | nil}]) ::
          String.t()
  def render_answers(ticket_id, pending \\ []) do
    existing =
      Enum.map(answered(ticket_id), fn row ->
        {%{
           row.question
           | artifact_version: %{version: row.version, artifact: %{name: row.artifact}}
         }, row.answer.choice, row.answer.text}
      end)

    entries =
      Enum.map_join(existing ++ pending, "\n", fn {question, choice, text} ->
        answer = Answer.reads(choice, text)

        "## #{question.key}\n\nQ: #{question.text}\n\nA: #{answer}\n" <>
          assumed(question, choice)
      end)

    "# Answers\n\nDecisions a person made on this ticket, oldest first.\n\n" <> entries
  end

  # `docs/design/job-prompt.md` § Non-blocking questions. A document written on an assumption is
  # immutable, and its answer lands here, beside it: every later job reads both, and without this
  # each re-derived which one holds. So the entry names the document and the assumption, and says
  # outright when the answer is a different option from the one assumed. An assumption in prose
  # cannot be compared with a choice, so that case is named and left to the reader. Only a
  # non-blocking question carries an assumption — the parser refuses one on a blocking question —
  # so the assumption alone is the match.
  defp assumed(%Question{assumption: assumption} = question, choice)
       when is_binary(assumption) do
    where = source(question)

    option? = ForgeCore.Document.Question.offers?(question, assumption)

    # `option?` is an equivalent mutant in the first clause: a choice is one of the options'
    # labels, so a choice equal to the assumption already says the assumption is one.
    cond do
      option? and choice == assumption ->
        "\n#{where} assumed `#{assumption}` and carried on; this confirms it.\n"

      option? and is_binary(choice) ->
        "\n**This overturns an assumption.** #{where} was written assuming `#{assumption}`#{at(question)}. " <>
          "Where it says otherwise, this answer holds, not the document.\n"

      true ->
        "\n#{where} was written assuming: #{assumption}#{at(question)}. " <>
          "Where this answer differs, the answer holds, not the document.\n"
    end
  end

  defp assumed(_question, _choice), do: ""

  defp source(%Question{artifact_version: %{version: version, artifact: %{name: name}}}),
    do: "`#{name}` version #{version}"

  # `anchor != ""` is an equivalent mutant: the parser refuses an empty anchor
  # (`ForgeCore.Document.Question`), so a stored question has a non-empty one or none.
  defp at(%Question{anchor: anchor}) when is_binary(anchor) and anchor != "",
    do: ", at the passage beginning \"#{String.slice(anchor, 0, 120)}\""

  defp at(_question), do: ""

  @doc """
  Records the branch head as a version of the `changeset` artifact, so approvals can attach
  to the exact commit that was reviewed.
  """
  @spec put_changeset(Multi.t(), term(), String.t(), author(), String.t()) :: Multi.t()
  def put_changeset(multi, key, ticket_id, author, head_sha) do
    put_version(multi, key, ticket_id, ForgeCore.Workflow.changeset_artifact(), :blob, author, %{
      blob_uri: @git_prefix <> head_sha,
      content_hash: @git_prefix <> head_sha
    })
  end

  # -- approvals ------------------------------------------------------------------------------

  @spec put_approval(
          Multi.t(),
          term(),
          Version.t(),
          Forge.Actor.t() | String.t(),
          :approved | :rejected,
          map(),
          String.t() | nil
        ) ::
          Multi.t()
  def put_approval(multi, key, %Version{} = version, who, decision, transition, comment) do
    multi
    |> Multi.insert(
      key,
      Approval.changeset(
        %Approval{},
        Map.merge(Forge.Actor.columns(who), %{
          artifact_version_id: version.id,
          decision: decision,
          transition: transition,
          comment: comment
        })
      )
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
