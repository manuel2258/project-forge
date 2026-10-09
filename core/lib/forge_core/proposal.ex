defmodule ForgeCore.Proposal do
  @moduledoc """
  A ticket proposal as an agent writes it: an H1 title and a body, and — optionally — the ticket
  type it suggests.

  See `docs/design/ticket-proposals.md`. The title and body are deliberately the same shape as the
  `ticket` document `Forge.Tickets.admit/3` writes — `"# title\\n\\nbody"` — because accepting
  a proposal *is* admitting it, and a shape that has to be converted is a shape that can be
  converted wrongly.

  **The only front matter is `type:`, and there is no question extraction; both limits are
  load-bearing.** A proposal is not in `produces`, so it carries no outcome. And a proposal is
  stored where a job's whole result is recorded, so anything that can refuse to parse can refuse
  the result with it: `Document.parse/1` rejects a malformed `question` block, and a proposal is
  not worth a job's outcome. So this parser is not `ForgeCore.Document.parse/2` with different
  options, and its front matter is not YAML: it reads one line of one key, a title and a body, and
  cannot fail on anything between them. The type is a suggestion a person confirms at accept
  (`docs/design/ticket-types.md` § Proposals).

  Parsing is pure and never raises. Every problem comes back as a `ForgeCore.Error`, because a
  proposal the platform cannot read is kept and shown rather than dropped.
  """

  alias ForgeCore.{Error, Workflow}

  @enforce_keys [:title, :body, :raw]
  defstruct [:title, :body, :raw, ticket_type: nil]

  @typedoc """
  `raw` is the text as the agent wrote it, before `to_document/1` normalises the spacing.

  Nothing reads it back: what is stored is `to_document/1`, so that a proposal round-trips to
  the same two fields it will be admitted with. It is kept because it is what makes this a
  faithful record of the file rather than a summary of it, and because an unreadable proposal —
  which has no `Proposal` struct at all — is kept the same way, as the bytes that were written.
  """
  @type t :: %__MODULE__{
          title: String.t(),
          body: String.t(),
          raw: String.t(),
          ticket_type: String.t() | nil
        }

  # CommonMark ATX: up to three spaces of indentation, one `#`, then whitespace and the text.
  # A closing sequence of `#`s is allowed and stripped, as CommonMark says.
  @h1 ~r/^ {0,3}#[ \t]+(.*?)[ \t]*#*[ \t]*$/

  @doc """
  Parses `text` into a title, a body and the type it suggests.

  The first non-blank line must be an ATX H1, or `---` opening front matter that holds `type:` and
  nothing else and is closed by `---`; the H1 then comes after it. Everything after the H1 is the
  body. Title and body must be non-empty once trimmed.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, [Error.t()]}
  def parse(text) when is_binary(text) do
    raw = String.replace_prefix(text, "\uFEFF", "")

    with {:ok, ticket_type, rest} <- front_matter(raw),
         {:ok, title, body} <- split(rest) do
      build(raw, title, body, ticket_type)
    else
      {:error, error} -> {:error, [error]}
    end
  end

  @doc "As `parse/1`, raising on anything it cannot read. For tests and fixtures."
  @spec parse!(String.t()) :: t()
  def parse!(text) do
    case parse(text) do
      {:ok, proposal} -> proposal
      {:error, errors} -> raise ArgumentError, "invalid proposal:\n" <> Error.format(errors)
    end
  end

  # `---`, `type: <name>`, `---`: one line of one key, read with a pattern rather than as YAML,
  # because anything that can fail to parse here can fail the result the proposal rides in.
  @type_line ~r/^type:[ \t]*["']?([^"'\s]*)["']?[ \t]*$/

  defp front_matter(text) do
    lines = String.split(text, ["\r\n", "\n"])

    case Enum.split_while(lines, &blank?/1) do
      {_leading, [opening | rest]} ->
        if String.trim(opening) == "---", do: fields(rest), else: {:ok, nil, text}

      {_leading, []} ->
        {:ok, nil, text}
    end
  end

  defp fields(lines) do
    case Enum.split_while(lines, &(String.trim(&1) != "---")) do
      {_fields, []} ->
        {:error, Error.new("front_matter", "is not closed: a second --- line is missing")}

      {fields, [_closing | rest]} ->
        with {:ok, type} <- type(Enum.reject(fields, &blank?/1)),
             do: {:ok, type, Enum.join(rest, "\n")}
    end
  end

  defp type([]), do: {:ok, nil}

  defp type([line]) do
    case Regex.run(@type_line, String.trim(line)) do
      [_line, name] ->
        if Workflow.valid_name?(name),
          do: {:ok, name},
          else: {:error, Error.new("type", "must be a ticket type's name, like bug")}

      nil ->
        {:error, only_type()}
    end
  end

  defp type(_lines), do: {:error, only_type()}

  defp only_type,
    do: Error.new("front_matter", "may hold only the ticket type it suggests, as type: <name>")

  defp split(text) do
    lines = String.split(text, ["\r\n", "\n"])

    case Enum.split_while(lines, &blank?/1) do
      {_leading, []} ->
        {:error, Error.new("", "a proposal is empty")}

      {_leading, [heading | rest]} ->
        case Regex.run(@h1, heading) do
          [_whole, title] -> {:ok, title, Enum.join(rest, "\n")}
          nil -> {:error, Error.new("title", "must begin with a level-one heading (# Title)")}
        end
    end
  end

  defp build(raw, title, body, ticket_type) do
    title = String.trim(title)
    body = String.trim(body)

    case Enum.reject(
           [
             title == "" && Error.new("title", "must not be empty"),
             body == "" && Error.new("body", "must say what the work is")
           ],
           &(&1 == false)
         ) do
      [] -> {:ok, %__MODULE__{title: title, body: body, raw: raw, ticket_type: ticket_type}}
      errors -> {:error, errors}
    end
  end

  defp blank?(line), do: String.trim(line) == ""

  @doc """
  The stored form of a proposal: the type it suggests as front matter when it suggests one, then
  exactly what `admit/3` stores as the `ticket` artifact.

  Round-tripping through `parse/1` gives the same title, body and type back, which is what makes
  accepting a proposal a matter of handing over fields rather than re-deriving them. The type is
  kept in the text because the text is all that is stored; it never reaches the ticket's body.
  """
  @spec to_document(t()) :: String.t()
  def to_document(%__MODULE__{title: title, body: body, ticket_type: nil}),
    do: "# #{title}\n\n#{body}"

  def to_document(%__MODULE__{ticket_type: type} = proposal),
    do: "---\ntype: #{type}\n---\n" <> to_document(%{proposal | ticket_type: nil})
end
