defmodule Forge.Git.Reader do
  @moduledoc """
  Reads any number of files at commits through **one** `git cat-file --batch` process.

  `Forge.Git.show/3` starts a git process for each file, and reading a workflow means a file for
  the workflow, one for every prompt and script it names and one for every library: admitting a
  ticket started ten processes, seven of them a `show` (ticket 68). A reader is opened for the
  length of one operation and asked for each path in turn. It is a port, so the question and the
  answer go over a pipe — `cat-file --batch` answers each line as it is read — and the process does
  not exist outside `with_reader/2`.

  **A path is `:error` unless it is a blob.** `git show <sha>:<dir>` prints a tree's listing, and
  `exists?/3` here is true for one (the object is there) while `read/3` refuses it: a file read as
  text that is a directory is a mistake, and its listing was never what a caller meant.
  """

  alias Forge.Git

  # How long it waits for the next piece of an answer, not for the whole of one.
  @timeout 30_000

  @opaque t :: %__MODULE__{port: port()}
  defstruct [:port]

  @doc """
  Runs `fun` with a reader over `repo`, and closes it afterwards. When git cannot be started in
  `repo` (a directory that is not there) `fun` is still run, with a reader that answers `:error`
  to every read and `false` to every existence check, which is what a `show` in the same place
  would have said.
  """
  @spec with_reader(Git.repo(), (t() | :unavailable -> result)) :: result when result: var
  def with_reader(repo, fun) do
    case open(repo) do
      {:ok, reader} ->
        try do
          fun.(reader)
        after
          close(reader.port)
        end

      :error ->
        fun.(:unavailable)
    end
  end

  # A directory that is not there is refused before a process is started for it: the runtime
  # prints "Could not cd to" to the server's stderr and the port then dies, which is a noise for
  # what `show/3` answered quietly. **Taking this check out is an equivalent mutant**: the port dies
  # (or `Port.command` raises `:badarg`, which `object/3` catches), every answer is `:missing` as
  # before, and only the line on stderr differs.
  defp open(repo) do
    if File.dir?(repo), do: spawn_reader(repo), else: :error
  end

  defp spawn_reader(repo) do
    path = Git.executable("git")

    :telemetry.execute([:forge, :git, :spawn], %{}, %{
      executable: path,
      args: ["cat-file", "--batch"]
    })

    port =
      Port.open({:spawn_executable, path}, [
        :binary,
        :use_stdio,
        :exit_status,
        args: ["cat-file", "--batch"],
        cd: repo,
        env: [{~c"GIT_TERMINAL_PROMPT", ~c"0"}]
      ])

    {:ok, %__MODULE__{port: port}}
  rescue
    # `git` is not on the machine's `PATH` (`Git.executable/1` then hands back the bare name, which
    # `:spawn_executable` refuses): every read says `:error`, where `System.cmd/3` would have raised
    # for the same reason, which is not what a read of a file should do. **Taking this clause out is not
    # caught by a test, and none is written:** once found, the path is kept for the whole VM
    # (`Git.executable/1`; a miss is not kept), so a test cannot make it vanish without breaking
    # every other one.
    ErlangError -> :error
  end

  @doc "The content of the blob at `path` in `sha`: `{:ok, text}`, or `:error`."
  @spec read(t() | :unavailable, Git.sha(), String.t()) :: {:ok, String.t()} | :error
  def read(:unavailable, _sha, _path), do: :error

  def read(%__MODULE__{} = reader, sha, path) do
    case object(reader, sha, path) do
      {:blob, content} -> {:ok, content}
      _tree_or_missing -> :error
    end
  end

  @doc "Whether `path` exists at `sha`, as a blob or a tree."
  @spec exists?(t() | :unavailable, Git.sha(), String.t()) :: boolean()
  def exists?(:unavailable, _sha, _path), do: false

  def exists?(%__MODULE__{} = reader, sha, path),
    do: object(reader, sha, path) != :missing

  # `{:blob, content}`, `:other` for anything else that exists, `:missing` for what git cannot
  # find or what cannot be asked. A name with a newline in it would be two questions on one pipe.
  defp object(_reader, _sha, path) when not is_binary(path), do: :missing

  defp object(%__MODULE__{port: port}, sha, path) do
    name = "#{sha}:#{path}"

    if String.contains?(name, ["\n", <<0>>]) do
      :missing
    else
      Port.command(port, name <> "\n")
      answer(port, <<>>)
    end
  catch
    # The port has closed under us: git went away. Asking again would only fail again.
    :error, :badarg -> :missing
  end

  # The header is `<oid> <type> <size>\n`, or `<name> missing\n`; a blob's `size` bytes and a
  # newline follow, and so does a tree's, which is read and dropped.
  defp answer(port, buffer) do
    case String.split(buffer, "\n", parts: 2) do
      [header, rest] -> body(port, header, rest)
      [_incomplete] -> more(port, buffer, &answer(port, &1))
    end
  end

  # A name with spaces in it makes `<name> missing` three words or more — `x blob missing` is a
  # missing path called `x blob` — so the ending is asked first; an object that is there is always
  # `<oid> <type> <size>`, with a number last.
  #
  # `ambiguous` is a defence no test makes: it is answered for an abbreviated object name matching
  # more than one object, and a name here is a 40-character commit id. The `exit_status` in `more/3`
  # (git dying between two answers) can be reached, by a directory that is not a repository, but
  # only by a race with the port's own death, so no test asserts it.
  defp body(port, header, rest) do
    if String.ends_with?(header, [" missing", " ambiguous"]) do
      # Whole answers: the pipe is still in step.
      :missing
    else
      found(port, String.split(header, " "), rest)
    end
  end

  defp found(port, [_oid, type, size], rest) when type in ["blob", "tree", "commit", "tag"],
    do: take(port, String.to_integer(size), rest, if(type == "blob", do: :blob, else: :other))

  # Not an answer this reader knows how to skip: it closes, and the rest read `:missing`.
  defp found(port, _words, _rest) do
    close(port)
    :missing
  end

  defp take(port, size, buffer, kind) do
    if byte_size(buffer) >= size + 1 do
      <<content::binary-size(size), "\n", _rest::binary>> = buffer
      if kind == :blob, do: {:blob, content}, else: :other
    else
      more(port, buffer, &take(port, size, &1, kind))
    end
  end

  defp more(port, buffer, continue) do
    receive do
      {^port, {:data, data}} -> continue.(buffer <> data)
      {^port, {:exit_status, _status}} -> :missing
    after
      # A pipe that has missed an answer is out of step with its questions for good: closed, so
      # that every later read is `:missing` and not the previous question's answer.
      @timeout ->
        close(port)
        :missing
    end
  end

  # Safe to call on a port that has exited or been closed already. What the port had sent and was
  # not read — after a timeout or an answer cut short — is taken out of the caller's mailbox: the
  # caller may be a LiveView, which lives on and would keep it. **Taking `flush/1` out is not caught
  # by a test, and none is written:** whether a message is already in the mailbox when the port
  # closes depends on when git answers, so no test can arrange it without a sleep that proves
  # nothing.
  defp close(port) do
    Port.close(port)
    flush(port)
  catch
    :error, :badarg -> flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _message} -> flush(port)
    after
      0 -> :ok
    end
  end
end
