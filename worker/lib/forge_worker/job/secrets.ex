defmodule ForgeWorker.Job.Secrets do
  @moduledoc """
  A job's project secrets on the worker (`docs/design/secrets.md` § Delivery, § Masking).

  The assignment carries them sealed for this worker, this job and the purpose `:secrets`
  (`ForgeCore.Job.Credential`), and **this holds nothing but that ciphertext**: every use opens it
  again — once for the file a process is spawned to load (`ForgeWorker.Job.Exec`), and once for
  each piece of text masked before it leaves the machine. Opening a few kilobytes is cheap, and a
  value opened inside one call is gone when the call returns, so no process — the link, the job's
  task, the runner, a conversation — holds the opened secrets in its state or mailbox. What the
  harness *prints* of one is another matter: it passes through those processes unmasked until it
  leaves the machine, as all its output does (`secrets.md` § Masking). The key is this machine's
  own token, read from `ForgeWorker.Config` when it is needed, as the credential's is.

  **The worker refuses a reserved name again** (`ForgeCore.Secret`), whatever the platform sent:
  a row written around the platform's changeset, or a platform older than the list, cannot put
  `ANTHROPIC_BASE_URL` in front of a harness. A refused name is left out of the environment and
  said in the machine's log; its value is still masked.

  **Masking is the exact value and its JSON-escaped forms**, replaced with `[secret NAME]` — what
  an `env` dump or an echoed configuration file shows, in an event, a transcript, a session file, a
  command's log, a document or a failure's reason. A value encoded, split or reversed passes; masking is against
  accidents, not against an agent that means it (§ Masking).
  """

  alias ForgeCore.Job.Credential, as: Sealed
  alias ForgeWorker.{Config, Log}

  @enforce_keys [:job_id, :sealed]
  defstruct [:job_id, :sealed]

  @type t :: %__MODULE__{job_id: String.t(), sealed: String.t()}

  @doc "The sealed secrets an assignment carries, or nil for a job that holds none."
  @spec from_assignment(map()) :: t() | nil
  # `is_binary(job_id)` is an **equivalent mutant** as far as the suite goes: the platform always
  # sends one. It stays because this reads the wire, and a job id that is not a string would raise
  # in the seal's associated data rather than read as no secrets.
  def from_assignment(%{"job_id" => job_id, "secrets" => sealed})
      when is_binary(job_id) and is_binary(sealed),
      do: %__MODULE__{job_id: job_id, sealed: sealed}

  def from_assignment(_assignment), do: nil

  @doc """
  The secrets, opened: a map of name to value. `:error` when they will not open — another worker's
  key, another job's, another purpose's, a byte changed — or are not a map of strings.
  """
  @spec open(t() | nil) :: {:ok, %{String.t() => String.t()}} | :error
  def open(nil), do: {:ok, %{}}

  def open(%__MODULE__{job_id: job_id, sealed: sealed}) do
    with {:ok, token_hash} <- Sealed.token_hash(Config.token()),
         {:ok, json} <- Sealed.open(sealed, token_hash, job_id, :secrets),
         {:ok, %{} = secrets} <- Jason.decode(json),
         true <- Enum.all?(secrets, fn {name, value} -> is_binary(name) and is_binary(value) end) do
      {:ok, secrets}
    else
      _unopened -> :error
    end
  end

  @doc """
  Whether a job may start: its secrets open, or it has none. A job that names a secret and cannot
  read it does not run without it — it fails here, before anything is spawned.
  """
  @spec check(t() | nil) :: :ok | {:error, :secrets_unopened}
  def check(secrets) do
    case open(secrets) do
      {:ok, _secrets} -> :ok
      :error -> {:error, :secrets_unopened}
    end
  end

  @doc """
  The environment entries for a spawn: `{name, {:secret, value}}` for every name the job may be
  given, which the runner and a command put in the process's environment and never its arguments.
  A reserved name, or one no secret could have, is left out and said once in the machine's log.
  """
  @spec env(t() | nil) :: [{String.t(), {:secret, String.t()}}]
  def env(nil), do: []

  def env(%__MODULE__{job_id: job_id} = secrets) do
    case open(secrets) do
      {:ok, opened} ->
        {allowed, refused} =
          Enum.split_with(opened, fn {name, _value} ->
            ForgeCore.Secret.validate_name(name) == :ok
          end)

        refuse(refused, job_id)
        Enum.map(allowed, fn {name, value} -> {name, {:secret, value}} end)

      :error ->
        Log.line("secrets.unopened", :error, "the job's secrets would not open; none were set",
          job_id: job_id
        )

        []
    end
  end

  defp refuse([], _job_id), do: :ok

  defp refuse(refused, job_id) do
    names = Enum.map_join(refused, ", ", fn {name, _value} -> name end)

    Log.line(
      "secrets.refused",
      :error,
      "#{names} may not be a secret's name and was not set: a job's environment needs it",
      job_id: job_id
    )
  end

  @doc """
  `term` with every value of `secrets` replaced by `[secret NAME]`, in every binary it contains —
  a string, or the strings in a list, a tuple, or a map's keys and values, however deep. A struct
  is left as it is: nothing a job writes arrives as one.
  """
  @spec mask(t() | nil, term()) :: term()
  def mask(nil, term), do: term

  def mask(secrets, term) do
    case replacements(secrets) do
      [] -> term
      replacements -> mask_term(term, Enum.map(replacements, &compile/1))
    end
  end

  @doc "`event` with its payload masked: what a harness event carries out to the platform."
  @spec mask_event(t() | nil, map()) :: map()
  def mask_event(nil, event), do: event

  def mask_event(secrets, %{payload: payload} = event),
    do: %{event | payload: mask(secrets, payload)}

  @doc """
  Masks the file at `path` in place, before it is uploaded. Read and written whole: the files
  this is for — a transcript, a session, a command's log — are the job's own and bounded by its
  run, and a value split across two reads of a stream is the kind of value masking does not
  claim to catch anyway.
  """
  @spec mask_file(t() | nil, String.t() | nil) :: :ok
  def mask_file(nil, _path), do: :ok
  def mask_file(_secrets, nil), do: :ok

  def mask_file(secrets, path) do
    with {:ok, contents} <- File.read(path),
         masked when masked != contents <- mask(secrets, contents) do
      File.write!(path, masked)
    end

    :ok
  end

  # Each value and, where they differ, its JSON-escaped forms — a value with a quote, a backslash or
  # a line break is written escaped in an event or a transcript line — each pointing at its name.
  # Two escaped forms, because a control character is `\u001B` from Jason and `\u001b` from the
  # harness's own JSON (Node's and Bun's), and a transcript line is the harness's.
  defp replacements(secrets) do
    case open(secrets) do
      {:ok, opened} ->
        Enum.flat_map(opened, fn {name, value} ->
          encoded = Jason.encode!(value)
          escaped = binary_part(encoded, 1, byte_size(encoded) - 2)
          lower = Regex.replace(~r/\\u[0-9A-F]{4}/, escaped, &String.downcase/1)
          Enum.uniq([{value, name}, {escaped, name}, {lower, name}])
        end)

      :error ->
        []
    end
  end

  defp compile({value, name}), do: {:binary.compile_pattern(value), name}

  # **Every match of every value, then the spans they cover.** One combined pattern took the
  # longest match at each place and moved on, so where two values overlapped without one holding
  # the other the second's tail was left in the clear. Each value is found on its own, overlapping
  # matches are merged into one span, and the span is named by every value in it that is not
  # inside a longer one — so a value that contains another is still named once, and two secrets
  # holding the same value are both named.
  defp mask_term(text, compiled) when is_binary(text) do
    case for(
           {pattern, name} <- compiled,
           {at, length} <- :binary.matches(text, pattern),
           do: {at, at + length, name}
         ) do
      [] -> text
      matches -> matches |> Enum.sort() |> spans([]) |> splice(text, 0, [])
    end
  end

  defp mask_term(list, compiled) when is_list(list), do: Enum.map(list, &mask_term(&1, compiled))

  defp mask_term(tuple, compiled) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> mask_term(compiled) |> List.to_tuple()

  defp mask_term(%_{} = struct, _compiled), do: struct

  defp mask_term(%{} = map, compiled),
    do:
      Map.new(map, fn {key, value} -> {mask_term(key, compiled), mask_term(value, compiled)} end)

  defp mask_term(other, _compiled), do: other

  # Sorted matches into spans: one that starts inside the current span extends it.
  defp spans([], acc), do: Enum.reverse(acc)

  defp spans([{from, to, _name} = match | rest], [{span_from, span_to, matches} | acc])
       when from < span_to,
       do: spans(rest, [{span_from, max(to, span_to), [match | matches]} | acc])

  defp spans([{from, to, _name} = match | rest], acc),
    do: spans(rest, [{from, to, [match]} | acc])

  defp splice([], text, at, acc),
    do: IO.iodata_to_binary(Enum.reverse([binary_part(text, at, byte_size(text) - at) | acc]))

  defp splice([{from, to, matches} | rest], text, at, acc),
    do: splice(rest, text, to, [label(matches), binary_part(text, at, from - at) | acc])

  defp label(matches) do
    matches
    |> Enum.reject(fn {from, to, _name} ->
      Enum.any?(matches, fn {f, t, _n} -> f <= from and to <= t and t - f > to - from end)
    end)
    |> Enum.sort()
    |> Enum.map_join(fn {_from, _to, name} -> "[secret #{name}]" end)
  end
end
