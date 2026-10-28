defmodule Forge.Archive do
  @moduledoc """
  The project's past, composed for the worker to serve as a folder (`docs/design/archive.md`):
  what each ticket ever produced, in every version, and the ledger of the jobs that ran.

  **Every question about what the archive holds takes the project and scopes its query by it.** The
  project comes from the token row that authorised the request, never from anything in the path, so
  a ticket number or a version id of another project is not found — the same `:not_found` as one
  that does not exist. (`record_read/3` and `reads/1` are about one job, whose project the door
  has already settled.)

  Nothing here reads a document's or a file's bytes to list it: a size comes from the row
  (`octet_length`) or from the store's own metadata (`Forge.Storage.read_range/3`, which does not
  hash), and the hash is the one recorded when the version was written. The one exception is a
  milestone 1 `file://` row, whose size cannot be had without reading it.
  """

  import Ecto.Query, only: [from: 2]

  alias Forge.Artifacts
  alias Forge.Artifacts.{Artifact, Version}
  alias Forge.Events
  alias Forge.Jobs.{Job, Run}
  alias Forge.Projects.Project
  alias Forge.Repo
  alias Forge.Storage
  alias Forge.Tickets.Ticket

  require Logger

  @name_max 255
  @pad 3

  @typedoc "One file the worker may show: where, which version's bytes, and what they should be."
  @type entry :: %{
          required(String.t()) => String.t() | non_neg_integer() | nil
        }

  # -- the root ---------------------------------------------------------------------------------

  @doc """
  The root listing: the ticket numbers, and the two files the platform composes whole, with their
  text inline. `taken_at` is the moment of reading, and the index says so.
  """
  @spec root(Project.t(), DateTime.t()) :: map()
  def root(%Project{id: project_id}, now \\ DateTime.utc_now(:second)) do
    tickets = tickets(project_id)
    counts = counts(project_id)
    index = index(tickets, counts, now)
    jobs = jobs_tsv(project_id, nil)

    %{
      "taken_at" => DateTime.to_iso8601(now),
      "tickets" => Enum.map(tickets, & &1.number),
      "files" => [inline("index.md", index), inline("jobs.tsv", jobs)]
    }
  end

  defp inline(path, text),
    do: %{
      "path" => path,
      "ref" => nil,
      "size" => byte_size(text),
      "sha256" => nil,
      "inline" => text
    }

  defp tickets(project_id) do
    Repo.all(from t in Ticket, where: t.project_id == ^project_id, order_by: t.number)
  end

  # Per ticket: documents, versions and files, over what the archive shows (`shown/0`).
  defp counts(project_id) do
    from([a, v, t] in shown(project_id),
      group_by: [t.number, a.kind],
      select: {t.number, a.kind, count(a.id, :distinct), count(v.id)}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {number, kind, artifacts, versions}, acc ->
      Map.update(acc, number, tally(kind, artifacts, versions), fn held ->
        merge_tally(held, tally(kind, artifacts, versions))
      end)
    end)
  end

  defp tally(:blob, artifacts, versions),
    do: %{documents: 0, files: artifacts, versions: versions}

  defp tally(_kind, artifacts, versions),
    do: %{documents: artifacts, files: 0, versions: versions}

  defp merge_tally(a, b), do: Map.merge(a, b, fn _key, x, y -> x + y end)

  defp index(tickets, counts, now) do
    header =
      "# Archive index\n\nTaken at #{DateTime.to_iso8601(now)}. A ticket still in flight may hold " <>
        "newer versions than these counts.\n\n" <>
        "number | title | type | state | status | documents | versions | files\n"

    lines =
      Enum.map(tickets, fn ticket ->
        held = Map.get(counts, ticket.number, %{documents: 0, files: 0, versions: 0})

        Enum.join(
          [
            ticket.number,
            cell(ticket.title),
            cell(ticket.ticket_type),
            cell(ticket.state),
            ticket.status,
            held.documents,
            held.versions,
            held.files
          ],
          " | "
        )
      end)

    header <> Enum.join(lines, "\n") <> "\n"
  end

  # -- one ticket -------------------------------------------------------------------------------

  @doc """
  One ticket's files: `{:ok, %{"files" => entries}}`, or `:not_found` for a number this project does
  not have. The ticket's own `jobs.tsv` is among the entries, inline.
  """
  @spec ticket(Project.t(), term()) :: {:ok, map()} | :not_found
  def ticket(%Project{id: project_id}, number) do
    with {:ok, number} <- number(number),
         %Ticket{} = ticket <-
           Repo.one(from t in Ticket, where: t.project_id == ^project_id and t.number == ^number) do
      entries =
        project_id
        |> shown()
        |> ticket_rows(ticket.id)
        |> Enum.group_by(& &1.artifact_id)
        |> Enum.flat_map(fn {_id, versions} -> entries(versions) end)
        |> unique()

      {:ok, %{"files" => entries ++ [inline("jobs.tsv", jobs_tsv(project_id, ticket.id))]}}
    else
      _other -> :not_found
    end
  end

  # Not the whole version: a document's text is not read to list it, only how long it is.
  defp ticket_rows(query, ticket_id) do
    Repo.all(
      from([a, v, t] in query,
        where: t.id == ^ticket_id,
        order_by: [a.name, v.version],
        select: %{
          artifact_id: a.id,
          name: a.name,
          id: v.id,
          version: v.version,
          content_hash: v.content_hash,
          blob_uri: v.blob_uri,
          length: fragment("octet_length(?)", v.content)
        }
      )
    )
  end

  defp number(number) when is_integer(number) and number > 0 and number < 2_147_483_648,
    do: {:ok, number}

  defp number(number) when is_binary(number) do
    case Integer.parse(number) do
      {n, ""} -> number(n)
      _other -> :error
    end
  end

  defp number(_other), do: :error

  # What the archive shows of a project: documents, presentations and files of its tickets, and
  # never the changeset (a commit), a proposal (`tickets/` has those) or a transcript. The
  # joins are `[artifact, version, ticket]`, and the project is a clause of the query.
  defp shown(project_id) do
    from a in Artifact,
      join: v in Version,
      on: v.artifact_id == a.id,
      join: t in Ticket,
      on: t.id == a.ticket_id,
      where:
        t.project_id == ^project_id and a.name != "changeset" and
          not like(a.name, "proposal-%") and not like(a.name, "transcript-%") and
          (is_nil(v.blob_uri) or not like(v.blob_uri, "git:%"))
  end

  # One artifact's versions, oldest first: each under its versioned name, and the newest again
  # under the plain one, which is how "the latest is easy to find" is made true.
  defp entries([%{name: name} | _] = versions) do
    # An artifact whose own name is not a name is not listed at all, and nor are its versions; the
    # same for the one name that is the ledger's, which would otherwise be listed as `jobs.v001.tsv`.
    listed =
      if listable?(name), do: Enum.flat_map(versions, &listed/1), else: []

    case List.last(listed) do
      nil ->
        []

      {_path, newest} ->
        Enum.map(listed, fn {path, entry} -> Map.put(entry, "path", path) end) ++
          [Map.put(newest, "path", hd(versions).name)]
    end
  end

  defp listed(row) do
    case size(row) do
      {:ok, size} ->
        [
          {versioned(row.name, row.version),
           %{"ref" => row.id, "size" => size, "sha256" => sha256(row)}}
        ]

      :error ->
        # A blob whose bytes are gone from the store is not listed: it is a file that cannot be read.
        Logger.warning("archive: #{row.name} v#{row.version} has no bytes, not listed")
        []
    end
  end

  defp size(%{length: length}) when is_integer(length), do: {:ok, length}

  defp size(%{blob_uri: "store:" <> _ = uri}) do
    with {:ok, key} <- Storage.key_from_uri(uri),
         {:ok, %{size: size}} <- Storage.read_range(key, 0, 0) do
      {:ok, size}
    else
      _other -> :error
    end
  end

  # A milestone 1 row: `file://`, read only from inside the data directory (`Artifacts.content/1`).
  defp size(%{blob_uri: uri}) when is_binary(uri) do
    case Artifacts.content(%Version{blob_uri: uri}) do
      {:ok, bytes} -> {:ok, byte_size(bytes)}
      {:error, _reason} -> :error
    end
  end

  defp size(_row), do: :error

  defp sha256(%{content_hash: "sha256:" <> hex}) when byte_size(hex) == 64, do: hex
  defp sha256(_row), do: nil

  @doc """
  `plan.md` at version 2 is `plan.v002.md`; a name with no extension is `ticket.v001`; a group
  member keeps its folder, `reports/out.v001.txt`.
  """
  @spec versioned(String.t(), pos_integer()) :: String.t()
  def versioned(name, version) do
    ext = Path.extname(name)
    stem = String.slice(name, 0, byte_size(name) - byte_size(ext))
    number = version |> Integer.to_string() |> String.pad_leading(@pad, "0")
    stem <> ".v" <> number <> ext
  end

  # Names are checked here and nowhere else (`archive.md` § Layout): the worker keeps the tree in
  # memory and never turns a name into a path. In sort order the first entry keeps a path and a later
  # one is dropped; so is a path that is a file in one entry and a folder in another, a name that is
  # not valid.
  defp unique(entries) do
    entries
    |> Enum.sort_by(& &1["path"])
    |> Enum.reduce(%{}, fn entry, kept ->
      path = entry["path"]

      cond do
        not valid_path?(path) -> drop(path, "not a valid name", kept)
        Map.has_key?(kept, path) -> drop(path, "taken", kept)
        clash?(path, kept) -> drop(path, "a file and a folder of one name", kept)
        true -> Map.put(kept, path, entry)
      end
    end)
    |> Map.values()
  end

  defp drop(path, why, kept) do
    Logger.warning("archive: #{inspect(path)} not listed (#{why})")
    kept
  end

  # A name has at most two segments (`valid_path?/1`), so a folder is a first segment.
  defp clash?(path, kept) do
    case String.split(path, "/") do
      [name] -> Enum.any?(Map.keys(kept), &String.starts_with?(&1, name <> "/"))
      [group, _name] -> Map.has_key?(kept, group)
    end
  end

  defp listable?(name), do: valid_path?(name) and name != "jobs.tsv"

  @doc "Whether `path` is one segment, or `group/segment`, each a name the worker may show."
  @spec valid_path?(term()) :: boolean()
  def valid_path?(path) when is_binary(path) do
    case String.split(path, "/") do
      [name] -> valid_name?(name)
      [group, name] -> valid_name?(group) and valid_name?(name)
      _other -> false
    end
  end

  def valid_path?(_path), do: false

  defp valid_name?(name),
    do:
      name != "" and name not in [".", ".."] and byte_size(name) <= @name_max and
        String.valid?(name) and not String.contains?(name, [<<0>>, "/"])

  # -- one version's bytes ------------------------------------------------------------------------

  @doc """
  The version `ref` of ticket `number` in this project, for the door to serve, and the facts the
  read record needs. `:not_found` for anything else: a ref of another project or ticket, a git
  version, a proposal, a transcript, and something that is not an id.
  """
  @spec version(Project.t(), term(), term()) ::
          {:ok, Version.t(), %{ticket: pos_integer(), artifact: String.t()}} | :not_found
  def version(%Project{id: project_id}, number, ref) do
    with {:ok, number} <- number(number),
         {:ok, ref} <- Ecto.UUID.cast(ref),
         %{version: version, artifact: name} <-
           Repo.one(
             from([a, v, t] in shown(project_id),
               where: t.number == ^number and v.id == ^ref,
               select: %{version: v, artifact: a.name}
             )
           ) do
      {:ok, version, %{ticket: number, artifact: name}}
    else
      _other -> :not_found
    end
  end

  @doc """
  Records that `job_id` opened a version, once per distinct version (`archive.md` § What is
  recorded). Returns `:recorded` or `:seen`.
  """
  @spec record_read(Job.t(), Version.t(), map()) :: :recorded | :seen
  def record_read(%Job{} = job, %Version{} = version, %{ticket: ticket, artifact: artifact}) do
    {:ok, result} =
      Repo.transaction(fn ->
        # Two reads of one file at once would both find nothing recorded and both record it; the
        # lock is on the pair, held to the end of the transaction. The lock is an equivalent
        # mutant for the suite: the sandbox runs every process on one connection, where a session
        # advisory lock is taken again by the same session and so excludes nobody.
        Repo.query!("select pg_advisory_xact_lock(hashtext($1))", [job.id <> version.id])

        if seen?(job, version) do
          :seen
        else
          {:ok, _event} =
            Events.append("job.archive_read", :system, %{
              ticket_id: job.ticket_id,
              job_id: job.id,
              payload: %{
                "ticket" => ticket,
                "artifact" => artifact,
                "version" => version.version,
                "version_id" => version.id
              }
            })

          :recorded
        end
      end)

    result
  end

  defp seen?(job, version) do
    Repo.exists?(
      from e in Events.Event,
        where:
          e.job_id == ^job.id and e.type == "job.archive_read" and
            fragment("?->>'version_id' = ?", e.payload, ^version.id)
    )
  end

  @doc "How many distinct versions the job opened: the one figure the job page shows."
  @spec reads(String.t()) :: non_neg_integer()
  def reads(job_id) do
    Repo.one(
      from e in Events.Event,
        where: e.job_id == ^job_id and e.type == "job.archive_read",
        select: count()
    )
  end

  # -- the jobs ledger ----------------------------------------------------------------------------

  @header ~w(ticket state attempt kind outcome status started_at finished_at turns cost_usd model effort memory_max cores runs)

  # Every job of the project, or of one ticket (`ticket_id` set). A field the platform did not
  # record is `n/a` and the line is kept: a job that never started is still a job that ran here.
  # No credential, no machine and no owner is read at all (`archive.md` § Layout).
  defp jobs_tsv(project_id, ticket_id) do
    # Only this project's runs: unfiltered, every listing and every refresh of one aggregated the
    # whole node's. Dropping the filter is an equivalent mutant — the join on `job_id` below pairs
    # each job with its own runs either way — so nothing observable tells the two apart.
    runs =
      from r in Run,
        join: rj in Job,
        on: rj.id == r.job_id,
        where: rj.project_id == ^project_id,
        group_by: r.job_id,
        select: %{job_id: r.job_id, n: count(r.id)}

    query =
      from j in Job,
        left_join: t in Ticket,
        on: t.id == j.ticket_id,
        left_join: r in subquery(runs),
        on: r.job_id == j.id,
        where: j.project_id == ^project_id,
        order_by: [j.inserted_at, j.id],
        select: [
          t.number,
          j.state,
          j.attempt,
          j.kind,
          j.outcome,
          j.status,
          j.started_at,
          j.finished_at,
          j.turns,
          j.cost_usd,
          fragment("coalesce(?, ?->>'model')", j.model, j.spec),
          fragment("coalesce(?, ?->>'effort')", j.effort, j.spec),
          j.memory_max,
          j.cores,
          coalesce(r.n, 0)
        ]

    query = if ticket_id, do: from([j] in query, where: j.ticket_id == ^ticket_id), else: query

    rows =
      query |> Repo.all() |> Enum.map(fn row -> Enum.map_join(row, "\t", &field/1) end)

    Enum.join([Enum.join(@header, "\t") | rows], "\n") <> "\n"
  end

  defp field(nil), do: "n/a"
  defp field(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp field(%Decimal{} = number), do: Decimal.to_string(number, :normal)
  defp field(value) when is_atom(value), do: Atom.to_string(value)
  defp field(value) when is_binary(value), do: cell(value)
  defp field(value), do: to_string(value)

  # A title or a state is one cell: no tab or line break may open another.
  defp cell(nil), do: "n/a"
  defp cell(text) when is_atom(text), do: Atom.to_string(text)
  defp cell(text), do: String.replace(text, ~r/[\s|]+/, " ")
end
