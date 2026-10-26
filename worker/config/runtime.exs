import Config

# Read at boot, from the environment cloud-init wrote. `ForgeWorker.Config` reads the machine's
# identity — who it is, where the platform is — straight from `System.get_env`; what is here is
# everything that has to be an application setting because something takes it as an option.
#
# Tests configure themselves and never dial anything, so none of this applies to them.
if config_env() != :test do
  # **No credential.** A job brings its own in the assignment, sealed for this machine, and it is
  # opened only when the harness is spawned (docs/design/credentials.md § Delivery to the
  # machine). `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` in this machine's environment are
  # not read.
  harness_opts =
    Enum.reject(
      [
        executable: System.get_env("FORGE_CLAUDE_EXECUTABLE"),
        model: System.get_env("FORGE_CLAUDE_MODEL"),
        effort: System.get_env("FORGE_CLAUDE_EFFORT")
      ],
      fn {_key, value} -> is_nil(value) end
    )

  config :forge_worker,
    harness_opts: harness_opts,
    nix_env: System.get_env("FORGE_NIX_ENV", "1") in ["1", "true"]

  # How a job's process is confined (docs/design/worker-tier.md § The job slice). The image
  # says `systemd`; a development machine where systemd is not PID 1 leaves this unset and gets
  # `Direct`, which is not a mock but is also not a ceiling.
  case System.get_env("FORGE_SLICE") do
    "systemd" -> config :forge_worker, slice: ForgeWorker.Slice.Systemd
    "direct" -> config :forge_worker, slice: ForgeWorker.Slice.Direct
    nil -> :ok
    other -> raise ~s(FORGE_SLICE must be "systemd" or "direct", got #{inspect(other)})
  end

  # Where a job's worktree comes from (docs/design/worker-tier.md § Volumes and the seed).
  # Btrfs on the image, whose root is btrfs for exactly this; Copy anywhere else, which is
  # correct without the sharing.
  case System.get_env("FORGE_VOLUME") do
    "btrfs" -> config :forge_worker, volume: ForgeWorker.Volume.Btrfs
    "copy" -> config :forge_worker, volume: ForgeWorker.Volume.Copy
    nil -> :ok
    other -> raise ~s(FORGE_VOLUME must be "btrfs" or "copy", got #{inspect(other)})
  end
end
