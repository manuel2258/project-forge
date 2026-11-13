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
  page's heading and not a link. `record.ticket` must be loaded. Every link and download is a
  full-size target (`--target-min`, `ui.md` § The phone); the styles are `areas/releases.css`.
  """
  attr :record, Record, required: true
  attr :project, :map, required: true
  attr :link, :boolean, default: true

  def entry(assigns) do
    ~H"""
    <article id={"release-" <> to_string(@record.id)} class="release-entry">
      <h2 class="release-heading">
        <.link
          :if={@link}
          navigate={~p"/projects/#{@project.name}/releases/#{@record.id}"}
          class="release-target"
        >
          {heading(@record)}
        </.link>
        <span :if={!@link}>{heading(@record)}</span>
      </h2>
      <p class="release-tag">{tag_words(@record)}</p>
      <.fact_list dense class="release-facts">
        <:fact label="date">{date(@record)}</:fact>
        <:fact label="commit">
          <.link
            navigate={~p"/projects/#{@project.name}/repo/commits/#{@record.commit_sha}"}
            class="release-target release-mono"
          >
            {short(@record.commit_sha)}
          </.link>
        </:fact>
        <:fact label="ticket">
          <.link
            navigate={~p"/tickets/#{@project.name}/#{@record.ticket.number}"}
            class="release-target release-mono"
          >
            #{@record.ticket.number}
          </.link>
        </:fact>
      </.fact_list>

      <div :if={@record.notes} class="doc release-notes">
        {Markdown.to_html(@record.notes, %{})}
      </div>

      <section :if={@record.files != []} class="release-group">
        <.eyebrow>Files</.eyebrow>
        <ul>
          <li :for={file <- @record.files}>
            <a
              href={
                ~p"/tickets/#{@project.name}/#{@record.ticket.number}/artifacts/#{file["name"]}/#{file["version"]}"
              }
              class="release-target release-file"
            >
              <span class="release-file-name">{file["name"]}</span>
              <span class="release-file-size">{bytes(file["size"])}</span>
            </a>
          </li>
        </ul>
      </section>

      <section :if={@record.links != []} class="release-group">
        <.eyebrow>Links</.eyebrow>
        <ul>
          <li :for={link <- @record.links}>
            <a
              href={link["url"]}
              rel="noopener noreferrer nofollow"
              target="_blank"
              class="release-target release-link"
            >
              {link["label"]}
            </a>
          </li>
        </ul>
      </section>
    </article>
    """
  end

  @doc """
  The latest release on the project page, as a fact's value: its version linking to its page, its
  date and what became of its tag.
  """
  attr :id, :string, required: true
  attr :record, Record, required: true
  attr :project, :map, required: true

  def latest(assigns) do
    ~H"""
    <span id={@id} class="release-latest">
      <.link navigate={~p"/projects/#{@project.name}/releases/#{@record.id}"} class="release-target">
        {heading(@record)}
      </.link>
      <span class="release-latest-rest">· {date(@record)} · {tag_words(@record)}</span>
    </span>
    """
  end
end
