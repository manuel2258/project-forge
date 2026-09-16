defmodule ForgeCore.Proposal do
  @moduledoc """
  A ticket proposal as an agent writes it: an H1 title and a body, and nothing else.

  See `docs/design/ticket-proposals.md`. It is deliberately the same shape as the `ticket`
  document `Forge.Tickets.admit/3` writes — `"# title\\n\\nbody"` — because accepting a
  proposal *is* admitting it, and a shape that has to be converted is a shape that can be
  converted wrongly.

  **There is no front matter and no question extraction, and both absences are load-bearing.**
  A proposal is not in `produces`, so it carries no outcome and has no front matter to put one
  in. And a proposal is stored where a job's whole result is recorded, so anything that can
  refuse to parse can refuse the result with it: `Document.parse/1` rejects a malformed
  `question` block, and a proposal is not worth a job's outcome. So this parser is not
  `ForgeCore.Document.parse/2` with different options; it reads a title and a body and looks at
  nothing else, and cannot fail on anything between them.

  Parsing is pure and never raises. Every problem comes back as a `ForgeCore.Error`, because a
  proposal the platform cannot read is kept and shown rather than dropped.
  """

  alias ForgeCore.Error

  @enforce_keys [:title, :body, :raw]
  defstruct [:title, :body, :raw]

  @typedoc """
  `raw` is the text as the agent wrote it, before `to_document/1` normalises the spacing.

  Nothing reads it back: what is stored is `to_document/1`, so that a proposal round-trips to
  the same two fields it will be admitted with. It is kept because it is what makes this a
  faithful record of the file rather than a summary of it, and because an unreadable proposal —
  which has no `Proposal` struct at all — is kept the same way, as the bytes that were written.
  """
  @type t :: %__MODULE__{title: String.t(), body: String.t(), raw: String.t()}

  # CommonMark ATX: up to three spaces of indentation, one `#`, then whitespace and the text.
  # A closing sequence of `#`s is allowed and stripped, as CommonMark says.
  @h1 ~r/^ {0,3}#[ \t]+(.*?)[ \t]*#*[ \t]*$/

  @doc """
  Parses `text` into a title and a body.

  The first non-blank line must be an ATX H1; everything after it is the body. Both must be
  non-empty once trimmed.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, [Error.t()]}
  def parse(text) when is_binary(text) do
    text = String.replace_prefix(text, "﻿", "")

    case split(text) do
      {:ok, title, body} -> build(text, title, body)
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

  defp build(raw, title, body) do
    title = String.trim(title)
    body = String.trim(body)

    case Enum.reject(
           [
             title == "" && Error.new("title", "must not be empty"),
             body == "" && Error.new("body", "must say what the work is")
           ],
           &(&1 == false)
         ) do
      [] -> {:ok, %__MODULE__{title: title, body: body, raw: raw}}
      errors -> {:error, errors}
    end
  end

  defp blank?(line), do: String.trim(line) == ""

  @doc """
  The document form of a proposal: exactly what `admit/3` stores as the `ticket` artifact.

  Round-tripping through `parse/1` gives the same title and body back, which is what makes
  accepting a proposal a matter of handing over two fields rather than re-deriving them.
  """
  @spec to_document(t()) :: String.t()
  def to_document(%__MODULE__{title: title, body: body}), do: "# #{title}\n\n#{body}"
end
