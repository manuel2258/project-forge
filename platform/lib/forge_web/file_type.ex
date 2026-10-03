defmodule ForgeWeb.FileType do
  @moduledoc """
  What kind of file an artifact is, for drawing it: its icon and the hue of the tile it sits in,
  whether a document is rendered or shown as its text, and the media type a download carries
  (`docs/design/ui.md` § Artifact types, § Documents).

  From the name's extension and the artifact's kind, never from its bytes: a list draws every
  artifact on every patch, and reading a blob to draw its row would be a store read per row.
  """

  use Phoenix.Component

  import ForgeWeb.CoreComponents, only: [icon: 1]

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

  @doc "A type in words: what the icon says to assistive technology."
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
  A document's content as it is drawn (`docs/design/ui.md` § Documents): `{:html, rendered}` when
  it is Markdown, and `{:text, content}` when its name says text, a log or code, whose lines
  Markdown would join into one paragraph. Called by the page that loads the version rather than by
  a template, which is drawn again on every patch.
  """
  @spec render_document(String.t(), String.t() | nil) ::
          {:html, Phoenix.HTML.safe()} | {:text, String.t() | nil}
  def render_document(name, content) do
    if of(%{name: name, kind: :document}) == :markdown,
      do: {:html, ForgeWeb.Markdown.to_html(content)},
      else: {:text, content}
  end

  @doc "What `render_document/2` made, drawn: Markdown in `.doc`, text in a `pre` that scrolls."
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
  The type's icon in its tile. The tile's hue is `app.css`'s, keyed by `data-file-type`, and the
  icon is labelled with the type in words.
  """
  attr :artifact, :map, required: true, doc: "anything with a `name` and a `kind`"
  attr :size, :atom, values: [:row, :chip], default: :row

  def file_icon(assigns) do
    assigns = assign(assigns, :type, of(assigns.artifact))

    ~H"""
    <span
      role="img"
      aria-label={label(@type)}
      title={label(@type)}
      data-file-type={@type}
      class={[
        "file-icon inline-flex shrink-0 items-center justify-center rounded-field",
        if(@size == :chip, do: "size-5", else: "size-7")
      ]}
    >
      <.glyph type={@type} class={if(@size == :chip, do: "size-3.5", else: "size-4")} />
    </span>
    """
  end

  attr :type, :atom, required: true
  attr :class, :string, required: true

  # The Changes tab's `+n −m`, since a changeset is a change and not a file.
  defp glyph(%{type: :changeset} = assigns) do
    ~H"""
    <span aria-hidden="true" class="font-mono text-[13px] leading-none">±</span>
    """
  end

  defp glyph(assigns) do
    ~H"""
    <.icon name={hero(@type)} class={@class} />
    """
  end

  defp hero(:markdown), do: "hero-document-text-mini"
  defp hero(:text), do: "hero-bars-3-bottom-left-mini"
  defp hero(:log), do: "hero-command-line-mini"
  defp hero(:code), do: "hero-code-bracket-mini"
  defp hero(:image), do: "hero-photo-mini"
  defp hero(:archive), do: "hero-archive-box-mini"
  defp hero(:apk), do: "hero-device-phone-mobile-mini"
  defp hero(:file), do: "hero-cube-mini"
end
