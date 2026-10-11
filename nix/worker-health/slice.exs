# ForgeWorker.Slice.Systemd, driven from inside the worker image by the release the image carries,
# so what `nix/worker-health.nix` starts is what the worker would start — its flags, its stop
# step, its reading of what came back — and never a copy that could drift from it.
#
#     FJ_ACTION=<action> FJ_ID=<job id> [FJ_MEM=<bytes>] [FJ_FILE=<path>] [FJ_SECRET=<value>] \
#       forge_worker eval 'Code.eval_file("/root/worker-health/slice.exs")'
#
# setup      makes the job's user, gives it the worktree, prepares the slice (which writes the
#            unit's stop step), and prints `wrap/3`'s command, one argument per line; with
#            FJ_SECRET, the job is given it as FORGE_HEALTH_SECRET the way the runner gives a job
#            its secrets — the file, the unit's credential and the loader, all `Job.Exec`'s;
# paths      prints the job's paths as shell assignments;
# ended      prints `ended/2` for the job's stderr;
# memory     prints `memory/1`, the unit's cgroup as the worker samples it;
# bus_error  prints `bus_error/1` for the text of FJ_FILE;
# probe      prints `probe/0`'s answer and how long it took, in milliseconds;
# reboot     calls `ForgeWorker.Health.reboot/0`, which the worker calls when told to.
alias ForgeWorker.Job.{Dir, Exec}
alias ForgeWorker.Slice.Systemd

id = System.get_env("FJ_ID", "none")
root = "/var/lib/forge"
job_dir = Path.join([root, "jobs", id])
worktree = Path.join([root, "worktrees", id])

context = %{
  job_id: id,
  job_dir: job_dir,
  worktree: worktree,
  memory_max: String.to_integer(System.get_env("FJ_MEM", "536870912")),
  cpu_weight: 100,
  env: [{"PATH", "/run/current-system/sw/bin"}, {"HOME", "/nonexistent"}],
  secrets_file: nil,
  kind: :systemd,
  user: Systemd.user_name(id)
}

case System.fetch_env!("FJ_ACTION") do
  "setup" ->
    File.mkdir_p!(job_dir)
    File.mkdir_p!(worktree)
    {:ok, owner} = Systemd.enter(id)
    :ok = Systemd.own(owner, [worktree])

    secrets =
      case System.get_env("FJ_SECRET", "") do
        "" -> []
        value -> [{"FORGE_HEALTH_SECRET", value}]
      end

    secrets_file = Exec.write_secrets(job_dir, secrets)
    {:ok, context} = Systemd.prepare(%{context | secrets_file: secrets_file})
    {executable, args} = Exec.load_secrets("sh", [Path.join(worktree, "job.sh")], secrets_file)
    {executable, args} = Systemd.wrap(executable, args, context)
    IO.puts(Enum.join([executable | args], "\n"))

  "paths" ->
    IO.puts("worker_dir=#{Dir.worker_dir(job_dir)}")
    IO.puts("stderr=#{Dir.stderr_path(job_dir)}")
    IO.puts("worktree=#{worktree}")
    IO.puts("unit=#{Systemd.unit_name(id)}")

  "ended" ->
    IO.inspect(Systemd.ended(context, Dir.stderr_path(job_dir)),
      limit: :infinity,
      printable_limit: :infinity
    )

  # No ceiling in the context, so the one it prints can only have come from the cgroup.
  "memory" ->
    IO.inspect(Systemd.memory(Map.delete(context, :memory_max)))

  "bus_error" ->
    IO.inspect(Systemd.bus_error(File.read!(System.fetch_env!("FJ_FILE"))))

  "probe" ->
    {micros, answer} = :timer.tc(&Systemd.probe/0)
    IO.puts("#{div(micros, 1000)} #{inspect(answer)}")

  "reboot" ->
    IO.inspect(ForgeWorker.Health.reboot())
end
