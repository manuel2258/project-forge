defmodule ForgeWeb.Markdown do
  @moduledoc """
  Renders a document's Markdown for the browser. Agents wrote it, so nothing they typed may
  reach the page as HTML: every text `md` leaves raw (inline code, double-backtick spans, text
  after an unclosed `{{`) is escaped at the AST level, and the whole result is sanitised. Front
  matter is stripped textually since the page shows its fields itself.

  **References** (`docs/design/ui.md` § Documents → References): `![alt](name)` and `[text](name)`
  point at artifacts. `references/1` lists the targets, `Forge.References.resolve/2` answers them,
  and `to_html/2` / `render/2` draw the answers: the only `img` the page ever gets is one this
  module built from a resolved raster blob, and every other image is a note.
  """

  use Phoenix.VerifiedRoutes, endpoint: ForgeWeb.Endpoint, router: ForgeWeb.Router

  alias Forge.References

  @front_matter ~r/\A\x{FEFF}?---\r?\n.*?\r?\n---\r?\n/su

  # Left as they are, because they name something outside the product that a reader can follow.
  #
  # Requiring `//` is an equivalent mutant through `to_html/2`: a looser pattern keeps
  # `https:/oidc/github` here and the scrubber, which also requires it, drops the `href`. It is
  # tight here so that the two agree and neither is a lone defence.
  @kept ~r{\A(?:https?://|mailto:|#)}i

  @typedoc "What `Forge.References.resolve/2` answered for the references of one text."
  @type resolved :: %{String.t() => {:ok, References.found()} | {:error, References.reason()}}

  @type parsed :: {:md, String.t(), term()} | {:plain, String.t()}

  @doc """
  The Markdown parsed, or the text alone when the parser raises. Split from drawing so that a page
  with many paragraphs can parse each once, ask `references/1` of every one, resolve them all
  together and `render/2` them.
  """
  @spec parse(String.t() | nil) :: parsed()
  def parse(nil), do: {:plain, ""}

  def parse(markdown) when is_binary(markdown) do
    text = strip_front_matter(markdown)

    try do
      state = Md.parse(text)
      {:md, text, %{state | ast: Enum.map(state.ast, &escape_inline_code(&1, nil))}}
    rescue
      # The renderer is a dependency and its parser raises on markdown people actually write:
      # `md` 0.13.1 dies on reference links (`[a][1]`) and on footnotes (`[^1]`), which is what
      # a citation-heavy verification report is made of. Every call site renders at mount, so
      # one such document used to make the ticket, review and chat pages raise for ever — an
      # agent could deny the operator the surfaces where merges are approved and money is spent,
      # by writing an ordinary footnote.
      #
      # Degrading is the right answer rather than a parser fix: the content is agent-written and
      # unbounded, so the next construct that raises should cost legibility and not the page.
      # The fallback escapes, so it is not a way around the sanitiser either.
      _error -> {:plain, text}
    end
  end

  @doc """
  The targets of the images and links in `parsed` that need resolving: every image's, and every
  link's but those left as they are (`http:`, `https:`, `mailto:`, `#fragment`). Unique.
  """
  @spec references(parsed()) :: [String.t()]
  def references({:plain, _text}), do: []

  def references({:md, _text, state}),
    do: state.ast |> Enum.reduce([], &collect/2) |> Enum.reverse() |> Enum.uniq()

  defp collect({:img, %{src: src}, _children}, acc) when is_binary(src), do: [src | acc]

  defp collect({:a, %{href: href}, children}, acc) when is_binary(href) do
    acc = if href =~ @kept, do: acc, else: [href | acc]
    Enum.reduce(children, acc, &collect/2)
  end

  defp collect({_tag, _attrs, children}, acc) when is_list(children),
    do: Enum.reduce(children, acc, &collect/2)

  defp collect(_other, acc), do: acc

  @doc """
  Draws Markdown. `resolved` is what `Forge.References.resolve/2` answered for
  `references/1`'s targets, and there is deliberately no way to leave it out: an image the caller
  did not resolve is a note and is never emitted as an `<img>`, so a caller that forgets gets
  notes where it wanted pictures and not a request to an address an agent chose.
  """
  @spec to_html(String.t() | nil, resolved()) :: Phoenix.HTML.safe()
  def to_html(nil, _resolved), do: Phoenix.HTML.raw("")
  def to_html(markdown, resolved), do: markdown |> parse() |> render(resolved)

  @doc "Resolves `markdown`'s own references against `scope` at `moment`, and draws it."
  @spec draw(
          String.t() | nil,
          References.scope(),
          References.moment() | Forge.Artifacts.Version.t()
        ) :: Phoenix.HTML.safe()
  def draw(nil, _scope, _moment), do: Phoenix.HTML.raw("")

  def draw(markdown, scope, moment) do
    parsed = parse(markdown)
    %{0 => resolved} = References.resolve(scope, [{0, moment, references(parsed)}])
    render(parsed, resolved)
  end

  @spec render(parsed(), resolved()) :: Phoenix.HTML.safe()
  def render({:plain, text}, _resolved), do: plain(text)

  def render({:md, text, state}, resolved) do
    ast = Enum.flat_map(state.ast, &walk(&1, resolved, false))

    %{state | ast: ast}
    |> Md.generate(format: :none)
    |> then(&HtmlSanitizeEx.Scrubber.scrub(&1, ForgeWeb.Markdown.Scrubber))
    |> Phoenix.HTML.raw()
  rescue
    # `Md.generate/2` is the same dependency, and the fallback is the same.
    _error -> plain(text)
  end

  # -- references --------------------------------------------------------------------------

  defp walk({:img, attrs, _children}, resolved, in_link?) do
    src = Map.get(attrs, :src)
    alt = Map.get(attrs, :title)
    [image(src, alt, Map.get(resolved, src), in_link?)]
  end

  defp walk({:a, %{href: href} = attrs, children}, resolved, _in_link?) when is_binary(href) do
    inner = Enum.flat_map(children, &walk(&1, resolved, true))

    case {href =~ @kept, Map.get(resolved, href)} do
      {true, _} -> [{:a, attrs, inner}]
      {false, {:ok, found}} -> [{:a, %{href: address(found)}, inner}]
      # A link that does not resolve keeps its words and loses its target.
      {false, _} -> inner
    end
  end

  defp walk({tag, attrs, children}, resolved, in_link?) when is_list(children),
    do: [{tag, attrs, Enum.flat_map(children, &walk(&1, resolved, in_link?))}]

  defp walk(other, _resolved, _in_link?), do: [other]

  # The only place an `img` is made: a raster blob that resolved. Its address is the numbered one
  # of the ticket or chat it is on, and a tap on it opens that version.
  defp image(_src, alt, {:ok, %{raster?: true} = found}, in_link?) do
    address = address(found)

    img =
      {:img, %{src: address, alt: alt || "", loading: "lazy", decoding: "async"}, []}

    if in_link?, do: img, else: {:a, %{href: address}, [img]}
  end

  defp image(src, alt, {:ok, %{where: {:chat, _id}}}, _in_link?),
    do: note(src, alt, "chats keep no images")

  defp image(src, alt, {:ok, _found}, _in_link?),
    do: note(src, alt, "is not drawn as an image")

  # A project chat's artifacts are documents, so a bare image there is never found — and the
  # reader is told why rather than that the name is missing.
  defp image(src, alt, {:error, {:missing, :chat}}, _in_link?),
    do: note(src, alt, "chats keep no images")

  defp image(src, alt, {:error, reason}, _in_link?), do: note(src, alt, why(reason))
  defp image(src, alt, nil, _in_link?), do: note(src, alt, "is not shown")

  defp why({:missing, :ticket}), do: "is not on this ticket"
  defp why({:missing, number}), do: "is not on ticket #{number}"
  defp why({:no_version, _n}), do: "has no such version"
  defp why({:no_ticket, number}), do: "— this project has no ticket #{number}"
  defp why(:outside), do: "— images from outside the project are not shown"

  # Everything here is escaped exactly once: the alt and the name are raw (the parser keeps
  # attribute values as typed), and the reason is ours. The result is a node of the AST, which
  # `Md.generate/2` writes as it is.
  defp note(src, alt, reason) do
    name = [{:code, nil, [escape_text(to_string(src))]}, " " <> reason]
    lead = if alt in [nil, ""], do: [], else: [escape_text(alt), " — "]
    {:span, %{class: "ref-note"}, lead ++ name}
  end

  defp address(%{where: {:ticket, project, number}, name: name, version: version}),
    do: ~p"/tickets/#{project}/#{number}/artifacts/#{name}/#{version}"

  defp address(%{where: {:chat, id}, name: name, version: version}),
    do: ~p"/chats/#{id}/artifacts/#{name}/#{version}"

  # Escaped, with paragraphs kept, and nothing else. Deliberately not a second parser.
  defp plain(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.map_join("<br>", &(&1 |> Plug.HTML.html_escape_to_iodata() |> IO.iodata_to_binary()))
    |> then(&Phoenix.HTML.raw("<p>" <> &1 <> "</p>"))
  end

  @doc "The Markdown without its leading YAML front matter, whether or not it parses."
  @spec strip_front_matter(String.t()) :: String.t()
  def strip_front_matter(markdown), do: Regex.replace(@front_matter, markdown, "", global: false)

  # `md` escapes text nodes and fenced blocks but not inline code; do it here. Fenced code
  # arrives as {:pre, _, [{:code, _, [already_escaped]}]} and must not be escaped twice.
  defp escape_inline_code({:code, attrs, children}, parent) when parent != :pre do
    {:code, attrs, Enum.map(children, &escape_text/1)}
  end

  defp escape_inline_code({tag, attrs, children}, _parent) when is_list(children) do
    {tag, attrs, Enum.map(children, &escape_inline_code(&1, tag))}
  end

  # **Raw text is escaped wherever `md` leaves it raw**, not only in `code`: a double-backtick
  # span arrives as a `span`'s child and an unclosed `{{` as a paragraph's, both with their `<`
  # intact, and the sanitiser's `img src` and `a href` checks are lexical, so a raw
  # `<img src="/tickets/../oidc/x">` was an `<img>` the resolver never made. Text `md` escaped has
  # no `<` left, so this changes nothing for it.
  defp escape_inline_code(text, _parent) when is_binary(text),
    do: String.replace(text, "<", "&lt;")

  defp escape_inline_code(other, _parent), do: other

  defp escape_text(text) when is_binary(text),
    do: text |> Plug.HTML.html_escape_to_iodata() |> IO.iodata_to_binary()

  defp escape_text(other), do: escape_inline_code(other, :code)
end
