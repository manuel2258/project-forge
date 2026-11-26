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
  # and FORGE_INTERNAL is what pre-receive accepts as authority over the default branch and over
  # tags: leaking it into a CGI child would let any credential that reaches the network rewrite the
  # one and create the other.
  @cleared ~w(FORGE_INTERNAL FORGE_ALLOWED_REF FORGE_ALLOWED_REFS FORGE_NO_REWRITE FORGE_TOKEN_ID FORGE_TICKET_ID FORGE_PROJECT
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
          Forge.Git.spawn_cmd("sh", ["-c", script(), "forge-git", in_path, out_path, err_path],
            cd: Path.dirname(repo_path),
            env: env
          )

        report(err_path, project, token)

        if status == 0 do
          record_pushes(conn, project, tail, token, repo_path, in_path)
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

    set =
      [
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
        {"SERVER_SOFTWARE", "forge"}
      ] ++
        Forge.Git.committer_env() ++
        [
          {"FORGE_ALLOWED_REFS", token |> Forge.Git.Tokens.allowed_refs(project) |> allowed()},
          {"FORGE_NO_REWRITE", if(token.git_access in [:developer, :admin], do: "1")},
          {"FORGE_TOKEN_ID", token.id},
          {"FORGE_TICKET_ID", token.ticket_id},
          {"FORGE_PROJECT", project.name}
        ]

    # The cleared list comes first so a variable this request does set wins over its removal.
    Enum.uniq_by(Enum.reject(set, &(elem(&1, 1) == nil)) ++ cleared, &elem(&1, 0))
  end

  # Empty is nothing to export: `pre-receive` reads an unset list as "writes nothing".
  defp allowed([]), do: nil
  defp allowed(refs), do: Enum.join(refs, " ")

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

  # -- what a push did to a ticket's branch -------------------------------------------------------

  @zeros String.duplicate("0", 40)
  # The ref commands of a push are its first pkt-lines, a few hundred bytes each; a megabyte holds
  # any push a branch token or a developer can make, and the rest of the body is the pack, which
  # is never read here.
  @commands_probe 1_000_000
  # Nine digits at most: a ticket number is a 32-bit integer in the database, and a longer one is
  # no ticket's.
  @ticket_ref ~r|\Arefs/heads/ticket/([1-9][0-9]{0,8})\z|

  # **`branch.pushed` for every ticket branch a push moved** (`docs/design/git-hosting.md` § A job
  # pushes with a lease): the event a moved-branch stop names its pushers from. It is read from the
  # request body already on disk, and recorded only for a ref that **now resolves to the commit the
  # push named** — a push a hook refused leaves the ref where it was and `http-backend` still answers
  # 200 with the refusal in its report, so the status says nothing and the ref is the witness. A
  # body that is not a receive-pack request, or cannot be read as pkt-lines, records nothing and
  # never fails the push.
  defp record_pushes(%{method: "POST"}, project, ["git-receive-pack"], token, repo_path, in_path) do
    for {old, new, ref} <- ref_commands(in_path),
        number = ticket_number(ref),
        old != new,
        {:ok, ^new} <- [Forge.Git.resolve(repo_path, ref)],
        %{id: ticket_id} <- [
          Forge.Repo.get_by(Forge.Tickets.Ticket, project_id: project.id, number: number)
        ] do
      Forge.Events.append("branch.pushed", pusher(token), %{
        ticket_id: ticket_id,
        payload: %{"ref" => ref, "from" => if(old == @zeros, do: nil, else: old), "to" => new}
      })

      # A job's own push is the run's business; a person's or a token's is what a page watching the
      # ticket wants to see.
      if token.job_id == nil, do: Forge.Events.notify(ticket_id)
    end

    :ok
  end

  defp record_pushes(_conn, _project, _tail, _token, _repo_path, _in_path), do: :ok

  defp ticket_number(ref) do
    case Regex.run(@ticket_ref, ref) do
      [_whole, digits] -> String.to_integer(digits)
      nil -> nil
    end
  end

  # A project token is named, so the event says which; a job's own token is the job.
  defp pusher(%Token{job_id: job_id}) when is_binary(job_id), do: {:job, job_id}
  defp pusher(%Token{id: id, name: name}), do: {:api, id, name || "token"}

  @doc """
  The ref commands `{old, new, ref}` at the start of a receive-pack request body in the file `path`,
  in order, or `[]` when it does not read as them. `shallow` lines and a push certificate are not
  commands and are skipped past or end the list.
  """
  @spec ref_commands(Path.t()) :: [{String.t(), String.t(), String.t()}]
  def ref_commands(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          case IO.binread(file, @commands_probe) do
            data when is_binary(data) -> parse_commands(data, [])
            _eof_or_error -> []
          end
        after
          File.close(file)
        end

      {:error, _reason} ->
        []
    end
  end

  # pkt-line: four hex digits, the length including themselves; `0000` is the flush that ends the
  # commands. The first command carries the capabilities after a NUL.
  defp parse_commands(<<"0000", _pack::binary>>, acc), do: Enum.reverse(acc)

  defp parse_commands(<<len::binary-size(4), rest::binary>>, acc) do
    with {n, ""} when n >= 4 <- Integer.parse(len, 16),
         size = n - 4,
         <<line::binary-size(size), more::binary>> <- rest do
      case command(line) do
        {:command, command} -> parse_commands(more, [command | acc])
        :skip -> parse_commands(more, acc)
        :stop -> Enum.reverse(acc)
      end
    else
      _unreadable -> []
    end
  end

  defp parse_commands(_short, _acc), do: []

  defp command("shallow " <> _sha), do: :skip

  defp command(line) do
    [text | _caps] = String.split(line, <<0>>, parts: 2)

    case String.split(String.trim_trailing(text, "\n"), " ", parts: 3) do
      [old, new, ref] when byte_size(old) in [40, 64] and byte_size(new) in [40, 64] ->
        {:command, {old, new, ref}}

      _not_a_command ->
        :stop
    end
  end
end
