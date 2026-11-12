defmodule Forge.ForgeRelease do
  @moduledoc """
  The forge release a project records it was last brought up to: `.forge/forge-release`
  (`docs/design/changelog.md` § The recorded release).

  **Read from git's object store at one commit and never from a checkout.** A symlink committed at
  the path is a blob whose content is its target, so it reads as that text and is not a release;
  following it would read whatever it points at. The read is bounded by asking the blob's size
  first: a file over the bound is never read.
  """

  alias Forge.{Changelog, Git}

  @path ".forge/forge-release"

  # The bound ticket-types.md § Releases gives a version in a release note's front matter.
  @max_bytes 64

  # How much of what the file holds is quoted back to a person.
  @quote_graphemes 40

  @typedoc "What the file holds, before it is judged."
  @type read :: :none | {:ok, binary()} | :too_large

  @typedoc "The five cases the project page draws (`ui.md` § The project page)."
  @type status ::
          :not_recorded
          | :current
          | {:behind, String.t()}
          | {:newer, String.t()}
          | {:not_release, String.t() | :too_large}

  @doc "Where a project records its forge release, relative to the repository."
  @spec path() :: String.t()
  def path, do: @path

  @doc "The most bytes of the file that are read; a larger one is not a release."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  The file's content at `sha`, or why there is none.

  `:none` for a missing path and for anything at it that is not a blob (`Git.blob_size/3` refuses a
  directory and a submodule), `:too_large` above the bound.
  """
  @spec read(Git.repo(), Git.sha()) :: read()
  def read(repo, sha) do
    case Git.blob_size(repo, sha, @path) do
      {:ok, size} when size > @max_bytes ->
        :too_large

      {:ok, _size} ->
        # `{:error, _} -> :none` is an equivalent mutant (`{:ok, ""}` would read as not a release
        # instead): it is reachable only if the blob vanishes between `blob_size/3` and this read,
        # which a test cannot arrange.
        case Git.show(repo, sha, @path) do
          {:ok, bytes} -> {:ok, bytes}
          {:error, _} -> :none
        end

      {:error, _} ->
        :none
    end
  end

  @doc """
  Judges what was read against the releases the changelog knows and the one the node runs, by the
  rule in `docs/design/changelog.md` § The one list. The two lists are arguments so a test can run
  the rule over a list of its own.
  """
  @spec status(read(), [String.t()], String.t()) :: status()
  def status(read, releases \\ Changelog.releases(), running \\ Changelog.running())

  def status(:none, _releases, _running), do: :not_recorded
  def status(:too_large, _releases, _running), do: {:not_release, :too_large}

  def status({:ok, bytes}, releases, running) do
    case parse(bytes) do
      nil ->
        {:not_release, quote_of(bytes)}

      version ->
        cond do
          newer?(version, running) -> {:newer, version}
          version not in releases -> {:not_release, quote_of(bytes)}
          version == running -> :current
          true -> {:behind, version}
        end
    end
  end

  # `N.N.N` after trimming whitespace, as a tuple that orders numerically. Nothing else is a version
  # here: not `v0.17.0`, not `0.17`, not `0.17.0-rc1`.
  defp parse(bytes) do
    trimmed = String.trim(bytes)

    # Two equivalent mutants live here, so no test is written for them: `String.valid?/1` is
    # implied by the match (bytes that are not valid UTF-8 are not `\d` or `.` either), and `\z` and
    # `$` differ only before a trailing newline, which `String.trim/1` has already removed.
    if String.valid?(trimmed) and trimmed =~ ~r/\A\d+\.\d+\.\d+\z/, do: trimmed
  end

  defp newer?(version, running), do: key(version) > key(running)

  defp key(version),
    do: version |> String.split(".") |> Enum.map(&String.to_integer/1) |> List.to_tuple()

  # What a person is shown of a value that is not a release: invalid UTF-8 replaced, control
  # characters and newlines collapsed to spaces, and cut short. The template escapes it; nothing
  # here makes it markup.
  defp quote_of(bytes) do
    text =
      bytes
      |> String.replace_invalid()
      |> String.replace(~r/[[:cntrl:]]+/u, " ")
      |> String.trim()

    if String.length(text) > @quote_graphemes,
      do: String.slice(text, 0, @quote_graphemes) <> "…",
      else: text
  end
end
