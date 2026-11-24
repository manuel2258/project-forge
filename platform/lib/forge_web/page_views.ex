defmodule ForgeWeb.PageViews do
  @moduledoc """
  Where a page is drawn outside its own screen (`docs/design/ui.md` § Docs, § The job page,
  § The queue, § Pages): a row under *Produced*, a link on a job's *Wrote*, a pin on a decision, an
  *Open `<name>` ›* on a queue item.

  **A page is one row, never its files.** Its files are blob artifacts named `<page>/<file>`
  (`docs/design/pages.md` § What a page is), which every list of a ticket's artifacts would
  show as rows of their own, so each list filters them with `member?/2` and draws the page's row
  from `docs/3` instead. A page with no version yet has no row, as `Forge.Pages.list/1` says.

  Opening a row is a full page load (`<.link href>`, never `navigate`): the page lives in a live
  session of its own so that it never shares a document with another screen.
  """

  use ForgeWeb, :verified_routes

  import Ecto.Query, only: [from: 2]

  alias Forge.{Jobs, Pages, Repo}
  alias ForgeWeb.TicketViews

  @typedoc "Where the page is read: its project, its ticket and the chat, either of the last two nil."
  @type where :: %{project: map(), ticket: map() | nil, chat: map() | nil}

  @doc "The scope a ticket's or a project chat's pages are in."
  @spec scope(where()) :: Pages.scope()
  def scope(%{ticket: %{id: id}}), do: {:ticket, id}
  def scope(%{chat: %{id: id}}), do: {:chat, id}

  @doc "The names of the pages of `scope` that have a version."
  @spec names(Pages.scope()) :: MapSet.t(String.t())
  def names(scope), do: scope |> Pages.list() |> MapSet.new(& &1.page.name)

  @doc """
  Whether an artifact called `name` is a file of one of the pages in `names`. A group's files are
  named `<group>/<file>` too, and are not: a name is a page or a group, never both
  (`docs/design/workflow-grammar-v1.md` § Validation).
  """
  @spec member?(MapSet.t(String.t()), String.t()) :: boolean()
  def member?(names, name) when is_binary(name) do
    case String.split(name, "/", parts: 2) do
      [page, _file] -> MapSet.member?(names, page)
      _no_slash -> false
    end
  end

  @doc "The address a page opens at."
  @spec open_path(where(), String.t()) :: String.t()
  def open_path(%{ticket: %{number: number}, project: project}, name),
    do: ~p"/tickets/#{project.name}/#{number}/pages/#{name}"

  def open_path(%{chat: chat}, name), do: ~p"/chats/#{chat.id}/pages/#{name}"

  # A page's files are artifacts of its scope, so a file's address is that scope's.
  defp file_path(%{ticket: %{number: number}, project: project}, file, version),
    do: ~p"/tickets/#{project.name}/#{number}/artifacts/#{file}/#{version}"

  defp file_path(%{chat: chat}, file, version),
    do: ~p"/chats/#{chat.id}/artifacts/#{file}/#{version}"

  @doc """
  The Docs entries of the pages of `where`, in `WorkScreen.doc/5`'s shape: kind and type `:page`,
  the latest version's address being the **page** and the earlier versions' being the version's
  `index.html` as a download, never run (`ui.md` § Docs).

  `jobs` is the `%{id => job}` the page already holds, to say *agent · implementing* for whoever
  wrote the version; one it does not hold is read. `only_by` keeps the pages whose latest version a
  given job wrote: a ticket conversation's Docs lists what it wrote.
  """
  @spec docs(where(), %{String.t() => map()}, String.t() | nil) :: [map()]
  def docs(where, jobs \\ %{}, only_by \\ nil) do
    for %{page: page, version: latest} <- Pages.list(scope(where)),
        is_nil(only_by) or latest.job_id == only_by do
      entry(where, page, latest, jobs)
    end
  end

  defp entry(where, page, latest, jobs) do
    earlier = Pages.versions(page) |> Enum.reject(&(&1.version == latest.version))
    numbers = artifact_numbers(earlier)

    %{
      name: page.name,
      kind: :page,
      type: :page,
      latest: %{
        version: latest.version,
        href: open_path(where, page.name),
        author: by(latest, jobs),
        at: latest.inserted_at,
        body: nil
      },
      earlier:
        for version <- earlier, number = numbers[version.files["index.html"]] do
          %{
            version: version.version,
            href: file_path(where, page.name <> "/index.html", number),
            files: version_files(where, page, version, numbers),
            author: by(version, jobs),
            at: version.inserted_at
          }
        end,
      approvable: false,
      approved: false,
      by: by(latest, jobs)
    }
  end

  @doc """
  A ticket's pages as links — `%{name, version, href}` — for a panel that names them without a
  row: a decision's, a queue item's (`ui.md` § The decision row, § The queue).
  """
  @spec links(where()) :: [%{name: String.t(), version: pos_integer(), href: String.t()}]
  def links(where) do
    for %{page: page, version: latest} <- Pages.list(scope(where)),
        do: %{name: page.name, version: latest.version, href: open_path(where, page.name)}
  end

  @doc """
  The page versions a job published, for its *Wrote*: `%{name, version, href}`, the address being the
  page when the version is its latest and the version's own `index.html`, a download, when a later
  one has replaced it (`ui.md` § The job page).
  """
  @spec written(where(), String.t()) :: [
          %{name: String.t(), version: pos_integer(), href: String.t()}
        ]
  def written(%{ticket: %{id: ticket_id}} = where, job_id) do
    rows =
      Repo.all(
        from(v in Pages.Version,
          join: p in Pages.Page,
          on: p.id == v.page_id,
          where: v.job_id == ^job_id and p.ticket_id == ^ticket_id,
          order_by: [p.name, v.version],
          select: {p, v}
        )
      )

    numbers = index_versions(Enum.map(rows, &elem(&1, 1)))

    for {page, version} <- rows do
      latest = Pages.latest_version(page)

      href =
        if latest.version == version.version,
          do: open_path(where, page.name),
          else: file_path(where, page.name <> "/index.html", numbers[version.id])

      %{name: page.name, version: version.version, href: href}
    end
  end

  # Every file of an earlier version, as a download of the artifact version that version holds —
  # which is the latest's own when the file did not change between them. `index.html` is the row's
  # own link, so it is not listed again.
  defp version_files(where, page, version, numbers) do
    for {file, id} <- Enum.sort(version.files),
        file != "index.html",
        number = numbers[id] do
      %{name: file, href: file_path(where, page.name <> "/" <> file, number)}
    end
  end

  # The artifact version number of every file of the given page versions, by artifact version id,
  # in one query.
  defp artifact_numbers(versions) do
    ids = for v <- versions, id <- Map.values(v.files), do: id

    from(v in Forge.Artifacts.Version, where: v.id in ^ids, select: {v.id, v.version})
    |> Repo.all()
    |> Map.new()
  end

  # The artifact version number of each page version's `index.html`, in one query.
  defp index_versions(versions) do
    by_id = artifact_numbers(versions)
    Map.new(versions, &{&1.id, by_id[&1.files["index.html"]]})
  end

  # Who wrote it, in the words of every Docs row: `agent · <state> #n`, `conversation · <state>`.
  defp by(%{job_id: nil}, _jobs), do: "an agent"

  defp by(%{job_id: job_id}, jobs) do
    case jobs[job_id] || Jobs.get(job_id) do
      nil -> "an agent"
      job -> TicketViews.written_by(%{"kind" => "job", "id" => job.id}, %{job.id => job})
    end
  end

  @doc """
  What a human state's *Open `<name>` ›* is: the address of the page when it has a version, and
  `nil` for the address when it has none yet, which the screens draw as *no version yet*.
  """
  @spec opens(where(), String.t() | nil) :: %{name: String.t(), href: String.t() | nil} | nil
  def opens(_where, nil), do: nil

  def opens(where, name) do
    case Pages.get(scope(where), name) do
      %Pages.Page{} = page ->
        %{name: name, href: if(Pages.latest_version(page), do: open_path(where, name))}

      nil ->
        %{name: name, href: nil}
    end
  end
end
