defmodule Forge.Git.Lfs.Pointer do
  @moduledoc """
  Reads a Git LFS pointer the way git-lfs's own decoder does, so a page shows as LFS what `git lfs`
  would read as a pointer and shows anything else as the file it is. **By content alone**: a page
  draws any valid pointer as LFS whatever the repository's attributes say, where the push guard goes
  by the paths whose attributes send them through the filter. One shape differs, on purpose left
  alone: a pointer with `ext-N-…` lines *before* `version`, which `git lfs pointer --check` accepts
  and this does not; it takes crafted content, and the result is a file drawn as text.

  **Used by the pages, never by a guard.** A guard has to use the smudge's own model — the attributes
  asked of git, and the pointer read by something that cannot be told a path is a line — which is
  what `pre-receive` does; this is for drawing a size next to a name, and it is checked against `git lfs pointer --check` over a table of shapes in its test. What it
  accepts: a blob under 1024 bytes, whitespace trimmed from both ends, blank lines ignored, a
  `version` line first with one of the three URLs git-lfs knows, then any `ext-N-name` lines, then
  `oid sha256:<64 lowercase hex>`, then `size <n>`, and nothing after. A key out of order, a repeated
  or unknown key, an upper-case oid or a size that is not a whole number up to the largest 64-bit
  integer is not a pointer.
  """

  @versions [
    "https://git-lfs.github.com/spec/v1",
    "https://hawser.github.com/spec/v1",
    "http://git-media.io/v/2"
  ]
  @max_int 9_223_372_036_854_775_807

  @doc "The oid and size a pointer names, or `:error` for anything git-lfs would not read as one."
  @spec parse(binary()) :: {:ok, %{oid: String.t(), size: non_neg_integer()}} | :error
  def parse(data) when is_binary(data) and byte_size(data) < 1024 do
    lines =
      data
      |> String.trim()
      |> String.split("\n")
      |> Enum.map(&String.trim_trailing(&1, "\r"))
      |> Enum.reject(&(&1 == ""))

    with ["version " <> version | rest] <- lines,
         true <- version in @versions,
         {:ok, oid, size} <- fields(rest) do
      {:ok, %{oid: oid, size: size}}
    else
      _other -> :error
    end
  end

  def parse(_data), do: :error

  # `ext-N-name sha256:<oid>` lines, then exactly `oid` and `size`.
  defp fields([line | rest] = lines) do
    if String.starts_with?(line, "ext-"),
      do: if(ext?(line), do: fields(rest), else: :error),
      else: oid_and_size(lines)
  end

  defp fields(lines), do: oid_and_size(lines)

  defp ext?(line), do: Regex.match?(~r/\Aext-[0-9]+-[^ ]+ sha256:[0-9a-f]{64}\z/, line)

  defp oid_and_size(["oid sha256:" <> oid, "size " <> size]) do
    with true <- Forge.Git.Lfs.oid?(oid),
         true <- Regex.match?(~r/\A[+-]?[0-9]+\z/, size),
         {n, ""} <- Integer.parse(size),
         true <- n >= 0 and n <= @max_int do
      {:ok, oid, n}
    else
      _other -> :error
    end
  end

  defp oid_and_size(_lines), do: :error
end
