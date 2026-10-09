defmodule ForgeWorker.Job.ExecTest do
  @moduledoc """
  The worker's allowlist against the names a project secret may not take
  (`docs/design/secrets.md` § Names). Two lists kept by hand in two projects: this is what keeps
  a variable added to the allowlist from becoming one a secret could set over it.

  And the one route a secret takes into a process: a file only root can read, loaded by the
  process itself (`docs/design/secrets.md` § Delivery).
  """

  use ExUnit.Case, async: true

  alias ForgeWorker.Job.Exec

  test "no project secret can take a name the worker passes to a job" do
    for name <- Exec.inherited() do
      assert ForgeCore.Secret.validate_name(name) != :ok, name
    end
  end

  describe "the secrets file" do
    setup do
      dir = Path.join(System.tmp_dir!(), "exec-#{System.unique_integer([:positive])}")
      job_dir = Path.join(dir, "job")
      File.mkdir_p!(job_dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{job_dir: job_dir}
    end

    # Every byte as it was given — a quote, a `$`, a backslash, a newline — because the process
    # reads it back through a shell.
    test "is loaded into the process's environment exactly, and is nowhere in its argv", %{
      job_dir: job_dir
    } do
      value = ~s(it's "$HOME" \\ `id`\n-----END KEY-----)
      path = Exec.write_secrets(job_dir, [{"KEY_A", value}, {"KEY_B", "plain-value"}])

      {executable, args} = Exec.load_secrets("printenv", ["KEY_A"], path)
      refute Enum.any?([executable | args], &(&1 =~ "plain-value" or &1 == value))

      assert {out, 0} = System.cmd(executable, args, env: [{"CREDENTIALS_DIRECTORY", nil}])
      assert out == value <> "\n"

      {executable, args} = Exec.load_secrets("printenv", ["KEY_B"], path)

      assert {"plain-value\n", 0} =
               System.cmd(executable, args, env: [{"CREDENTIALS_DIRECTORY", nil}])
    end

    # Inside a unit the file the worker wrote is root's, and the copy systemd made is the one the
    # job's user can read: `$CREDENTIALS_DIRECTORY` is where it is, and it wins.
    test "is read from the unit's credentials where there are any", %{job_dir: job_dir} do
      path = Exec.write_secrets(job_dir, [{"KEY_A", "from-the-worker"}])
      credentials = Path.join(job_dir, "credentials")
      File.mkdir_p!(credentials)

      File.write!(
        Path.join(credentials, Exec.secrets_credential()),
        "KEY_A='from-the-unit'\n"
      )

      {executable, args} = Exec.load_secrets("printenv", ["KEY_A"], path)

      assert {"from-the-unit\n", 0} =
               System.cmd(executable, args, env: [{"CREDENTIALS_DIRECTORY", credentials}])
    end

    test "that cannot be read stops the process before it runs", %{job_dir: job_dir} do
      {executable, args} =
        Exec.load_secrets("touch", [Path.join(job_dir, "ran")], Path.join(job_dir, "absent"))

      assert {_out, status} =
               System.cmd(executable, args,
                 env: [{"CREDENTIALS_DIRECTORY", nil}],
                 stderr_to_stdout: true
               )

      assert status != 0
      refute File.exists?(Path.join(job_dir, "ran"))
    end

    test "is in the worker's own directory, closed to everyone else, and goes when asked", %{
      job_dir: job_dir
    } do
      path = Exec.write_secrets(job_dir, [{"KEY_A", "value-a1"}])

      assert Path.dirname(path) == ForgeWorker.Job.Dir.worker_dir(job_dir)
      assert File.stat!(Path.dirname(path)).mode |> Bitwise.band(0o777) == 0o700
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600

      assert Exec.remove_secrets(job_dir) == :ok
      refute File.exists?(path)

      # None to write is none left behind from an earlier round.
      path = Exec.write_secrets(job_dir, [{"KEY_A", "value-a1"}])
      assert Exec.write_secrets(job_dir, []) == nil
      refute File.exists?(path)
    end

    test "with nothing in it, the process is started as it was" do
      assert Exec.load_secrets("claude", ["-p"], nil) == {"claude", ["-p"]}
    end
  end
end
