defmodule ForgeWeb.Api.Builds do
  @moduledoc """
  Looking into a ticket's kept command copies, as data: what `ForgeWeb.Api.BuildController` serves
  over the JSON API and `ForgeWeb.Mcp.Tools` over MCP, so that the two cannot disagree
  (`docs/design/api-and-ui.md` § JSON API, § MCP; `docs/design/worker-tier.md` § Looking into a copy).

  Every function takes the **ticket the request already reached**, and a copy is found through it
  (`Forge.WarmBuilds.copy/2`): another ticket's copy, or another project's, is a copy that does not
  exist. Who may look is the caller's: any member, a project token with read or write access alike.
  Nothing here records that anyone looked.

  A path is `path` (text) or `path_b64` (URL-safe base64, for a name that is not text), `""` the
  copy's root. Names, paths and link targets come back as `name` (text, or null when the bytes are
  not valid text) and `name_b64` (always).
  """

  alias Forge.{Explore, WarmBuilds}
  alias ForgeWeb.Api.Render

  @doc "The ticket's kept copies, the next command's first."
  @spec list(Forge.Tickets.Ticket.t()) :: map()
  def list(ticket), do: %{builds: Render.copies(WarmBuilds.copies(ticket))}

  @doc """
  One page of a folder. `params`: `path`/`path_b64`, `offset` (default 0). `{:ok, map}` or `{:error,
  reason}` in the API's words.
  """
  @spec folder(Forge.Tickets.Ticket.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def folder(ticket, job_id, params) do
    with {:ok, path} <- path(params),
         {:ok, offset} <- offset(params["offset"]),
         {:ok, copy} <- copy(ticket, job_id),
         {:ok, page} <- asked(ticket, copy, Explore.list(copy, path, offset)) do
      next = page.offset + length(page.entries)

      {:ok,
       Map.merge(named(path, "path"), %{
         job_id: copy.job.id,
         entries: Enum.map(page.entries, &entry/1),
         total: page.total,
         offset: page.offset,
         next_offset: if(next < page.total, do: next)
       })}
    end
  end

  @doc """
  A file's facts, and with `hash: true` its SHA-256, and with `content: true` its text (up to
  `ForgeCore.Explore.text_limit/0` bytes; a file that is not text is `not_text`). `opts` are
  booleans; the API reads them from `?hash=true` and `?content=true`. MCP passes `:if_file` and
  `:if_text`, which leave out what a file that is not one or not text has none of, rather than refuse.
  """
  @spec file(Forge.Tickets.Ticket.t(), term(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def file(ticket, job_id, params, opts) do
    with {:ok, path} <- path(params),
         {:ok, copy} <- copy(ticket, job_id),
         {:ok, facts} <- asked(ticket, copy, Explore.file(copy, path)),
         {:ok, hash} <- hashed(ticket, copy, path, facts, opts[:hash]),
         {:ok, content} <- contented(facts, opts[:content]) do
      {:ok,
       Map.merge(named(path, "path"), %{
         job_id: copy.job.id,
         kind: facts.kind,
         size: facts.size,
         mtime: facts.mtime,
         entries: facts.entries,
         text: facts.text?,
         truncated: facts.truncated?,
         target: text(facts.target),
         target_b64: encode(facts.target),
         sha256: hash,
         content: content
       })}
    end
  end

  @doc """
  Where a download of a copy, a folder or a file is fetched from, and its size when forge knows it
  without asking the machine (the whole copy). For MCP, which answers one JSON request with one JSON
  response and so cannot carry a stream: the caller fetches the address with its own token.
  """
  @spec download_target(Forge.Tickets.Ticket.t(), String.t(), term(), map()) ::
          {:ok, map()} | {:error, term()}
  def download_target(ticket, project_name, job_id, params) do
    with {:ok, path} <- path(params),
         {:ok, copy} <- copy(ticket, job_id) do
      query = if path == "", do: "", else: "?" <> URI.encode_query(%{"path_b64" => encode(path)})

      {:ok,
       %{
         job_id: copy.job.id,
         path: text(path),
         size: if(path == "", do: copy.size),
         url:
           ForgeWeb.Endpoint.url() <>
             "/api/v1/tickets/#{project_name}/#{ticket.number}/builds/#{copy.job.id}/download" <>
             query,
         note:
           "Fetch this address with your own token as `Authorization: Bearer …`. It answers with " <>
             "a tar archive (a file is sent as itself), streamed as the machine packs it; a " <>
             "download that is cut off starts again from the beginning."
       }}
    end
  end

  @doc "The copy a request names, through this ticket: `{:ok, copy}` or the refusal in the API's words."
  @spec copy(Forge.Tickets.Ticket.t(), term()) :: {:ok, map()} | {:error, term()}
  def copy(ticket, job_id) do
    case WarmBuilds.copy(ticket, job_id) do
      {:ok, copy} ->
        {:ok, copy}

      :error ->
        case Explore.missing(ticket, job_id) do
          :not_found -> {:error, :not_found}
          refusal -> {:error, refusal}
        end
    end
  end

  @doc "An answer from `Forge.Explore` in the API's words: a code becomes `{:explore, code, extra}`."
  @spec asked(Forge.Tickets.Ticket.t(), map(), {:ok, term()} | {:error, atom()}) ::
          {:ok, term()} | {:error, term()}
  def asked(_ticket, _copy, {:ok, answer}), do: {:ok, answer}
  def asked(ticket, copy, {:error, code}), do: {:error, Explore.refusal(ticket, copy, code)}

  defp hashed(ticket, copy, path, facts, true) do
    if facts.kind == :file,
      do: ticket |> asked(copy, Explore.hash(copy, path)) |> sha(),
      else: {:error, {:explore, :not_a_file, %{}}}
  end

  # MCP asks for the hash of whatever is a file and says nothing of what is not.
  defp hashed(ticket, copy, path, %{kind: :file}, :if_file),
    do: hashed(ticket, copy, path, %{kind: :file}, true)

  defp hashed(_ticket, _copy, _path, _facts, _no), do: {:ok, nil}

  defp sha({:ok, %{sha256: hex}}), do: {:ok, hex}
  defp sha({:error, _reason} = error), do: error

  defp contented(%{text?: true, content: content}, wanted)
       when wanted in [true, :if_text] and is_binary(content),
       do: {:ok, String.replace_invalid(content)}

  defp contented(_facts, :if_text), do: {:ok, nil}
  defp contented(_facts, true), do: {:error, {:explore, :not_text, %{}}}
  defp contented(_facts, _no), do: {:ok, nil}

  defp entry(entry) do
    Map.merge(named(entry.name, "name"), %{
      kind: entry.kind,
      size: entry.size,
      entries: entry.entries,
      mtime: entry.mtime,
      target: text(entry.target),
      target_b64: encode(entry.target)
    })
  end

  # `name` as text when it is, null when it is not; `name_b64` is always the bytes.
  defp named(bytes, key) do
    %{String.to_atom(key) => text(bytes), String.to_atom(key <> "_b64") => encode(bytes)}
  end

  defp text(bytes) when is_binary(bytes), do: if(String.valid?(bytes), do: bytes)
  defp text(_none), do: nil

  defp encode(bytes) when is_binary(bytes), do: Base.url_encode64(bytes, padding: false)
  defp encode(_none), do: nil

  @doc """
  The path a request names: `path_b64` when given (URL-safe base64, padded or not), else `path`,
  else the root. A shape the machine would refuse (`..`, an absolute path) is refused here too.
  """
  @spec path(map()) :: {:ok, binary()} | {:error, term()}
  def path(params) do
    with {:ok, path} <- raw_path(params) do
      if ForgeCore.Explore.path_ok?(path),
        do: {:ok, path},
        else: {:error, {:explore, :path_refused, %{}}}
    end
  end

  defp raw_path(%{"path_b64" => encoded}) when is_binary(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, path} -> {:ok, path}
      :error -> {:error, {:bad_request, "path_b64 is URL-safe base64"}}
    end
  end

  defp raw_path(%{"path" => path}) when is_binary(path), do: {:ok, path}
  defp raw_path(%{"path" => _other}), do: {:error, {:bad_request, "path is text"}}
  defp raw_path(_none), do: {:ok, ""}

  defp offset(nil), do: {:ok, 0}
  defp offset(n) when is_integer(n) and n >= 0, do: {:ok, n}

  defp offset(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> {:ok, n}
      _other -> {:error, {:bad_request, "offset is a whole number"}}
    end
  end

  defp offset(_other), do: {:error, {:bad_request, "offset is a whole number"}}
end
