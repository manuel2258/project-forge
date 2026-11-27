defmodule ForgeCore.CommandSteps do
  @moduledoc """
  The steps of a command's run on a machine, in the order the worker takes them
  (`docs/design/worker-tier.md` § Looking into a copy, ticket 84).

  They live in core because three places say them and must agree: the worker times them, the
  platform keeps one `command.step` event for each and draws them on a command's page, and the
  platform checks what a worker reports against `names/0` and `skip_reasons/0` before it stores
  a word it has never heard of.

  A step as the worker reports it, and as the platform stores it in an event's payload:
  `%{"name" => one of names/0, "at" => wall clock in ms, "ms" => how long}`, or
  `%{"name" => …, "skipped" => one of skip_reasons/0}` for a step that did not happen — **never a
  zero**. The snapshot also carries `"source"`, one of `ForgeCore.WarmBuild.sources/0`. `other` is
  the whole run's time less the others, so the steps add up to the command's time on the machine
  by construction.
  """

  alias ForgeCore.WarmBuild

  @names ~w(snapshot fetch reset own devshell script ignored hand_back keep upload discard sweep other)

  # Why a step did not happen, besides the reasons a build is not kept (`ForgeCore.WarmBuild`),
  # which `keep` and `ignored` skip with.
  # `no_source`: a clone has no snapshot to take. `no_env`: the command runs without a devshell.
  # `unmeasured`: the devshell and the script could not be told apart, so `script` has both.
  # `not_run`: the script never ran. `not_kept`: nothing is kept, so nothing is listed as ignored.
  @skip_reasons ~w(no_source no_env unmeasured not_run not_kept)

  @labels %{
    "snapshot" => "Taking the snapshot to start from",
    "fetch" => "Fetching the command's commit",
    "reset" => "Resetting the tree to it",
    "own" => "Giving the tree to the job's user",
    "devshell" => "Starting the devshell",
    "script" => "Running the script",
    "ignored" => "Listing what git ignores",
    "hand_back" => "Handing the tree back",
    "keep" => "Keeping it as the ticket's warm build",
    "upload" => "Uploading the log and the files",
    "discard" => "Removing the working tree",
    "sweep" => "Sweeping old copies",
    "other" => "Other"
  }

  @skip_sentences %{
    "no_source" => "no copy to start from",
    "no_env" => "no devshell",
    "unmeasured" => "not measured on its own: it is counted in the script",
    "not_run" => "the script did not run",
    "not_kept" => "nothing kept"
  }

  # More than the steps there are, so a worker that repeats one is bounded rather than refused.
  @max 20

  @doc "The steps, in the order a command takes them; `other` last."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc "Why a step may be skipped."
  @spec skip_reasons() :: [String.t()]
  def skip_reasons, do: @skip_reasons ++ WarmBuild.reasons()

  @doc "What a step is called on a page."
  @spec label(term()) :: String.t()
  def label(name), do: Map.get(@labels, name, to_string(name))

  @doc """
  The sentence for a skipped step's reason: *no copy to start from*, *nothing kept*. A build's
  reason for not being kept reads as *nothing kept*, which is the whole of what a step has to say
  about it; the reason itself is `ForgeCore.WarmBuild.reason_sentence/1`'s.
  """
  @spec skip_sentence(term()) :: String.t()
  def skip_sentence(reason) do
    cond do
      Map.has_key?(@skip_sentences, reason) -> Map.fetch!(@skip_sentences, reason)
      reason in WarmBuild.reasons() -> "nothing kept: " <> WarmBuild.reason_sentence(reason)
      true -> to_string(reason)
    end
  end

  @doc """
  A worker's `steps`, cleaned: only the names this module knows, at most #{@max} entries, whole
  numbers of zero or more, a skip reason that is in the list, a source that is one. A step that
  has neither a duration nor a skip is dropped. `nil` when nothing is left, so a worker that
  reports none leaves every step unrecorded.
  """
  @spec sanitize(term()) :: [map()] | nil
  def sanitize(steps) when is_list(steps) do
    case steps |> Enum.take(@max) |> Enum.flat_map(&step/1) do
      [] -> nil
      cleaned -> cleaned
    end
  end

  def sanitize(_other), do: nil

  defp step(%{"name" => name} = step) when name in @names do
    at = whole(Map.get(step, "at"))

    case {Map.get(step, "skipped"), whole(Map.get(step, "ms"))} do
      {reason, _ms} when is_binary(reason) ->
        if reason in skip_reasons(),
          do: [name |> base(at, step) |> Map.put("skipped", reason)],
          else: []

      {_none, ms} when is_integer(ms) ->
        [name |> base(at, step) |> Map.put("ms", ms)]

      _neither ->
        []
    end
  end

  defp step(_other), do: []

  defp base(name, at, step) do
    base = if at, do: %{"name" => name, "at" => at}, else: %{"name" => name}

    if name == "snapshot" and Map.get(step, "source") in WarmBuild.sources(),
      do: Map.put(base, "source", step["source"]),
      else: base
  end

  defp whole(value) when is_integer(value) and value >= 0, do: value
  defp whole(_value), do: nil

  @doc """
  The step that took longest, by name, or nil when none has a duration: what a page emphasises.
  `other` never is: it is what is left, not a step anyone can shorten.
  """
  @spec longest([map()]) :: String.t() | nil
  def longest(steps) do
    steps
    |> Enum.filter(&(is_integer(&1["ms"]) and &1["name"] != "other"))
    |> Enum.max_by(& &1["ms"], fn -> nil end)
    |> case do
      nil -> nil
      step -> step["name"]
    end
  end

  @doc "The sum of the durations: the command's whole time on the machine, when `other` is in."
  @spec total([map()]) :: non_neg_integer()
  def total(steps), do: steps |> Enum.map(&(&1["ms"] || 0)) |> Enum.sum()
end
