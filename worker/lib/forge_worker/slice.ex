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

  **Two lifetimes.** The unit is the runner's: `prepare/1`, `wrap/3` and `cleanup/1` bracket the
  harness or the command's script. The Unix user is the job's, and longer: `enter/1` makes it
  before the worktree exists and `leave/2` removes it after the worker's last git command in that
  worktree, because every one of those runs as the job's user (`run_as/3`) — a repository's hooks
  and configuration are programs the job could have written, and git run as root would run them
  as root. `docs/design/worker-tier.md` § The job slice has the order; the job's owner holds it,
  through `enter/1`, `own/2`, `as_user/1` and `leave/2` here.
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

  @typedoc "A job's Unix user as an implementation made it: what it needs back to use it."
  @type owner :: map()

  @typedoc "A job's Unix user and the implementation that made it, as the job's owner holds it."
  @type user :: {module(), owner()}

  @typedoc "How a command is run as the job's user: the command, and what runs instead."
  @type as :: (String.t(), [String.t()] -> {String.t(), [String.t()]})

  @doc "Makes what the unit needs before the process starts. The job's user already exists."
  @callback prepare(opts()) :: {:ok, context()} | {:error, term()}

  @doc "The command that runs `executable` inside the slice."
  @callback wrap(String.t(), [String.t()], context()) :: {String.t(), [String.t()]}

  @doc "Removes what `prepare/1` made. Called whether the job succeeded or not."
  @callback cleanup(context()) :: :ok

  @doc "Makes the job's Unix user, before anything of the job exists on this machine."
  @callback enter(job_id :: String.t()) :: {:ok, owner()} | {:error, term()}

  @doc "Gives `paths`, and everything under them, to the job's user."
  @callback own(owner(), [String.t()]) :: :ok | {:error, term()}

  @doc "The command that runs `executable` as the job's user, for one the worker waits on."
  @callback run_as(owner(), String.t(), [String.t()]) :: {String.t(), [String.t()]}

  @doc """
  Gives `paths` back to root and removes the job's user. Never raises: it is on every ending,
  including the ones where something has already gone wrong. A second call finds the user gone
  and says nothing of it; a path already removed is the caller's to leave out.
  """
  @callback leave(owner(), [String.t()]) :: :ok

  @doc "The implementation in force. `Direct` unless something says otherwise."
  @spec impl() :: module()
  def impl, do: Application.get_env(:forge_worker, :slice, ForgeWorker.Slice.Direct)

  @doc "Makes the job's user with the implementation in force."
  @spec enter(String.t()) :: {:ok, user()} | {:error, term()}
  def enter(job_id) do
    slice = impl()
    with {:ok, owner} <- slice.enter(job_id), do: {:ok, {slice, owner}}
  end

  @doc "Gives `paths` to the job's user."
  @spec own(user(), [String.t()]) :: :ok | {:error, term()}
  def own({slice, owner}, paths), do: slice.own(owner, paths)

  @doc "How to run a command as the job's user — what `ForgeWorker.Checkout` takes as `as`."
  @spec as_user(user()) :: as()
  def as_user({slice, owner}),
    do: fn executable, args -> slice.run_as(owner, executable, args) end

  @doc "Gives `paths` back and removes the job's user."
  @spec leave(user(), [String.t()]) :: :ok
  def leave({slice, owner}, paths), do: slice.leave(owner, paths)
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

  @impl ForgeWorker.Slice
  def enter(job_id), do: {:ok, %{kind: :direct, job_id: job_id}}

  @impl ForgeWorker.Slice
  def own(_owner, _paths), do: :ok

  @impl ForgeWorker.Slice
  def run_as(_owner, executable, args), do: {executable, args}

  @impl ForgeWorker.Slice
  def leave(_owner, _paths), do: :ok
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

  **The unit is not exercised by the test suite.** It needs systemd as PID 1 and cgroup v2, which
  the machine this was written on has neither of. What is tested is the command it builds. The
  mechanism itself is what `measure/`'s M3 already measured, and what milestone 3's demo has
  to show — `docs/measurements.md` says the crossing of M2 and M3, four builds with one under
  a binding ceiling, has never been run and should be before the demo depends on it.

  **The user is, where the suite runs as root.** `enter/1`, `own/2`, `run_as/3` and `leave/2` need
  only `useradd`, `chown`, `setpriv` and `userdel`, and `ForgeWorker.JobUserTest` uses them to show
  a hook the job planted running as the job's user rather than root: `mix test --include root`.
  """

  @behaviour ForgeWorker.Slice

  alias ForgeWorker.Log

  # The user is the job owner's (`enter/1`), and the worktree was given to it before any git ran
  # in it. What is left is the job directory, which the runner has just written as root.
  @impl ForgeWorker.Slice
  def prepare(opts) do
    user = user_name(opts.job_id)

    with :ok <- chown(user, [Map.get(opts, :job_dir)]) do
      {:ok, Map.merge(opts, %{kind: :systemd, user: user})}
    end
  end

  @impl ForgeWorker.Slice
  def wrap(executable, args, context) do
    {"systemd-run", flags(context) ++ ["--", executable | args]}
  end

  # Nothing: the unit is collected by systemd (`--collect`), and the user and its files are the
  # job owner's to take back once its last git command has run (`leave/2`).
  @impl ForgeWorker.Slice
  def cleanup(_context), do: :ok

  @impl ForgeWorker.Slice
  def enter(job_id) do
    user = user_name(job_id)

    with :ok <- create_user(user),
         {:ok, gid} <- gid(user) do
      {:ok, %{kind: :systemd, job_id: job_id, user: user, gid: gid}}
    end
  end

  @impl ForgeWorker.Slice
  def own(%{user: user}, paths), do: chown(user, paths)

  # `setpriv` rather than a unit: git is a short command the worker waits on and reads, dozens of
  # times a job. Its uid and gid, and no supplementary groups, so nothing of root's comes along.
  # `HOME` names nothing, because the worker's is root's: git would read root's configuration
  # and warn that it may not, on every command.
  @impl ForgeWorker.Slice
  def run_as(owner, executable, args), do: {"setpriv", as_flags(owner) ++ [executable | args]}

  @doc "What `run_as/3` puts in front of a command. Public because it is what can be checked here."
  @spec as_flags(map()) :: [String.t()]
  def as_flags(%{user: user, gid: gid}) do
    ["--reuid=" <> user, "--regid=" <> gid, "--clear-groups", "--", "env", "HOME=/nonexistent"]
  end

  # The files come back to root before the user goes, because files owned by a deleted uid are
  # handed to whoever `useradd` gives that uid next.
  @impl ForgeWorker.Slice
  def leave(%{user: user} = owner, paths) do
    case chown("root", paths) do
      :ok ->
        :ok

      {:error, reason} ->
        Log.line(
          "slice.uncleaned",
          :warning,
          "could not take #{user}'s files back: #{inspect(reason)}",
          job_id: owner.job_id
        )
    end

    # No `--remove`: the user was made without a home, and asking for one to be removed fails
    # with a warning on every job that ever succeeded. 6 is a user that is already gone, which a
    # second `leave/2` finds.
    case System.cmd("userdel", [user], stderr_to_stdout: true) do
      {_out, code} when code in [0, 6] ->
        :ok

      {out, code} ->
        Log.line(
          "slice.uncleaned",
          :warning,
          "could not remove #{user} (#{code}): #{String.trim(out)}",
          job_id: owner.job_id
        )
    end

    :ok
  end

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
  # `-R` does not follow a link the job left in the tree: the link is chowned, not its target.
  defp chown(user, paths) do
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
  # takes 16 hex characters of the id (dashes stripped) for a 26-character name: 60 bits of
  # entropy — sixteen hex digits less the UUIDv4 version digit, which is always `4` — where the
  # first segment's 8 hex gave 32 and two concurrent jobs colliding on it shared a Unix user —
  # and `create_user/1` reads "already exists" as success, so the collision was silent and one
  # job's cleanup pulled the other's files and user out from under it. At 60 bits a collision is
  # not a thing that happens on one machine, so the reuse branch is safe.
  defp short(job_id), do: job_id |> String.replace("-", "") |> String.slice(0, 16)

  # The primary group `useradd` gave the user, which `setpriv` has to be told: it changes nothing
  # it is not asked to, and a gid left at root's is root's group permissions.
  defp gid(user) do
    case System.cmd("id", ["-g", user], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, {:id, code, out}}
    end
  end

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
