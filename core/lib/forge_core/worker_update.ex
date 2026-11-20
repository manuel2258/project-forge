defmodule ForgeCore.WorkerUpdate do
  @moduledoc """
  What a permanent machine and the platform agree an update is: the step names, the limits, the
  target's shape, and what each side does with a report it was sent
  (`docs/design/worker-tier.md` § Updating a permanent machine, protocol 13 in
  `docs/design/worker-channel.md`). **One definition, used by both sides**, so the worker and the
  platform cannot disagree on how many tries there are or what a step is called.

  **The report and target readers raise on nothing they are given.** A report is whatever some release pushed and the
  platform keeps it in a jsonb column that every later mount of the workers page reads again, so a
  value of the wrong type that got through once would take the page down for good — the
  `harness_text/1` lesson. `normalise/1` and `normalise_disk/1` keep the keys they know, with the
  type they expect, and drop the rest.
  """

  @steps ~w(downloading installing pausing restarting trying failed fell_back gave_up kept)

  # The reasons a machine gives for *not even trying*, as codes the page turns into sentences:
  # the old boot layout, and a worker that does not run on the forge image at all (a development
  # node's, started by hand).
  @reasons ~w(layout not_an_image)

  @tries 3
  # What follows the first failure and the second; the third is the last.
  @retry_ms [15 * 60_000, 60 * 60_000]
  @trial_ms 15 * 60_000
  @pause_ms 30 * 60_000

  @text_limit 500
  @id_limit 200
  @kinds ~w(nix_store volumes seeds jobs rest)
  @rules ~w(nix_store volumes seeds jobs)

  @doc "The steps a report may name, in the order an update goes through them."
  @spec steps() :: [String.t()]
  def steps, do: @steps

  @doc "The codes a machine gives for an update it will not attempt."
  @spec reasons() :: [String.t()]
  def reasons, do: @reasons

  @doc "How many attempts a platform build gets before the machine stops trying it."
  @spec tries() :: pos_integer()
  def tries, do: @tries

  @doc """
  Milliseconds to wait after the `failures`-th failure of one build before the next try: 15
  minutes after the first, an hour after the second, and nil after the third — it has given up.
  """
  @spec retry_after_ms(pos_integer()) :: pos_integer() | nil
  def retry_after_ms(failures) when is_integer(failures) and failures >= 1,
    do: Enum.at(@retry_ms, failures - 1)

  @doc "How long a new system has, from its boot, to be accepted by the platform: 15 minutes."
  @spec trial_ms() :: pos_integer()
  def trial_ms, do: @trial_ms

  @doc "How long a machine waits for its jobs to hibernate before it restarts: 30 minutes."
  @spec pause_ms() :: pos_integer()
  def pause_ms, do: @pause_ms

  @doc "The kinds of disk use a report names, in the order they are drawn."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "The cleanup rules whose last run a report names."
  @spec rules() :: [String.t()]
  def rules, do: @rules

  @doc """
  A target as the platform sends it, or `:error` when anything about it is not what a release
  publishes: a 12-character build, a version, the repository, the layer's digest and the raw
  disk's checksum and size. The worker checks these shapes before it passes any of them to a
  script, and the script checks the repository against its own again — **a value that came from
  the platform is never trusted for where to download from.**
  """
  @spec target(term()) :: {:ok, map()} | :error
  def target(%{} = raw) do
    with build when is_binary(build) <- field(raw, :build),
         true <- build =~ ~r/\A[a-z0-9]{12}\z/,
         version when is_binary(version) <- field(raw, :version),
         {:ok, _version} <- Version.parse(version),
         repository when is_binary(repository) <- field(raw, :repository),
         true <- repository =~ ~r{\A[a-z0-9][a-z0-9._-]*(:[0-9]+)?(/[a-z0-9._-]+)+\z},
         digest when is_binary(digest) <- field(raw, :digest),
         true <- digest =~ ~r/\Asha256:[0-9a-f]{64}\z/,
         sha when is_binary(sha) <- field(raw, :raw_sha256),
         true <- sha =~ ~r/\A[0-9a-f]{64}\z/,
         size when is_integer(size) and size > 0 <- field(raw, :raw_size) do
      {:ok,
       %{
         "build" => build,
         "version" => version,
         "repository" => repository,
         "digest" => digest,
         "raw_sha256" => sha,
         "raw_size" => size
       }}
    else
      _invalid -> :error
    end
  end

  def target(_other), do: :error

  @doc """
  An update report the machine sent, cleaned: the known keys with the type each should have, and
  nothing else. Text is clipped; a number outside `0..2^53` or a string where a number belongs is
  left out rather than raised on.
  """
  @spec normalise(term()) :: map()
  def normalise(%{} = raw) do
    %{}
    |> put_step(raw)
    |> put_text(raw, :target_build, 64)
    |> put_text(raw, :target_version, 64)
    |> put_text(raw, :from_version, 64)
    |> put_text(raw, :reason, @text_limit)
    |> put_text(raw, :failed_step, 64)
    |> put_text(raw, :requested_by, 200)
    |> put_count(raw, :attempt)
    |> put_count(raw, :next_at)
    # The machine's own clock when it said so: the platform dates what it reports by its own, from
    # the difference (`Forge.Workers.Updates.record/2`).
    |> put_count(raw, :at)
    |> put_ids(raw, :jobs)
    |> put_ids(raw, :chats)
    |> put_flag(raw, :automatic)
    |> put_unable(raw)
  end

  def normalise(_other), do: %{}

  @doc """
  A disk report, cleaned the same way: `at` and, per kind in `kinds/0`, a byte count; per rule in
  `rules/0`, when it last ran and what it freed. Empty when there is nothing usable, which the
  page reads as *not measured yet*.
  """
  @spec normalise_disk(term()) :: map()
  def normalise_disk(%{} = raw) do
    kinds =
      for kind <- @kinds, bytes = count(field(field(raw, :kinds), kind)), into: %{} do
        {kind, bytes}
      end

    cleanups =
      for rule <- @rules,
          %{} = entry <- [field(field(raw, :cleanups), rule)],
          at = count(field(entry, :at)),
          freed = count(field(entry, :freed)),
          into: %{} do
        {rule, %{"at" => at, "freed" => freed}}
      end

    if kinds == %{} do
      %{}
    else
      %{"kinds" => kinds, "cleanups" => cleanups} |> put_count(raw, :at)
    end
  end

  def normalise_disk(_other), do: %{}

  # A key may arrive as a string (the wire) or an atom (a test, a caller in this node).
  defp field(%{} = map, key) when is_atom(key),
    do: Map.get(map, Atom.to_string(key), Map.get(map, key))

  defp field(%{} = map, key) when is_binary(key), do: Map.get(map, key)
  defp field(_other, _key), do: nil

  defp put_step(map, raw) do
    case field(raw, :step) do
      step when step in @steps -> Map.put(map, "step", step)
      _unknown -> map
    end
  end

  defp put_text(map, raw, key, limit) do
    case field(raw, key) do
      text when is_binary(text) ->
        if String.valid?(text),
          do: Map.put(map, Atom.to_string(key), text |> String.slice(0, limit)),
          else: map

      _other ->
        map
    end
  end

  defp put_count(map, raw, key) do
    case count(field(raw, key)) do
      nil -> map
      number -> Map.put(map, Atom.to_string(key), number)
    end
  end

  defp put_flag(map, raw, key) do
    case field(raw, key) do
      flag when is_boolean(flag) -> Map.put(map, Atom.to_string(key), flag)
      _other -> map
    end
  end

  # Why the machine cannot update at all: only a code this module names, so a sentence the page
  # draws from it is one this repository wrote.
  defp put_unable(map, raw) do
    case field(raw, :unable) do
      reason when reason in @reasons -> Map.put(map, "unable", reason)
      _other -> map
    end
  end

  defp put_ids(map, raw, key) do
    case field(raw, key) do
      ids when is_list(ids) ->
        ids =
          ids
          |> Enum.filter(&(is_binary(&1) and String.valid?(&1)))
          |> Enum.map(&String.slice(&1, 0, @id_limit))
          |> Enum.take(500)

        Map.put(map, Atom.to_string(key), ids)

      _other ->
        map
    end
  end

  defp count(value) when is_integer(value) and value >= 0 and value <= 9_007_199_254_740_992,
    do: value

  defp count(_other), do: nil
end
