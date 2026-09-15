defmodule Forge.Git.Http do
  @moduledoc """
  `git http-backend` as a CGI program, driven from a `Plug.Conn`.

  Erlang ports cannot half-close stdin and `System.cmd/3` offers none at all, so a child reading
  its request body from stdin would block forever. All three of the child's streams are therefore
  files: the request body is streamed into one a megabyte at a time, and the response is sent back
  out of another with `Plug.Conn.send_file/5` at the offset where the CGI headers end. A clone's
  packfile goes kernel to file to socket and never becomes a binary on the heap.

  The whole response is produced before its first byte reaches the client, so there is no sideband
  progress during a clone. On a PoC that runs on one machine this is invisible; the fix, when it
  stops being invisible, is named in `docs/design/git-hosting.md`.
  """

  import Plug.Conn

  alias Forge.Git.Token
  alias Forge.Projects
  alias Forge.Projects.Project

  require Logger

  @chunk 1_000_000
  @default_max_body 100 * 1024 * 1024
  @header_probe 8192

  # Every FORGE_* variable the platform's own environment might carry, listed so it can be
  # removed. `System.cmd/3` MERGES `:env` with the BEAM's environment rather than replacing it,
  # and FORGE_INTERNAL is what pre-receive accepts as authority over the default branch: leaking
  # it into a CGI child would let any credential that reaches the network rewrite it.
  @cleared ~w(FORGE_INTERNAL FORGE_ALLOWED_REF FORGE_TOKEN_ID FORGE_TICKET_ID FORGE_PROJECT
              FORGE_GIT_TOKEN FORGE_GIT_URL)

  @doc """
  Serves one smart-HTTP request for `project` against `tail` — the path segments after the
  repository — as the identity `token` describes. Always returns a sent conn.
  """
  @spec serve(Plug.Conn.t(), Project.t(), [String.t()], Token.t()) :: Plug.Conn.t()
  def serve(conn, %Project{} = project, tail, %Token{} = token) do
    dir = Path.join(Forge.Jobs.data_dir(), "git-http")
    File.mkdir_p!(dir)
    stem = Path.join(dir, Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false))
    paths = {stem <> ".in", stem <> ".out", stem <> ".err"}

    try do
      run(conn, project, tail, token, paths)
    after
      # The response has been sent by then: send_file/5 completes before the conn is returned.
      {in_path, out_path, err_path} = paths
      Enum.each([in_path, out_path, err_path], &File.rm/1)
    end
  end

  defp run(conn, project, tail, token, {in_path, out_path, err_path}) do
    case capture_body(conn, in_path) do
      {:ok, conn, length} ->
        repo_path = Projects.repo_path(project)
        env = env(conn, project, repo_path, tail, token, length)

        {_out, status} =
          System.cmd("sh", ["-c", script(), "forge-git", in_path, out_path, err_path],
            cd: Path.dirname(repo_path),
            env: env
          )

        report(err_path, project, token)

        if status == 0 do
          reply(conn, out_path)
        else
          Logger.error("git http-backend exited #{status} for #{project.name}")
          send_resp(conn, 500, "")
        end

      {:error, :too_large} ->
        send_resp(conn, 413, "forge: the request body is larger than this endpoint accepts\n")

      {:error, reason} ->
        Logger.warning("could not read a git request body: #{inspect(reason)}")
        send_resp(conn, 400, "")
    end
  end

  defp script, do: ~S|exec git http-backend <"$1" >"$2" 2>"$3"|

  # `read_body/2`'s `:length` is per call, so memory stays at one chunk however large the push.
  defp capture_body(conn, path) do
    max = Forge.Jobs.config(:git_max_body_bytes, @default_max_body)
    file = File.open!(path, [:write, :binary])

    try do
      read_into(conn, file, 0, max)
    after
      File.close(file)
    end
  end

  defp read_into(conn, file, written, max) do
    case read_body(conn, length: @chunk, read_timeout: 60_000) do
      {:ok, chunk, conn} ->
        IO.binwrite(file, chunk)
        {:ok, conn, written + byte_size(chunk)}

      {:more, chunk, conn} ->
        written = written + byte_size(chunk)

        if written > max do
          {:error, :too_large}
        else
          IO.binwrite(file, chunk)
          read_into(conn, file, written, max)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp env(conn, project, repo_path, tail, token, length) do
    path_info = "/" <> Path.basename(repo_path) <> "/" <> Enum.join(tail, "/")

    cleared = Enum.map(@cleared, &{&1, nil})

    set = [
      {"GIT_PROJECT_ROOT", Path.dirname(repo_path)},
      {"GIT_HTTP_EXPORT_ALL", "1"},
      {"PATH_INFO", path_info},
      {"REQUEST_METHOD", conn.method},
      {"QUERY_STRING", conn.query_string},
      {"CONTENT_TYPE", header(conn, "content-type")},
      {"CONTENT_LENGTH", Integer.to_string(length)},
      # Clients gzip upload-pack request bodies, and http-backend inflates only when it sees this.
      {"HTTP_CONTENT_ENCODING", header(conn, "content-encoding")},
      # Without this every protocol v2 client silently degrades to v0.
      {"GIT_PROTOCOL", header(conn, "git-protocol")},
      {"REMOTE_USER", remote_user(token)},
      {"REMOTE_ADDR", conn.remote_ip |> :inet.ntoa() |> to_string()},
      {"SERVER_PROTOCOL", "HTTP/1.1"},
      {"GATEWAY_INTERFACE", "CGI/1.1"},
      {"SERVER_SOFTWARE", "forge"},
      {"GIT_COMMITTER_NAME", "forge"},
      {"GIT_COMMITTER_EMAIL", "forge@localhost"},
      {"FORGE_ALLOWED_REF", token.ref},
      {"FORGE_TOKEN_ID", token.id},
      {"FORGE_TICKET_ID", token.ticket_id},
      {"FORGE_PROJECT", project.name}
    ]

    # The cleared list comes first so a variable this request does set wins over its removal.
    Enum.uniq_by(Enum.reject(set, &(elem(&1, 1) == nil)) ++ cleared, &elem(&1, 0))
  end

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _rest] -> value
      [] -> nil
    end
  end

  # `git http-backend` enables `receive-pack` only when `REMOTE_USER` is set, so being non-empty
  # is the whole of what this has to be. The two prefixes are for a person reading a log, and
  # nothing in this product reads them back: the audit trail uses `actor/1`, which reads the
  # token's `job_id` directly, and neither the hooks nor the worker look at `REMOTE_USER` at all.
  # Changing a prefix is therefore cosmetic — no test can distinguish them, and that is correct
  # rather than a gap.
  defp remote_user(%Token{job_id: nil, id: id}), do: "forge-token-" <> id
  defp remote_user(%Token{job_id: job_id}), do: "forge-job-" <> job_id

  # CGI writes its headers, a blank line, then the body. git emits CRLF; be liberal about LF.
  defp reply(conn, out_path) do
    {headers, offset} = read_headers(out_path)
    {status, headers} = split_status(headers)

    conn
    |> merge_resp_headers(headers)
    |> send_file(status, out_path, offset, :all)
  end

  defp read_headers(path) do
    file = File.open!(path, [:read, :binary])
    probe = IO.binread(file, @header_probe)
    File.close(file)

    probe = if probe == :eof, do: "", else: probe

    case boundary(probe) do
      nil -> {[], 0}
      {at, size} -> {parse_headers(binary_part(probe, 0, at)), at + size}
    end
  end

  defp boundary(probe) do
    crlf = :binary.match(probe, "\r\n\r\n")
    lf = :binary.match(probe, "\n\n")

    case {crlf, lf} do
      {:nomatch, :nomatch} -> nil
      {{at, size}, :nomatch} -> {at, size}
      {:nomatch, {at, size}} -> {at, size}
      {{a, sa}, {b, sb}} -> if a <= b, do: {a, sa}, else: {b, sb}
    end
  end

  defp parse_headers(block) do
    block
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] -> [{name |> String.trim() |> String.downcase(), String.trim(value)}]
        _other -> []
      end
    end)
  end

  defp split_status(headers) do
    case List.keytake(headers, "status", 0) do
      nil -> {200, headers}
      {{_name, value}, rest} -> {status_code(value), rest}
    end
  end

  defp status_code(value) do
    case Integer.parse(String.trim(value)) do
      {code, _rest} when code in 100..599 -> code
      _other -> 500
    end
  end

  # A hook's refusal and its notes arrive on stderr. They reach the pushing client through the
  # sideband already; this is what puts them in the platform's own record.
  defp report(err_path, project, token) do
    case File.read(err_path) do
      {:ok, ""} ->
        :ok

      {:ok, text} ->
        for line <- String.split(text, "\n", trim: true), String.starts_with?(line, "forge: ") do
          Forge.Events.append("git.hook.said", actor(token), %{
            ticket_id: token.ticket_id,
            job_id: token.job_id,
            payload: %{"project" => project.name, "message" => line}
          })
        end

        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp actor(%Token{job_id: nil}), do: :system
  defp actor(%Token{job_id: job_id}), do: {:job, job_id}
end
