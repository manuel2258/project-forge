defmodule ForgeWorker.Fixtures do
  @moduledoc "Shared test data and directories for forge_worker."

  alias ForgeCore.Job.Spec
  alias ForgeCore.Job.Spec.Input

  @fake Path.expand("fake_claude.sh", __DIR__)

  def fake_executable, do: @fake

  @fake_codex Path.expand("fake_codex.sh", __DIR__)

  @doc """
  The stand-in for `codex app-server` (`test/support/fake_codex.sh`), **in a directory of its own
  with a `codex-code-mode-host` beside it**: a `codex` with no host is one the worker does not offer
  (`ForgeWorker.Harness.Codex.probe/1`), so a stand-in standing alone in `test/support/` would not
  be taken for Codex. Made once per test run and removed when it ends.
  """
  def fake_codex_executable do
    case :persistent_term.get({__MODULE__, :fake_codex}, nil) do
      nil ->
        path = stage_fake_codex(System.tmp_dir!(), host: true)
        System.at_exit(fn _status -> File.rm_rf(Path.dirname(Path.dirname(path))) end)
        :persistent_term.put({__MODULE__, :fake_codex}, path)
        path

      path ->
        path
    end
  end

  @doc """
  A copy of the stand-in under `parent`, in a directory of its own, and the path of the `codex` in
  it: `host: false` leaves the sidecar out, `host: mode` gives it that mode. The caller removes
  `parent`'s subdirectory (`Path.dirname(Path.dirname(path))`).
  """
  def stage_fake_codex(parent, opts) do
    dir =
      Path.join(parent, "fake-codex-#{System.unique_integer([:positive])}-#{System.os_time()}")

    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    File.cp!(@fake_codex, Path.join(bin, "codex"))
    File.chmod!(Path.join(bin, "codex"), 0o755)

    case Keyword.get(opts, :host, true) do
      false ->
        :ok

      host ->
        path = Path.join(bin, "codex-code-mode-host")
        File.write!(path, "#!/bin/sh\nexit 0\n")
        File.chmod!(path, if(is_integer(host), do: host, else: 0o755))
    end

    Path.join(bin, "codex")
  end

  def spec(overrides \\ %{}) do
    Map.merge(
      %Spec{
        job_id: uuid(),
        ticket: %{number: 7, title: "Persist the high score table", ticket_type: nil},
        state: "planning",
        attempt: 1,
        prompt: "Write a plan for the ticket.",
        prompt_path: "agents/plan.md",
        env: "implement",
        commit: String.duplicate("a", 40),
        branch: "ticket/7",
        budget: %{turns: 40, tokens: 400_000},
        preamble_hash: ForgeCore.Prompt.preamble_hash(),
        inputs: [
          %Input{name: "ticket", version: 1, content: "Scores vanish on restart."},
          %Input{
            name: "refinement.md",
            version: 2,
            content: "---\noutcome: done\n---\nRefined.\n"
          }
        ],
        produces: ["plan.md", "changeset"],
        outcomes: ["done", "plan_invalid"]
      },
      overrides
    )
  end

  @doc """
  `secrets` sealed for `job_id` the way the platform seals them (`Forge.Secrets.for_wire/3`): for
  this machine's token and the purpose `:secrets`. The token is the one configured, or a new one,
  removed again when the test exits.
  """
  def sealed_secrets(secrets, job_id) do
    %ForgeWorker.Job.Secrets{
      job_id: job_id,
      sealed:
        ForgeCore.Job.Credential.seal(Jason.encode!(secrets), token_hash(), job_id, :secrets)
    }
  end

  @doc "The digest of this machine's token, as the platform keeps it; sets a token for the test when there is none."
  def worker_token_hash, do: token_hash()

  defp token_hash do
    token =
      case Application.get_env(:forge_worker, :token) do
        token when is_binary(token) ->
          token

        nil ->
          token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
          Application.put_env(:forge_worker, :token, token)
          ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:forge_worker, :token) end)
          token
      end

    {:ok, hash} = ForgeCore.Job.Credential.token_hash(token)
    hash
  end

  @doc "A random UUID (the worker does not depend on Ecto)."
  def uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    [a, b, c, d, e]
    |> then(&:io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", &1))
    |> IO.iodata_to_binary()
  end

  @doc """
  A fresh temporary directory, removed when the test process exits — after whatever is still
  running in it has been killed (`reap/1`).

  Named by the OS process as well as `System.unique_integer/1`, which is unique only within one
  BEAM: suites run side by side from sibling worktrees share the system temp directory, and two
  of them made — and removed — each other's directories.
  """
  def tmp_dir(context) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "#{System.pid()}-forge-#{context}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    ExUnit.Callbacks.on_exit(fn ->
      reap(dir)
      File.rm_rf!(dir)
    end)

    dir
  end

  @doc """
  Kills every process of this machine that is working in `dir` — its current directory, or the
  `FORGE_JOB` its environment names, is `dir` or under it — and returns once none is left, or
  after about five seconds of trying.

  **Why a test that starts a job needs it.** A test that stops at the event it checks (the slice
  was prepared, the harness has started) leaves the job running: the runner dies with the test, but
  closing its port does not signal the harness, and a harness that is still writing into the
  directory while `File.rm_rf!` empties it makes `rm_rf!` fail with `eexist` — a directory it has
  just emptied is not empty by the time it removes it. The failure was in `on_exit`, in a test
  that asserted nothing about it, one run in several on a loaded machine. Waiting for the process
  to be gone is waiting for an event, not for time: it polls `/proc`, which says so at once.
  """
  def reap(dir) do
    case holders(dir) do
      [] ->
        :ok

      pids ->
        Enum.each(pids, fn pid -> System.cmd("kill", ["-KILL", pid], stderr_to_stdout: true) end)
        wait_gone(dir, 500)
    end
  end

  defp wait_gone(dir, attempts) do
    case {holders(dir), attempts} do
      {[], _} ->
        :ok

      {_pids, 0} ->
        :ok

      {pids, _} ->
        Enum.each(pids, fn pid -> System.cmd("kill", ["-KILL", pid], stderr_to_stdout: true) end)
        Process.sleep(10)
        wait_gone(dir, attempts - 1)
    end
  end

  # The OS pids (as strings) working under `dir`. A process that exits while this reads it, and a
  # zombie, whose links `/proc` no longer answers, are not holders.
  defp holders(dir) do
    case File.ls("/proc") do
      {:ok, entries} ->
        me = System.pid()

        for entry <- entries,
            entry =~ ~r/\A\d+\z/,
            entry != me,
            under?(File.read_link("/proc/#{entry}/cwd"), dir) or job_under?(entry, dir),
            do: entry

      {:error, _reason} ->
        []
    end
  end

  defp under?({:ok, path}, dir), do: path == dir or String.starts_with?(path, dir <> "/")
  defp under?(_other, _dir), do: false

  defp job_under?(entry, dir) do
    case File.read("/proc/#{entry}/environ") do
      {:ok, environ} ->
        environ
        |> String.split(<<0>>)
        |> Enum.any?(fn
          "FORGE_JOB=" <> job -> under?({:ok, job}, dir)
          _other -> false
        end)

      {:error, _reason} ->
        false
    end
  end
end
