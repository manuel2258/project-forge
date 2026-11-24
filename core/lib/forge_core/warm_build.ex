defmodule ForgeCore.WarmBuild do
  @moduledoc """
  The words for a ticket's **warm build**: where a command's tree came from, and whether what it
  built was kept for the ticket's next command (`docs/design/worker-tier.md` § The command copy).

  They live in core because three places say them and must agree: the worker writes the first and
  last line of a command's log, the platform draws the same facts on a command's page and over the
  API, and the platform checks what a worker reports against `sources/0` and `reasons/0` before it
  stores a word it has never heard of.

  A command's `warm` fact, as the worker reports it in `ForgeCore.Job.Result`:
  `%{"source" => one of sources/0, "from" => the job that left the copy, when source is "copy",
  "kept" => boolean, "unkept" => one of reasons/0 when not kept, "size" => bytes of a kept copy}`.
  """

  # Where a command's tree came from: this ticket's command copy, its ticket volume, the project's
  # seed, a fresh clone.
  @sources ~w(copy ticket seed clone)

  # Why a build was not kept. `keeps_nothing`: the command declares no `keep_build`. `status`: the
  # script's exit status is not one it lists. `timeout`, `cancelled`, `killed`: it did not end on
  # its own. `failed`: keeping it failed on the machine. `not_run`: the script never ran.
  # `not_a_ticket`: the branch is not a `ticket/<n>`, so a conversation's command keeps nothing.
  @reasons ~w(keeps_nothing status timeout cancelled killed failed not_run not_a_ticket)

  @sentences %{
    "keeps_nothing" => "the command keeps nothing",
    "status" => "its exit status is not one the command keeps",
    "timeout" => "it was stopped by its timeout",
    "cancelled" => "it was cancelled",
    "killed" => "it was killed",
    "failed" => "keeping it failed on the machine",
    "not_run" => "the script did not run",
    "not_a_ticket" => "it is not a ticket's command"
  }

  @doc "Where a tree can come from."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc "Why a build was not kept."
  @spec reasons() :: [String.t()]
  def reasons, do: @reasons

  @doc "The sentence a command's page and the API's readers see while it waits for the warm machine."
  @spec wait_sentence() :: String.t()
  def wait_sentence do
    "Waiting for the machine that holds this ticket's warm build: up to two minutes, " <>
      "then any machine with room."
  end

  @doc "What the ticket page says when the ticket has no usable copy."
  @spec no_copy_sentence() :: String.t()
  def no_copy_sentence,
    do: "No warm build yet: the first command that keeps its build leaves one."

  @doc """
  Where a tree came from, as a phrase: `"this ticket's warm build"`, `"the ticket's volume"`, `"the
  project's seed"`, `"a fresh clone"`. Nil for a word that is not a source.
  """
  @spec source_phrase(term()) :: String.t() | nil
  def source_phrase("copy"), do: "this ticket's warm build"
  def source_phrase("ticket"), do: "the ticket's volume"
  def source_phrase("seed"), do: "the project's seed"
  def source_phrase("clone"), do: "a fresh clone"
  def source_phrase(_other), do: nil

  @doc "The first line of a command's log. `from` is the job that left the copy, for \"copy\"."
  @spec source_line(String.t(), String.t() | nil) :: String.t()
  def source_line("copy", from) when is_binary(from),
    do: "forge: started from this ticket's warm build, left by job #{from}"

  def source_line(source, _from) do
    "forge: started from #{source_phrase(source) || "an unknown source"}"
  end

  @doc "The sentence for a reason a build was not kept; the word itself for one it does not know."
  @spec reason_sentence(term()) :: String.t()
  def reason_sentence(reason), do: Map.get(@sentences, reason, to_string(reason))

  @doc "The last line of a command's log: kept as the ticket's warm build, or not and why."
  @spec kept_line(boolean(), String.t() | nil) :: String.t()
  def kept_line(true, _reason), do: "forge: kept this build as the ticket's warm build"

  def kept_line(false, reason),
    do: "forge: did not keep this build as the ticket's warm build: #{reason_sentence(reason)}"

  @doc """
  A worker's `warm` report, cleaned: only the keys this module knows, a source and a reason that are
  in the lists, a boolean `kept`. Nil when there is nothing in it to store, so a result from a
  worker that does not report one leaves every fact empty.
  """
  @spec sanitize(term()) :: map() | nil
  def sanitize(%{} = warm) do
    kept = Map.get(warm, "kept")

    cleaned = %{
      "source" => known(Map.get(warm, "source"), @sources),
      "kept" => if(is_boolean(kept), do: kept)
    }

    cleaned =
      Map.merge(cleaned, %{
        "from" => from(cleaned["source"], Map.get(warm, "from")),
        "unkept" => if(kept == false, do: known(Map.get(warm, "unkept"), @reasons)),
        "size" => if(kept == true, do: size(Map.get(warm, "size")))
      })

    if Enum.all?(cleaned, fn {_key, value} -> is_nil(value) end), do: nil, else: cleaned
  end

  def sanitize(_other), do: nil

  defp known(value, allowed), do: if(value in allowed, do: value)
  defp from("copy", from) when is_binary(from), do: from
  defp from(_source, _from), do: nil
  defp size(size) when is_integer(size) and size >= 0, do: size
  defp size(_size), do: nil
end
