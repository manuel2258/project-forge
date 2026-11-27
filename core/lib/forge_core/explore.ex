defmodule ForgeCore.Explore do
  @moduledoc """
  What the platform and a worker share about **looking into a ticket's command copy**
  (`docs/design/worker-tier.md` § Looking into a copy, ticket 84): the limits both sides apply,
  and the words an answer's error is one of, with the sentence a person reads for each.

  The worker answers an `explore` message with `{"ok" => …}` or `{"error" => code}`; the platform
  adds the codes that are about the machine and not the copy (`machine_*`, `copy_gone`), and both
  say them over the JSON API as `error`.
  """

  # The size of a folder's page, and how much of a text file is read: criteria 13 and 15.
  @page_size 200
  @text_limit 1_048_576
  # How long the machine keeps a copy as it was after the last action on it, and how long the
  # platform waits for any word from it: criteria 5 and 19.
  @hold_ms 600_000
  # The lines of one command's live output the platform holds, and so all a worker resends.
  @max_live_lines 20_000
  @answer_ms 15_000

  @ops ~w(list file hash download)

  # What the worker says about a path or a copy; the first four are the worker's own words.
  @worker_errors ~w(no_copy path_refused path_not_found not_a_folder not_a_file failed)
  # What the platform adds.
  @platform_errors ~w(machine_not_answering machine_not_connected machine_outdated copy_gone not_text)

  @sentences %{
    "no_copy" => "This copy is no longer on the machine",
    "path_refused" => "That path is not one inside the copy",
    "path_not_found" => "Nothing is there",
    "not_a_folder" => "That is not a folder",
    "not_a_file" => "That is not a file",
    "failed" => "The machine could not read it",
    "machine_not_answering" => "The machine did not answer in 15 seconds",
    "machine_not_connected" => "The machine is not connected",
    "machine_outdated" => "The machine runs an older release: update it to explore this copy",
    "copy_gone" => "This copy is no longer there",
    "not_text" => "That file is not text"
  }

  @doc "Entries in a page of a folder."
  @spec page_size() :: pos_integer()
  def page_size, do: @page_size

  @doc "Bytes of a text file shown or returned."
  @spec text_limit() :: pos_integer()
  def text_limit, do: @text_limit

  @doc "Lines of a running command's output the platform holds, and a worker keeps to resend."
  @spec max_live_lines() :: pos_integer()
  def max_live_lines, do: @max_live_lines

  @doc "Milliseconds a copy is held after the last action on it."
  @spec hold_ms() :: pos_integer()
  def hold_ms, do: @hold_ms

  @doc "Milliseconds without any word from the machine before it counts as not answering."
  @spec answer_ms() :: pos_integer()
  def answer_ms, do: @answer_ms

  @doc "What may be asked of a machine."
  @spec ops() :: [String.t()]
  def ops, do: @ops

  @doc "The words a worker may answer with."
  @spec worker_errors() :: [String.t()]
  def worker_errors, do: @worker_errors

  @doc "Every error word."
  @spec errors() :: [String.t()]
  def errors, do: @worker_errors ++ @platform_errors

  @doc "The sentence for an error word, the word itself for one that is not."
  @spec sentence(term()) :: String.t()
  def sentence(code) do
    code = if is_atom(code), do: Atom.to_string(code), else: code
    Map.get(@sentences, code, to_string(code))
  end

  @doc """
  Whether `path` is one a worker will resolve: a string with no NUL, no empty component but
  the root, no `.` and no `..`, and not absolute. `""` is the copy's root. The worker checks
  again against the filesystem; this is the shape, which both sides agree on
  (`CLAUDE.md` § Rules: the guard that matters is the one the machine makes with `lstat`).
  """
  @spec path_ok?(term()) :: boolean()
  def path_ok?(""), do: true

  def path_ok?(path) when is_binary(path) do
    # An equivalent mutant: an absolute path splits to an empty first component, which the check
    # below already refuses. This clause says so where it reads, and no test can tell it from that.
    not String.contains?(path, <<0>>) and
      not String.starts_with?(path, "/") and
      Enum.all?(:binary.split(path, "/", [:global]), &(&1 not in ["", ".", ".."]))
  end

  def path_ok?(_other), do: false

  @doc "A path's components. Only for a path `path_ok?/1` accepts."
  @spec components(String.t()) :: [String.t()]
  def components(""), do: []
  def components(path), do: :binary.split(path, "/", [:global])
end
