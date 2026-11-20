defmodule ForgeWeb.Blob do
  @moduledoc """
  One file at one commit, read to be drawn whole: the repository's file screen
  (`docs/design/ui.md` § The project's repository) and the whole file a ticket's Changes opens
  (§ Changes) both read through `read/3`, so the two have one bound and one rule for what is text.

  **Bounded before it is read.** The size is asked of git first (`Forge.Git.blob_size/3`) and the
  content read only when the size allows it, so a file at or over 512 KB says so and never passes
  through the page's process on the way to being refused. One file is what a page holds, so that
  bound is the whole of what it holds.

  **Text means `ForgeCore.Document.text?/1`** — valid UTF-8 with no NUL, over the whole file — and
  not git's own sniff: what is drawn goes out as JSON over the socket, and a byte that is not
  UTF-8 there makes the serializer raise in the socket's own process. A file that is text is
  highlighted here, once, where it is read (`ForgeWeb.Highlight.file/2`), never in a template that
  is drawn again on every patch.

  Read out of the commit's tree and nowhere else, so a path is git's and never the filesystem's:
  `..` in one matches nothing in a tree and is `:missing` like any other typo.
  """

  alias Forge.Git
  alias Forge.Git.Lfs.Pointer
  alias ForgeWeb.Highlight

  @max_bytes 512 * 1024

  @typedoc "What `read/3` found: the lines to draw, or what the file is instead."
  @type t ::
          {:text, Highlight.lines(), non_neg_integer()}
          | {:lfs, non_neg_integer()}
          | {:too_large, non_neg_integer()}
          | :binary
          | :missing

  @doc """
  The whole of `path` at `commit`: `{:text, lines, bytes}` highlighted, `{:lfs, size}` for a blob under
  1024 bytes that is a valid Git LFS pointer — the size of the object it stands for, the pointer's
  own text never drawn — `{:too_large, bytes}` at or over 512 KB, `:binary` for bytes that are not text, and `:missing` for anything git cannot read there —
  no commit, a path not in that tree, a directory, a path out of it.
  """
  @spec read(String.t(), String.t() | nil, String.t()) :: t()
  def read(_repo, nil, _path), do: :missing

  def read(repo, commit, path) do
    case Git.blob_size(repo, commit, path) do
      {:ok, bytes} when bytes >= @max_bytes -> {:too_large, bytes}
      {:ok, bytes} -> content(Git.show(repo, commit, path), path, bytes)
      {:error, :not_found} -> :missing
    end
  end

  defp content({:ok, text}, path, bytes) do
    case Pointer.parse(text) do
      {:ok, %{size: size}} -> {:lfs, size}
      :error -> plain(text, path, bytes)
    end
  end

  # `blob_size/3` has just answered for this exact path at this exact commit, so a `show/3` that
  # then cannot find it is a repository rewritten between two reads. Here rather than left to
  # crash the page; no test can open that window, and its removal is an equivalent mutant.
  defp content({:error, :not_found}, _path, _bytes), do: :missing

  defp plain(text, path, bytes) do
    if ForgeCore.Document.text?(text),
      do: {:text, Highlight.file(path, text), bytes},
      else: :binary
  end

  @doc """
  What a Git LFS file is called wherever one is drawn: `LFS · 2.3 MB`, or with two sizes
  `LFS · 1.1 MB → 1.4 MB`, and with one side nil — added, removed — the size that is there.
  """
  @spec lfs_label(non_neg_integer() | nil, non_neg_integer() | nil) :: String.t()
  def lfs_label(old, new) when is_integer(old) and is_integer(new),
    do: "LFS · #{size_label(old)} → #{size_label(new)}"

  def lfs_label(old, nil) when is_integer(old), do: "LFS · #{size_label(old)}"
  def lfs_label(nil, new) when is_integer(new), do: "LFS · #{size_label(new)}"

  @spec lfs_label(non_neg_integer()) :: String.t()
  def lfs_label(size), do: lfs_label(nil, size)

  @doc "A size the way the pages say one: `812 B`, `3 KB`, `2.3 MB`, `1.1 GB`."
  @spec size_label(non_neg_integer()) :: String.t()
  def size_label(n) when n < 1024, do: "#{n} B"
  def size_label(n) when n < 1_048_576, do: "#{trim(n / 1024)} KB"
  def size_label(n) when n < 1_073_741_824, do: "#{trim(n / 1_048_576)} MB"
  def size_label(n), do: "#{trim(n / 1_073_741_824)} GB"

  defp trim(float) do
    rounded = Float.round(float, 1)

    if rounded == trunc(rounded),
      do: Integer.to_string(trunc(rounded)),
      else: Float.to_string(rounded)
  end

  @doc "The bound, in bytes: a file this size or larger is not drawn."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  What a page says in place of a file `read/3` found too large, in one wording for every page
  that reads through it (Changes and the repository): its size, the bound, and that git is where
  to read it, since no page here will.
  """
  @spec too_large(String.t(), non_neg_integer()) :: String.t()
  def too_large(path, bytes),
    do:
      "#{path} is #{div(bytes, 1024)} KB; this page draws a file under " <>
        "#{div(@max_bytes, 1024)} KB. Read it with git."
end
