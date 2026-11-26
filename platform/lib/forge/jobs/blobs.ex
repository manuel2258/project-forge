defmodule Forge.Jobs.Blobs do
  @moduledoc """
  A run's groups of files on the platform (`docs/design/workflow-grammar-v1.md` § Semantics,
  `docs/design/storage.md` § Serving): where the worker may put them, and recording what it put as
  blob versions on the ticket.

  What the worker reports is not a guard. A file is recorded only when its group is one the job
  declared, its name is an artifact name, and its key is under the job's own keys and in the
  store — whatever the result says about it.
  """

  alias Ecto.Multi
  alias Forge.{Artifacts, Pages, Storage}
  alias Forge.Jobs.Job
  alias ForgeCore.Job.{Result, Spec}
  alias ForgeCore.Workflow

  require Logger

  @doc """
  What the assignment carries for a job that declares a group of files or a page: a prefix of its
  own keys, fresh per assignment as a transcript's key is, and a `put` token for it that lives
  `lifetime_ms` past its minting. Empty for a job that declares none.

  **A conversation always has one**: it declares nothing and may write a page at any turn
  (`docs/design/pages.md` § Recording a publish), so its token lives as long as the run may.
  """
  @spec outputs(Job.t(), Spec.t(), non_neg_integer()) :: map()
  def outputs(%Job{kind: kind} = job, %Spec{} = spec, lifetime_ms) do
    if kind == :chat or Spec.group_outputs(spec) != [] or Workflow.page_names(spec.produces) != [] do
      prefix = Storage.Key.job_prefix(job.id, "out-" <> Storage.Key.nonce())

      %{
        "outputs" => %{
          "prefix" => prefix,
          "token" => Storage.Token.sign_prefix(prefix, job: job.id, outlasting_ms: lifetime_ms)
        }
      }
    else
      %{}
    end
  end

  @doc """
  A run that says it converged but whose declared page was not kept — it has no `index.html` in
  what the worker reports, because the file was refused or would not upload — is an error, as one
  that never wrote the page is (`ForgeCore.Job.Outcome`): the worker decides its outcome before it
  uploads, so this is the one place that sees both. A page in `optional` is excused. Any other
  outcome is left as it is.
  """
  @spec require_pages(Spec.t(), Result.t()) :: Result.t()
  def require_pages(%Spec{} = spec, %Result{status: :finished, outcome: :converged} = result) do
    unkept =
      for page <- Workflow.page_names(spec.produces),
          page not in Spec.optional_outputs(spec),
          not Map.has_key?(result.blobs, page <> "/index.html"),
          do: page

    case unkept do
      [] ->
        result

      pages ->
        %{
          result
          | outcome: :error,
            declared_outcome: nil,
            reason: "missing outputs: " <> Enum.join(pages, ", ") <> " (no index.html was kept)"
        }
    end
  end

  def require_pages(_spec, result), do: result

  @doc """
  Adds a blob version to `multi` for each file of the result it may record: a group's, and a
  declared page's, which also makes the page's version (`put_pages/6`).
  """
  @spec put(Multi.t(), term(), Job.t(), Spec.t(), Result.t()) :: Multi.t()
  def put(multi, ticket_id, %Job{} = job, %Spec{} = spec, %Result{blobs: blobs}) do
    groups = Spec.group_outputs(spec)
    pages = Workflow.page_names(spec.produces)

    multi
    |> put_groups(ticket_id, job, groups, Map.reject(blobs, &of_page?(&1, pages)))
    |> put_pages({:ticket, ticket_id}, job, pages, blobs, always?: true)
  end

  # A page's files are recorded by `put_pages/6`, not as a group's: they are not reported twice.
  defp of_page?({name, _info}, pages), do: hd(String.split(name, "/", parts: 2)) in pages

  defp put_groups(multi, ticket_id, job, groups, blobs) do
    blobs
    |> Enum.sort()
    |> Enum.reduce(multi, fn {name, info}, multi ->
      with :ok <- declared(name, groups),
           {:ok, key} <- owned(job, info),
           {:ok, %{hash: hash}} <- Storage.stat(key) do
        Artifacts.put_version(multi, {:blob, name}, ticket_id, name, :blob, {:job, job.id}, %{
          blob_uri: Storage.uri(key),
          content_hash: hash
        })
      else
        {:error, reason} ->
          Logger.warning("job #{job.id} reported #{inspect(name)}: #{inspect(reason)}")
          multi
      end
    end)
  end

  @doc """
  Records the pages among `blobs` — `"<page>/<file>" => info` — and a version of each, in `scope`
  (an artifact scope: `{:ticket, id}` or `{:job, chat_id}`).

  `pages` names the pages that may be recorded; a file of another is never recorded. A page is
  recorded when its files include `index.html`. A file is reported either with its `"key"` — an
  upload, recorded as a new version of `<page>/<file>` unless its bytes equal the latest version's
  — or with a `"hash"` alone, which says the bytes are what the latest version holds (writing
  nothing) or what an earlier one does (the new page version then points at that one), since a job
  may skip an upload on the strength of a spec that a republish has overtaken. A hash no version
  holds is unrecorded, since there are no bytes to keep. With `always?: false` (a chat's turn) a
  version of the page is made only when its set of files differs from the latest version's.

  Nothing here fails the job: a file or page that cannot be recorded is logged and skipped, as a
  group's file is.
  """
  @spec put_pages(Multi.t(), Artifacts.scope(), Job.t(), [String.t()], map(), keyword()) ::
          Multi.t()
  def put_pages(multi, scope, %Job{} = job, pages, blobs, opts) do
    page_scope = page_scope(scope)

    pages
    |> Enum.sort()
    |> Enum.reduce(multi, fn page, multi ->
      members =
        for {name, info} <- blobs,
            [^page, file] <- [String.split(name, "/", parts: 2)],
            into: %{} do
          {file, info}
        end

      put_page(multi, scope, page_scope, job, page, members, opts)
    end)
  end

  @doc """
  Tells the subscribers of each page a committed `Multi` published a version of (`Forge.Pages`).
  The caller's, once its transaction has committed.
  """
  @spec announce(map()) :: :ok
  def announce(changes) do
    for {{{:page, _name} = key, :page}, %Pages.Page{} = page} <- changes,
        %Pages.Version{version: version} <- [changes[{key, :version}]] do
      Pages.announce_published(page, version)
    end

    :ok
  end

  defp page_scope({:ticket, id}), do: {:ticket, id}
  defp page_scope({:job, id}), do: {:chat, id}

  defp put_page(multi, _scope, _page_scope, _job, _page, members, _opts) when members == %{},
    do: multi

  # Decided before anything is added: a page whose `index.html` cannot be kept is not a page, and
  # the artifact versions of its other files would be loose `<page>/<file>` files in Docs.
  defp put_page(multi, scope, page_scope, job, page, members, opts) do
    plans =
      for {file, info} <- Enum.sort(members), into: %{} do
        {file, page_file(scope, job, page <> "/" <> file, file, info)}
      end

    files = for {file, {:ok, plan}} <- plans, into: %{}, do: {file, plan}
    log_unkept(job, page, plans)

    if Map.has_key?(files, "index.html") do
      multi = Enum.reduce(files, multi, &add_page_file(&2, scope, job, page, &1))

      Pages.put_version(
        multi,
        {:page, page},
        page_scope,
        page,
        &version_files(files, page, &1),
        job: job,
        always?: Keyword.get(opts, :always?, true)
      )
    else
      multi
    end
  end

  defp log_unkept(job, page, plans) do
    for {file, {:error, reason}} <- plans do
      Logger.warning(
        "job #{job.id} reported page file #{inspect(page <> "/" <> file)}: #{inspect(reason)}"
      )
    end

    :ok
  end

  # The page version's files, by name: the artifact version each is, reused or just written.
  defp version_files(files, page, changes) do
    Map.new(files, fn
      {file, {:reuse, id}} ->
        {file, id}

      {file, {:new, _key, _hash}} ->
        {file, changes[{{:blob, page <> "/" <> file}, :version}].id}
    end)
  end

  defp add_page_file(multi, _scope, _job, _page, {_file, {:reuse, _id}}), do: multi

  defp add_page_file(multi, scope, job, page, {file, {:new, key, hash}}) do
    Artifacts.put_version(
      multi,
      {:blob, page <> "/" <> file},
      scope,
      page <> "/" <> file,
      :blob,
      {:job, job.id},
      %{blob_uri: Storage.uri(key), content_hash: hash}
    )
  end

  # `{:ok, {:reuse, version_id}}` for bytes a version of the file already holds, `{:ok, {:new, key,
  # hash}}` for a version to add. A file reported with its key and the bytes the latest version
  # holds is the latest's; one reported with a hash alone is whichever version holds that hash — a
  # job that skipped an upload because the spec said the platform had the bytes may end after the
  # page was republished.
  defp page_file(scope, job, name, file, info) do
    versions = Artifacts.versions(scope, name)

    with :ok <- page_file_name(file),
         {:ok, hash, key} <- page_bytes(job, info) do
      cond do
        versions != [] and List.last(versions).content_hash == hash ->
          {:ok, {:reuse, List.last(versions).id}}

        key == nil ->
          held_version(versions, hash)

        true ->
          {:ok, {:new, key, hash}}
      end
    end
  end

  defp held_version(versions, hash) do
    case versions |> Enum.reverse() |> Enum.find(&(&1.content_hash == hash)) do
      nil -> {:error, :not_what_any_version_holds}
      version -> {:ok, {:reuse, version.id}}
    end
  end

  defp page_file_name(file) do
    cond do
      file == Pages.reserved_file() -> {:error, :reserved}
      not Workflow.valid_name?(file) -> {:error, :undeclared}
      true -> :ok
    end
  end

  defp page_bytes(job, %{"key" => key}) do
    with {:ok, key} <- owned(job, %{"key" => key}),
         {:ok, %{hash: hash}} <- Storage.stat(key) do
      {:ok, hash, key}
    end
  end

  defp page_bytes(_job, %{"hash" => hash}) when is_binary(hash), do: {:ok, normal_hash(hash), nil}
  defp page_bytes(_job, _info), do: {:error, :no_key}

  defp normal_hash("sha256:" <> _hex = hash), do: String.downcase(hash)
  defp normal_hash(hex), do: "sha256:" <> String.downcase(hex)

  defp declared(name, groups) do
    case String.split(name, "/", parts: 2) do
      [group, file] ->
        if group in groups and Workflow.valid_name?(file), do: :ok, else: {:error, :undeclared}

      _other ->
        {:error, :undeclared}
    end
  end

  defp owned(%Job{id: id}, %{"key" => key}) do
    if Storage.Key.job?(key, id), do: {:ok, key}, else: {:error, :not_this_jobs}
  end

  defp owned(_job, _info), do: {:error, :no_key}
end
