defmodule Forge.Pages do
  @moduledoc """
  Pages an agent writes, hosted by forge, and the live store each keeps
  (`docs/design/pages.md`).

  A page belongs to a ticket or to a project chat: a **scope**, `{:ticket, ticket_id}` or
  `{:chat, job_id}`. Its files are blob artifacts named `<page>/<file>` (`Forge.Jobs.Blobs`), its
  versions are `Forge.Pages.Version` rows, and its store is `Forge.Pages.Entry` rows. **Every
  guard on the store is here**, under the page's row lock: read only, the limits and the counter
  a conditional write names. The doors — `Forge.Operator` for a person or a token, the job door
  for a job — decide who may reach a page, then end in these functions.

  A **writer** is `{:user, id}`, `{:job, id}`, `{:token, id}` (or the `{:api, id, name}` an actor
  is). The store holds JSON values and **never logs one**: a value is hostile data, and a burst
  names keys only.

  ## Counters

  `pages.seq` is per page. Every set or delete takes `seq + 1`, so a key deleted and written again
  never has a counter an earlier reader holds. A write that names `counter: n` is refused when the
  key's counter is not `n` (`nil` for a key expected to be absent) and the writer is handed the
  current entry; `counter: :any` is a person's last-write-wins.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Forge.{Artifacts, Events, Repo}
  alias Forge.Jobs.Job
  alias Forge.Pages.{Burst, Entry, Outside, Page, Version}
  alias ForgeCore.Workflow

  @typedoc "A ticket's pages, or a project chat's own."
  @type scope :: {:ticket, String.t()} | {:chat, String.t()}
  @type writer :: {:user, String.t()} | {:job, String.t()} | {:token, String.t()}
  @type counter :: non_neg_integer() | nil | :any
  @type reason :: :done | :cancelled | :chat_ended

  @defaults [
    value_bytes: 256 * 1024,
    key_bytes: 255,
    keys: 2000,
    data_bytes: 4 * 1024 * 1024,
    burst_quiet_seconds: 60,
    burst_max_seconds: 600,
    burst_keys: 50
  ]

  # `page_entries.key`, `pages.name` and the names a burst keeps are `varchar(255)`: more than that
  # raises in the database, which is a crash where a refusal belongs.
  @column_max 255

  # The name a page's own library is served under: a page file of it would be shadowed.
  @reserved_file "forge-page.js"

  @doc "The limits, from `config :forge, Forge.Pages` over the defaults, so the suite can test them small."
  @spec limits() :: keyword()
  def limits, do: Keyword.merge(@defaults, Application.get_env(:forge, __MODULE__, []))

  @doc "The one file name a page may not have: the library forge serves in its place."
  @spec reserved_file() :: String.t()
  def reserved_file, do: @reserved_file

  # -- scopes and reading -----------------------------------------------------------------------

  @doc """
  The scope a job reaches: its ticket's pages, or — a chat with no ticket — its own. `nil` for a
  command, which reaches none.
  """
  @spec scope_of_job(Job.t()) :: scope() | nil
  def scope_of_job(%Job{kind: :command}), do: nil
  def scope_of_job(%Job{ticket_id: ticket_id}) when is_binary(ticket_id), do: {:ticket, ticket_id}
  def scope_of_job(%Job{kind: :chat, id: id}), do: {:chat, id}
  def scope_of_job(%Job{}), do: nil

  @doc "The scope the artifacts of a page's files are in: `Forge.Artifacts`' own spelling of it."
  @spec artifact_scope(scope() | Page.t()) :: Artifacts.scope()
  def artifact_scope({:ticket, id}), do: {:ticket, id}
  def artifact_scope({:chat, id}), do: {:job, id}
  def artifact_scope(%Page{ticket_id: id}) when is_binary(id), do: {:ticket, id}
  def artifact_scope(%Page{job_id: id}), do: {:job, id}

  @doc "The scope a page row belongs to."
  @spec scope(Page.t()) :: scope()
  def scope(%Page{ticket_id: id}) when is_binary(id), do: {:ticket, id}
  def scope(%Page{job_id: id}), do: {:chat, id}

  @doc "A page by id, or nil."
  @spec get(String.t()) :: Page.t() | nil
  def get(id) when is_binary(id), do: Repo.get(Page, id)

  @doc "A page by its name within a scope, or nil: with a row, whether or not it has a version."
  @spec get(scope(), String.t()) :: Page.t() | nil
  def get(scope, name) when is_binary(name),
    do: Repo.one(from p in Page, where: ^in_scope(scope), where: p.name == ^name)

  @doc """
  The pages of a scope **that have a version**, by name, each with its latest version. A page
  whose store was written before anything was published is not listed (`docs/design/pages.md`).
  """
  @spec list(scope()) :: [%{page: Page.t(), version: Version.t()}]
  def list(scope) do
    latest =
      from v in Version,
        group_by: v.page_id,
        select: %{page_id: v.page_id, version: max(v.version)}

    Repo.all(
      from p in Page,
        join: v in Version,
        on: v.page_id == p.id,
        join: l in subquery(latest),
        on: l.page_id == v.page_id and l.version == v.version,
        where: ^in_scope(scope),
        order_by: p.name,
        select: %{page: p, version: v}
    )
  end

  @doc "The latest version of a page, or nil when it has none yet."
  @spec latest_version(Page.t()) :: Version.t() | nil
  def latest_version(%Page{id: id}) do
    Repo.one(from v in Version, where: v.page_id == ^id, order_by: [desc: v.version], limit: 1)
  end

  @doc "Every version of a page, newest first."
  @spec versions(Page.t()) :: [Version.t()]
  def versions(%Page{id: id}),
    do: Repo.all(from v in Version, where: v.page_id == ^id, order_by: [desc: v.version])

  @doc """
  Why a scope's pages cannot be written, or `false`: the ticket is done or cancelled — read when
  each write happens, so a jump that reopened it makes them writable again — or a project chat
  has been ended for good (`docs/design/pages.md` § Who may write).
  """
  @spec read_only(scope()) :: false | {true, reason()}
  def read_only({:ticket, id}) do
    case Repo.one(from t in Forge.Tickets.Ticket, where: t.id == ^id, select: t.status) do
      status when status in [:done, :cancelled] -> {true, status}
      _open_or_gone -> false
    end
  end

  def read_only({:chat, id}),
    do: if(Forge.Conversations.ended?(id), do: {true, :chat_ended}, else: false)

  @doc "A page's keys, in key order."
  @spec entries(Page.t()) :: [Entry.t()]
  def entries(%Page{id: id}),
    do: Repo.all(from e in Entry, where: e.page_id == ^id, order_by: e.key)

  @doc "One key of a page, or nil."
  @spec entry(Page.t(), String.t()) :: Entry.t() | nil
  def entry(%Page{id: id}, key),
    do: Repo.one(from e in Entry, where: e.page_id == ^id and e.key == ^key)

  @doc "A page's store as `%{key => value}` — the values only, which is what the archive shows."
  @spec data_map(Page.t()) :: %{String.t() => term()}
  def data_map(page), do: Map.new(entries(page), &{&1.key, &1.value})

  # -- the store --------------------------------------------------------------------------------

  @doc """
  Sets `key` to `value` (any JSON value) on `page`.

  `opts`: `counter:` — `:any` (the default; a person's), an integer the key must still have, or
  `nil` for a key that must not exist.

  `{:ok, entry}`, or `{:error, {:changed, current_entry_or_nil}}`, `{:error, {:read_only,
  reason}}`, `{:error, {:limit, name, max}}`, `{:error, {:invalid_key, why}}`,
  `{:error, :invalid_value}` (not JSON, or a string holding a NUL character, which `jsonb`
  refuses) or `{:error, :not_found}` for a page that is gone.
  """
  @spec put(Page.t(), String.t(), term(), writer(), keyword()) ::
          {:ok, Entry.t()} | {:error, term()}
  def put(%Page{} = page, key, value, writer, opts \\ []) do
    with :ok <- check_key(key),
         {:ok, encoded} <- encode(value),
         :ok <- check_nul(encoded),
         :ok <- check_value(encoded) do
      write(page, writer, opts, {:set, key, value, byte_size(encoded) + byte_size(key)})
    end
  end

  @doc "Deletes `key` from `page`; `opts` as for `put/5`. Deleting an absent key writes nothing."
  @spec delete(Page.t(), String.t(), writer(), keyword()) ::
          {:ok, Entry.t() | nil} | {:error, term()}
  def delete(%Page{} = page, key, writer, opts \\ []) do
    with :ok <- check_key(key), do: write(page, writer, opts, {:delete, key})
  end

  @doc """
  A job's write: its page by name, within the scope it reaches (`scope_of_job/1`), never one the
  job names. `op` is `{:set, key, value}` or `{:delete, key}`; `opts[:counter]` is **required** —
  a job never overwrites what it has not read — and an absent one is `{:error, :counter_required}`.

  A job may write the store of a page that has a row, or one its own state declares as `name@`;
  a conversation may write any valid page name. A command reaches nothing (`{:error, :forbidden}`).
  """
  @spec job_write(
          Job.t(),
          String.t(),
          {:set, String.t(), term()} | {:delete, String.t()},
          keyword()
        ) ::
          {:ok, Entry.t() | nil} | {:error, term()}
  def job_write(%Job{} = job, name, op, opts) do
    with {:ok, scope} <- job_scope(job),
         :ok <- counter_named(opts),
         {:ok, page} <- job_page(job, scope, name, :write) do
      case op do
        {:set, key, value} -> put(page, key, value, {:job, job.id}, opts)
        {:delete, key} -> delete(page, key, {:job, job.id}, opts)
      end
    end
  end

  defp job_scope(job) do
    case scope_of_job(job) do
      nil -> {:error, :forbidden}
      scope -> {:ok, scope}
    end
  end

  defp counter_named(opts),
    do: if(Keyword.has_key?(opts, :counter), do: :ok, else: {:error, :counter_required})

  @doc """
  The page of `name` a job reads, or `{:error, :not_found}`; `{:error, :forbidden}` for a command.
  Reading needs a row, which a page has once anything has been written or published.
  """
  @spec job_page(Job.t(), String.t(), :read | :write) :: {:ok, Page.t()} | {:error, term()}
  def job_page(%Job{} = job, name, mode \\ :read) do
    with {:ok, scope} <- job_scope(job), do: job_page(job, scope, name, mode)
  end

  defp job_page(job, scope, name, mode) do
    case {get(scope, name), mode} do
      {%Page{} = page, _mode} -> {:ok, page}
      {nil, :write} -> create_for_job(job, scope, name)
      {nil, :read} -> {:error, :not_found}
    end
  end

  # A store may exist before its page has a version: a clone seeds its data while the files are
  # still in `out/`. Only a job that declares the page, or a conversation, may start one.
  defp create_for_job(job, scope, name) do
    if Workflow.valid_name?(name) and (job.kind == :chat or declares?(job, name)),
      do: ensure(scope, name),
      else: {:error, :not_found}
  end

  defp declares?(%Job{spec: spec}, name),
    do: name in Workflow.page_names((spec || %{})["produces"] || [])

  @doc "The page of `name` in `scope`, created when it has no row yet."
  @spec ensure(scope(), String.t()) :: {:ok, Page.t()} | {:error, term()}
  def ensure(scope, name), do: ensure(Repo, scope, name)

  @doc false
  def ensure(_repo, _scope, name) when byte_size(name) > @column_max,
    do: {:error, {:limit, "name", @column_max}}

  def ensure(repo, scope, name) do
    query = from p in Page, where: ^in_scope(scope), where: p.name == ^name

    case repo.one(query) do
      %Page{} = page ->
        {:ok, page}

      nil ->
        # `on_conflict: :nothing` and a read after it, and not the struct the insert returns: a
        # page made in the same instant by another writer wins, and the struct would carry the id
        # this one generated for a row that was never inserted.
        {:ok, _page} =
          repo.insert(
            Map.merge(
              %Page{name: name, project_id: project_of(repo, scope)},
              scope_columns(scope)
            ),
            on_conflict: :nothing
          )

        {:ok, repo.one!(query)}
    end
  end

  defp write(page, writer, opts, op) do
    counter = Keyword.get(opts, :counter, :any)
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      locked = Repo.one(from p in Page, where: p.id == ^page.id, lock: "FOR UPDATE")

      with %Page{} <- locked || {:error, :not_found},
           :ok <- writable(locked),
           current = entry(locked, elem(op, 1)),
           :ok <- expected(current, counter),
           {:ok, change} <- apply_change(locked, current, op, writer, now) do
        change
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {entry, nil}} ->
        {:ok, entry}

      {:ok, {entry, event}} ->
        broadcast(page.id, event)
        {:ok, entry}

      {:error, _reason} = error ->
        error
    end
  end

  defp writable(%Page{} = page) do
    case read_only(scope(page)) do
      false -> :ok
      {true, reason} -> {:error, {:read_only, reason}}
    end
  end

  defp expected(_current, :any), do: :ok
  defp expected(nil, nil), do: :ok
  defp expected(%Entry{counter: n}, n) when is_integer(n), do: :ok
  defp expected(current, _other), do: {:error, {:changed, current}}

  defp apply_change(page, current, {:set, key, value, size}, writer, now) do
    old_size = if current, do: current.size, else: 0
    new_keys = page.key_count + if(current, do: 0, else: 1)
    new_bytes = page.data_bytes - old_size + size
    limits = limits()

    cond do
      new_keys > limits[:keys] ->
        {:error, {:limit, "keys", limits[:keys]}}

      new_bytes > limits[:data_bytes] ->
        {:error, {:limit, "data", limits[:data_bytes]}}

      true ->
        counter = page.seq + 1

        attrs =
          writer
          |> writer_columns()
          |> Map.merge(%{
            page_id: page.id,
            key: key,
            value: value,
            counter: counter,
            size: size,
            written_at: now
          })

        entry =
          case current do
            nil ->
              Repo.insert!(struct!(Entry, attrs))

            %Entry{} = row ->
              row
              |> Ecto.Changeset.change(attrs)
              |> Repo.update!()
          end

        settle(page, counter, new_keys, new_bytes, key, writer, now)
        {:ok, {entry, %{key: key, op: :set, value: value, counter: counter, writer: writer}}}
    end
  end

  # Nothing to delete, nothing written: no counter taken, no event, nobody told.
  defp apply_change(_page, nil, {:delete, _key}, _writer, _now), do: {:ok, {nil, nil}}

  defp apply_change(page, %Entry{} = current, {:delete, key}, writer, now) do
    counter = page.seq + 1
    Repo.delete!(current)
    settle(page, counter, page.key_count - 1, page.data_bytes - current.size, key, writer, now)
    {:ok, {current, %{key: key, op: :delete, value: nil, counter: counter, writer: writer}}}
  end

  # The page's counters and the burst, in the write's own transaction so a crash loses no audit.
  defp settle(page, counter, key_count, data_bytes, key, writer, now) do
    page
    |> Ecto.Changeset.change(seq: counter, key_count: key_count, data_bytes: data_bytes)
    |> Repo.update!()

    note_burst(page, writer, key, now)
  end

  defp note_burst(page, writer, key, now) do
    writer_key = writer_key(writer)
    cap = limits()[:burst_keys]

    # `FOR UPDATE`: the sweeper deletes a due burst under this same lock (`Forge.Pages.Bursts`,
    # which skips a locked row), so a delete cannot land between this read and the update.
    case Repo.one(
           from b in Burst,
             where: b.page_id == ^page.id and b.writer_key == ^writer_key,
             lock: "FOR UPDATE"
         ) do
      nil ->
        Repo.insert!(%Burst{
          page_id: page.id,
          writer_key: writer_key,
          writer: writer_map(writer),
          opened_at: now,
          last_at: now,
          changes: 1,
          keys: [key],
          key_count: 1
        })

      %Burst{keys: keys} = burst ->
        seen? = key in keys
        keys = if seen? or length(keys) >= cap, do: keys, else: keys ++ [key]

        # `key_count` is exact while every name fits in `keys`. Past the cap a name is not kept, so
        # a repeat of one cannot be told from a new one: each write to such a key adds one, and the
        # count is an upper bound on the distinct keys (`changes` is the exact figure).
        burst
        |> Ecto.Changeset.change(
          last_at: now,
          changes: burst.changes + 1,
          keys: keys,
          key_count: burst.key_count + if(seen?, do: 0, else: 1)
        )
        |> Repo.update!()
    end
  end

  # -- viewers' toggle --------------------------------------------------------------------------

  @doc "Whether this person has switched outside addresses on for this page."
  @spec outside?(String.t(), String.t()) :: boolean()
  def outside?(user_id, page_id),
    do: Repo.exists?(from o in Outside, where: o.user_id == ^user_id and o.page_id == ^page_id)

  @doc """
  Switches outside access on or off for one person on one page, recording who, which page and
  when in the event log — and nothing when it is already so. The guard (the viewer reaches the
  page) is `Forge.Operator.set_page_outside/4`'s.
  """
  @spec set_outside(String.t(), Page.t(), boolean()) :: {:ok, boolean()} | {:error, term()}
  def set_outside(user_id, %Page{} = page, on?) when is_boolean(on?) do
    if outside?(user_id, page.id) == on? do
      {:ok, on?}
    else
      Multi.new()
      |> toggle(on?, user_id, page)
      |> Events.log(:event, "page.outside_access", {:user, user_id}, %{
        ticket_id: page.ticket_id,
        job_id: page.job_id,
        project_id: page.project_id,
        payload: %{"page" => page.name, "page_id" => page.id, "on" => on?}
      })
      |> Repo.transaction()
      |> case do
        {:ok, _changes} -> {:ok, on?}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  defp toggle(multi, true, user_id, page),
    do: Multi.insert(multi, :toggle, %Outside{user_id: user_id, page_id: page.id})

  defp toggle(multi, false, user_id, page) do
    Multi.delete_all(
      multi,
      :toggle,
      from(o in Outside, where: o.user_id == ^user_id and o.page_id == ^page.id)
    )
  end

  # -- publishing -------------------------------------------------------------------------------

  @doc """
  Adds the steps that record a new version of page `name` in `scope` to `multi`, under
  `{key, :page}` and `{key, :version}`: `files` is `%{file => artifact_version_id}`, already
  recorded (or reused from the latest version) by the caller.

  A job's publish always makes a version (`always?: true`); a chat's turn makes one only when the
  file set differs from the latest version's (`always?: false`), and `{key, :version}` is then
  nil. Nothing is added to the log but one `page.published` event, in its own right: the files'
  `artifact.version_written` events stay as they are.
  """
  @spec put_version(Multi.t(), term(), scope(), String.t(), (map() -> map()), keyword()) ::
          Multi.t()
  def put_version(multi, key, scope, name, files_fun, opts) when is_function(files_fun, 1) do
    job = Keyword.fetch!(opts, :job)
    always? = Keyword.get(opts, :always?, true)

    multi
    |> Multi.run({key, :page}, fn repo, _changes -> ensure(repo, scope, name) end)
    |> Multi.run({key, :version}, fn repo, changes ->
      page = changes[{key, :page}]
      files = files_fun.(changes)

      latest =
        repo.one(
          from v in Version, where: v.page_id == ^page.id, order_by: [desc: v.version], limit: 1
        )

      if not always? and latest != nil and latest.files == files do
        {:ok, nil}
      else
        repo.insert(%Version{
          page_id: page.id,
          version: if(latest, do: latest.version + 1, else: 1),
          job_id: job.id,
          files: files
        })
      end
    end)
    |> Multi.run({key, :announced}, fn repo, changes ->
      case changes[{key, :version}] do
        nil ->
          {:ok, nil}

        version ->
          page = changes[{key, :page}]

          %Events.Event{}
          |> Events.Event.changeset(%{
            type: "page.published",
            actor: Events.encode_actor({:job, job.id}),
            ticket_id: page.ticket_id,
            job_id: job.id,
            project_id: page.project_id,
            payload: %{
              "page" => page.name,
              "page_id" => page.id,
              "version" => version.version,
              "files" => map_size(version.files),
              "job_id" => job.id
            }
          })
          |> repo.insert()
      end
    end)
  end

  @doc "Tells subscribers of a page that a version was published; the caller's, after its commit."
  @spec announce_published(Page.t(), pos_integer()) :: :ok
  def announce_published(%Page{id: id}, version),
    do: Phoenix.PubSub.broadcast(Forge.PubSub, topic(id), {:page_published, id, version})

  # -- the spec's view ---------------------------------------------------------------------------

  @doc """
  What a job's spec says of its scope's pages when it is assigned (`docs/design/pages.md`, the
  worker's `spec.pages`): per page that has a version — `name`, `version`, `files` (`file =>
  %{"hash", "size"}`), `keys`, `read_only` (a reason string or nil), `by` and `at`. String keys,
  as a spec crosses the wire. Never stored on the job.
  """
  @spec manifest(scope() | nil) :: [map()]
  def manifest(nil), do: []

  def manifest(scope) do
    read_only = read_only(scope)

    for %{page: page, version: version} <- list(scope) do
      %{
        "name" => page.name,
        "version" => version.version,
        "files" => file_facts(version.files),
        "keys" => page.key_count,
        "read_only" => read_only_word(read_only),
        "by" => said_by(version.job_id),
        "at" => DateTime.to_iso8601(version.inserted_at)
      }
    end
  end

  defp read_only_word({true, :chat_ended}), do: "ended"
  defp read_only_word({true, reason}), do: Atom.to_string(reason)
  defp read_only_word(false), do: nil

  # Who wrote a version, in the words the product uses: an agent in its state, or a chat.
  defp said_by(nil), do: nil

  defp said_by(job_id) do
    case Repo.one(from j in Job, where: j.id == ^job_id, select: {j.kind, j.state}) do
      {:chat, _state} -> "a chat"
      {_kind, state} when is_binary(state) -> "an agent in " <> state
      _gone -> nil
    end
  end

  defp file_facts(files) do
    ids = Map.values(files)

    by_id =
      Repo.all(
        from v in Artifacts.Version,
          where: v.id in ^ids,
          select: {v.id, v.content_hash, v.blob_uri}
      )
      |> Map.new(fn {id, hash, uri} -> {id, {hash, uri}} end)

    Map.new(files, fn {file, id} ->
      {hash, uri} = Map.get(by_id, id, {nil, nil})
      {file, %{"hash" => bare_hash(hash), "size" => size_of(uri)}}
    end)
  end

  defp bare_hash("sha256:" <> hex), do: hex
  defp bare_hash(other), do: other

  # `read_range/3` for the size: `stat/1` hashes the object, and a page may hold gigabytes.
  defp size_of(uri) when is_binary(uri) do
    with {:ok, key} <- Forge.Storage.key_from_uri(uri),
         {:ok, %{size: size}} <- Forge.Storage.read_range(key, 0, 0) do
      size
    else
      _gone -> nil
    end
  end

  defp size_of(nil), do: nil

  # -- pubsub -------------------------------------------------------------------------------------

  @doc "The PubSub topic of a page's changes and versions."
  @spec topic(String.t()) :: String.t()
  def topic(page_id), do: "page:" <> page_id

  @doc "Subscribes the caller to `{:page_changed, page_id, change}` and `{:page_published, page_id, version}`."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(page_id), do: Phoenix.PubSub.subscribe(Forge.PubSub, topic(page_id))

  defp broadcast(page_id, change) do
    Phoenix.PubSub.broadcast(Forge.PubSub, topic(page_id), {:page_changed, page_id, change})
  end

  # -- validation ---------------------------------------------------------------------------------

  defp check_key(key) when is_binary(key) do
    max = min(limits()[:key_bytes], @column_max)

    cond do
      not String.valid?(key) ->
        {:error, {:invalid_key, "is not UTF-8"}}

      key == "" ->
        {:error, {:invalid_key, "is empty"}}

      byte_size(key) > max ->
        {:error, {:limit, "key", max}}

      String.match?(key, ~r/[\x00-\x1f\x7f]/) ->
        {:error, {:invalid_key, "has a control character"}}

      true ->
        :ok
    end
  end

  defp check_key(_key), do: {:error, {:invalid_key, "is not text"}}

  defp encode(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> {:error, :invalid_value}
    end
  end

  # `jsonb` holds no U+0000: it raises where this refuses. Jason writes one as `\u0000`, and a
  # backslash followed by the text u0000 as `\\u0000`, so only an odd run of backslashes before
  # it is a NUL.
  defp check_nul(encoded) do
    if Regex.match?(~r/(?<!\\)(?:\\\\)*\\u0000/, encoded),
      do: {:error, :invalid_value},
      else: :ok
  end

  defp check_value(encoded) do
    max = limits()[:value_bytes]
    if byte_size(encoded) > max, do: {:error, {:limit, "value", max}}, else: :ok
  end

  # -- writers --------------------------------------------------------------------------------------

  defp writer_columns({:user, id}), do: %{user_id: id, job_id: nil, token_id: nil}
  defp writer_columns({:job, id}), do: %{user_id: nil, job_id: id, token_id: nil}
  defp writer_columns({:token, id}), do: %{user_id: nil, job_id: nil, token_id: id}
  defp writer_columns({:api, id, _name}), do: writer_columns({:token, id})

  defp writer_key({:api, id, _name}), do: writer_key({:token, id})
  defp writer_key({kind, id}), do: "#{kind}:#{id}"

  # What a burst, and the event it becomes, says of its writer: a person, a job and the state it
  # ran, or a token and its name — read once, when the burst opens.
  defp writer_map({:user, id}), do: %{"kind" => "user", "id" => id}

  defp writer_map({:job, id}),
    do: %{
      "kind" => "job",
      "id" => id,
      "state" => Repo.one(from j in Job, where: j.id == ^id, select: j.state)
    }

  defp writer_map({:token, id}),
    do: %{
      "kind" => "api",
      "id" => id,
      "name" => Repo.one(from t in Forge.Git.Token, where: t.id == ^id, select: t.name)
    }

  defp writer_map({:api, id, name}), do: %{"kind" => "api", "id" => id, "name" => name}

  # -- scope plumbing -------------------------------------------------------------------------------

  defp in_scope({:ticket, id}), do: dynamic([p], p.ticket_id == ^id)
  defp in_scope({:chat, id}), do: dynamic([p], p.job_id == ^id)

  defp scope_columns({:ticket, id}), do: %{ticket_id: id, job_id: nil}
  defp scope_columns({:chat, id}), do: %{ticket_id: nil, job_id: id}

  defp project_of(repo, {:ticket, id}),
    do: repo.one!(from t in Forge.Tickets.Ticket, where: t.id == ^id, select: t.project_id)

  defp project_of(repo, {:chat, id}),
    do: repo.one!(from j in Job, where: j.id == ^id, select: j.project_id)
end
