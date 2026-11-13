defmodule ForgeWeb.FileType do
  @moduledoc """
  What kind of file an artifact is, for drawing it: its glyph and the hue of the tile it sits in,
  whether a document is rendered or shown as its text, and the media type a download carries
  (`docs/design/ui.md` § Artifact types, § Documents).

  From the name's extension and the artifact's kind, never from its bytes: a list draws every
  artifact on every patch, and reading a blob to draw its row would be a store read per row.
  """

  use Phoenix.Component

  @type t :: :markdown | :text | :log | :code | :image | :archive | :apk | :file | :changeset

  @markdown ~w(.md .markdown)
  @text ~w(.txt .csv .tsv)
  @code ~w(.json .yaml .yml .toml .xml .html .css .js .ts .ex .exs .heex .py .rb .go .rs .java
           .kt .swift .c .h .sh .sql .nix .diff .patch)
  @image ~w(.png .jpg .jpeg .gif .webp .svg .avif)
  @archive ~w(.zip .tar .gz .tgz .xz .bz2 .zst .7z .jar .aab)
  @changeset ForgeCore.Workflow.changeset_artifact()

  @doc """
  The type of an artifact, from its `name` and `kind`. A document is text by construction, so it
  is Markdown unless its extension says text, a log or code; a blob is what its extension says,
  and a `:file` when that says nothing this knows. The changeset is a commit and not a file, and
  is its own type.
  """
  @spec of(%{name: String.t(), kind: atom()}) :: t()
  def of(%{name: name, kind: :blob}) when name == @changeset, do: :changeset

  def of(%{name: name, kind: kind}) do
    case {by_extension(name), kind} do
      {type, _kind} when type in [:text, :log, :code] -> type
      {_type, kind} when kind in [:document, :presentation] -> :markdown
      {type, :blob} -> type
    end
  end

  defp by_extension(name) do
    ext = name |> Path.extname() |> String.downcase()

    cond do
      ext == ".apk" -> :apk
      ext == ".log" -> :log
      ext in @markdown -> :markdown
      ext in @text -> :text
      ext in @code -> :code
      ext in @image -> :image
      ext in @archive -> :archive
      true -> :file
    end
  end

  @doc "A type in words: what the tile says to assistive technology."
  @spec label(t()) :: String.t()
  def label(:markdown), do: "Markdown"
  def label(:text), do: "text"
  def label(:log), do: "log"
  def label(:code), do: "code and data"
  def label(:image), do: "image"
  def label(:archive), do: "archive"
  def label(:apk), do: "Android app"
  def label(:file), do: "file"
  def label(:changeset), do: "changeset"

  @doc """
  The media type a version called `name` is downloaded as, when it is not served as text. An
  Android app is its own, which a phone's browser hands to the package installer; everything else
  is bytes, never something a browser lays out (`docs/design/ui.md` § Addressable artifact
  versions).
  """
  @spec download_type(String.t()) :: String.t()
  def download_type(name) do
    if by_extension(name) == :apk,
      do: "application/vnd.android.package-archive",
      else: "application/octet-stream"
  end

  @doc """
  Whether a version is drawn and served as an image (`Forge.Artifacts.raster?/2`): the one test
  both the route and the Markdown renderer ask.
  """
  defdelegate raster?(name, version), to: Forge.Artifacts

  @doc "Whether `name` is an SVG, which can carry script: a blob of that name is only ever a download."
  @spec svg?(String.t()) :: boolean()
  def svg?(name), do: name |> Path.extname() |> String.downcase() == ".svg"

  defdelegate image_type(name), to: Forge.Artifacts

  @doc """
  A document's content as it is drawn (`docs/design/ui.md` § Documents): `{:html, rendered}` when
  it is Markdown, and `{:text, content}` when its name says text, a log or code, whose lines
  Markdown would join into one paragraph. Called by the page that loads the version rather than by
  a template, which is drawn again on every patch.
  """
  @spec render_document(String.t(), Forge.Artifacts.Version.t(), Forge.References.scope()) ::
          {:html, Phoenix.HTML.safe()} | {:text, String.t() | nil}
  def render_document(name, version, scope) do
    if of(%{name: name, kind: :document}) == :markdown,
      do: {:html, ForgeWeb.Markdown.draw(version.content, scope, version)},
      else: {:text, version.content}
  end

  @doc "What `render_document/3` made, drawn: Markdown in `.doc`, text in a `pre` that scrolls."
  attr :body, :any, required: true

  def document_body(assigns) do
    ~H"""
    <div :if={match?({:html, _}, @body)} class="doc">{elem(@body, 1)}</div>
    <pre
      :if={match?({:text, _}, @body)}
      class="overflow-x-auto font-mono text-[12.5px]/[1.5]"
    >{elem(@body, 1)}</pre>
    """
  end

  @doc """
  The type's glyph in its tile (`docs/design/ui.md` § Artifact types): a mono label — `md`, `{}`,
  `img` — tinted with the type's hue, which is `components.css`'s, keyed by `data-file-type`. The
  tile is labelled with the type in words, since a glyph alone says little to a screen reader.
  """
  attr :artifact, :map, required: true, doc: "anything with a `name` and a `kind`"
  attr :size, :atom, values: [:row, :chip], default: :row

  def file_icon(assigns) do
    assigns = assign(assigns, type: of(assigns.artifact), glyph: glyph(of(assigns.artifact)))

    ~H"""
    <span
      role="img"
      aria-label={label(@type)}
      title={label(@type)}
      data-file-type={@type}
      class={[
        "file-icon inline-flex shrink-0 items-center justify-center rounded-md font-mono leading-none",
        if(@size == :chip, do: "size-5", else: "size-[26px]"),
        glyph_size(@glyph, @size)
      ]}
    >
      <span aria-hidden="true">{@glyph}</span>
    </span>
    """
  end

  @doc "The glyph a type is drawn with, as § Artifact types tables it."
  @spec glyph(t()) :: String.t()
  def glyph(:markdown), do: "md"
  def glyph(:text), do: "txt"
  def glyph(:log), do: "log"
  def glyph(:code), do: "{}"
  def glyph(:image), do: "img"
  def glyph(:archive), do: "zip"
  def glyph(:apk), do: "apk"
  def glyph(:file), do: "file"
  # The Changes tab's `+n −m`, since a changeset is a change and not a file.
  def glyph(:changeset), do: "±"

  # The handoff's `TypeIcon`: 12px for one character, 9.5 for a word; a chip a step down. `file`
  # is the one four-letter glyph, and at 9.5 it still fits the 26px tile.
  defp glyph_size(glyph, size) do
    case {String.length(glyph), size} do
      {1, :row} -> "text-[12px]"
      {1, :chip} -> "text-[11px]"
      {_word, :row} -> "text-[9.5px]"
      {_word, :chip} -> "text-[8px]"
    end
  end
end
