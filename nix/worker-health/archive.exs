# The archive of one job, mounted and held for the length of nix/worker-health/guest.sh's `archive`
# item. The server is a process of the BEAM that started it, so this one stays alive until the
# guest says it is done.
#
#     FJ_ID=<job id> FJ_READY=<file> FJ_DONE=<file> forge_worker eval 'Code.eval_file("archive.exs")'
# `release eval` loads the applications and starts none. The worker's is started without its link to
# the platform, which is not what is being looked at, and the kernel's mount is chosen here rather
# than read from the environment so that this item still means something on a machine without it.
Application.put_env(:forge_worker, :connect, false)
Application.put_env(:forge_worker, :archive_mount, ForgeWorker.Archive.Mount.NineP)
{:ok, _} = Application.ensure_all_started(:forge_worker)

id = System.fetch_env!("FJ_ID")
job_dir = Path.join(["/var/lib/forge/jobs", id])
File.mkdir_p!(job_dir)

# The platform is not there: a port nothing listens on, so a read fails and says why.
:ok = ForgeWorker.Archive.start(job_dir, %{url: "http://127.0.0.1:9", token: "none"}, id)
File.write!(System.fetch_env!("FJ_READY"), "ready")

wait = fn wait ->
  if File.exists?(System.fetch_env!("FJ_DONE")), do: :ok, else: (Process.sleep(100); wait.(wait))
end

wait.(wait)
:ok = ForgeWorker.Archive.release(job_dir)
File.rm_rf!(job_dir)
