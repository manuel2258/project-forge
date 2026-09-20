defmodule ForgeWorker.Slice do
  @moduledoc """
  How a job's process is confined. `docs/decisions.md` settles the mechanism — a transient
  systemd unit with a memory ceiling and a proportional CPU share, and a Unix user per job —
  and this is the seam it lives behind.

  Two implementations, and neither is a mock:

    * `ForgeWorker.Slice.Systemd` is what runs on the worker image.
    * `ForgeWorker.Slice.Direct` runs the process with no unit and no ceiling. It is what the
      worker does on a machine without systemd, which is any development machine and every
      container, and it is what the tests exercise.

  `measure/` makes the same substitution for the same reason and stamps which one ran
  (`docs/design/measurement-harness.md`); so does the worker, in the job's `started` event.
  """

  @typedoc """
  What the slice is made for. `env` and `secret_names` are the process environment the runner
  composed, split as it splits it: an implementation that starts the process somewhere else —
  which is what a transient unit is — has to carry it across, and a secret is named without its
  value so it never reaches an argument vector.
  """
  @type opts :: %{
          required(:job_id) => String.t(),
          required(:worktree) => String.t(),
          optional(:job_dir) => String.t(),
          optional(:memory_max) => pos_integer() | nil,
          optional(:cpu_weight) => pos_integer() | nil,
          optional(:env) => [{String.t(), String.t()}],
          optional(:secret_names) => [String.t()]
        }

  @typedoc "What `prepare/1` set up and `wrap/3` and `cleanup/1` need back."
  @type context :: map()

  @doc "Makes whatever the slice needs before the process starts, such as its Unix user."
  @callback prepare(opts()) :: {:ok, context()} | {:error, term()}

  @doc "The command that runs `executable` inside the slice."
  @callback wrap(String.t(), [String.t()], context()) :: {String.t(), [String.t()]}

  @doc "Removes what `prepare/1` made. Called whether the job succeeded or not."
  @callback cleanup(context()) :: :ok

  @doc "The implementation in force. `Direct` unless something says otherwise."
  @spec impl() :: module()
  def impl, do: Application.get_env(:forge_worker, :slice, ForgeWorker.Slice.Direct)
end

defmodule ForgeWorker.Slice.Direct do
  @moduledoc """
  The process, with no unit and no ceiling: what the worker does where systemd is not PID 1.
  A job that overruns takes the machine with it, which is exactly what the slice exists to
  prevent — so this is for development, and the image runs `ForgeWorker.Slice.Systemd`.
  """

  @behaviour ForgeWorker.Slice

  @impl ForgeWorker.Slice
  def prepare(opts), do: {:ok, %{kind: :direct, job_id: opts.job_id}}

  @impl ForgeWorker.Slice
  def wrap(executable, args, _context), do: {executable, args}

  @impl ForgeWorker.Slice
  def cleanup(_context), do: :ok
end

defmodule ForgeWorker.Slice.Systemd do
  @moduledoc """
  A transient systemd unit per job: a hard memory ceiling so an out-of-memory build kills one
  job rather than the machine, an equal CPU weight so an agent waiting on inference donates
  its share to whoever is compiling, and a fresh Unix user that owns the job's files.

  `MemorySwapMax=0` because a slice allowed to swap does not die at its ceiling — it drags the
  machine to disk speed and takes its neighbours with it. `--pipe --wait` because the runner
  is built around seeing the harness's stdout and its exit; the unit is a wrapper, not a
  different execution model.

  **Not exercised by the test suite.** It needs systemd as PID 1 and cgroup v2, which the
  machine this was written on has neither of. What is tested is the command it builds. The
  mechanism itself is what `measure/`'s M3 already measured, and what milestone 3's demo has
  to show — `docs/measurements.md` says the crossing of M2 and M3, four builds with one under
  a binding ceiling, has never been run and should be before the demo depends on it.
  """

  @behaviour ForgeWorker.Slice

  require Logger

  @impl ForgeWorker.Slice
  def prepare(opts) do
    user = user_name(opts.job_id)

    with :ok <- create_user(user),
         :ok <- own(user, [Map.get(opts, :worktree), Map.get(opts, :job_dir)]) do
      {:ok, Map.merge(opts, %{kind: :systemd, user: user})}
    end
  end

  @impl ForgeWorker.Slice
  def wrap(executable, args, context) do
    {"systemd-run", flags(context) ++ ["--", executable | args]}
  end

  @impl ForgeWorker.Slice
  def cleanup(%{user: user} = context) do
    # The files come back to the worker before the user goes away. Two reasons, and the first
    # is not optional: the worker commits and pushes the worktree the moment the job ends, and
    # git refuses to work in a repository owned by somebody else — rightly, since that is how
    # a repository's own configuration gets executed by a user who did not write it. The second
    # is that files owned by a deleted uid outlive every job this machine ever runs.
    case own("root", [Map.get(context, :worktree), Map.get(context, :job_dir)]) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("could not take #{user}'s files back: #{inspect(reason)}")
    end

    # No `--remove`: the user was made without a home, and asking for one to be removed fails
    # with a warning on every job that ever succeeded.
    case System.cmd("userdel", [user], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> Logger.warning("could not remove #{user} (#{code}): #{out}")
    end

    :ok
  end

  def cleanup(_context), do: :ok

  @doc "The unit's flags. Public because it is the part of this that can be checked here."
  @spec flags(map()) :: [String.t()]
  def flags(context) do
    [
      "--pipe",
      "--wait",
      "--collect",
      "--quiet",
      "--unit=" <> unit_name(context.job_id),
      "--uid=" <> context.user,
      "--property=WorkingDirectory=" <> context.worktree,
      "--property=MemorySwapMax=0"
    ] ++
      limit("MemoryMax", context[:memory_max]) ++
      limit("CPUWeight", context[:cpu_weight]) ++
      environment(context)
  end

  # systemd-run hands the unit to systemd, which starts it with its own default environment and
  # not with systemd-run's: everything the runner composed — PATH, HOME, the job directory, the
  # harness's own variables — has to be named here or the process starts without it. A secret is
  # named without its value, which systemd-run then reads from its own environment, so the value
  # crosses to systemd over its bus rather than sitting in an argument vector for the length of
  # the job.
  defp environment(context) do
    Enum.map(context[:env] || [], fn {name, value} -> "--setenv=#{name}=#{value}" end) ++
      Enum.map(context[:secret_names] || [], &("--setenv=" <> &1))
  end

  # The job's files belong to the job's user: it has to write them, and no other job on this
  # machine may read them. Without this the unit cannot even change into its working directory.
  defp own(user, paths) do
    paths
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce_while(:ok, fn path, :ok ->
      with {_out, 0} <- System.cmd("chown", ["-R", user, path], stderr_to_stdout: true),
           {_out, 0} <- System.cmd("chmod", ["700", path], stderr_to_stdout: true) do
        {:cont, :ok}
      else
        {out, code} -> {:halt, {:error, {:own, path, code, out}}}
      end
    end)
  end

  @doc "The transient unit's name, which is also how a stuck one is found by hand."
  @spec unit_name(String.t()) :: String.t()
  def unit_name(job_id), do: "forge-job-" <> short(job_id)

  @doc "The Unix user a job runs as. One per job, made before it starts and gone after."
  @spec user_name(String.t()) :: String.t()
  def user_name(job_id), do: "forge-job-" <> short(job_id)

  defp limit(_name, nil), do: []
  defp limit(name, value), do: ["--property=#{name}=#{value}"]

  # Systemd and useradd both cap a user name at 31 characters. `"forge-job-"` is 10, so this
  # takes 16 hex characters of the id (dashes stripped) for a 26-character name: 64 bits of
  # entropy, where the first segment's 8 hex gave 32 and two concurrent jobs colliding on it
  # shared a Unix user — and `create_user/1` reads "already exists" as success, so the collision
  # was silent and one job's cleanup pulled the other's files and user out from under it. At 64
  # bits a collision is not a thing that happens on one machine, so the reuse branch is safe.
  defp short(job_id), do: job_id |> String.replace("-", "") |> String.slice(0, 16)

  defp create_user(user) do
    args = ["--system", "--no-create-home", "--shell", "/sbin/nologin", user]

    case System.cmd("useradd", args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      # Already there: a resumed job on a worker that still has its user.
      {_out, 9} -> :ok
      {out, code} -> {:error, {:useradd, code, out}}
    end
  end
end
