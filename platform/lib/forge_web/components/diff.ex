defmodule ForgeWeb.Diff do
  @moduledoc """
  A change between two commits: how it is read out of the repository, and how it is drawn.

  Two pages show one — the ticket's review and a conversation's — and they show the same thing
  for the same reason, so there is one of this rather than two. What differs between them is what
  authorised the merge, not what the diff looks like.

  **A diff is bounded.** Past a size it is not rendered inline: a page nobody can read is not a
  review, and the change is still named file by file with its counts. See `docs/design/ui.md`
  § Semantics that must not be lost.
  """

  use Phoenix.Component

  alias Forge.Git

  # Big enough for a real change, small enough that the page stays readable.
  @max_patch_bytes 512 * 1024
  @max_patch_files 60

  @typedoc "What `build/3` returns: the change, or why it could not be read."
  @type t :: %{optional(:error) => term(), optional(atom()) => term()}

  @doc "Reads the change from `base` to `head` out of `repo`."
  @spec build(String.t(), String.t() | nil, String.t() | nil) :: t() | nil
  def build(_repo, nil, _head), do: nil
  def build(_repo, _base, nil), do: nil

  def build(repo, base, head) do
    with {:ok, stat} <- Git.diff_stat(repo, base, head),
         {:ok, patch} <- Git.diff(repo, base, head) do
      %{
        head: head,
        base: base,
        files: stat,
        added: total(stat, 1),
        removed: total(stat, 2),
        patch: patch,
        inline: byte_size(patch) <= @max_patch_bytes and length(stat) <= @max_patch_files,
        bytes: byte_size(patch)
      }
    else
      {:error, reason} -> %{error: reason}
    end
  end

  defp total(stat, index) do
    stat
    |> Enum.map(&elem(&1, index))
    |> Enum.reject(&(&1 == :binary))
    |> Enum.sum()
  end

  attr :diff, :map, required: true
  attr :id, :string, default: "diff"
  attr :title, :string, default: "The diff"

  def section(assigns) do
    ~H"""
    <section id={@id}>
      <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">{@title}</h2>

      <p :if={@diff[:error]} class="mt-3 text-sm/[1.55] text-error">
        The change cannot be read from the repository: {inspect(@diff[:error])}
      </p>

      <div :if={@diff[:files] == []} class="mt-3 text-sm/[1.55] opacity-70">
        The branch changes nothing against its base.
      </div>

      <table :if={@diff[:files] not in [nil, []]} class="mt-3 w-full text-[12.5px]">
        <tbody>
          <tr :for={{path, added, removed} <- @diff.files} class="border-b border-base-300/60">
            <td class="py-1.5 font-mono break-all">{path}</td>
            <td class="w-24 py-1.5 text-right font-mono opacity-60">
              {count(added, "+")} {count(removed, "−")}
            </td>
          </tr>
        </tbody>
      </table>

      <pre
        :if={@diff[:inline] && @diff[:patch] not in [nil, ""]}
        class="mt-4 overflow-x-auto border border-base-300 p-3 font-mono text-[12.5px] leading-[1.5]"
      ><code>{@diff.patch}</code></pre>

      <p :if={@diff[:files] not in [nil, []] and @diff[:inline] == false} class="mt-4 text-sm/[1.55]">
        This change is {bytes(@diff.bytes)} across {length(@diff.files)} files, too much to read on
        one page. Read it with <span class="font-mono text-[12.5px]">git diff {short(@diff.base)}..{short(@diff.head)}</span>.
      </p>
    </section>
    """
  end

  defp count(:binary, _sign), do: "binary"
  defp count(number, sign), do: "#{sign}#{number}"

  @doc "The first twelve characters of a sha, for reading rather than for resolving."
  @spec short(String.t() | nil) :: String.t()
  def short(nil), do: "—"
  def short(sha), do: String.slice(sha, 0, 12)

  defp bytes(count) when count >= 1_048_576, do: "#{Float.round(count / 1_048_576, 1)} MB"
  defp bytes(count) when count >= 1024, do: "#{div(count, 1024)} KB"
  defp bytes(count), do: "#{count} bytes"
end
