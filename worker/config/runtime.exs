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
      # Unset and set-to-nothing are the same statement: this machine has no opinion.
      #
      # **`executable` is why this filter cannot be pruned**, and this is the file where that is
      # true. `ForgeWorker.Harness.ClaudeCode.command/3` reads it as
      # `Keyword.get(opts, :executable, "claude")`, which hands back `""` for a key that is
      # present and empty — so a machine booted with `FORGE_CLAUDE_EXECUTABLE=` spawned
      # `nix develop … --command "" …` and failed every job on it. The fallback to `claude` only
      # happens if the key is absent, which is what this line makes it.
      #
      # The two dials are refused again downstream (`flag_args/3`), so for them this is defence
      # in depth; `executable` has nothing after it. `runtime_config_test.exs` beside this
      # release holds the rule.
      fn {_key, value} -> value in [nil, ""] end
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

  # Where a job's archive folder comes from (docs/design/archive.md § The worker's side). The image
  # says `9p`; unset, a job's archive is a README saying there is none on this machine.
  case System.get_env("FORGE_ARCHIVE") do
    "9p" -> config :forge_worker, archive_mount: ForgeWorker.Archive.Mount.NineP
    nil -> :ok
    other -> raise ~s(FORGE_ARCHIVE must be "9p", got #{inspect(other)})
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
