# `:root` tests make and remove Unix users, so they run only when asked for, as root:
# `mix test --include root` (`ForgeWorker.JobUserTest`).
ExUnit.start(exclude: [:root])
