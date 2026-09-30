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

  @typedoc """
  What a slice read of a job's memory, any of it nil where it could not be read
  (`ForgeWorker.Job.Memory` says what it means): the ceiling, now, the most so far, how often the
  ceiling was reached and a process killed for memory, and the share of the last ten seconds every
  process in the job was stalled on memory.
  """
  @type reading :: %{
          ceiling: non_neg_integer() | nil,
          current: non_neg_integer() | nil,
          peak: non_neg_integer() | nil,
          max_events: non_neg_integer() | nil,
          oom_kills: non_neg_integer() | nil,
          pressure: float() | nil
        }

  @typedoc """
  What a slice can say about a process once it has ended (`ended/2`):

    * `memory` — the unit's own last reading, taken before its cgroup went, or nil;
    * `exit` — how its main process ended, as the unit saw it (`code` `exited` or `killed`,
      `status`, and the unit's `result`), or nil;
    * `unreachable` — why the slice's supervisor could not be reached, when that is why the
      process never ran: the machine's failure, not the job's;
    * `last_line` — the last line the process itself wrote to its output, the slice's own lines
      taken out, or nil.
  """
  @type ending :: %{
          memory: reading() | nil,
          exit:
            %{code: String.t() | nil, status: String.t() | nil, result: String.t() | nil} | nil,
          unreachable: String.t() | nil,
          last_line: String.t() | nil
        }

  @doc "Makes what the unit needs before the process starts. The job's user already exists."
  @callback prepare(opts()) :: {:ok, context()} | {:error, term()}

  @doc "The command that runs `executable` inside the slice."
  @callback wrap(String.t(), [String.t()], context()) :: {String.t(), [String.t()]}

  @doc "Removes what `prepare/1` made. Called whether the job succeeded or not."
  @callback cleanup(context()) :: :ok

  @doc """
  The job's memory as its slice can read it now, while its process runs; nil when there is
  nothing to read. Plain reads, which answer even when the slice's supervisor does not.
  """
  @callback memory(context()) :: reading() | nil

  @doc """
  What the slice can say about a process that has ended, given the file its output went to.
  Called once per process, after it has exited.
  """
  @callback ended(context(), output :: String.t()) :: ending()

  @doc """
  Whether the slice's supervisor still answers — for the machine's health
  (`ForgeWorker.Health`). `:none` from a slice with nothing to ask.
  """
  @callback probe() :: :ok | {:error, String.t()} | :none

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

  @doc "The last `bytes` of a file, as text; empty when there is no file."
  @spec tail(String.t(), pos_integer()) :: String.t()
  def tail(path, bytes) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          {:ok, size} = :file.position(file, :eof)
          {:ok, _at} = :file.position(file, max(size - bytes, 0))

          case IO.binread(file, bytes) do
            data when is_binary(data) -> String.replace_invalid(data)
            _eof -> ""
          end
        after
          File.close(file)
        end

      {:error, _reason} ->
        ""
    end
  end

  @doc """
  The last line of `text` that is the process's own, not one `own?` says the slice wrote; nil
  when there is none.
  """
  @spec last_line(String.t(), (String.t() -> boolean())) :: String.t() | nil
  def last_line(text, own? \\ fn _line -> false end) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or own?.(&1)))
    |> List.last()
  end
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

  # No cgroup of the job's own, and no supervisor to ask: all it can say is what the process
  # wrote last.
  @impl ForgeWorker.Slice
  def memory(_context), do: nil

  @impl ForgeWorker.Slice
  def ended(_context, output) do
    last = output |> ForgeWorker.Slice.tail(2048) |> ForgeWorker.Slice.last_line()
    %{memory: nil, exit: nil, unreachable: nil, last_line: last}
  end

  @impl ForgeWorker.Slice
  def probe, do: :none

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

  **The unit is not exercised by the test suite**, which needs neither systemd as PID 1 nor
  cgroup v2; what it tests is the command this builds. **It is exercised on the worker image** by
  `nix build .#checks.x86_64-linux.worker-health` (`nix/worker-health.nix`), which needs KVM: the
  release in the image makes the user, the unit and its stop step with this module and reads what
  came back with it — a child and a main process killed at a 512 MiB ceiling, the cgroup under
  pressure, a forged bus error, and a PID 1 wedged by a 2-byte ceiling
  (`docs/measurements.md` § The worker at its ceiling, on the image).

  **The user is, where the suite runs as root.** `enter/1`, `own/2`, `run_as/3` and `leave/2` need
  only `useradd`, `chown`, `setpriv` and `userdel`, and `ForgeWorker.JobUserTest` uses them to show
  a hook the job planted running as the job's user rather than root: `mix test --include root`.

  **What it reads is, from fixture files.** The cgroup's files, the unit's last reading and what
  `systemd-run` prints are plain text, so `memory/1`, `ended/2` and the script behind the unit's
  `ExecStopPost` are tested against a directory standing in for the cgroup
  (`docs/design/worker-tier.md` § What the slice reads while a job runs).
  """

  @behaviour ForgeWorker.Slice

  alias ForgeWorker.Job.Dir
  alias ForgeWorker.Log

  @cgroup_root "/sys/fs/cgroup/system.slice"
  @tail_bytes 2048

  # **What `systemd-run` prints when it could not reach PID 1**, read in systemd's source, and the
  # first of them also seen on the worker image (261.2, `nix/worker-health.nix`): `run.c`'s
  # `bus_call_with_hint()` says `Failed to start transient service unit: <errno>`, and
  # `bus-util.c`'s `bus_log_connect_full()` says `Failed to connect to <scope> bus via <transport>
  # transport: <errno>` (older releases: `Failed to connect to bus: <errno>`). The errno texts are
  # the ones that mean nobody answered, not an answer that said no — `Unit … already exists` is
  # PID 1 answering. One list, and the only one (`docs/design/worker-tier.md` § How a machine finds
  # out). The run that wedges PID 1 prints neither — `Failed to request invocation ID for unit: `
  # or `Failed to query unit state: ` — and is left to end as the job's own failure until the
  # operator says otherwise (`docs/design/worker-tier.md` § Open).
  @bus_calls ["Failed to start transient service unit: ", "Failed to connect to "]
  @bus_errors [
    "Connection timed out",
    "Transport endpoint is not connected",
    "Connection reset by peer"
  ]

  # `systemd-run`'s own lines, in the stderr it shares with the job now that it is not `--quiet`:
  # the one saying the unit exists, and the summary it prints once the unit has ended.
  @started "Running as unit:"
  @summary [
    "Finished with result",
    "Main processes terminated with",
    "Service runtime",
    "CPU time consumed",
    "Memory peak",
    "IP Traffic",
    "IO Bytes"
  ]

  # The user is the job owner's (`enter/1`), and the worktree was given to it before any git ran
  # in it. What is left is the job directory, which the runner has just written as root — and the
  # script the unit runs as root when its process has ended, which goes in the worker's own
  # directory beside it, where the job's user can write nothing.
  @impl ForgeWorker.Slice
  def prepare(opts) do
    user = user_name(opts.job_id)

    with :ok <- chown(user, [Map.get(opts, :job_dir)]) do
      context = Map.merge(opts, %{kind: :systemd, user: user})
      write_at_exit(context)
      {:ok, context}
    end
  end

  # A reading left by an earlier worker's run of this job — a unit that outlived the worker that
  # started it — would hide this run's genuine bus error and lend it an exit it never had
  # (`docs/design/worker-tier.md` § How a machine finds out).
  defp write_at_exit(%{job_dir: job_dir} = context) when is_binary(job_dir) do
    Dir.worker_dir!(job_dir)
    File.rm(at_exit_reading(context))
    script = at_exit_path(context)
    File.write!(script, at_exit_script(cgroup(context), at_exit_reading(context)))
    File.chmod!(script, 0o755)
  end

  defp write_at_exit(_context), do: :ok

  @doc """
  The script the unit runs as its `ExecStopPost`, once its main process has ended and before its
  cgroup is removed: `memory.events`, `memory.peak` and `memory.max`, and how the main process
  ended as systemd hands a stop command it (`EXIT_CODE`, `EXIT_STATUS`, `SERVICE_RESULT`), into
  `reading`. POSIX `sh` and its builtins alone, so it needs no `PATH`; each file only if it is
  there, since `memory.peak` needs a kernel from 5.19 on; and it always exits 0, since a stop
  command that failed would fail the unit a job had finished cleanly in.
  """
  @spec at_exit_script(String.t(), String.t()) :: String.t()
  def at_exit_script(cgroup, reading) do
    """
    #!/bin/sh
    # Written by the forge worker (ForgeWorker.Slice.Systemd): the unit's own last reading.
    cg=#{sh_quote(cgroup)}
    {
      if [ -r "$cg/memory.events" ]; then
        while IFS= read -r line; do printf 'events %s\\n' "$line"; done < "$cg/memory.events"
      fi
      [ -r "$cg/memory.peak" ] && read -r value < "$cg/memory.peak" && printf 'peak %s\\n' "$value"
      [ -r "$cg/memory.max" ] && read -r value < "$cg/memory.max" && printf 'max %s\\n' "$value"
      printf 'exit_code %s\\nexit_status %s\\nresult %s\\n' \\
        "${EXIT_CODE-}" "${EXIT_STATUS-}" "${SERVICE_RESULT-}"
    } > #{sh_quote(reading)} 2> /dev/null
    exit 0
    """
  end

  defp sh_quote(text), do: "'" <> String.replace(text, "'", ~S('"'"')) <> "'"

  defp at_exit_path(context), do: Path.join(Dir.worker_dir(context.job_dir), "at-exit")
  defp at_exit_reading(context), do: Path.join(Dir.worker_dir(context.job_dir), "at-exit.reading")

  defp cgroup(context) do
    root = context[:cgroup_root] || Application.get_env(:forge_worker, :cgroup_root, @cgroup_root)
    Path.join(root, unit_name(context.job_id) <> ".service")
  end

  @impl ForgeWorker.Slice
  def wrap(executable, args, context) do
    {"systemd-run", flags(context) ++ ["--", executable | args]}
  end

  # Nothing: the unit is collected by systemd (`--collect`), and the user and its files are the
  # job owner's to take back once its last git command has run (`leave/2`).
  @impl ForgeWorker.Slice
  def cleanup(_context), do: :ok

  # -- what it reads -----------------------------------------------------------------------------

  # Plain reads of the unit's cgroup, which answer whether or not PID 1 does. Nil when the cgroup
  # is not there — the unit not made yet, or gone — which is nothing to say rather than zero.
  @impl ForgeWorker.Slice
  def memory(context) do
    dir = cgroup(context)

    case read(dir, "memory.events") do
      nil ->
        nil

      events ->
        events = parse_events(events)

        %{
          ceiling: dir |> read("memory.max") |> parse_bytes(),
          current: dir |> read("memory.current") |> parse_bytes(),
          peak: dir |> read("memory.peak") |> parse_bytes(),
          max_events: events["max"],
          oom_kills: events["oom_kill"],
          pressure: dir |> read("memory.pressure") |> parse_pressure()
        }
    end
  end

  defp read(dir, file) do
    case File.read(Path.join(dir, file)) do
      {:ok, text} -> text
      {:error, _reason} -> nil
    end
  end

  @doc "`memory.events` as a map of counter to count: `max`, `oom`, `oom_kill` and the rest."
  @spec parse_events(String.t()) :: %{String.t() => non_neg_integer()}
  def parse_events(text) do
    for line <- String.split(text, "\n", trim: true),
        [key, count] <- [String.split(line, " ", trim: true)],
        {n, ""} <- [Integer.parse(count)],
        into: %{},
        do: {key, n}
  end

  @doc "A cgroup's byte figure: a number, or nil for `max` — no ceiling — and for nothing read."
  @spec parse_bytes(String.t() | nil) :: non_neg_integer() | nil
  def parse_bytes(nil), do: nil

  def parse_bytes(text) do
    case Integer.parse(String.trim(text)) do
      {n, ""} -> n
      _max -> nil
    end
  end

  @doc """
  `memory.pressure`'s `full avg10`: the share of the last ten seconds in which every process in the
  cgroup was stalled on memory at once, as a percentage. Nil when there is none to read.
  """
  @spec parse_pressure(String.t() | nil) :: float() | nil
  def parse_pressure(nil), do: nil

  def parse_pressure(text) do
    case Regex.run(~r/^full avg10=(\d+(?:\.\d+)?)/m, text) do
      [_line, figure] -> figure |> Float.parse() |> elem(0)
      nil -> nil
    end
  end

  # **Read once, and removed**: a correction round runs a unit of the same name, and a reading left
  # behind would be the next round's if that round never got as far as a unit.
  @impl ForgeWorker.Slice
  def ended(context, output) do
    tail = ForgeWorker.Slice.tail(output, @tail_bytes)
    reading = take_reading(context)
    {memory, exit} = parse_at_exit(reading)

    %{
      memory: memory,
      exit: exit,
      unreachable: if(is_nil(reading), do: unreachable(output, tail)),
      last_line: ForgeWorker.Slice.last_line(tail, &own_line?/1)
    }
  end

  defp take_reading(%{job_dir: job_dir} = context) when is_binary(job_dir) do
    path = at_exit_reading(context)

    case File.read(path) do
      {:ok, text} ->
        File.rm(path)
        text

      {:error, _none} ->
        nil
    end
  end

  defp take_reading(_context), do: nil

  @doc """
  The unit's last reading (`at_exit_script/2`) as a memory reading and how its main process ended;
  `{nil, nil}` when there was none — a unit that never existed, or never stopped cleanly enough to
  run its stop command.
  """
  @spec parse_at_exit(String.t() | nil) :: {ForgeWorker.Slice.reading() | nil, map() | nil}
  def parse_at_exit(nil), do: {nil, nil}

  def parse_at_exit(text) do
    lines = String.split(text, "\n", trim: true)

    fields =
      for line <- lines,
          [key, value] <- [String.split(line, " ", parts: 2)],
          into: %{},
          do: {key, String.trim(value)}

    events =
      lines
      |> Enum.flat_map(fn
        "events " <> event -> [event]
        _other -> []
      end)
      |> Enum.join("\n")
      |> parse_events()

    memory = %{
      ceiling: parse_bytes(fields["max"]),
      current: nil,
      peak: parse_bytes(fields["peak"]),
      max_events: events["max"],
      oom_kills: events["oom_kill"],
      pressure: nil
    }

    exit = %{
      code: blank(fields["exit_code"]),
      status: blank(fields["exit_status"]),
      result: blank(fields["result"])
    }

    {memory, exit}
  end

  defp blank(nil), do: nil
  defp blank(""), do: nil
  defp blank(value), do: value

  # A bus error in the tail is believed only when nothing says the unit came to exist: not its
  # last reading, which `ended/2` asks first and which root wrote where the job cannot reach — so
  # the one proof a job cannot forge or remove — and not the output's `Running as unit:`, which a
  # job can: its stderr is this very file, and it may truncate it and write a bus error of its own
  # (`docs/design/worker-tier.md` § How a machine finds out). The whole output is read, but only
  # when there is a bus error to check: a genuine one leaves a file of two lines.
  defp unreachable(output, tail) do
    case bus_error(tail) do
      nil -> nil
      line -> if started?(output), do: nil, else: "systemd-run could not reach PID 1: #{line}"
    end
  end

  @doc """
  The line of `output` saying `systemd-run` could not reach PID 1, or nil. Whether to believe it is
  `started?/1`'s question.
  """
  @spec bus_error(String.t()) :: String.t() | nil
  def bus_error(output) do
    output
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(String.starts_with?(&1, @bus_calls) and String.ends_with?(&1, @bus_errors)))
  end

  @doc """
  Whether the output at `path` says the unit came to exist (`Running as unit:`). A job's process
  runs only once its unit exists, and `systemd-run` says so as soon as it does, so an output that
  never says it holds nothing a job wrote (`docs/design/worker-tier.md` § How a machine finds out).
  """
  @spec started?(String.t()) :: boolean()
  def started?(path) do
    path |> File.stream!() |> Enum.any?(&String.contains?(&1, @started))
  rescue
    File.Error -> false
  end

  @doc "Whether a line of the unit's output is `systemd-run`'s own rather than the process's."
  @spec own_line?(String.t()) :: boolean()
  def own_line?(line) do
    line = String.trim(line)

    String.starts_with?(line, @started) or
      Enum.any?(@summary, &String.starts_with?(line, &1 <> ":"))
  end

  # **Asked of PID 1 itself**, with a deadline it cannot outlive: `timeout` ends `systemctl` at ten
  # seconds and kills it five after, so a probe of a wedged PID 1 comes back as a failure rather
  # than never (`docs/design/worker-tier.md` § How a machine finds out).
  @impl ForgeWorker.Slice
  def probe do
    args = ["-k", "5", "10", "systemctl", "show", "--property=Version", "--value"]

    case System.cmd("timeout", args, stderr_to_stdout: true) do
      {_version, 0} -> :ok
      {out, code} -> {:error, "systemctl show exited #{code}: #{String.trim(out)}"}
    end
  end

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
      # Not `--quiet`: `Running as unit:` is what shows the unit came to exist, which is what lets
      # a bus error in this output be believed (`ended/2`).
      "--pipe",
      "--wait",
      "--collect",
      "--unit=" <> unit_name(context.job_id),
      "--uid=" <> context.user,
      "--property=WorkingDirectory=" <> context.worktree,
      "--property=MemorySwapMax=0",
      # A process the kernel kills for memory dies alone; the default, `stop`, ends the whole unit
      # with it, so an agent's build dying took the agent with it. The harness dying still ends
      # the unit, because its main process is gone (`docs/design/worker-tier.md` § The job slice).
      "--property=OOMPolicy=continue"
    ] ++
      at_exit(context) ++
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

  # `+` runs it as root, so it may write into the worker's directory and nothing the job ran can
  # forge what it writes; `-` keeps its failing from failing the unit.
  defp at_exit(%{job_dir: job_dir} = context) when is_binary(job_dir),
    do: ["--property=ExecStopPost=-+" <> at_exit_path(context)]

  defp at_exit(_context), do: []

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
