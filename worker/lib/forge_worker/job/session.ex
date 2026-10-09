defmodule ForgeWorker.Job.Session do
  @moduledoc """
  The harness session a resume needs, carried between machines
  (`docs/design/claude-code-events.md` § Resume).

  `--resume` finds a session by a file in the harness's `HOME`, which is the job's and lives on the
  machine that ran it. So after a run the worker uploads that file under the job's own key, and
  before a resume it puts the one the assignment names back — checked first, because a file that
  is not the session's own is not refused by the harness, it starts a session with no memory
  (`docs/measurements.md` § Session resume). A check that fails drops the resume: the run is a
  cold start with the full prompt, which is what the runner composes when it is not asked to
  resume, so the prompt and the flag still come from one value.

  Used by a workflow job's run (`ForgeWorker.Link`), which uploads when the run ends, and by a
  conversation, which uploads after every turn and not when it stops: it may stop because its
  machine did, with nothing left to upload anything.
  """

  alias ForgeWorker.{Config, Log, Store}
  alias ForgeWorker.Job.Dir

  @doc """
  What a run should do with the session the assignment names, as `{harness_opts, session}`:
  the options with the resume left in or dropped, and what `ForgeWorker.Job.Dir.prepare/3` is to
  put back — `%{id, source, cwd}` — or nil.

  - No session named: the options as they are, and nothing to restore. A resume then finds
    whatever the machine holds, which is the case before sessions were carried.
  - Named, and it will not download: the same for a job, and a line saying so. A conversation
    starts cold instead, since nothing re-queues it.
  - Downloaded, and written by another version of the CLI, or not the session's own: the resume
    is dropped — a cold start — and a line says why.
  - Otherwise: restored, and resumed.
  """
  @spec restore(map(), String.t(), String.t(), keyword(), module()) ::
          {keyword(), map() | nil}
  def restore(assignment, job_dir, worktree, harness_opts, harness) do
    case assignment["session"] do
      %{"key" => key, "token" => token, "id" => id} = session ->
        # In the worker's own directory, which the job's user cannot reach.
        Dir.worker_dir!(job_dir)
        File.rm_rf!(Dir.session_dir(job_dir))
        File.mkdir_p!(Dir.session_dir(job_dir))
        path = Path.join(Dir.session_dir(job_dir), "restore.jsonl")

        case Store.fetch(Config.platform_url(), key, token, path) do
          :ok -> check(path, id, session["version"], worktree, harness_opts, harness, assignment)
          {:error, reason} -> unfetched(reason, harness_opts, assignment)
        end

      _none ->
        {harness_opts, nil}
    end
  end

  defp check(path, id, version, worktree, harness_opts, harness, assignment) do
    local = harness.probe(harness_opts).version

    cond do
      is_nil(version) or version != local ->
        cold(
          harness_opts,
          assignment,
          "it was written by #{version || "?"} and this machine runs #{local || "?"}"
        )

      not Dir.session_file?(path, id) ->
        cold(harness_opts, assignment, "the file is not session #{id}'s own")

      true ->
        {harness_opts, %{id: id, source: path, cwd: worktree}}
    end
  end

  # Dropping `:fork_session` with the resume is an equivalent mutant: the driver and the runner
  # read it only beside `:resume_session`, and without one there is nothing to fork. Dropped so
  # the options say what the run is.
  defp cold(harness_opts, assignment, why) do
    Log.line("session.unrestored", :warning, "starting cold rather than resuming: #{why}",
      job_id: assignment["job_id"]
    )

    {Keyword.drop(harness_opts, [:resume_session, :fork_session]), nil}
  end

  # A job's resume that finds nothing is re-queued cold by the platform, so it is left to find
  # what the machine holds. A conversation's is not re-queued — it has a person in it — so it
  # starts cold here, with the replay its spec carries for exactly this.
  defp unfetched(reason, harness_opts, %{"kind" => "chat"} = assignment),
    do: cold(harness_opts, assignment, "could not fetch the session: #{inspect(reason)}")

  defp unfetched(reason, harness_opts, assignment) do
    Log.line(
      "session.unrestored",
      :warning,
      "could not fetch the session, so the resume finds what this machine holds: #{inspect(reason)}",
      job_id: assignment["job_id"]
    )

    {harness_opts, nil}
  end

  @doc """
  Uploads session `session_id` from the job's `HOME` as the `n`th upload of this assignment, and
  returns its key, or nil when there is none to upload or nowhere to put it. Never fails the run:
  a session that did not leave the machine costs a later resume its warmth and nothing else.
  """
  @spec upload(String.t(), String.t() | nil, map(), pos_integer()) :: String.t() | nil
  def upload(_job_dir, nil, _assignment, _n), do: nil

  def upload(job_dir, session_id, assignment, n) do
    store = assignment["store"] || %{}
    Dir.worker_dir!(job_dir)
    staged = Path.join(Dir.session_dir(job_dir), "upload-#{n}.jsonl")

    with prefix when is_binary(prefix) <- store["session_prefix"],
         url when is_binary(url) <- Config.platform_url(),
         :ok <- Dir.stage_session(job_dir, session_id, staged),
         # The staged copy, and not the session the harness resumes from on this machine: what
         # leaves is masked (`docs/design/secrets.md` § Masking), what stays is the agent's own.
         :ok <-
           ForgeWorker.Job.Secrets.mask_file(
             ForgeWorker.Job.Secrets.from_assignment(assignment),
             staged
           ),
         key = prefix <> "#{n}.jsonl",
         {:ok, _info} <- Store.put(url, key, store["session_token"], staged) do
      File.rm(staged)
      key
    else
      nil ->
        nil

      {:error, reason} ->
        Log.line(
          "upload.failed",
          :warning,
          "the session did not leave the machine: #{inspect(reason)}",
          job_id: assignment["job_id"]
        )

        File.rm(staged)
        nil
    end
  end
end
