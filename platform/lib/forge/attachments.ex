defmodule Forge.Attachments do
  @moduledoc """
  Files people attach: staged when uploaded, claimed by the act they ride on, handed to every later
  run of the ticket (or of a project chat) and withdrawable. The standard is
  `docs/design/attachments.md`.

  **A pool** is `{:ticket, id}` for a ticket (a ticket chat's files included) or `{:job, id}` for a
  project chat, the shape `Forge.Artifacts` already uses for a scope. Its files are the live
  versions of the artifacts named `attachments/<file>`; the row of `attachments` beside each says
  what it was attached to, who attached it and whether it was withdrawn.
  """

  import Ecto.Query, only: [from: 2, dynamic: 2]

  alias Forge.Access
  alias Forge.Accounts.Scope
  alias Forge.Accounts.User
  alias Forge.Actor
  alias Forge.Artifacts
  alias Forge.Artifacts.{Artifact, Version}
  alias Forge.Attachments.{Attachment, Batch, Upload}
  alias Forge.Events
  alias Forge.Events.Event
  alias Forge.Jobs.Job
  alias Forge.Projects
  alias Forge.Repo
  alias Forge.Storage
  alias Forge.Tickets.Ticket

  require Logger

  @prefix ForgeCore.Workflow.attachments_dir() <> "/"
  @mebibyte 1024 * 1024

  @type pool :: {:ticket, String.t()} | {:job, String.t()}

  @typedoc "What a file was attached to, as the act that wrote it says."
  @type anchor ::
          {:version, String.t()}
          | {:event, integer()}
          | {:events_after, integer(), [String.t()]}
          | :added

  # -- limits ------------------------------------------------------------------------------------

  @doc """
  The limits (`docs/design/attachments.md` § Limits), from `config :forge, Forge.Attachments` where
  the suite lowers them so it needs no large file.
  """
  @spec limits() :: %{
          file_bytes: pos_integer(),
          per_act: pos_integer(),
          pool_files: pos_integer(),
          pool_bytes: pos_integer()
        }
  def limits do
    config = Application.get_env(:forge, __MODULE__, [])

    %{
      file_bytes: Keyword.get(config, :file_bytes, 500 * @mebibyte),
      per_act: Keyword.get(config, :per_act, 10),
      pool_files: Keyword.get(config, :pool_files, 100),
      pool_bytes: Keyword.get(config, :pool_bytes, 5 * 1024 * @mebibyte)
    }
  end

  @doc "How long a staged upload that nobody sent is kept, in milliseconds."
  @spec stage_ttl_ms() :: pos_integer()
  def stage_ttl_ms,
    do:
      :forge |> Application.get_env(__MODULE__, []) |> Keyword.get(:stage_ttl_ms, 24 * 3_600_000)

  @doc "A limit in words, as a refusal says it."
  @spec limit_text(atom()) :: String.t()
  def limit_text(:file_bytes), do: "#{div(limits().file_bytes, @mebibyte)} MiB for one file"
  def limit_text(:per_act), do: "#{limits().per_act} files with one message or note"
  def limit_text(:pool_files), do: "#{limits().pool_files} files in all"
  def limit_text(:pool_bytes), do: "#{gib(limits().pool_bytes)} in all"
  def limit_text(:size), do: "size"

  defp gib(bytes) when bytes >= 1024 * @mebibyte,
    do: "#{Float.round(bytes / (1024 * @mebibyte), 1)} GiB"

  defp gib(bytes), do: "#{Float.round(bytes / @mebibyte, 1)} MiB"

  @doc """
  What is left of a pool's room, for a page to refuse early with: `%{files, bytes}`. A courtesy and
  not the guard — `claim/5` counts under a lock.
  """
  @spec room(pool()) :: %{files: non_neg_integer(), bytes: non_neg_integer()}
  def room(pool) do
    {files, bytes} = counts(Repo, pool)
    limits = limits()
    %{files: max(limits.pool_files - files, 0), bytes: max(limits.pool_bytes - bytes, 0)}
  end

  # -- names -------------------------------------------------------------------------------------

  @doc """
  The artifact file name made from a name as uploaded (`docs/design/attachments.md` § Names): its
  last segment, only letters, digits, `.`, `_` and `-`, starting with a letter or digit, its
  extension kept and the whole at most 200 bytes, `file` when nothing is left, and never a stem
  that ends `.v<digits>`, which is how the folder spells an earlier version. It always passes
  `ForgeCore.Workflow.valid_name?/1`.
  """
  @spec name(String.t()) :: String.t()
  def name(original) when is_binary(original) do
    cleaned =
      original
      |> String.split(["/", "\\"])
      |> List.last()
      |> String.replace(~r/[^A-Za-z0-9._-]+/u, "-")
      |> String.replace(~r/\A[^A-Za-z0-9]+/, "")

    # `shot.v001` is the folder's spelling of version 1 of `shot` whether or not it has an
    # extension of its own: `Path.extname("shot.v001")` is `.v001`, so it is read as part of the stem.
    cleaned = Regex.replace(~r/\.v(\d+)\z/, cleaned, "-v\\1")

    ext = cleaned |> Path.extname() |> binary_part_max(40)
    stem = binary_part(cleaned, 0, byte_size(cleaned) - byte_size(Path.extname(cleaned)))
    stem = binary_part_max(stem, 200 - byte_size(ext))
    stem = if stem == "", do: "file", else: stem
    # And a stem that ends so (`shot.v001.png`) is made the same.
    stem = Regex.replace(~r/\.v(\d+)\z/, stem, "-v\\1")

    stem <> ext
  end

  defp binary_part_max(binary, max), do: binary_part(binary, 0, min(byte_size(binary), max))

  @doc "The artifact name a file is kept under."
  @spec artifact_name(String.t()) :: String.t()
  def artifact_name(file), do: @prefix <> file

  @doc "The file part of an artifact name `attachments/<file>`."
  @spec file_name(String.t()) :: String.t()
  def file_name(@prefix <> file), do: file

  # -- staging -----------------------------------------------------------------------------------

  @doc """
  Keeps the bytes at `source` (`{:file, path}`) as an upload of `project` by `actor`, not yet in any
  pool. The size kept is the size the store wrote — the bytes received, not any size announced. A
  file over the limit is refused and deleted. `{:ok, upload}`.
  """
  @spec stage(Projects.Project.t(), Actor.t() | struct(), Storage.source(), String.t()) ::
          {:ok, Upload.t()} | {:error, term()}
  def stage(%Projects.Project{id: project_id}, actor, source, original_name) do
    id = Ecto.UUID.generate()
    key = Storage.Key.upload(id)

    original_name = if String.valid?(original_name), do: original_name, else: "file"

    with {:ok, %{size: size, hash: hash}} <- Storage.put(key, source) do
      if size > limits().file_bytes do
        Storage.delete(key)
        {:error, {:attachments_refused, [{original_name, :file_bytes}]}}
      else
        insert_upload(id, key, project_id, actor, original_name, size, hash)
      end
    end
  end

  defp insert_upload(id, key, project_id, actor, original_name, size, hash) do
    columns =
      Map.merge(Actor.columns(Actor.of(actor)), %{
        project_id: project_id,
        key: key,
        original_name: String.slice(original_name, 0, 255),
        size: size,
        content_hash: hash
      })

    case Repo.insert(Ecto.Changeset.change(%Upload{id: id}, columns)) do
      {:ok, upload} ->
        {:ok, upload}

      {:error, reason} ->
        Storage.delete(key)
        {:error, reason}
    end
  rescue
    # The bytes are in the store and no row names them, so nothing would ever sweep them. A defence
    # for a failure of the database itself (an equivalent mutant: no test can make an insert raise,
    # now that a name is made valid text first).
    error ->
      Storage.delete(key)
      reraise error, __STACKTRACE__
  end

  @doc """
  Removes the staged uploads `actor` made with these ids, and their bytes. Another's, another
  project's, and ids that are not uploads are left alone and not reported.
  """
  @spec discard(Projects.Project.t(), Actor.t() | struct(), [String.t()]) :: non_neg_integer()
  def discard(%Projects.Project{id: project_id}, actor, ids) do
    owner = owner_clause(Actor.columns(Actor.of(actor)))

    mine =
      Repo.all(
        from u in Upload,
          where: u.id in ^uuids(ids) and u.project_id == ^project_id,
          where: ^owner,
          select: {u.id, u.key}
      )

    remove_staged(mine)
  end

  @doc false
  # Public for the test that stands in for the race: rows selected, then claimed, then removed.
  def remove_staged(rows) do
    ids = Enum.map(rows, &elem(&1, 0))

    # The bytes of the rows **this delete removed**, and not of every row that was selected: a row
    # an act claimed in between is gone from the table already, its version is live, and its bytes
    # are the version's now (`docs/design/attachments.md` § Staging, claiming and the sweep).
    {count, deleted} =
      Repo.delete_all(from u in Upload, where: u.id in ^ids, select: {u.id, u.key})

    Enum.each(deleted, fn {_id, key} -> Storage.delete(key) end)
    count
  end

  defp owner_clause(%{user_id: id}) when is_binary(id),
    do: Ecto.Query.dynamic([u], u.user_id == ^id)

  defp owner_clause(%{token_id: id}), do: Ecto.Query.dynamic([u], u.token_id == ^id)

  # An id off the wire is a UUID or it is nothing; a malformed one would otherwise raise in the cast.
  defp uuids(ids),
    do: for(id <- ids, is_binary(id), {:ok, uuid} <- [Ecto.UUID.cast(id)], do: uuid)

  @doc """
  The sweep: staged uploads older than the time-to-live, rows first and then their bytes, so a
  failure between the two leaves bytes no row names any more. Also removes the bytes of any
  withdrawn version a delete after the commit missed. Returns `{staged, withdrawn}` counts.
  """
  @spec sweep(DateTime.t()) :: {non_neg_integer(), non_neg_integer()}
  def sweep(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -stage_ttl_ms(), :millisecond)

    stale =
      Repo.all(from u in Upload, where: u.inserted_at < ^cutoff, select: {u.id, u.key})

    {remove_staged(stale), sweep_withdrawn()}
  end

  @doc "Deletes the bytes of withdrawn versions that are still in the store."
  @spec sweep_withdrawn() :: non_neg_integer()
  def sweep_withdrawn do
    keys =
      Repo.all(
        from a in Attachment,
          join: v in Version,
          on: v.id == a.artifact_version_id,
          where: not is_nil(a.withdrawn_at),
          select: v.blob_uri
      )

    Enum.count(keys, fn uri ->
      with {:ok, key} <- Storage.key_from_uri(uri),
           {:ok, _info} <- Storage.stat(key) do
        Storage.delete(key) == :ok
      else
        _gone -> false
      end
    end)
  end

  # -- claiming ----------------------------------------------------------------------------------

  @doc """
  The sequence number events after which are the act's: read before the act, handed to `claim/5`
  with the types of event the act writes.
  """
  @spec mark() :: integer()
  def mark, do: Repo.one(from e in Event, select: coalesce(max(e.seq), 0))

  @doc """
  Claims the batch's staged uploads into `pool`, **inside the caller's transaction**
  (`docs/design/attachments.md` § Staging, claiming and the sweep). `kind` is what the act is
  (`:ticket`, `:document`, `:message`, `:answer`, `:note`) and `anchor` the row it wrote.

  Locks the pool's row, then the staged rows, counts what the pool holds, and takes each upload in
  order: one that is not the actor's or not this project's is *not received*, said by the name the
  caller sent; one that passes a limit is refused — a page's act records it as not received and
  goes on, the API's (`batch.whole?`) refuses the whole with `{:error, {:attachments_refused,
  [{name, limit}]}}` and the caller's transaction rolls back. Logs one `attachment.added`.

  `{:ok, %{added: [Attachment.t()], not_received: [Attachment.t()]}}`; `{:ok, nil}` for an empty
  batch, which writes nothing.
  """
  @spec claim(pool(), Actor.t() | struct(), Batch.t() | nil, atom(), anchor(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def claim(pool, actor, batch, kind, anchor, opts \\ []) do
    if Batch.empty?(batch),
      do: {:ok, nil},
      else: do_claim(pool, Actor.of(actor), once(batch), kind, anchor, Keyword.get(opts, :job_id))
  end

  @lock_class 60

  @doc """
  Holds the ticket's **assignment lock** while `fun` runs: a session advisory lock on one connection,
  released when `fun` returns, raises or the connection goes. `Forge.Jobs.pending/2` leaves out the
  jobs of a ticket whose lock is held, so a job an act makes is not assigned before the act's files
  are claimed (`docs/design/attachments.md` § Delivery): a run assigned in between would be handed a
  pool without them and never learn of them. Taken before the act, so any job it creates is made
  while the lock is held.
  """
  @spec hold(String.t(), (-> result)) :: result when result: term()
  def hold(ticket_id, fun) do
    Repo.checkout(fn ->
      Repo.query!("SELECT pg_advisory_lock($1::int, hashtext($2::text))", [@lock_class, ticket_id])

      try do
        fun.()
      after
        Repo.query!("SELECT pg_advisory_unlock($1::int, hashtext($2::text))", [
          @lock_class,
          ticket_id
        ])
      end
    end)
  end

  @doc "The class of the assignment lock, for the one query that reads it (`Forge.Jobs.pending/2`)."
  @spec lock_class() :: integer()
  def lock_class, do: @lock_class

  @doc "The project a pool's ticket or conversation is in."
  @spec project_of(pool()) :: String.t() | nil
  def project_of({:ticket, id}),
    do: Repo.one(from t in Ticket, where: t.id == ^id, select: t.project_id)

  def project_of({:job, id}),
    do: Repo.one(from j in Job, where: j.id == ^id, select: j.project_id)

  @doc """
  What a **whole** request would be refused for, before its act runs: `:ok`, or `{:error,
  {:attachments_refused, [{name, limit}]}}` by the rules `claim/6` applies, counted without a lock.
  Asked first because the act may push to git or merge, which no refusal after it can take back
  (`docs/design/attachments.md` § Staging, claiming and the sweep). A request that is not whole is
  `:ok` here: a page's act goes on and names what did not arrive. `pool` is nil for a ticket not made
  yet, whose pool is empty. A race between this and the claim leaves the file *not received*, as on
  a page.
  """
  @spec preflight(Batch.t() | nil, Actor.t() | struct(), String.t(), pool() | nil) ::
          :ok | {:error, term()}
  def preflight(%Batch{whole?: true} = batch, actor, project_id, pool)
      when is_binary(project_id) do
    if Batch.empty?(batch) do
      :ok
    else
      batch = once(batch)
      owner = owner_clause(Actor.columns(Actor.of(actor)))

      staged =
        from(u in Upload,
          where: u.id in ^uuids(Enum.map(batch.uploads, & &1.id)) and u.project_id == ^project_id,
          where: ^owner
        )
        |> Repo.all()
        |> Map.new(&{&1.id, &1})

      counted = if pool, do: counts(Repo, pool), else: {0, 0}
      {_taken, refused, _counted} = partition(batch, staged, counted)
      whole(batch, refused)
    end
  end

  def preflight(_batch, _actor, _project_id, _pool), do: :ok

  # An id a form repeats is one file: the second claim of it would find the row gone.
  defp once(%Batch{uploads: uploads} = batch),
    do: %{batch | uploads: Enum.uniq_by(uploads, &normalise(&1.id))}

  defp do_claim(pool, actor, %Batch{} = batch, kind, anchor, job_id) do
    project_id = lock_pool(pool)
    staged = lock_staged(batch, actor, project_id)
    counted = counts(Repo, pool)

    {taken, refused, _counted} = partition(batch, staged, counted)

    with :ok <- whole(batch, refused),
         {:ok, written} <- write_versions(pool, actor, taken),
         {:ok, added_event} <-
           log_added(pool, actor, written, refused, batch.not_received, kind, job_id) do
      seq = anchor_seq(anchor, pool, added_event)
      insert_rows(pool, actor, kind, seq, written, refused, batch.not_received)
    end
  end

  # **The lock is what makes the pool's limits hold under two claims at once**: both count under it,
  # so two files that each fit cannot together pass 100 files or 5 GiB. Equivalent mutant in the
  # suite: dropping `FOR UPDATE` changes nothing it can observe, because the sandbox gives every test
  # one connection and the race needs two committing between each other's count and insert.
  defp lock_pool({:ticket, id}),
    do: Repo.one!(from t in Ticket, where: t.id == ^id, lock: "FOR UPDATE", select: t.project_id)

  defp lock_pool({:job, id}),
    do: Repo.one!(from j in Job, where: j.id == ^id, lock: "FOR UPDATE", select: j.project_id)

  # Locked so a staged file is claimed once, by whichever of two claims reaches it first. Equivalent
  # mutant in the suite, for the reason `lock_pool/1` gives: it needs two connections.
  defp lock_staged(%Batch{uploads: uploads}, actor, project_id) do
    owner = owner_clause(Actor.columns(actor))

    from(u in Upload,
      where: u.id in ^uuids(Enum.map(uploads, & &1.id)) and u.project_id == ^project_id,
      where: ^owner,
      lock: "FOR UPDATE"
    )
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  # Takes each upload in the order sent: `{taken, refused, counted}`, `taken` being
  # `{upload, name_as_uploaded}` and `refused` `{name_as_uploaded, limit}`. A file past a limit does
  # not stop the others, and does not use up the room it did not take.
  defp partition(%Batch{uploads: uploads}, staged, counted) do
    limits = limits()

    {taken, refused, counted, _acts} =
      Enum.reduce(uploads, {[], [], counted, 0}, fn %{id: id, name: name},
                                                    {taken, refused, {files, bytes}, acts} ->
        with {:ok, upload} <- Map.fetch(staged, normalise(id)),
             nil <- over(limits, upload.size, files, bytes, acts) do
          {[{upload, name} | taken], refused, {files + 1, bytes + upload.size}, acts + 1}
        else
          :error -> {taken, [{name, :missing} | refused], {files, bytes}, acts}
          limit -> {taken, [{name, limit} | refused], {files, bytes}, acts}
        end
      end)

    {Enum.reverse(taken), Enum.reverse(refused), counted}
  end

  defp normalise(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> id
    end
  end

  defp over(limits, size, files, bytes, acts) do
    cond do
      # A file past this limit was refused by `stage/4`; this covers a limit lowered between the
      # upload and the send (`attachments_test.exs`, "a limit lowered after the upload").
      size > limits.file_bytes -> :file_bytes
      acts >= limits.per_act -> :per_act
      files + 1 > limits.pool_files -> :pool_files
      bytes + size > limits.pool_bytes -> :pool_bytes
      true -> nil
    end
  end

  # A staged id that is not the actor's is *not received* on a page and says nothing of whose it
  # was; the API stages its own, so for it a missing one cannot happen, and a refusal is whole.
  defp whole(%Batch{whole?: true}, [_ | _] = refused),
    do: {:error, {:attachments_refused, refused}}

  defp whole(%Batch{}, _refused), do: :ok

  defp write_versions(pool, actor, taken) do
    taken
    |> Enum.reduce_while({:ok, []}, fn {upload, original}, {:ok, written} ->
      file = name(original)

      attrs = %{
        blob_uri: Storage.uri(upload.key),
        content_hash: upload.content_hash,
        parse: false
      }

      case Artifacts.record_version(pool, artifact_name(file), :blob, actor, attrs) do
        {:ok, version} ->
          {:cont,
           {:ok, [%{upload: upload, version: version, file: file, original: original} | written]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, written} -> {:ok, Enum.reverse(written)}
      error -> error
    end
  end

  defp log_added(pool, actor, written, refused, failed, kind, job_id) do
    Events.append("attachment.added", actor, %{
      ticket_id: ticket_of(pool),
      job_id: job_id || job_of(pool),
      payload: %{
        "to" => Atom.to_string(kind),
        "files" =>
          Enum.map(written, fn w ->
            %{
              "name" => artifact_name(w.file),
              "version" => w.version.version,
              "original" => w.original,
              "size" => w.upload.size
            }
          end),
        "not_received" => Enum.map(refused, &elem(&1, 0)) ++ failed,
        "refused" =>
          Enum.map(refused, fn {name, limit} ->
            %{"name" => name, "limit" => Atom.to_string(limit)}
          end)
      }
    })
  end

  defp ticket_of({:ticket, id}), do: id
  defp ticket_of({:job, _id}), do: nil
  defp job_of({:job, id}), do: id
  defp job_of({:ticket, _id}), do: nil

  # What the act wrote, or the `attachment.added` event itself when it wrote nothing that can be
  # found: the anchor is a place to read from, and one that exists always beats none.
  defp anchor_seq({:event, seq}, _pool, _added), do: {:event, seq}
  defp anchor_seq({:version, id}, _pool, _added), do: {:version, id}
  defp anchor_seq(:added, _pool, added), do: {:event, added.seq}

  # The first event of the act's type after the mark **by the same actor**: two people answering
  # on one ticket at once each find their own.
  defp anchor_seq({:events_after, after_seq, types}, pool, added) do
    found =
      Repo.one(
        from e in Event,
          where: e.seq > ^after_seq and e.seq < ^added.seq and e.type in ^types,
          where: e.actor == ^added.actor,
          where: ^pool_events(pool),
          select: min(e.seq)
      )

    {:event, found || added.seq}
  end

  defp pool_events({:ticket, id}), do: Ecto.Query.dynamic([e], e.ticket_id == ^id)
  defp pool_events({:job, id}), do: Ecto.Query.dynamic([e], e.job_id == ^id)

  defp insert_rows(pool, actor, kind, anchor, written, refused, failed) do
    base = Map.merge(pool_columns(pool), Actor.columns(actor))
    base = Map.merge(base, %{author: Events.encode_actor(actor), to_kind: kind})
    base = Map.merge(base, anchor_columns(anchor))

    added =
      Enum.map(written, fn w ->
        insert!(
          Map.merge(base, %{
            artifact_version_id: w.version.id,
            name: artifact_name(w.file),
            original_name: w.original,
            size: w.upload.size
          }),
          w.upload
        )
      end)

    missing =
      Enum.map(Enum.map(refused, &elem(&1, 0)) ++ failed, fn original ->
        insert!(Map.merge(base, %{original_name: original}), nil)
      end)

    {:ok, %{added: added, not_received: missing}}
  end

  defp insert!(attrs, upload) do
    row = Repo.insert!(struct!(Attachment, attrs))
    if upload, do: Repo.delete!(upload)
    row
  end

  defp pool_columns({:ticket, id}), do: %{ticket_id: id, job_id: nil}
  defp pool_columns({:job, id}), do: %{ticket_id: nil, job_id: id}
  defp anchor_columns({:version, id}), do: %{to_version_id: id}
  defp anchor_columns({:event, seq}), do: %{to_event_seq: seq}

  # -- reading a pool ----------------------------------------------------------------------------

  @doc """
  The pool's live files, as every run is handed them (`docs/design/attachments.md` § Delivery):
  one entry per version not withdrawn, oldest first by name, each with the folder spelling — the
  newest live version keeps the plain name, an earlier one is `stem.v001.ext`. One function for the
  manifest, the assignment and the worker, so the prompt cannot name a file the folder does not
  hold.
  """
  @spec pool(pool()) :: [map()]
  def pool(pool) do
    rows =
      Repo.all(
        from a in Attachment,
          join: v in Version,
          on: v.id == a.artifact_version_id,
          where: ^pool_clause(pool),
          where: is_nil(a.withdrawn_at),
          order_by: [a.name, v.version],
          select: %{attachment: a, version: v}
      )

    rows
    |> Enum.group_by(& &1.attachment.name)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {name, versions} ->
      newest = versions |> List.last() |> then(& &1.version.version)

      Enum.map(versions, fn %{attachment: a, version: v} ->
        file = file_name(name)

        %{
          file: if(v.version == newest, do: file, else: Forge.Archive.versioned(file, v.version)),
          name: name,
          version: v.version,
          version_id: v.id,
          key: key_of(v),
          size: a.size,
          hash: v.content_hash,
          attachment: a
        }
      end)
    end)
  end

  defp key_of(%Version{blob_uri: uri}) do
    {:ok, key} = Storage.key_from_uri(uri)
    key
  end

  defp pool_clause({:ticket, id}), do: Ecto.Query.dynamic([a], a.ticket_id == ^id)
  defp pool_clause({:job, id}), do: Ecto.Query.dynamic([a], a.job_id == ^id)

  defp counts(repo, pool) do
    {files, bytes} =
      repo.one(
        from a in Attachment,
          where: ^pool_clause(pool),
          where: is_nil(a.withdrawn_at) and not is_nil(a.artifact_version_id),
          select: {count(a.id), coalesce(sum(a.size), 0)}
      )

    {files, to_integer(bytes)}
  end

  defp to_integer(%Decimal{} = decimal), do: Decimal.to_integer(decimal)
  defp to_integer(number) when is_integer(number), do: number

  @doc "Every attachment row of a pool, newest first: received, not received and withdrawn."
  @spec all(pool()) :: [Attachment.t()]
  def all(pool),
    do:
      Repo.all(
        from a in Attachment,
          where: ^pool_clause(pool),
          order_by: [desc: a.inserted_at, desc: a.id]
      )

  @doc "The files not received in the pool, for the manifest's `not_received` list."
  @spec not_received(pool()) :: [Attachment.t()]
  def not_received(pool),
    do:
      Repo.all(
        from a in Attachment,
          where: ^pool_clause(pool),
          where: is_nil(a.artifact_version_id),
          order_by: [a.inserted_at, a.id]
      )

  @doc "The attachment row of an artifact version, or nil when it is not a person's file."
  @spec for_version(String.t()) :: Attachment.t() | nil
  def for_version(version_id),
    do: Repo.one(from a in Attachment, where: a.artifact_version_id == ^version_id)

  @doc "Rows by artifact version id, for the pages that draw many versions at once."
  @spec for_versions([String.t()]) :: %{String.t() => Attachment.t()}
  def for_versions([]), do: %{}

  def for_versions(version_ids) do
    from(a in Attachment, where: a.artifact_version_id in ^version_ids)
    |> Repo.all()
    |> Map.new(&{&1.artifact_version_id, &1})
  end

  @doc """
  What was attached to each of these events, by `seq`: the rows, received ones and not, withdrawn
  ones too — a link under a message says *withdrawn* where its file was.
  """
  @spec for_events([integer()]) :: %{integer() => [Attachment.t()]}
  def for_events([]), do: %{}

  def for_events(seqs) do
    from(a in Attachment,
      where: a.to_event_seq in ^seqs,
      order_by: [a.inserted_at, a.id]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.to_event_seq)
  end

  @doc "What was attached to each of these artifact versions (a ticket's text, a document), by version id."
  @spec attached_to_versions([String.t()]) :: %{String.t() => [Attachment.t()]}
  def attached_to_versions([]), do: %{}

  def attached_to_versions(version_ids) do
    from(a in Attachment, where: a.to_version_id in ^version_ids, order_by: [a.inserted_at, a.id])
    |> Repo.all()
    |> Enum.group_by(& &1.to_version_id)
  end

  # -- what a page draws ---------------------------------------------------------------------------

  @typedoc """
  A file as a page names it under what it came with: `state` is `:live`, `:withdrawn` or
  `:not_received`, `file` the name in the folder's plain spelling (nil when not received), `version`
  the version's number and `original` the name as uploaded.
  """
  @type entry :: %{
          id: String.t(),
          state: :live | :withdrawn | :not_received,
          file: String.t() | nil,
          name: String.t() | nil,
          version: pos_integer() | nil,
          original: String.t(),
          withdrawn: map() | nil,
          row: Attachment.t()
        }

  @doc "Rows as the pages name them (`t:entry/0`), the version numbers read in one query."
  @spec entries([Attachment.t()]) :: [entry()]
  def entries([]), do: []

  def entries(rows) do
    ids = for a <- rows, a.artifact_version_id, do: a.artifact_version_id

    versions =
      from(v in Version, where: v.id in ^ids, select: {v.id, v.version})
      |> Repo.all()
      |> Map.new()

    Enum.map(rows, fn a ->
      %{
        id: a.id,
        state: state(a),
        file: a.name && file_name(a.name),
        name: a.name,
        version: versions[a.artifact_version_id],
        original: a.original_name,
        withdrawn:
          a.withdrawn_at && %{at: a.withdrawn_at, by: a.withdrawn_by, reason: a.withdraw_reason},
        row: a
      }
    end)
  end

  defp state(%Attachment{artifact_version_id: nil}), do: :not_received
  defp state(%Attachment{withdrawn_at: nil}), do: :live
  defp state(%Attachment{}), do: :withdrawn

  @doc "What came with each of these events, as `entries/1`, by `seq`."
  @spec entries_for_events([integer()]) :: %{integer() => [entry()]}
  def entries_for_events(seqs),
    do: group_entries(for_events(seqs) |> Map.values() |> List.flatten(), & &1.to_event_seq)

  @doc "What came with each of these artifact versions (the ticket's text, a document), by version id."
  @spec entries_for_versions([String.t()]) :: %{String.t() => [entry()]}
  def entries_for_versions(ids),
    do:
      group_entries(
        attached_to_versions(ids) |> Map.values() |> List.flatten(),
        & &1.to_version_id
      )

  defp group_entries(rows, key) do
    rows
    |> entries()
    |> Enum.group_by(&key.(&1.row))
  end

  @doc """
  The pool's files as artifacts with every version, withdrawn ones included, oldest first: what a
  project chat's Docs draws, since a project chat's artifacts are not a ticket's to list
  (`docs/design/ui.md` § Docs).
  """
  @spec artifacts(pool()) :: [{Artifact.t(), [Version.t()]}]
  def artifacts(pool) do
    scope =
      case pool do
        {:ticket, id} -> dynamic([a], a.ticket_id == ^id)
        {:job, id} -> dynamic([a], a.job_id == ^id)
      end

    versions = from(v in Version, order_by: v.version)

    from(a in Artifact,
      where: ^scope,
      where: like(a.name, ^(@prefix <> "%")),
      order_by: a.name,
      preload: [versions: ^versions]
    )
    |> Repo.all()
    |> Enum.map(&{&1, &1.versions})
  end

  # -- describing --------------------------------------------------------------------------------

  @doc """
  What each row was attached to, in words, and by whom: `%{id => %{to: String.t(), by: String.t()}}`.
  Batched — one query per kind of anchor however many rows — and the one place the words are made,
  for the manifest and for the pages.
  """
  @spec describe([Attachment.t()]) :: %{String.t() => %{to: String.t(), by: String.t()}}
  def describe([]), do: %{}

  def describe(rows) do
    versions = anchor_versions(rows)
    events = anchor_events(rows)
    users = author_users(rows)

    Map.new(rows, fn a ->
      {a.id, %{to: to_words(a, versions, events), by: by_words(a, users)}}
    end)
  end

  defp anchor_versions(rows) do
    ids = for a <- rows, a.to_version_id, do: a.to_version_id

    from(v in Version,
      join: art in Artifact,
      on: art.id == v.artifact_id,
      where: v.id in ^ids,
      select: {v.id, art.name, v.version}
    )
    |> Repo.all()
    |> Map.new(fn {id, name, version} -> {id, {name, version}} end)
  end

  defp anchor_events(rows) do
    seqs = for a <- rows, a.to_event_seq, do: a.to_event_seq

    from(e in Event, where: e.seq in ^seqs, select: {e.seq, e.type})
    |> Repo.all()
    |> Map.new()
  end

  defp author_users(rows) do
    ids = for a <- rows, a.user_id, do: a.user_id

    from(u in User, where: u.id in ^ids, select: {u.id, u.email}) |> Repo.all() |> Map.new()
  end

  defp to_words(%{to_kind: :ticket}, _versions, _events), do: "the ticket"

  defp to_words(%{to_kind: :document, to_version_id: id}, versions, _events) do
    case versions[id] do
      {name, version} -> "`#{name}` version #{version}"
      nil -> "a document"
    end
  end

  defp to_words(%{to_kind: :message}, _versions, _events), do: "a chat message"
  defp to_words(%{to_kind: :answer}, _versions, _events), do: "an answer"

  defp to_words(%{to_kind: :note, to_event_seq: seq}, _versions, events) do
    case events[seq] do
      "approval.rejected" -> "a rejection note"
      "approval.approved" -> "an approval note"
      "transition.taken" -> "a transition's comment"
      "ticket.retried" -> "a note to run the state again"
      "job.extended" -> "a note extending a job"
      _other -> "a note"
    end
  end

  defp by_words(%{author: %{"kind" => "api", "name" => name}}, _users), do: "the token #{name}"
  defp by_words(%{user_id: id}, users) when is_binary(id), do: Map.get(users, id, "a person")
  defp by_words(_attachment, _users), do: "the platform"

  @doc """
  The spec's `attachments` map for a run: the pool as every run is handed it, in words
  (`ForgeCore.Job.Spec`'s field), from `files` — `pool/1`'s answer, when the caller already read it for the
  assignment — or from a read of its own. Never stored, and carrying no key and no token.
  """
  @spec manifest(pool(), [map()] | nil) :: map()
  def manifest(pool, files \\ nil) do
    files = files || pool(pool)
    failed = not_received(pool)
    words = describe(Enum.map(files, & &1.attachment) ++ failed)

    %{
      "files" =>
        Enum.map(files, fn f ->
          said = words[f.attachment.id]

          %{
            "file" => f.file,
            "name" => f.name,
            "version" => f.version,
            "size" => f.size,
            "to" => said.to,
            "by" => said.by,
            "at" => at(f.attachment.inserted_at),
            "original" => f.attachment.original_name
          }
        end),
      "not_received" =>
        Enum.map(failed, fn a ->
          said = words[a.id]

          %{
            "original" => a.original_name,
            "to" => said.to,
            "by" => said.by,
            "at" => at(a.inserted_at)
          }
        end)
    }
  end

  defp at(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  @doc """
  The pool as a worker is handed it (`docs/design/attachments.md` § Delivery): each live file's folder
  name, version, key, size, hash and a store `get` token that outlasts `outlasting_ms` — the
  preparation margin, as every other file a worker fetches before it starts. String keys, as the
  assignment is JSON.
  """
  @spec deliveries(pool() | [map()], non_neg_integer()) :: [map()]
  def deliveries(pool, outlasting_ms) when is_tuple(pool),
    do: deliveries(pool(pool), outlasting_ms)

  def deliveries(files, outlasting_ms) when is_list(files) do
    for f <- files do
      %{
        "file" => f.file,
        "version_id" => f.version_id,
        "key" => f.key,
        "token" => Storage.Token.sign(:get, f.key, outlasting_ms: outlasting_ms),
        "size" => f.size,
        "hash" => f.hash
      }
    end
  end

  @doc """
  What a message says of the files that came with it, for an agent
  (`ForgeCore.Prompt.message_files/2`): `{files, not_received}`, the files as they are in the folder
  *now* — a later version of the same name may have taken the plain one — and not the ones
  withdrawn since. `rows` are the attachments of one event.
  """
  @spec message_files(pool(), [Attachment.t()]) :: {[map()], [String.t()]}
  def message_files(pool, rows) do
    in_folder = pool |> pool() |> Map.new(&{&1.version_id, &1})

    files =
      for %Attachment{artifact_version_id: id} <- rows,
          entry = in_folder[id],
          do: %{"file" => entry.file, "size" => entry.size}

    {files, for(%Attachment{artifact_version_id: nil} = a <- rows, do: a.original_name)}
  end

  # -- withdrawing -------------------------------------------------------------------------------

  @doc """
  Withdraws one version of a file, or `:all` of its versions, of the pool (`docs/design/attachments.md`
  § Withdrawing). **A person only**: allowed to whoever attached it and to an admin of the project; a
  file a project token attached, to an admin only. The bytes are deleted from the store after the
  commit; the record, with who withdrew it, when and why, stays.

  `{:ok, [Attachment.t()]}` (the rows withdrawn), `{:error, :forbidden}` or `{:error, :not_found}`.
  """
  @spec withdraw(pool(), User.t(), String.t(), pos_integer() | :all, String.t() | nil) ::
          {:ok, [Attachment.t()]} | {:error, :forbidden | :not_found}
  def withdraw(pool, %User{} = user, name, which, reason) do
    result =
      Repo.transact(fn ->
        project_id = lock_pool(pool)
        scope = scope_for(user, project_id)

        rows = withdrawable(pool, name, which)

        cond do
          rows == [] -> {:error, :not_found}
          not Enum.all?(rows, &may_withdraw?(scope, user, &1)) -> {:error, :forbidden}
          true -> do_withdraw(pool, user, rows, reason)
        end
      end)

    with {:ok, rows} <- result do
      delete_bytes(rows)
      {:ok, rows}
    end
  end

  defp scope_for(user, project_id) do
    Scope.for_project(Scope.for_user(user), Projects.get!(project_id))
  end

  defp may_withdraw?(scope, user, %Attachment{} = attachment) do
    Access.can?(scope, :manage) or
      (Access.can?(scope, :use) and attachment.user_id == user.id)
  end

  # Locked so two withdrawals of one file are one. Equivalent mutant in the suite, for the reason
  # `lock_pool/1` gives.
  defp withdrawable(pool, name, which) do
    base =
      from a in Attachment,
        join: v in Version,
        on: v.id == a.artifact_version_id,
        where: ^pool_clause(pool),
        where: a.name == ^name and is_nil(a.withdrawn_at),
        lock: "FOR UPDATE",
        select: {a, v.version}

    base
    |> restrict(which)
    |> Repo.all()
    |> Enum.map(&elem(&1, 0))
  end

  defp restrict(query, :all), do: query

  defp restrict(query, version) when is_integer(version),
    do: from([a, v] in query, where: v.version == ^version)

  defp do_withdraw(pool, user, rows, reason) do
    now = DateTime.utc_now()
    reason = reason && String.slice(String.trim(reason), 0, 500)
    reason = if reason == "", do: nil, else: reason
    by = Events.encode_actor({:user, user.id})
    ids = Enum.map(rows, & &1.id)

    {_count, _} =
      Repo.update_all(from(a in Attachment, where: a.id in ^ids),
        set: [
          withdrawn_at: now,
          withdrawn_by: by,
          withdrawn_user_id: user.id,
          withdraw_reason: reason
        ]
      )

    {:ok, _event} =
      Events.append("attachment.withdrawn", {:user, user.id}, %{
        ticket_id: ticket_of(pool),
        job_id: job_of(pool),
        payload: %{
          "name" => hd(rows).name,
          "versions" =>
            Repo.all(
              from v in Version,
                where: v.id in ^Enum.map(rows, & &1.artifact_version_id),
                select: v.version,
                order_by: v.version
            ),
          "reason" => reason
        }
      })

    {:ok, Repo.all(from a in Attachment, where: a.id in ^ids, order_by: a.inserted_at)}
  end

  defp delete_bytes(rows) do
    versions =
      Repo.all(from v in Version, where: v.id in ^Enum.map(rows, & &1.artifact_version_id))

    Enum.each(versions, fn v ->
      with {:ok, key} <- Storage.key_from_uri(v.blob_uri),
           :ok <- Storage.delete(key) do
        :ok
      else
        reason ->
          Logger.warning(
            "attachments: bytes of #{v.id} not deleted (#{inspect(reason)}); the sweep will"
          )
      end
    end)
  end

  @doc "Whether a person may withdraw this file: the attacher or an admin of its project."
  @spec withdrawable_by?(Scope.t() | nil, User.t() | nil, Attachment.t()) :: boolean()
  def withdrawable_by?(_scope, _user, %Attachment{withdrawn_at: at}) when not is_nil(at),
    do: false

  def withdrawable_by?(_scope, nil, _attachment), do: false
  def withdrawable_by?(scope, user, attachment), do: may_withdraw?(scope, user, attachment)
end
