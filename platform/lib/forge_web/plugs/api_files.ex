defmodule ForgeWeb.Plugs.ApiFiles do
  @moduledoc """
  Files on an API write (`docs/design/attachments.md` § The API): a `multipart/form-data` request
  whose `files[]` parts are people's files, kept whole or refused whole.

  **Why the body is read here and not by the endpoint.** `Plug.Parsers` in the endpoint no longer
  lists `:multipart`: nothing else in the product posts one, and a parser that runs before the
  router would read — to temporary files, up to its limit — a body the caller was never going to be
  allowed to send. This runs **after** `ForgeWeb.Plugs.ApiAccess` and the ticket's or proposal's
  lookup, so a read token, a caller of another project and a ticket that is not there are refused
  without a byte read.

  What it does with a request:

  - **JSON and anything else that is not multipart passes untouched.**
  - **A caller who may not write in the project is not read either.** The check is the Operator's
    own (`Forge.Access`, `:use`), asked here only so that nothing is staged for a caller the
    operation will refuse; the operation still asks.
  - Every file is staged (`Forge.Attachments.stage/4`) as the caller, counted on the bytes the
    store wrote, and the request becomes `conn.assigns.attachments`, a `Forge.Attachments.Batch`
    with `whole?: true`: the operation checks the lot against the limits **before** it acts
    (`Forge.Attachments.preflight/4`) and refuses it whole if any file passes one; its claim is
    lenient (`Forge.Operator`).
  - **The body is bounded in every part of it**: a field's value at a megabyte in all, a file at the
    file limit, the headers of all the parts at a megabyte, the parts at a hundred, and the whole at
    ten files and the fields — each `413`, so no request grows memory or a disk without bound.
  - **A refusal leaves nothing behind**: a file that cannot be staged is `422 attachments_refused`
    naming the file and the limit, with what was staged removed; a response of 400 or more removes
    what the operation did not claim (`before_send`); and a request an exception cut short — Phoenix
    answers 400 to one the action has no clause for — does too, through the router's error handler
    (`discard_after_error/1`).
  """

  import Plug.Conn

  alias Forge.{Access, Attachments, Projects, Proposals}
  alias Forge.Accounts.Scope
  alias Forge.Attachments.Batch
  alias ForgeWeb.Api.FallbackController

  # The fields of a request, all together: nothing an API write sends as text is larger.
  @fields 1024 * 1024

  # Parts in one request: ten files and a handful of fields are what an API write sends.
  @parts 100

  def init(opts), do: opts

  def call(conn, _opts) do
    # A connection that is kept serves one request after another in one process.
    Process.delete(:api_files_staged)

    if multipart?(conn), do: files(conn), else: conn
  end

  # Case does not matter in a media type: `Multipart/Form-Data` is one, and passing it untouched
  # would run a write with no files and answer 200.
  defp multipart?(conn) do
    case get_req_header(conn, "content-type") do
      [type | _] -> type |> String.downcase() |> String.starts_with?("multipart/form-data")
      _other -> false
    end
  end

  # **`may_write?/2` is an equivalent mutant in everything the suite can see**: `ApiAccess :writable`
  # and the ticket's lookup run before this plug and refuse a read token, a caller of another
  # project and a ticket that is not there (403, 404), and an accepted proposal is guarded by the
  # operation, whose cleanup (`discard_unclaimed/4`) removes what was staged. It is a second asking,
  # so that no byte is read for a caller who will be refused.
  defp files(conn) do
    with %{} = project <- project_of(conn),
         true <- may_write?(conn.assigns.current_scope, project) do
      read(conn, project)
    else
      # The operation refuses, in its own words, and the body is never read.
      _not_here -> conn
    end
  end

  defp project_of(%{assigns: %{project: project}}), do: project

  defp project_of(%{params: %{"version_id" => version_id}}) do
    case Proposals.get(version_id) do
      %{job: %{project_id: id}} when is_binary(id) -> Projects.get!(id)
      _absent -> nil
    end
  end

  defp project_of(%{params: %{"project" => name}}) when is_binary(name),
    do: Projects.by_name(name)

  defp project_of(_conn), do: nil

  defp may_write?(%Scope{token: %{} = token} = scope, project),
    do: token.project_id == project.id and Access.can?(%{scope | project: project}, :use)

  defp may_write?(%Scope{} = scope, project),
    do: Access.can?(Scope.for_project(scope, project), :use)

  @chunk 1024 * 1024

  # **The body is read part by part here, and not by `Plug.Parsers.MULTIPART`**, for two reasons that
  # parser cannot be told: it holds a part with no `filename` in memory as one binary, up to one
  # budget for the whole body (a 3 GiB `comment` would grow the BEAM by 3 GiB), and it leaves a
  # file part's temporary file until the connection's process exits, which on a kept connection is
  # long after the request. Here a field is bounded by `@fields` in all, a file by the file limit, the
  # body by ten files and the fields, and each temporary file is removed when its bytes are in the
  # store, whatever became of the request.
  defp read(conn, project) do
    limits = Attachments.limits()

    state = %{
      fields: [],
      parts: 0,
      header_bytes: 0,
      refused: [],
      files: [],
      field_bytes: 0,
      bytes: 0,
      max: limits.file_bytes * limits.per_act + @fields
    }

    try do
      case parts(conn, state) do
        {:ok, conn, state} ->
          fields = decode(state.fields)
          conn = merge(conn, fields)
          stage(conn, project, Enum.reverse(state.files), Enum.reverse(state.refused))

        {:error, conn, :too_large} ->
          too_large(conn)
      end
    rescue
      _error in [Plug.Parsers.BadEncodingError, Plug.Parsers.ParseError, Plug.UploadError] ->
        refuse(conn, :bad_request, "bad_request", "the multipart body could not be read")
    after
      # Whatever was read to a file is removed, staged or not.
      for %{path: path} <- Process.get(:api_files_temp, []), do: File.rm(path)
      Process.delete(:api_files_temp)
    end
  end

  defp parts(conn, state) do
    case read_part_headers(conn, length: @chunk, read_length: @chunk) do
      {:ok, headers, conn} ->
        # Every part costs its headers and its place in the count, whatever its body: millions of
        # empty parts with a name each are a body with no upper bound otherwise.
        state = %{
          state
          | parts: state.parts + 1,
            header_bytes: state.header_bytes + headers_size(headers)
        }

        with :ok <- within(state),
             {:ok, conn, state} <- part(conn, headers, state) do
          parts(conn, state)
        else
          :over -> {:error, conn, :too_large}
          {:error, conn, reason} -> {:error, conn, reason}
        end

      {:done, conn} ->
        {:ok, conn, state}

      {:error, _reason} ->
        raise Plug.UploadError, "the multipart body could not be read"
    end
  end

  defp within(%{parts: parts, header_bytes: bytes}) do
    if parts > @parts or bytes > @fields, do: :over, else: :ok
  end

  defp headers_size(headers),
    do: Enum.reduce(headers, 0, fn {k, v}, sum -> sum + byte_size(k) + byte_size(v) end)

  # A part with a filename is a file: streamed to a temporary file of its own, counted. Any other is
  # a field, held in memory and counted against `@fields` together with the rest.
  defp part(conn, headers, state) do
    case disposition(headers) do
      {name, filename} when is_binary(filename) ->
        if name in ["files", "files[]"],
          do: file_part(conn, filename, state),
          else: skip_part(conn, state)

      {name, nil} when is_binary(name) ->
        field_part(conn, name, state)

      _none ->
        skip_part(conn, state)
    end
  end

  defp file_part(conn, filename, state) do
    path = temp_path()
    Process.put(:api_files_temp, [%{path: path} | Process.get(:api_files_temp, [])])
    file = File.open!(path, [:write, :binary, :raw, :delayed_write])

    result =
      try do
        copy_part(conn, file, 0, Attachments.limits().file_bytes, state.max - state.bytes)
      after
        File.close(file)
      end

    case result do
      {:ok, conn, size} ->
        upload = %Plug.Upload{path: path, filename: filename}
        {:ok, conn, %{state | files: [upload | state.files], bytes: state.bytes + size}}

      {:over, conn, size} ->
        {:ok, conn,
         %{state | refused: [{filename, :file_bytes} | state.refused], bytes: state.bytes + size}}

      {:error, conn} ->
        {:error, conn, :too_large}
    end
  end

  # `{:ok, conn, size}`; `{:over, conn, size}` for a file past the file limit, read to its end
  # without being kept, so the request can name it; `{:error, conn}` once the body itself is past
  # what a request may hold.
  defp copy_part(conn, file, written, file_max, body_left) do
    case read_part_body(conn, length: @chunk, read_length: @chunk) do
      {status, chunk, conn} when status in [:ok, :more] ->
        written = written + byte_size(chunk)

        cond do
          written > body_left ->
            {:error, conn}

          # Equivalent mutant: dropping this branch keeps writing a file past its limit to the
          # temporary file, which `stage/4` then refuses with the same 422; it only bounds the disk
          # one refused request can use. (`drained/4` is what a file past the limit takes.)
          written > file_max ->
            drained(conn, status, written, body_left)

          status == :ok ->
            IO.binwrite(file, chunk)
            {:ok, conn, written}

          true ->
            IO.binwrite(file, chunk)
            copy_part(conn, file, written, file_max, body_left)
        end

      {:error, _reason} ->
        raise Plug.UploadError, "the multipart body could not be read"
    end
  end

  # A file past its limit is read to its end without being kept, so the request can name it. Its
  # last chunk may already have been read.
  defp drained(conn, :ok, written, _body_left), do: {:over, conn, written}
  defp drained(conn, :more, written, body_left), do: drain(conn, written, body_left)

  defp drain(conn, written, body_left) do
    case read_part_body(conn, length: @chunk, read_length: @chunk) do
      {next, chunk, conn} when next in [:ok, :more] ->
        written = written + byte_size(chunk)

        cond do
          written > body_left -> {:error, conn}
          next == :ok -> {:over, conn, written}
          true -> drain(conn, written, body_left)
        end

      {:error, _reason} ->
        raise Plug.UploadError, "the multipart body could not be read"
    end
  end

  defp field_part(conn, name, state) do
    case read_field(conn, "", @fields - state.field_bytes) do
      {:ok, conn, value} ->
        Plug.Conn.Utils.validate_utf8!(value, Plug.Parsers.BadEncodingError, "multipart body")

        {:ok, conn,
         %{
           state
           | fields: [{name, value} | state.fields],
             field_bytes: state.field_bytes + byte_size(value)
         }}

      {:error, conn} ->
        {:error, conn, :too_large}
    end
  end

  defp read_field(conn, acc, left) do
    case read_part_body(conn, length: @chunk, read_length: @chunk) do
      {status, chunk, conn} when status in [:ok, :more] ->
        acc = acc <> chunk

        cond do
          byte_size(acc) > left -> {:error, conn}
          status == :ok -> {:ok, conn, acc}
          true -> read_field(conn, acc, left)
        end

      {:error, _reason} ->
        raise Plug.UploadError, "the multipart body could not be read"
    end
  end

  # A part that is not ours is read past without being kept, counted against the body.
  defp skip_part(conn, state) do
    case read_part_body(conn, length: @chunk, read_length: @chunk) do
      # The bound on a `:more` chunk is an equivalent mutant: the last chunk is counted as well, so a
      # part past the body is refused either way; this one only stops reading it sooner.
      {:more, chunk, conn} ->
        bytes = state.bytes + byte_size(chunk)

        if bytes > state.max,
          do: {:error, conn, :too_large},
          else: skip_part(conn, %{state | bytes: bytes})

      {:ok, chunk, conn} ->
        bytes = state.bytes + byte_size(chunk)

        if bytes > state.max,
          do: {:error, conn, :too_large},
          else: {:ok, conn, %{state | bytes: bytes}}

      {:error, _reason} ->
        raise Plug.UploadError, "the multipart body could not be read"
    end
  end

  # `{name, filename | nil}` from the part's `content-disposition`, or nil.
  defp disposition(headers) do
    with {_, value} <- List.keyfind(headers, "content-disposition", 0),
         %{"name" => name} = params <- Plug.Conn.Utils.params(value) do
      {name, params["filename"] || star_filename(params["filename*"])}
    else
      _other -> nil
    end
  end

  defp star_filename("utf-8''" <> encoded), do: URI.decode(encoded)
  defp star_filename(_other), do: nil

  # The fields as a form's would be: `a[b]=1` is a map.
  defp decode(pairs) do
    pairs
    |> Enum.reverse()
    |> Enum.reduce(Plug.Conn.Query.decode_init(), &Plug.Conn.Query.decode_each/2)
    |> Plug.Conn.Query.decode_done()
  end

  defp temp_path do
    dir = Path.join(System.tmp_dir!(), "forge-upload")
    File.mkdir_p!(dir)
    Path.join(dir, Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false))
  end

  # Path parameters win, as they do for a body Plug parsed itself.
  defp merge(conn, fields) do
    %{
      conn
      | body_params: fields,
        params: conn.params |> Map.merge(fields) |> Map.merge(conn.path_params)
    }
  end

  defp stage(conn, project, uploads, refused) do
    actor = actor(conn)

    case stage_all(project, actor, uploads, refused) do
      {:ok, staged} ->
        ids = Enum.map(staged, & &1.id)

        # In the request's own process, which is what the router's error handler can reach: the conn it
        # is given is the one the router was called with, before this plug ran.
        Process.put(:api_files_staged, {project, actor, ids})

        conn
        |> register_before_send(&discard_unclaimed(&1, project, actor, ids))
        |> assign(:attachments, %Batch{uploads: staged, whole?: true})

      {:refused, refused, staged} ->
        Attachments.discard(project, actor, Enum.map(staged, & &1.id))
        FallbackController.call(conn, {:error, {:attachments_refused, refused}}) |> halt()
    end
  end

  defp stage_all(project, actor, uploads, refused_before) do
    limits = Attachments.limits()

    # Equivalent mutant: the claim refuses the 11th file whole as well. This only stops one request
    # from staging a thousand files before it is told so.
    {kept, over} = Enum.split(uploads, limits.per_act)
    extra = refused_before ++ Enum.map(over, &{&1.filename, :per_act})

    {staged, refused} =
      Enum.reduce(kept, {[], extra}, fn %Plug.Upload{path: path, filename: name}, {ok, bad} ->
        case Attachments.stage(project, actor, {:file, path}, name) do
          {:ok, upload} -> {[%{id: upload.id, name: name} | ok], bad}
          {:error, {:attachments_refused, found}} -> {ok, bad ++ found}
          {:error, _reason} -> {ok, bad ++ [{name, :size}]}
        end
      end)

    case refused do
      [] -> {:ok, Enum.reverse(staged)}
      _some -> {:refused, refused, staged}
    end
  end

  # What the operation did not claim goes with a failed request: a refusal after staging must not
  # leave the bytes for the sweep to find a day later.
  #
  # `>= 400` against `> 400` is an equivalent mutant: the only 400 a route that takes files answers
  # after staging is Phoenix's for a request the action has no clause for (a missing `to`), which is
  # an exception and is cleaned by `discard_after_error/1`, not here; the other answers are 403, 404,
  # 409, 413 and 422.
  defp discard_unclaimed(conn, project, actor, ids) do
    if conn.status >= 400, do: Attachments.discard(project, actor, ids)
    Process.delete(:api_files_staged)
    conn
  end

  @doc """
  What a request staged and an **exception** cut short: `before_send` does not run for a request
  Phoenix answers by rendering an error (a missing `to` is an `ActionClauseError`, a 400), so
  `ForgeWeb.Router`'s error handler calls this, and the files do not wait for the day-old sweep.
  Nothing to do for a request that staged nothing.
  """
  @spec discard_after_error() :: :ok
  def discard_after_error do
    case Process.delete(:api_files_staged) do
      {project, actor, ids} -> Attachments.discard(project, actor, ids)
      nil -> 0
    end

    :ok
  end

  defp actor(%{assigns: %{current_scope: %{token: %{} = token}}}), do: token
  defp actor(conn), do: conn.assigns.current_scope.user

  defp too_large(conn),
    do:
      refuse(
        conn,
        :request_entity_too_large,
        "too_large",
        "the request is larger than #{Attachments.limit_text(:per_act)} allow"
      )

  defp refuse(conn, status, reason, detail) do
    conn
    |> put_status(status)
    |> Phoenix.Controller.json(%{error: %{reason: reason, detail: detail}})
    |> halt()
  end
end
