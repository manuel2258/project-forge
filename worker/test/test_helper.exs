# The archive's mount is the recording one for every test, once and for good: it routes by the
# root a test registers and treats every other folder as `Mount.None` does, so no test writes the
# mount to the application environment (`ForgeWorker.RecordingMount`).
ForgeWorker.RecordingMount.start()
Application.put_env(:forge_worker, :archive_mount, ForgeWorker.RecordingMount)

# The attached files' folder is chosen by a setting of its own, and routed the same way
# (`ForgeWorker.RecordingBind`).
ForgeWorker.RecordingBind.start()
Application.put_env(:forge_worker, :attachments_mount, ForgeWorker.RecordingBind)

# `:root` tests make and remove Unix users, so they run only when asked for, as root:
# `mix test --include root` (`ForgeWorker.JobUserTest`).
#
# `assert_receive_timeout` is the limit of every `assert_receive` and `assert_push` that names none,
# which is about 210 of the ~270 in this suite, and it was ExUnit's 100 ms: a second job, or the
# platform suite beside this one on a machine of two cores, made the `ready` a test waits for come
# a few hundred milliseconds late, and every such test failed on a commit nothing was wrong with
# (`LinkTest` waiting for `ready` was most of them). Such a wait ends the moment its message
# arrives, so a passing test is no slower; only a real failure takes longer to be reported.
# Slipstream's `assert_push` and `connect_and_assert_join` read the same setting when a test file
# compiles, which is after this file has run. Waits that name their own limit, and every
# `refute_receive`, are left as they are: the latter's limit is how long nothing may happen.
ExUnit.start(exclude: [:root], assert_receive_timeout: 3_000)
