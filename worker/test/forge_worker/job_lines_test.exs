defmodule ForgeWorker.JobLinesTest.RefusingSlice do
  @moduledoc "A slice that cannot be made."

  @behaviour ForgeWorker.Slice

  @impl ForgeWorker.Slice
  def prepare(_opts), do: {:error, :no_such_user}

  @impl ForgeWorker.Slice
  def wrap(executable, args, _context), do: {executable, args}

  @impl ForgeWorker.Slice
  def cleanup(_context), do: :ok

  @impl ForgeWorker.Slice
  defdelegate enter(job_id), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate own(owner, paths), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate run_as(owner, executable, args), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate leave(owner, paths), to: ForgeWorker.Slice.Direct
end

defmodule ForgeWorker.JobLinesTest.StuckVolume do
  @moduledoc "A volume that will not go: a subvolume still mounted, a file still held open."

  def delete(_path), do: {:error, :busy}
end

defmodule ForgeWorker.JobLinesTest do
  @moduledoc """
  What the worker could not do for a job is a line in the machine's log, tied to the job
  (`docs/design/worker-log.md` § What goes in, and what does not). Each of these was a journal
  line and nothing else, on a machine nobody can read — which is how a conversation whose every
  turn failed to commit looked, from the platform, like one with nothing to commit.

  The ones only a running link can reach are in `ForgeWorker.LinkTest` § the machine's log.

  Not async: the test stands in for the link by taking its registered name.
  """

  use ExUnit.Case, async: false

  import ForgeWorker.Fixtures

  alias ForgeCore.Job.{Result, Spec}
  alias ForgeWorker.Job.{Blobs, Command, Conversation, Credential, Dir, Runner, Workspace}
  alias ForgeWorker.JobLinesTest.{RefusingSlice, StuckVolume}
  alias ForgeWorker.Slice.Systemd

  @direct {ForgeWorker.Slice.Direct, %{kind: :direct}}

  setup do
    # Released with the test's process, as the link's own name is with the link's.
    Process.register(self(), ForgeWorker.Link)
    %{root: tmp_dir("root"), job_id: uuid()}
  end

  # The line about `job_id` of `type`, and nothing about any other job in between.
  defp line(type, job_id) do
    assert_receive {:log, %{"type" => ^type, "job_id" => ^job_id} = entry}, 5_000
    entry
  end

  describe "what a job is handed" do
    test "a backlog entry that leaves its folder is refused, and says so", context do
      spec = %{spec() | job_id: context.job_id}
      backlog = %{"index" => "", "tickets" => [%{"file" => "../escaped.md", "content" => "x"}]}

      Dir.prepare(context.root, spec, backlog: backlog)

      entry = line("backlog.unwritten", context.job_id)
      assert entry["level"] == "warning"
      assert entry["message"] =~ ~s("../escaped.md")
      assert entry["message"] =~ "leaves the folder"
    end

    test "a backlog entry with no name is refused, and says so", context do
      spec = %{spec() | job_id: context.job_id}
      backlog = %{"index" => "", "proposals" => [%{"content" => "a proposal with no file"}]}

      Dir.prepare(context.root, spec, backlog: backlog)

      assert line("backlog.unwritten", context.job_id)["message"] =~ "no file name"
    end

    test "a backlog that will not be laid out at all says why", context do
      spec = %{spec() | job_id: context.job_id}

      Dir.prepare(context.root, spec, backlog: %{"tickets" => "not a list"})

      assert line("backlog.unwritten", context.job_id)["message"] =~
               "could not write the backlog"
    end

    test "a command's log with a name that is not one is left out, and says so", context do
      spec = %{spec() | job_id: context.job_id}
      source = Path.join(tmp_dir("fetched"), "log")
      File.write!(source, "built\n")

      Dir.prepare(context.root, spec, command_logs: [{"../1-build.log", source}])

      entry = line("commands.unwritten", context.job_id)
      assert entry["message"] =~ ~s("../1-build.log")
    end
  end

  describe "the worktree" do
    setup do
      origin = Path.join(tmp_dir("origin"), "project.git")
      work = tmp_dir("work")
      git!(nil, ["init", "--bare", "--quiet", origin])
      git!(nil, ["clone", "--quiet", origin, work])
      git!(work, ["config", "user.name", "seed"])
      git!(work, ["config", "user.email", "seed@forge"])
      File.write!(Path.join(work, "README.md"), "# Game\n")
      git!(work, ["add", "."])
      git!(work, ["commit", "--quiet", "-m", "seed"])
      git!(work, ["push", "--quiet", "origin", "HEAD:refs/heads/ticket/1"])

      on_exit(fn -> Application.delete_env(:forge_worker, :volume) end)
      %{origin: origin}
    end

    defp assignment(origin, job_id) do
      %{
        "job_id" => job_id,
        "spec" => %{"state" => "planning", "attempt" => 1},
        "git" => %{"url" => origin, "branch" => "ticket/1", "base" => nil}
      }
    end

    test "a ticket volume that will not become the worktree starts it colder, and says so",
         context do
      job = assignment(context.origin, context.job_id)
      template = Workspace.template(job, context.root)
      File.mkdir_p!(template)
      File.write!(Path.join(template, "junk.txt"), "not a checkout\n")

      assert {:ok, _dir} = Workspace.prepare(job, context.root, @direct)

      entry = line("volume.unused", context.job_id)
      assert entry["message"] =~ "could not use the ticket volume"
      assert entry["message"] =~ "starts colder"
    end

    test "a worktree that will not become the ticket's template says so", context do
      job = assignment(context.origin, context.job_id)

      assert :ok = Workspace.promote(job, context.root, Path.join(context.root, "no-such-tree"))

      assert line("volume.unkept", context.job_id)["message"] =~ "next job starts colder"
    end

    test "a worktree that will not go says so", context do
      job = assignment(context.origin, context.job_id)
      Application.put_env(:forge_worker, :volume, StuckVolume)

      assert :ok = Workspace.discard(job, context.root)

      assert line("worktree.undeleted", context.job_id)["message"] =~ ":busy"
    end

    defp git!(dir, args) do
      args = if dir, do: ["-C", dir | args], else: args
      {out, 0} = System.cmd("git", args, stderr_to_stdout: true)
      out
    end
  end

  describe "the process" do
    test "a job that cannot be confined is an error line with why", context do
      spec = %{spec() | job_id: context.job_id}

      {:ok, pid} =
        Runner.start_link(
          spec: spec,
          root: context.root,
          worktree: tmp_dir("worktree"),
          harness_opts: [executable: fake_executable()],
          slice: RefusingSlice
        )

      assert {:ok, %Result{outcome: :error}} = Runner.await(pid, 5_000)

      entry = line("slice.failed", context.job_id)
      assert entry["level"] == "error"
      assert entry["message"] =~ ":no_such_user"
    end

    test "a command that cannot be confined is an error line with why", context do
      spec = %Spec{
        job_id: context.job_id,
        kind: :command,
        branch: "ticket/7",
        commit: String.duplicate("a", 40),
        command: %{
          "name" => "build",
          "args" => [],
          "script" => "#!/bin/sh\necho ran\n",
          "at" => String.duplicate("b", 40),
          "timeout_ms" => 10_000
        }
      }

      {:ok, pid} =
        Command.start_link(
          spec: spec,
          root: context.root,
          worktree: tmp_dir("worktree"),
          slice: RefusingSlice
        )

      assert {:ok, %Result{outcome: :error}} = Command.await(pid, 5_000)

      entry = line("slice.failed", context.job_id)
      assert entry["level"] == "error"
      assert entry["message"] =~ ":no_such_user"
    end

    # A sink that fails once fails for every event after it: one line, not one per event.
    test "an event it could not hand on is said once per run", context do
      spec = %{spec() | job_id: context.job_id}

      {:ok, pid} =
        Runner.start_link(
          spec: spec,
          root: context.root,
          worktree: tmp_dir("worktree"),
          sink: fn _event -> raise "the link is not there" end,
          harness_opts: [executable: fake_executable()],
          extra_env: [{"FAKE_SCENARIO", "success"}]
        )

      assert {:ok, %Result{}} = Runner.await(pid, 5_000)

      assert line("event.dropped", context.job_id)["message"] =~ "the link is not there"
      job_id = context.job_id
      refute_receive {:log, %{"type" => "event.dropped", "job_id" => ^job_id}}, 200
    end

    # Not a user this machine can make or unmake here, so both halves of cleaning up fail —
    # which is what the test needs, and what a real machine says when they do.
    #
    # Both failures are forced rather than hoped for, so the test says the same run as root or
    # not: a path that is not there will not chown, and a name `userdel` reads as an option it
    # refuses before it asks about privileges.
    test "a job's files not taken back, and its user not removed, say so", context do
      owner = %{job_id: context.job_id, kind: :systemd, user: "--not-a-user", gid: "0"}
      paths = [Path.join(context.root, "nothing-here")]

      ExUnit.CaptureLog.capture_log(fn -> assert Systemd.leave(owner, paths) == :ok end)

      assert line("slice.uncleaned", context.job_id)["message"] =~ "files back"
      assert line("slice.uncleaned", context.job_id)["message"] =~ "could not remove"
    end

    test "a credential that will not open is an error line, and no secret", context do
      token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      Application.put_env(:forge_worker, :token, token)
      on_exit(fn -> Application.delete_env(:forge_worker, :token) end)
      {:ok, hash} = ForgeCore.Job.Credential.token_hash(token)

      # Sealed for another job, which is what a credential replayed into this one looks like.
      assignment = %{
        "job_id" => context.job_id,
        "credential" => %{
          "harness" => "claude_code",
          "kind" => "oauth",
          "sealed" => ForgeCore.Job.Credential.seal("sk-ant-oat01-never", hash, uuid())
        }
      }

      opts = Credential.put([], assignment, "claude_code")
      assert Keyword.fetch!(opts, :credential).() == nil

      entry = line("credential.unopened", context.job_id)
      assert entry["level"] == "error"
      refute entry["message"] =~ "sk-ant"
    end

    # The harness gone before the conversation heard it go: the message is written into a
    # closed pipe. A runner that answers as that one does stands in for it.
    test "a message the harness would not take says so", context do
      runner =
        spawn_link(fn ->
          receive do
            {:"$gen_call", from, {:send_message, _text}} ->
              GenServer.reply(from, {:error, :closed})
          end
        end)

      state = %{runner: runner, job_id: context.job_id, pending: []}

      assert {:noreply, ^state} =
               Conversation.handle_cast({:message, "m-1", "hello"}, state)

      assert line("chat.undelivered", context.job_id)["message"] =~ ":closed"
    end
  end

  describe "the store" do
    setup do
      Application.put_env(:forge_worker, :platform_url, "http://platform.test")

      Application.put_env(:forge_worker, :req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 507, "the store is full") end,
        retry: false
      )

      on_exit(fn ->
        Application.delete_env(:forge_worker, :req_options)
        Application.delete_env(:forge_worker, :platform_url)
      end)
    end

    test "a file of a group that will not upload says so", context do
      staging = tmp_dir("staging")
      path = Path.join(staging, "app.bin")
      File.write!(path, "built")

      result = %Result{status: :finished, blobs: %{"pkg/app.bin" => %{"path" => path}}}

      assignment = %{
        "job_id" => context.job_id,
        "outputs" => %{"prefix" => "job/j1/out-abc/", "token" => "prefix-token"}
      }

      result = Blobs.upload(result, assignment, staging)
      assert Map.has_key?(result.invalid_blobs, "pkg/app.bin")

      entry = line("upload.failed", context.job_id)
      assert entry["message"] =~ "job/j1/out-abc/1"
      assert entry["message"] =~ "507"
    end
  end
end
