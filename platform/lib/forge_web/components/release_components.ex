defmodule ForgeWeb.ReleaseComponents do
  @moduledoc """
  How a release record is drawn (`docs/design/ui.md` § A project's releases): the entry on the
  releases page and on a release's own page, and the one line on the project page.

  **The tag's sentence is `tag_words/1`'s alone**, so the three surfaces cannot say it three ways.
  Nothing here is a form and nothing writes. Every value a record holds came from a document or
  a file name, so every one is drawn as text; only the notes are rendered, and through
  `ForgeWeb.Markdown`, exactly as the Docs tab renders a document.
  """

  use ForgeWeb, :html

  alias Forge.ReleaseRecords.Record
  alias ForgeWeb.Markdown

  @doc "What became of the tag, in words (`ui.md` § A project's releases)."
  @spec tag_words(Record.t()) :: String.t()
  def tag_words(%Record{tag_status: :tagged, tag_name: name}), do: "Tagged #{name}"

  def tag_words(%Record{tag_status: :taken, tag_name: name, tag_detail: other}),
    do: "#{name} was already taken by another commit (#{short(other)}) and was not moved"

  def tag_words(%Record{tag_status: :failed, tag_detail: why}), do: "Not tagged: #{why}"
  def tag_words(%Record{tag_status: :no_version}), do: "No version, so no tag"

  @doc "A commit's first seven characters."
  @spec short(String.t() | nil) :: String.t()
  def short(nil), do: ""
  def short(sha), do: String.slice(sha, 0, 7)

  @doc "The record's heading: its version, or a plain 'no version'."
  @spec heading(Record.t()) :: String.t()
  def heading(%Record{version: nil}), do: "No version"
  def heading(%Record{version: version}), do: version

  @doc "A file's size, for a person."
  @spec bytes(non_neg_integer() | nil) :: String.t()
  def bytes(nil), do: "size unknown"
  def bytes(count) when count >= 1_048_576, do: "#{Float.round(count / 1_048_576, 1)} MB"
  def bytes(count) when count >= 1024, do: "#{div(count, 1024)} KB"
  def bytes(count), do: "#{count} B"

  @doc "The date a release concluded."
  @spec date(Record.t()) :: String.t()
  def date(%Record{concluded_at: at}), do: Calendar.strftime(at, "%Y-%m-%d")

  @doc """
  One release. `link` makes the heading the way to the record's own page; on that page it is the
  page's heading and not a link. `record.ticket` must be loaded.
  """
  attr :record, Record, required: true
  attr :project, :map, required: true
  attr :link, :boolean, default: true

  def entry(assigns) do
    ~H"""
    <article id={"release-#{@record.id}"} class="min-w-0 border-t border-base-300 py-6">
      <h2 class="text-xl font-semibold -tracking-[.02em] break-words">
        <.link
          :if={@link}
          navigate={~p"/projects/#{@project.name}/releases/#{@record.id}"}
          class="flex min-h-[46px] items-center hover:underline"
        >
          {heading(@record)}
        </.link>
        <span :if={!@link} class="break-words">{heading(@record)}</span>
      </h2>
      <p class="mt-1 text-sm break-words">{tag_words(@record)}</p>
      <dl class="mt-3 flex flex-wrap gap-x-6 gap-y-1 font-mono text-[12.5px] opacity-70">
        <div class="flex gap-2">
          <dt>Date</dt>
          <dd>{date(@record)}</dd>
        </div>
        <div class="flex gap-2">
          <dt>Commit</dt>
          <dd>
            <.link
              navigate={~p"/projects/#{@project.name}/repo/commits/#{@record.commit_sha}"}
              class="inline-flex min-h-[46px] items-center text-primary hover:underline"
            >
              {short(@record.commit_sha)}
            </.link>
          </dd>
        </div>
        <div class="flex gap-2">
          <dt>Ticket</dt>
          <dd>
            <.link
              navigate={~p"/tickets/#{@project.name}/#{@record.ticket.number}"}
              class="inline-flex min-h-[46px] items-center text-primary hover:underline"
            >
              #{@record.ticket.number}
            </.link>
          </dd>
        </div>
      </dl>

      <div :if={@record.notes} class="doc mt-3 min-w-0 text-sm/[1.6] break-words">
        {Markdown.to_html(@record.notes)}
      </div>

      <section :if={@record.files != []} class="mt-4">
        <h3 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Files</h3>
        <ul class="mt-1 flex flex-col">
          <li :for={file <- @record.files} class="min-w-0">
            <a
              href={
                ~p"/tickets/#{@project.name}/#{@record.ticket.number}/artifacts/#{file["name"]}/#{file["version"]}"
              }
              class="flex min-h-[46px] min-w-0 flex-wrap items-center gap-x-3 text-sm text-primary hover:underline"
            >
              <span class="min-w-0 break-all">{file["name"]}</span>
              <span class="font-mono text-[12.5px] opacity-60">{bytes(file["size"])}</span>
            </a>
          </li>
        </ul>
      </section>

      <section :if={@record.links != []} class="mt-4">
        <h3 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Links</h3>
        <ul class="mt-1 flex flex-col">
          <li :for={link <- @record.links} class="min-w-0">
            <a
              href={link["url"]}
              rel="noopener noreferrer nofollow"
              target="_blank"
              class="flex min-h-[46px] min-w-0 items-center text-sm break-words text-primary hover:underline"
            >
              {link["label"]}
            </a>
          </li>
        </ul>
      </section>
    </article>
    """
  end

  @doc "The latest release on the project page: version, date, what became of its tag."
  attr :record, Record, required: true
  attr :project, :map, required: true

  def latest(assigns) do
    ~H"""
    <p id="latest-release" class="mt-3 min-w-0 text-sm break-words">
      <span class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Latest release</span>
      <.link
        navigate={~p"/projects/#{@project.name}/releases/#{@record.id}"}
        class="ml-2 inline-flex min-h-[46px] items-center text-primary hover:underline"
      >
        {heading(@record)}
      </.link>
      <span class="opacity-70">· {date(@record)} · {tag_words(@record)}</span>
    </p>
    """
  end
end
