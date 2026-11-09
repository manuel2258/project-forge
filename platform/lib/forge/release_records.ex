defmodule Forge.ReleaseRecords do
  @moduledoc """
  The history of a project's releases (`docs/design/ticket-types.md` § The record, the tag, the
  history): one record per release ticket that ended `done`, written once, with the tag the platform
  made on its commit.

  Named for what it holds; `Forge.Release` is the release tasks and `Forge.ReleaseTickets` the
  ticket a release is.

  `conclude/2` is the only writer. It is called by the engine where a release reaches `done` and
  **never fails what called it**: whatever goes wrong becomes the record's own words (a tag that was
  not made) or a log line, and the release stays `done` and merged.
  """

  import Ecto.Query

  alias Forge.{Artifacts, Events, Git, Projects, ReleaseTickets, Repo, Storage, Tickets}
  alias Forge.Artifacts.Version
  alias Forge.Jobs.Job
  alias Forge.Projects.Project
  alias Forge.ReleaseRecords.{Record, Tag}
  alias Forge.Tickets.Ticket
  alias ForgeCore.Document
  alias ForgeCore.Workflow

  require Logger

  # Bounds on what a document can put on a record. A label or a URL is shown to every member of the
  # project, and a list read entry by entry still has to end somewhere.
  @label_bytes 200
  @url_bytes 2048
  @links_per_document 50

  @doc """
  Writes the record of `ticket`'s release, if it has just concluded, and returns it.

  `commit` is the sha the merge produced or found, or `:head` for a release whose workflow merged
  nothing, resolved to the default branch's head now. Does nothing (`:skipped`) unless the ticket
  pinned `release: true` and is `done` — read from the database, not from the struct given, which
  a merge entered with the status it had before — and returns the record already there for a
  ticket that has one, so a second conclusion changes nothing.
  """
  @spec conclude(Ticket.t(), String.t() | :head) ::
          {:ok, Record.t()} | :skipped | {:error, term()}
  def conclude(%Ticket{id: id} = given, commit) do
    # The pin is the ticket's for life, so the struct given answers "is it a release" and spares
    # every transition of every ticket a query; only the status needs the database.
    with true <- ReleaseTickets.release?(given),
         %Ticket{status: :done} = ticket <- Repo.get(Ticket, id) do
      write(ticket, commit)
    else
      _not_a_concluded_release -> :skipped
    end
  end

  defp write(ticket, commit) do
    case Repo.get_by(Record, ticket_id: ticket.id) do
      %Record{} = record -> {:ok, record}
      nil -> build_and_insert(ticket, commit)
    end
  rescue
    # A record can never un-merge or stick the release, so whatever raises here (a database error,
    # a value the table refuses) is logged and answered as an error to a caller that ignores it.
    error ->
      Logger.error("release record for ticket #{ticket.id} failed: #{Exception.message(error)}")
      {:error, error}
  end

  defp build_and_insert(ticket, commit) do
    project = Projects.get!(ticket.project_id)
    repo = Projects.repo_path(project)

    case commit_sha(repo, project, commit) do
      {:ok, sha} -> build_record(ticket, project, sha)
      {:error, reason} -> no_commit(ticket, reason)
    end
  end

  defp no_commit(ticket, reason) do
    Logger.error("release record for ticket #{ticket.id}: no commit: #{inspect(reason)}")
    {:error, reason}
  end

  defp build_record(ticket, project, sha) do
    workflow = Tickets.workflow(ticket)
    notes = notes(ticket, workflow)
    version = ReleaseTickets.renamed_version(ticket)

    attrs =
      %{
        project_id: project.id,
        ticket_id: ticket.id,
        version: version,
        concluded_at: DateTime.utc_now(),
        commit_sha: sha,
        files: files(ticket, workflow),
        links: links(ticket)
      }
      |> Map.merge(notes)
      |> Map.merge(tag(project, version, sha, notes.notes))

    insert(ticket, attrs)
  end

  defp commit_sha(_repo, _project, sha) when is_binary(sha), do: {:ok, sha}

  defp commit_sha(repo, %Project{default_branch: branch}, :head),
    do: Git.resolve(repo, "refs/heads/" <> branch)

  defp insert(ticket, attrs) do
    candidate = struct(Record, attrs)

    case Repo.insert(candidate, on_conflict: :nothing, conflict_target: :ticket_id) do
      {:ok, %Record{id: id}} ->
        # The id is generated here, so the struct comes back with one whether or not the row went
        # in; the row for the ticket is what says which conclusion won. A conclusion that lost the
        # race to the unique index returns the winner's record and announces nothing. No test
        # races two: the sandbox gives a test the one connection, so the lost branch is an
        # equivalent mutant of "announce every time" that nothing can tell apart.
        case Repo.get_by!(Record, ticket_id: ticket.id) do
          %Record{id: ^id} = record ->
            Events.notify(ticket.id)
            {:ok, record}

          %Record{} = winner ->
            {:ok, winner}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # -- the tag ---------------------------------------------------------------------------------

  defp tag(_project, nil, _sha, _notes),
    do: %{tag_name: nil, tag_status: :no_version, tag_detail: "no version was known"}

  defp tag(project, version, sha, notes) do
    case Tag.make(project, version, sha, notes) do
      {:tagged, name} -> %{tag_name: name, tag_status: :tagged, tag_detail: nil}
      {:taken, name, other} -> %{tag_name: name, tag_status: :taken, tag_detail: other}
      {:failed, name, reason} -> %{tag_name: name, tag_status: :failed, tag_detail: reason}
    end
  end

  # -- notes -----------------------------------------------------------------------------------

  defp notes(ticket, %Workflow{release_notes: name}) when is_binary(name) do
    with %Version{content: text, version: version} when is_binary(text) <-
           Artifacts.latest(ticket.id, name),
         body when body != "" <- String.trim(Document.body(text)) do
      %{notes: body, notes_document: name, notes_version: version}
    else
      _none -> no_notes()
    end
  end

  defp notes(_ticket, %Workflow{}), do: no_notes()

  defp no_notes, do: %{notes: nil, notes_document: nil, notes_version: nil}

  # -- files -----------------------------------------------------------------------------------

  # Per named group, the files written by the last job that wrote any of the group. A rebuild
  # with other file names would otherwise leave the first build's files beside it.
  defp files(ticket, %Workflow{release_files: groups}) do
    groups
    |> Enum.flat_map(fn group -> group_files(ticket, Workflow.group_name(group)) end)
  end

  # Two filters below are equivalent mutants, kept so the query says what it means:
  #
  #   * `a.kind == :blob`: only a group's file is named `group/file`, and a workflow cannot
  #     declare a document or presentation with a slash in its name
  #     (`Workflow.document_name_error/1`).
  #   * the author's `"kind" == "job"`: the join on `Job` already drops a person's, a token's or
  #     the system's version, whose id is a user's, a token's or none, never a job's.
  #
  # No test can tell either away.
  defp group_files(ticket, group) do
    prefix = group <> "/"

    rows =
      Repo.all(
        from v in Version,
          join: a in assoc(v, :artifact),
          join: j in Job,
          on: j.id == type(fragment("(?->>'id')", v.author), :binary_id),
          where:
            a.ticket_id == ^ticket.id and a.kind == :blob and
              fragment("starts_with(?, ?)", a.name, ^prefix) and
              fragment("?->>'kind'", v.author) == "job",
          select: {a.name, v, j.id, j.inserted_at}
      )

    case rows do
      [] ->
        []

      rows ->
        {_name, _version, last_job, _at} =
          Enum.max_by(rows, fn {_n, _v, _j, at} -> at end, DateTime)

        rows
        |> Enum.filter(fn {_name, _version, job, _at} -> job == last_job end)
        |> Enum.group_by(fn {name, _version, _job, _at} -> name end)
        |> Enum.map(fn {name, versions} ->
          {_name, version, _job, _at} = Enum.max_by(versions, fn {_n, v, _j, _a} -> v.version end)
          %{"name" => name, "version" => version.version, "size" => size(version)}
        end)
        |> Enum.sort_by(& &1["name"])
    end
  end

  defp size(%Version{blob_uri: uri}) do
    with {:ok, key} <- Storage.key_from_uri(uri || ""),
         {:ok, %{size: size}} <- Storage.stat(key) do
      size
    else
      _unreadable -> nil
    end
  end

  # -- links -----------------------------------------------------------------------------------

  # The latest version of each document, when a job that is not a conversation wrote it: the
  # `version:` rule (`ReleaseTickets.put_rename/4`). A person's later edit carrying `links:` does not
  # publish them, and neither does a chat step's document.
  defp links(ticket) do
    latest =
      from v in Version,
        group_by: v.artifact_id,
        select: %{artifact_id: v.artifact_id, version: max(v.version)}

    Repo.all(
      from v in Version,
        join: a in assoc(v, :artifact),
        join: l in subquery(latest),
        on: l.artifact_id == v.artifact_id and l.version == v.version,
        join: j in Job,
        on: j.id == type(fragment("(?->>'id')", v.author), :binary_id),
        where:
          a.ticket_id == ^ticket.id and a.kind in [:document, :presentation] and
            fragment("?->>'kind'", v.author) == "job" and j.kind != :chat,
        order_by: a.name,
        select: {a.name, v.version, v.meta}
    )
    |> Enum.flat_map(fn {name, version, meta} ->
      for {label, url} <- entries(meta),
          do: %{"label" => label, "url" => url, "document" => name, "version" => version}
    end)
  end

  defp entries(%{"links" => links}) when is_list(links) do
    links
    |> Enum.take(@links_per_document)
    |> Enum.flat_map(fn
      %{"label" => label, "url" => url} when is_binary(label) and is_binary(url) ->
        if label?(label) and url?(url), do: [{label, url}], else: []

      _malformed ->
        []
    end)
  end

  defp entries(_meta), do: []

  defp label?(label), do: String.trim(label) != "" and byte_size(label) <= @label_bytes

  # Absolute, http or https, with a host, and nothing a browser would read differently from the
  # URI parser: no whitespace or control character anywhere in it.
  defp url?(url) do
    byte_size(url) <= @url_bytes and not String.match?(url, ~r/[\s[:cntrl:]]/u) and
      match?(
        %URI{scheme: scheme, host: host}
        when scheme in ["http", "https"] and host not in [nil, ""],
        URI.parse(url)
      )
  end

  # -- reading ---------------------------------------------------------------------------------

  @doc "The project's newest `limit` records, newest first, each with its ticket."
  @spec list(Project.t(), pos_integer()) :: [Record.t()]
  def list(%Project{id: id}, limit) do
    Repo.all(
      from r in Record,
        where: r.project_id == ^id,
        order_by: [desc: r.concluded_at, desc: r.inserted_at, desc: r.id],
        limit: ^limit,
        preload: :ticket
    )
  end

  @doc "How many records the project has."
  @spec count(Project.t()) :: non_neg_integer()
  def count(%Project{id: id}),
    do: Repo.aggregate(from(r in Record, where: r.project_id == ^id), :count)

  @doc "The project's newest record, or nil."
  @spec latest(Project.t()) :: Record.t() | nil
  def latest(%Project{} = project), do: project |> list(1) |> List.first()

  @doc """
  One of the project's records. An id that is not one, or names no record of this project, raises
  `Ecto.NoResultsError`, which is a 404: the same answer for a record that is not there and one
  that is another project's.
  """
  @spec get!(Project.t(), String.t()) :: Record.t()
  def get!(%Project{id: project_id}, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Repo.one!(
          from r in Record, where: r.id == ^uuid and r.project_id == ^project_id, preload: :ticket
        )

      :error ->
        raise Ecto.NoResultsError, queryable: Record
    end
  end
end
