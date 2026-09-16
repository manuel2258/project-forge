defmodule ForgeWorker.Job.Dir do
  @moduledoc """
  The job directory: the agent's whole interface to the platform, as files.
  See `docs/design/job-prompt.md`.

      <root>/<job_id>/spec.json
      <root>/<job_id>/prompt.md
      <root>/<job_id>/inputs/<name>
      <root>/<job_id>/tickets/index.md     the project's tickets and open proposals
      <root>/<job_id>/tickets/<number>.md  one ticket's body
      <root>/<job_id>/out/<name>
      <root>/<job_id>/out/proposals/<file> ticket proposals, written by the agent
      <root>/<job_id>/home                 HOME for the harness process
      <root>/<job_id>/transcript-<run>.jsonl
      <root>/<job_id>/stderr.log
  """

  alias ForgeCore.{Document, Proposal, Workflow}
  alias ForgeCore.Job.Spec

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
  """
  @spec prepare(String.t(), Spec.t(), keyword()) :: String.t()
  def prepare(root, %Spec{job_id: job_id} = spec, opts \\ []) do
    unless Regex.match?(@uuid, job_id) do
      raise ArgumentError, "job id must be a UUID, got #{inspect(job_id)}"
    end

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
    write_backlog(job_dir, Keyword.get(opts, :backlog))

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

  # The project's tickets and open proposals, laid out as a folder rather than put in the prompt.
  # An unread file costs nothing, which is the whole argument for handing every job the backlog:
  # tokens are the scarce thing here, not disk. See `docs/design/ticket-proposals.md`
  # § Reading the backlog.
  #
  # Rewritten whole each time. A stale file from an earlier composition would be a ticket the
  # agent believes still exists, which is worse than not having the folder at all.
  defp write_backlog(job_dir, nil), do: File.rm_rf!(backlog_dir(job_dir))

  defp write_backlog(job_dir, backlog) when is_map(backlog) do
    dir = backlog_dir(job_dir)
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    write_readonly(Path.join(dir, "index.md"), backlog["index"] || "")

    Enum.each(backlog["tickets"] || [], &write_backlog_entry(dir, &1))

    case backlog["proposals"] || [] do
      [] ->
        :ok

      proposals ->
        nested = Path.join(dir, Workflow.proposals_dir())
        File.mkdir_p!(nested)
        Enum.each(proposals, &write_backlog_entry(nested, &1))
    end
  rescue
    # The backlog is context, and context is never worth the job. `prepare/3` is called from
    # `Runner.init/1`, so anything that raises here is a job that never starts — and because the
    # backlog is recomposed identically on every assignment, it would be a job that never starts
    # again either. A name the platform should not have sent is a line in the log, not an outage.
    error ->
      Logger.warning("could not write the backlog: #{Exception.message(error)}")
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
  defp write_backlog_entry(dir, %{"file" => file, "content" => content}) when is_binary(file) do
    base = Path.expand(dir)
    path = Path.expand(Path.join(base, file))

    if Path.dirname(path) == base do
      write_readonly(path, content || "")
    else
      Logger.warning("backlog: refusing #{inspect(file)}, which leaves the folder")
    end
  end

  defp write_backlog_entry(_dir, entry) do
    Logger.warning("backlog: refusing an entry with no file name: #{inspect(entry)}")
  end

  defp write_readonly(path, content) do
    File.write!(path, content)
    File.chmod!(path, 0o444)
  end

  @doc """
  Removes job directories under `root` that nothing has touched for `older_than_ms`, and says
  how many went.

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
  def collect(job_dir, %Spec{} = spec) do
    out = Path.join(job_dir, "out")
    declared = Spec.document_outputs(spec)
    reserved = Workflow.proposals_dir()
    written = out |> File.ls!() |> Enum.sort()

    parsed =
      declared
      |> Enum.filter(&(&1 in written))
      |> Map.new(fn name -> {name, read_document(Path.join(out, name))} end)

    proposals = collect_proposals(Path.join(out, reserved))

    %{
      documents: for({name, {:ok, doc}} <- parsed, into: %{}, do: {name, doc}),
      invalid: for({name, {:error, errors}} <- parsed, into: %{}, do: {name, errors}),
      missing: declared -- written,
      undeclared: (written -- declared) -- [reserved],
      proposals: for({name, {:ok, p}} <- proposals, into: %{}, do: {name, p}),
      invalid_proposals: for({name, {:error, why}} <- proposals, into: %{}, do: {name, why})
    }
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
  def proposals(job_dir) do
    collected = collect_proposals(Path.join([job_dir, "out", Workflow.proposals_dir()]))

    %{
      proposals: for({name, {:ok, p}} <- collected, into: %{}, do: {name, p}),
      invalid_proposals: for({name, {:error, why}} <- collected, into: %{}, do: {name, why})
    }
  end

  # Everything in `out/proposals/`, readable or not. A proposal the platform cannot use is
  # reported with its reason rather than skipped: it is a person's to look at, and dropping it
  # silently is the failure this whole path exists to avoid.
  defp collect_proposals(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        Map.new(Enum.sort(files), fn file -> {file, read_proposal(Path.join(dir, file))} end)

      # Not a directory, or not there. A job that proposed nothing is the ordinary case, and a
      # regular file called `proposals` is reported rather than mistaken for one.
      {:error, :enotdir} ->
        reason = unusable("proposals must be a directory, not a file", nil)
        %{Workflow.proposals_dir() => {:error, reason}}

      {:error, _reason} ->
        %{}
    end
  end

  # A proposal the platform cannot use comes back with **the text as well as the reason**, so
  # the platform can keep what the agent wrote rather than only what was wrong with it. Dropping
  # the text is the drop `docs/design/ticket-proposals.md` § Malformed degrades, never drops
  # exists to forbid, and reporting a filename and an error message is not keeping it.
  #
  # `raw` is nil where there is no text to keep — a symlink, a directory, an unreadable file.
  defp read_proposal(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        raw = File.read!(path)

        case Proposal.parse(raw) do
          {:ok, proposal} -> {:ok, proposal}
          {:error, errors} -> {:error, unusable(ForgeCore.Error.format(errors), raw)}
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, unusable("a proposal must be a regular file, got #{type}", nil)}

      {:error, reason} ->
        {:error, unusable("unreadable: #{inspect(reason)}", nil)}
    end
  end

  defp unusable(reason, raw), do: %{"reason" => reason, "raw" => raw}

  # Only regular files count, and `lstat` rather than `stat` because a symlink is not one.
  #
  # `stat` follows the link, so a symlink the agent plants in `out/` has *this* process read the
  # target — and this process is the worker manager, a different and more privileged Unix user
  # than the transient one the agent runs as. `ln -s /root/.ssh/id_ed25519 out/plan.md` would
  # publish a key the agent itself cannot read into an artifact. `lstat` reports the link as
  # `:symlink`, which is not `:regular`, so it is refused with everything else that is not a
  # file. Fixed in both readers rather than only in the one that exposed it, per CLAUDE.md.
  defp read_document(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        path |> File.read!() |> Document.parse()

      {:ok, %File.Stat{type: type}} ->
        {:error, [ForgeCore.Error.new("", "output must be a regular file, got #{type}")]}

      {:error, reason} ->
        {:error, [ForgeCore.Error.new("", "output unreadable: #{inspect(reason)}")]}
    end
  end

  @spec prompt_path(String.t()) :: String.t()
  def prompt_path(job_dir), do: Path.join(job_dir, "prompt.md")

  @doc "A fresh transcript path for this run: `transcript-1.jsonl`, `transcript-2.jsonl`, ..."
  @spec new_transcript_path(String.t()) :: String.t()
  def new_transcript_path(job_dir) do
    run = job_dir |> File.ls!() |> Enum.count(&String.starts_with?(&1, "transcript-"))
    Path.join(job_dir, "transcript-#{run + 1}.jsonl")
  end

  @spec stderr_path(String.t()) :: String.t()
  def stderr_path(job_dir), do: Path.join(job_dir, "stderr.log")
end
