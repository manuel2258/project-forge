defmodule ForgeWorker.Job.Dir do
  @moduledoc """
  The job directory: the agent's whole interface to the platform, as files.
  See `docs/design/job-prompt.md`.

      <root>/<job_id>/spec.json
      <root>/<job_id>/prompt.md
      <root>/<job_id>/inputs/<name>
      <root>/<job_id>/tickets/index.md     the project's tickets and open proposals
      <root>/<job_id>/tickets/<number>.md  one ticket's body
      <root>/<job_id>/conversation.md      a reopened conversation's past, read-only
      <root>/<job_id>/out/<name>
      <root>/<job_id>/out/proposals/<file> ticket proposals, written by the agent
      <root>/<job_id>/out/<file>           a conversation's documents; see documents/1
      <root>/<job_id>/invoke.json          commands an agent asks to run, then removed
      <root>/<job_id>/commands/<n>-<name>.log  a resumed run's command logs, read-only
      <root>/<job_id>/home                 HOME for the harness process
      <root>/<job_id>/stderr.log

  And beside it, the worker's own (`worker_dir/1`), which the job cannot reach:

      <root>/<job_id>.worker/transcript-<run>.jsonl
      <root>/<job_id>.worker/command.log   a command job's combined output
      <root>/<job_id>.worker/blobs/<n>     a run's groups of files, staged for upload
      <root>/<job_id>.worker/fetched/<n>   command logs fetched for a resume, before `commands/`
  """

  alias ForgeCore.{Document, Proposal, Workflow}
  alias ForgeCore.Job.Spec
  alias ForgeWorker.Log

  require Logger

  @uuid ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  @doc """
  Prepares the directory for `spec` under `root` and returns its path. On a first run it is
  created; with `resume: true` the spec and inputs are refreshed while `out/`, earlier
  transcripts and the harness home are kept, so nothing the job already produced is lost.

  A cold start clears `out/`. The directory is keyed by job id, and a job re-queued after
  its node died keeps that id, so without this the new run would inherit the dead run's
  outputs and `collect/2` would decide an outcome on documents this run never wrote.

  `:backlog` is the project's tickets as the platform composed them at assignment, written to
  `tickets/`. It is rewritten on every call, resume included, for the same reason the platform
  documents are: a run that starts today should read what is true today.

  `:command_logs` is `[{file, path}]`: the logs of the commands a parked job invoked, already
  fetched from the store, copied into `commands/` read-only (`docs/design/job-prompt.md`
  § Commands). `commands/` and any `invoke.json` are removed on every call first — a request left
  from the run that parked has been acted on, and one read again would be run twice.
  """
  @spec prepare(String.t(), Spec.t(), keyword()) :: String.t()
  def prepare(root, %Spec{job_id: job_id} = spec, opts \\ []) do
    check_id!(job_id)
    job_dir = Path.join(root, job_id)
    inputs = Path.join(job_dir, "inputs")
    out = Path.join(job_dir, "out")
    File.rm_rf!(inputs)
    unless Keyword.get(opts, :resume, false), do: File.rm_rf!(out)
    File.mkdir_p!(inputs)
    File.mkdir_p!(out)
    File.mkdir_p!(home_dir(job_dir))
    File.write!(Path.join(job_dir, "spec.json"), Spec.to_json(spec))
    write_platform_docs(job_dir)
    write_backlog(job_dir, Keyword.get(opts, :backlog), job_id)
    write_replay(job_dir, spec.replay)
    File.rm_rf!(invoke_path(job_dir))
    write_command_logs(job_dir, Keyword.get(opts, :command_logs, []), job_id)

    Enum.each(spec.inputs, fn input ->
      path = Path.join(inputs, input.name)
      File.write!(path, input.content)
      File.chmod!(path, 0o444)
    end)

    job_dir
  end

  # What the platform is and what a workflow may contain, for every job and every conversation.
  # On disk rather than in the prompt: the prompt names the folder, so an agent reads it when the
  # machinery is the question and pays nothing for it when it is not. Rewritten every time, so a
  # resumed run gets the current documents rather than the ones its first attempt was given.
  defp write_platform_docs(job_dir) do
    dir = Path.join(job_dir, "platform")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    Enum.each(ForgeCore.Workflow.platform_docs(), fn {name, content} ->
      path = Path.join(dir, name)
      File.write!(path, content)
      File.chmod!(path, 0o444)
    end)
  end

  # Named by the platform, so matched rather than trusted before they become paths: `<n>-<name>.log`,
  # a name being a command's, which the validator holds to one path segment. The directory is made
  # fresh here, so there is nothing an agent planted in it for a lexical check to miss.
  defp write_command_logs(job_dir, logs, job_id) do
    dir = Path.join(job_dir, "commands")
    File.rm_rf!(dir)

    unless logs == [] do
      File.mkdir_p!(dir)
      Enum.each(logs, &write_command_log(dir, &1, job_id))
    end
  end

  defp write_command_log(dir, {file, source}, job_id) do
    if Regex.match?(~r/^[0-9]+-[A-Za-z0-9][A-Za-z0-9._-]*\.log$/, file) do
      target = Path.join(dir, file)
      File.cp!(source, target)
      File.chmod!(target, 0o444)
    else
      Log.line("commands.unwritten", :warning, "refusing a command's log named #{inspect(file)}",
        job_id: job_id
      )
    end
  end

  @doc """
  Raises unless `job_id` is a UUID. It becomes a directory name under the worker's root, and one
  the platform got wrong — or `../x` — would be a directory somewhere else.
  """
  @spec check_id!(String.t()) :: :ok
  def check_id!(job_id) do
    if Regex.match?(@uuid, job_id),
      do: :ok,
      else: raise(ArgumentError, "job id must be a UUID, got #{inspect(job_id)}")
  end

  @doc "Where an agent writes the commands it asks to run (`docs/design/commands.md`)."
  @spec invoke_path(String.t()) :: String.t()
  def invoke_path(job_dir), do: Path.join(job_dir, "invoke.json")

  @doc """
  What the agent asked to run, read from `invoke.json` and then removed: `:none` when it asked for
  nothing, `{:ok, invocations}` as `%{"command" => name, "args" => [string]}`, or `{:error, reason}`
  for a file that is there but is not a list of them — which is reported rather than dropped, so
  the agent hears why nothing ran (`docs/design/commands.md` § How an agent invokes).

  Read as `out/` is read (`read_text/2`): one open, the handle's owner and type checked, a size cap.
  """
  @spec invocations(String.t()) :: :none | {:ok, [map()]} | {:error, String.t()}
  def invocations(job_dir), do: invocations(job_dir, owner(job_dir))

  @doc false
  def invocations(job_dir, owner) do
    path = invoke_path(job_dir)

    case File.lstat(path) do
      {:error, :enoent} ->
        :none

      {:ok, _stat} ->
        read = read_text(path, owner)
        File.rm_rf(path)

        with {:ok, raw} <- read,
             {:ok, decoded} <- decode_invocations(raw) do
          {:ok, decoded}
        else
          {:error, reason} -> {:error, "invoke.json " <> reason}
        end

      {:error, reason} ->
        {:error, "invoke.json is unreadable: #{inspect(reason)}"}
    end
  end

  defp decode_invocations(raw) do
    case Jason.decode(raw) do
      {:ok, list} when is_list(list) and list != [] ->
        list
        |> Enum.map(&invocation/1)
        |> Enum.reduce_while({:ok, []}, fn
          {:ok, entry}, {:ok, acc} -> {:cont, {:ok, acc ++ [entry]}}
          {:error, reason}, _acc -> {:halt, {:error, reason}}
        end)

      {:ok, _other} ->
        {:error, "must be a non-empty JSON array of {\"command\": …, \"args\": […]}"}

      {:error, _reason} ->
        {:error, "is not valid JSON"}
    end
  end

  defp invocation(%{"command" => command} = entry) when is_binary(command) and command != "" do
    case Map.get(entry, "args", []) do
      args when is_list(args) ->
        if Enum.all?(args, &is_binary/1),
          do: {:ok, %{"command" => command, "args" => args}},
          else: {:error, "has arguments that are not strings for #{inspect(command)}"}

      _other ->
        {:error, "has args that are not a list for #{inspect(command)}"}
    end
  end

  defp invocation(_entry), do: {:error, "has an entry with no command name"}

  # What a reopened conversation had already said, for the new process to read. Removed when the
  # spec carries none: the directory is keyed by job id and outlives a process, so a file left
  # from an earlier start would be a conversation the agent believes it had. Removed before it is
  # written, too, because the last one was left read-only.
  defp write_replay(job_dir, replay) do
    path = Path.join(job_dir, Workflow.replay_file())
    File.rm_rf!(path)
    if is_binary(replay), do: write_readonly(path, replay)
  end

  # The project's tickets and open proposals, laid out as a folder rather than put in the prompt.
  # An unread file costs nothing, which is the whole argument for handing every job the backlog:
  # tokens are the scarce thing here, not disk. See `docs/design/ticket-proposals.md`
  # § Reading the backlog.
  #
  # Rewritten whole each time. A stale file from an earlier composition would be a ticket the
  # agent believes still exists, which is worse than not having the folder at all.
  defp write_backlog(job_dir, nil, _job_id), do: File.rm_rf!(backlog_dir(job_dir))

  defp write_backlog(job_dir, backlog, job_id) when is_map(backlog) do
    dir = backlog_dir(job_dir)
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    write_readonly(Path.join(dir, "index.md"), backlog["index"] || "")

    Enum.each(backlog["tickets"] || [], &write_backlog_entry(dir, &1, job_id))

    case backlog["proposals"] || [] do
      [] ->
        :ok

      proposals ->
        nested = Path.join(dir, Workflow.proposals_dir())
        File.mkdir_p!(nested)
        Enum.each(proposals, &write_backlog_entry(nested, &1, job_id))
    end
  rescue
    # The backlog is context, and context is never worth the job. `prepare/3` is called from
    # `Runner.init/1`, so anything that raises here is a job that never starts — and because the
    # backlog is recomposed identically on every assignment, it would be a job that never starts
    # again either. A name the platform should not have sent is a line in the log, not an outage.
    error ->
      Log.line(
        "backlog.unwritten",
        :warning,
        "could not write the backlog: #{Exception.message(error)}",
        job_id: job_id
      )
  end

  defp backlog_dir(job_dir), do: Path.join(job_dir, Workflow.tickets_dir())

  # The file name arrives over the channel and is joined to a path, so it is expanded and then
  # required to sit directly in the folder — a lexical check, which is *not* the model
  # `File.write!` follows.
  #
  # CLAUDE.md names that gap as the trap, so what closes it here has to be said rather than
  # assumed: `write_backlog/2` does `rm_rf!` then `mkdir_p!` on this directory on every call,
  # so there is no symlink for a lexical check to be wrong about — nothing the agent planted
  # survives into the window, and an entry cannot create a subdirectory to hide one in. The
  # guard is sound because of that, not because `Path.expand` is filesystem-aware. It is not.
  defp write_backlog_entry(dir, %{"file" => file, "content" => content}, job_id)
       when is_binary(file) do
    base = Path.expand(dir)
    path = Path.expand(Path.join(base, file))

    if Path.dirname(path) == base do
      write_readonly(path, content || "")
    else
      Log.line(
        "backlog.unwritten",
        :warning,
        "refusing #{inspect(file)}, which leaves the folder",
        job_id: job_id
      )
    end
  end

  defp write_backlog_entry(_dir, entry, job_id) do
    Log.line(
      "backlog.unwritten",
      :warning,
      "refusing an entry with no file name: #{inspect(entry)}",
      job_id: job_id
    )
  end

  defp write_readonly(path, content) do
    File.write!(path, content)
    File.chmod!(path, 0o444)
  end

  @doc """
  Removes job directories under `root` that nothing has touched for `older_than_ms`, and says
  how many went — the worker's own beside each (`worker_dir/1`) counted as one of them.

  Retention rather than lifecycle, and that is the point. A job directory holds the agent's
  private `HOME`, which is where Claude Code keeps the session a resume needs, so it cannot go
  the moment a job ends — and a worker cannot always tell whether a job will be resumed. An age
  is something it can tell. `docs/design/worker-tier.md` § What a machine that never dies
  accumulates says why this exists at all: until a worker could be permanent, the machine's own
  destruction collected these.

  The directory currently in use is never old, because `prepare/3` has just written to it.
  """
  @spec sweep(Path.t(), non_neg_integer()) :: non_neg_integer()
  def sweep(root, older_than_ms) do
    cutoff = System.os_time(:second) - div(older_than_ms, 1000)

    case File.ls(root) do
      {:ok, entries} -> Enum.count(entries, &remove_if_stale(Path.join(root, &1), cutoff))
      {:error, _reason} -> 0
    end
  end

  defp remove_if_stale(path, cutoff) do
    with true <- File.dir?(path),
         {:ok, %File.Stat{mtime: mtime}} <- File.stat(path, time: :posix),
         true <- mtime < cutoff do
      # Not the bang form: this runs on the path that reports a job's result, and an unlinkable
      # leftover would take the link process down with it and re-queue the worker's jobs. A
      # directory that will not go away is worth a line in the log and nothing more.
      case File.rm_rf(path) do
        {:ok, _removed} ->
          true

        {:error, reason, file} ->
          Logger.warning("could not sweep #{file}: #{inspect(reason)}")
          false
      end
    else
      _other -> false
    end
  end

  @doc "The harness's private HOME, so its own state lives with the job and not the operator."
  @spec home_dir(String.t()) :: String.t()
  def home_dir(job_dir), do: Path.join(job_dir, "home")

  @doc """
  Reads and parses what the agent wrote under `out/`, against what the spec declared.

  `proposals/` is read too, and is the one thing in `out/` that is neither declared nor
  undeclared: it is reserved, permitted to every job, and required of none
  (`docs/design/ticket-proposals.md` § The files). Leaving it out of `undeclared` is not
  cosmetic — an undeclared output ends the job with `error`, so a job that proposed anything
  would fail for having done so.
  """
  @spec collect(String.t(), Spec.t()) :: %{
          documents: %{String.t() => Document.t()},
          invalid: %{String.t() => [ForgeCore.Error.t()]},
          missing: [String.t()],
          undeclared: [String.t()],
          proposals: %{String.t() => Proposal.t()},
          invalid_proposals: %{String.t() => String.t()}
        }
  def collect(job_dir, %Spec{} = spec), do: collect(job_dir, spec, owner(job_dir))

  # The owner is the job directory's, always; this arity exists so a test can name another and
  # see a file refused for its owner without needing a second Unix user to make one.
  @doc false
  def collect(job_dir, %Spec{} = spec, owner) do
    out = Path.join(job_dir, "out")
    declared = Spec.document_outputs(spec)
    reserved = Workflow.proposals_dir()
    groups = Spec.group_outputs(spec)
    written = out |> list_dir() |> Enum.sort()

    parsed =
      declared
      |> Enum.filter(&(&1 in written))
      |> Map.new(fn name -> {name, read_document(Path.join(out, name), owner)} end)

    proposals = collect_proposals(Path.join(out, reserved), owner)

    %{
      documents: for({name, {:ok, doc}} <- parsed, into: %{}, do: {name, doc}),
      invalid: for({name, {:error, errors}} <- parsed, into: %{}, do: {name, errors}),
      missing: declared -- written,
      # A declared group's directory is declared, and its files are `stage_groups/4`'s to read.
      undeclared: (written -- declared) -- [reserved | groups],
      proposals: for({name, {:ok, p}} <- proposals, into: %{}, do: {name, p}),
      invalid_proposals: for({name, {:error, why}} <- proposals, into: %{}, do: {name, why})
    }
  end

  @doc """
  Copies the files of each declared group out of `out/<group>/` into `staging`, a directory only
  the worker writes, and says which could not be kept and why (`docs/design/job-prompt.md`
  § Groups of files). Returns `%{staged: [{artifact_name, path}], invalid: %{name => reason}}`.

  Each file is read the way `out/` always is (`read_text/2`, less the text): opened once, and the
  *handle's* stat decides — a regular file the job owns, no larger than `:max_bytes` — and the
  copy is made through that handle, so what is uploaded is what was checked. A group's count is
  capped at `:max_files`; a name that is not an artifact name is refused, not rewritten.
  """
  @spec stage_groups(String.t(), [String.t()], String.t(), keyword()) :: %{
          staged: [{String.t(), String.t()}],
          invalid: %{String.t() => String.t()}
        }
  def stage_groups(job_dir, groups, staging, opts \\ []) do
    owner = Keyword.get_lazy(opts, :owner, fn -> owner(job_dir) end)

    limits = %{
      max_bytes: Keyword.fetch!(opts, :max_bytes),
      max_files: Keyword.fetch!(opts, :max_files)
    }

    groups
    |> Enum.reduce(%{staged: [], invalid: %{}, n: 0}, fn group, acc ->
      stage_group(Path.join([job_dir, "out", group]), group, staging, owner, limits, acc)
    end)
    |> Map.delete(:n)
  end

  defp stage_group(dir, group, staging, owner, limits, acc) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory}} ->
        dir
        |> list_dir()
        |> Enum.sort()
        |> Enum.with_index()
        |> Enum.reduce(acc, &stage_entry(&1, &2, dir, group, staging, owner, limits))

      # Not there: a group with nothing in it this time, which is allowed.
      {:error, _reason} ->
        acc

      {:ok, %File.Stat{type: type}} ->
        refuse(acc, Workflow.member(group, "*"), "must be a directory, not a #{describe(type)}")
    end
  end

  defp stage_entry({file, index}, acc, dir, group, staging, owner, limits) do
    name = Workflow.member(group, file)

    cond do
      not Workflow.valid_name?(file) ->
        refuse(
          acc,
          name,
          "is not a name: letters, digits, . _ -, starting with one of the first two"
        )

      index >= limits.max_files ->
        refuse(acc, name, "is one more than the #{limits.max_files} files a group may keep")

      true ->
        stage_file(Path.join(dir, file), name, staging, owner, limits, acc)
    end
  end

  defp refuse(acc, name, reason), do: %{acc | invalid: Map.put(acc.invalid, name, reason)}

  defp stage_file(path, name, staging, owner, limits, acc) do
    target = Path.join(staging, Integer.to_string(acc.n + 1))

    case copy_owned(path, target, owner, limits.max_bytes) do
      :ok -> %{acc | staged: acc.staged ++ [{name, target}], n: acc.n + 1}
      {:error, reason} -> refuse(acc, name, reason)
    end
  end

  # The same guard as `read_text/2`: `lstat` names a link as a link and keeps a FIFO from being
  # opened at all, and then the handle's own stat decides, because the job is alive to swap the
  # path between the two.
  #
  # The stat's `size <= max_bytes` and the copy's own cap (`copy_chunks/4`) are each an equivalent
  # mutant for a file that does not change: either refuses it with the same words. They differ for
  # a file still being appended to, which is past the stat by the time it is read — the copy's cap
  # is the one that holds then, and no test can arrange a file growing mid-copy.
  #
  # The handle's `type: :regular` is out of a test's reach for the reason `read_open/2` gives: only
  # something swapped in between the `lstat` and the open arrives as anything else.
  defp copy_owned(path, target, owner, max_bytes) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, io} <- :file.open(path, [:read, :binary, :raw]) do
      try do
        with {:ok, info} <- :file.read_file_info(io),
             %File.Stat{type: :regular, uid: ^owner, size: size} when size <= max_bytes <-
               File.Stat.from_record(info) do
          File.mkdir_p!(Path.dirname(target))
          copy_handle(io, target, max_bytes)
        else
          %File.Stat{type: :regular, uid: ^owner} ->
            {:error, "is larger than #{max_bytes} bytes"}

          %File.Stat{type: :regular, uid: uid} ->
            {:error, "must be the job's own file, not one owned by uid #{uid}"}

          %File.Stat{type: type} ->
            {:error, "must be a regular file, got #{type}"}

          {:error, reason} ->
            {:error, "unreadable: #{inspect(reason)}"}
        end
      after
        :file.close(io)
      end
    else
      {:ok, %File.Stat{type: type}} -> {:error, "must be a regular file, got #{type}"}
      {:error, reason} -> {:error, "unreadable: #{inspect(reason)}"}
    end
  end

  # Capped as it is copied, not only by the stat: a file the job is still appending to is read no
  # further than the cap.
  defp copy_handle(io, target, max_bytes) do
    {:ok, out} = :file.open(target, [:write, :binary, :raw])

    try do
      copy_chunks(io, out, 0, max_bytes)
    after
      :file.close(out)
    end
  end

  defp copy_chunks(io, out, copied, max_bytes) do
    case :file.read(io, 1024 * 1024) do
      :eof ->
        :ok

      {:ok, chunk} when copied + byte_size(chunk) > max_bytes ->
        {:error, "is larger than #{max_bytes} bytes"}

      {:ok, chunk} ->
        :ok = :file.write(out, chunk)
        copy_chunks(io, out, copied + byte_size(chunk), max_bytes)

      {:error, reason} ->
        {:error, "unreadable: #{inspect(reason)}"}
    end
  end

  @doc """
  Just the proposals, for a caller with no spec to collect against.

  A conversation has no declared outputs and no outcome, so `collect/2` has nothing to do for
  it — but it may still propose, and its proposals have to be reported every turn rather than at
  the end: `out/` is not committed, and a conversation that loses its worker loses what is only
  there (`docs/design/conversations.md` § Lifetime).
  """
  @spec proposals(String.t()) :: %{
          proposals: %{String.t() => Proposal.t()},
          invalid_proposals: %{String.t() => String.t()}
        }
  def proposals(job_dir), do: proposals(job_dir, owner(job_dir))

  @doc false
  def proposals(job_dir, owner) do
    collected = collect_proposals(Path.join([job_dir, "out", Workflow.proposals_dir()]), owner)

    %{
      proposals: for({name, {:ok, p}} <- collected, into: %{}, do: {name, p}),
      invalid_proposals: for({name, {:error, why}} <- collected, into: %{}, do: {name, why})
    }
  end

  @doc """
  What a conversation wrote in `out/` besides its proposals: every file there, as text, and the
  ones that cannot be documents with the reason.

  A conversation declares nothing, so there is nothing to collect against — every file it leaves
  in `out/` is a document it means to keep, and it is reported every turn for the reason
  `proposals/1` is (`docs/design/conversations.md` § Commits). Held to a workflow job's rules
  where they apply: a name the platform does not keep for itself
  (`ForgeCore.Workflow.document_name_error/1`), a regular file, and text. Whether it parses is
  the platform's to decide, where it is recorded — it checks all of this again, since what
  crosses the channel is not a guard.
  """
  @spec documents(String.t()) :: %{
          documents: %{String.t() => String.t()},
          invalid_documents: %{String.t() => String.t()}
        }
  def documents(job_dir), do: documents(job_dir, owner(job_dir))

  @doc false
  def documents(job_dir, owner) do
    out = Path.join(job_dir, "out")

    read =
      out
      |> list_dir()
      |> Kernel.--([Workflow.proposals_dir()])
      |> Map.new(&{&1, read_output(out, &1, owner)})

    %{
      documents: for({name, {:ok, raw}} <- read, into: %{}, do: {name, raw}),
      invalid_documents: for({name, {:error, why}} <- read, into: %{}, do: {name, why})
    }
  end

  # The name first, so a file that could never be recorded is not read at all.
  defp read_output(out, name, owner) do
    case Workflow.document_name_error(name) do
      nil -> read_text(Path.join(out, name), owner)
      reason -> {:error, reason}
    end
  end

  # Everything in `out/proposals/`, readable or not. A proposal the platform cannot use is
  # reported with its reason rather than skipped: it is a person's to look at, and dropping it
  # silently is the failure this whole path exists to avoid.
  defp collect_proposals(dir, owner) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory}} ->
        dir
        |> list_dir()
        |> Enum.sort()
        |> Map.new(fn file -> {file, read_proposal(Path.join(dir, file), owner)} end)

      # Not there: a job that proposed nothing, the ordinary case.
      {:error, _reason} ->
        %{}

      # Anything else — a regular file called `proposals`, or a symlink standing in for the
      # directory — is reported rather than mistaken for one, and never listed.
      {:ok, %File.Stat{type: type}} ->
        reason = unusable("proposals must be a directory, not a #{describe(type)}", nil)
        %{Workflow.proposals_dir() => {:error, reason}}
    end
  end

  defp describe(:regular), do: "file"
  defp describe(type), do: to_string(type)

  # A proposal the platform cannot use comes back with **the text as well as the reason**, so
  # the platform can keep what the agent wrote rather than only what was wrong with it. Dropping
  # the text is the drop `docs/design/ticket-proposals.md` § Malformed degrades, never drops
  # exists to forbid, and reporting a filename and an error message is not keeping it.
  #
  # `raw` is nil where there is no text to keep — a symlink, a directory, an unreadable file,
  # bytes that are not text.
  defp read_proposal(path, owner) do
    case read_text(path, owner) do
      {:ok, raw} ->
        case Proposal.parse(raw) do
          {:ok, proposal} -> {:ok, proposal}
          {:error, errors} -> {:error, unusable(ForgeCore.Error.format(errors), raw)}
        end

      {:error, reason} ->
        {:error, unusable("a proposal " <> reason, nil)}
    end
  end

  defp unusable(reason, raw), do: %{"reason" => reason, "raw" => raw}

  defp read_document(path, owner) do
    case read_text(path, owner) do
      {:ok, raw} -> Document.parse(raw)
      {:error, reason} -> {:error, [ForgeCore.Error.new("", "output " <> reason)]}
    end
  end

  # Every reader of `out/` reads through this, so what an agent may leave there is one rule.
  #
  # **What is read is decided by the file actually opened, not by a path.** The agent owns the
  # job directory, so every name under it is the agent's to rearrange — `out` itself can be a
  # symlink to `/etc`, and `lstat` of `out/<name>` checks only the last component, following
  # every one before it. And this process is the worker manager, a more privileged Unix user than
  # the transient one the agent runs as: whatever it reads through a path the agent arranged is
  # a file the agent could not read itself, published as an artifact. A check on the path and a
  # read of the path are also two steps, and a conversation's agent is alive between them.
  #
  # So the file is opened once, and the *handle's* own stat decides: a regular file, owned by the
  # owner of the job directory — the job's own Unix user, fresh per job, which owns nothing
  # outside it — and no larger than a document is. A symlink to someone else's file, a
  # directory swapped in for `out`, a file swapped in between the check and the read: each opens
  # something the job's user does not own, and is refused. The same model as the read, because
  # it is the read. (A hard link to another user's file is the one shape this could not tell
  # apart, and `fs.protected_hardlinks` — on by default — refuses to make one.)
  #
  # The `lstat` in front is not the guard. It keeps a FIFO from being opened at all, which would
  # block this process until something wrote to it, and it names a symlink as a symlink.
  #
  # And only text (`ForgeCore.Document.text?/1`). Bytes that are not UTF-8 cannot be encoded
  # into the JSON the result or the turn travels in, so one file of them failed the whole message
  # — every other document, the outcome, the cost — and a NUL fails the transaction that stores
  # it the same way on the platform.
  defp read_text(path, owner) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, io} <- :file.open(path, [:read, :binary, :raw]) do
      try do
        read_open(io, owner)
      after
        :file.close(io)
      end
    else
      {:ok, %File.Stat{type: type}} -> {:error, "must be a regular file, got #{type}"}
      {:error, reason} -> {:error, "unreadable: #{inspect(reason)}"}
    end
  end

  # `type: :regular` on the handle is out of a test's reach: only something swapped in between
  # the lstat above and the open gets here as anything else, and of those a directory is already
  # refused by the open (`:eisdir`) and a FIFO blocks inside it. What it still stops is a device
  # node the job's user owns, made in that gap.
  defp read_open(io, owner) do
    with {:ok, info} <- :file.read_file_info(io),
         %File.Stat{type: :regular, uid: ^owner} <- File.Stat.from_record(info),
         {:ok, raw} <- read_capped(io) do
      case Document.text_error(raw) do
        nil -> {:ok, raw}
        reason -> {:error, reason}
      end
    else
      %File.Stat{type: :regular, uid: uid} ->
        {:error, "must be the job's own file, not one owned by uid #{uid}"}

      %File.Stat{type: type} ->
        {:error, "must be a regular file, got #{type}"}

      {:error, reason} ->
        {:error, "unreadable: #{inspect(reason)}"}
    end
  end

  # One byte past the cap and no further: enough for `Document.text_error/1` to see that the file
  # is too large without reading all of a file that may still be growing.
  defp read_capped(io) do
    case :file.read(io, Document.max_bytes() + 1) do
      :eof -> {:ok, ""}
      result -> result
    end
  end

  # Who the job is: the owner of its directory. The directory's parent is the worker's, so the
  # agent can replace what is inside the job directory but not the directory itself. The `nil`
  # for a missing directory is an equivalent mutant: nothing under it can be listed either, so no
  # file is ever compared with it.
  defp owner(job_dir) do
    case File.lstat(job_dir) do
      {:ok, %File.Stat{uid: uid}} -> uid
      {:error, _reason} -> nil
    end
  end

  # A directory's entries, if it is one, and not through a symlink standing in for it, whose
  # listing would be a way to learn the names in a directory the agent cannot read. **Not
  # airtight:** the check and the listing are two calls by path, and an agent swapping `out` for
  # a link between them is listed through it — Erlang cannot list a directory it holds open. What
  # that leaks is names, reported as refused entries: every file is read through a handle whose
  # owner is checked (`read_open/2`), so no content crosses.
  defp list_dir(dir) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(dir),
         {:ok, names} <- File.ls(dir) do
      names
    else
      _not_a_directory -> []
    end
  end

  @spec prompt_path(String.t()) :: String.t()
  def prompt_path(job_dir), do: Path.join(job_dir, "prompt.md")

  @doc """
  The worker's own directory for a job, beside the job directory rather than inside it: what the
  worker writes and later reads back or uploads — a run's transcript, a command's log, the groups
  of files staged for upload, the logs fetched for a resume.

  **Not inside the job directory, because the job's Unix user owns that** and can replace any
  name in it with a link. This process runs as a more privileged user, so a transcript uploaded
  from `<job_dir>/transcript-1.jsonl` could be `/etc/forge-worker.env` by the time it is read —
  the threat `read_text/2` answers for `out/`, arriving by a file the worker wrote itself. Here
  the job cannot reach at all: the parent is the worker's, and this is made mode 0700.

  Swept with the job directories (`sweep/2`), which is also what collects a stage the link never
  uploaded because the job failed between the two.
  """
  @spec worker_dir(String.t()) :: String.t()
  def worker_dir(job_dir), do: job_dir <> ".worker"

  @doc "`worker_dir/1`, made if it is not there yet and closed to every other user."
  @spec worker_dir!(String.t()) :: String.t()
  def worker_dir!(job_dir) do
    dir = worker_dir(job_dir)
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    dir
  end

  @doc "Where a run's groups of files are staged for upload (`ForgeWorker.Job.Blobs`)."
  @spec blobs_dir(String.t()) :: String.t()
  def blobs_dir(job_dir), do: Path.join(worker_dir(job_dir), "blobs")

  @doc "Where the logs a resume is handed are fetched to, before `prepare/3` copies them in."
  @spec fetched_dir(String.t()) :: String.t()
  def fetched_dir(job_dir), do: Path.join(worker_dir(job_dir), "fetched")

  @doc "A fresh transcript path for this run: `transcript-1.jsonl`, `transcript-2.jsonl`, ..."
  @spec new_transcript_path(String.t()) :: String.t()
  def new_transcript_path(job_dir) do
    dir = worker_dir!(job_dir)
    run = dir |> File.ls!() |> Enum.count(&String.starts_with?(&1, "transcript-"))
    Path.join(dir, "transcript-#{run + 1}.jsonl")
  end

  @spec stderr_path(String.t()) :: String.t()
  def stderr_path(job_dir), do: Path.join(job_dir, "stderr.log")
end
