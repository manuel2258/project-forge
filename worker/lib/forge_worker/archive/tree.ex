defmodule ForgeWorker.Archive.Tree do
  @moduledoc """
  The archive's shape as the worker serves it, as pure functions over the listings the platform
  has sent (`docs/design/archive.md` § Layout).

  A path is a list of names: `[]` is the root, `["12"]` ticket 12's folder, `["12", "plan.md"]` a
  file, `["12", "reports", "out.txt"]` a file in a group's folder. `listings` holds what has been
  fetched, `%{:root => listing, {:ticket, "12"} => listing}`, and a lookup that needs one that is
  not there says which (`{:need, key}`) rather than fetching it: the server decides when to go to
  the network.

  **A name is looked up by exact key in a map and never becomes a path on this machine's disk.**
  That is the whole model of the guard on names: a segment with a `/` or a NUL, or `.`/`..`, is
  not a name here and finds nothing; `.` and `..` are navigation, which the server handles before a
  name is looked up.
  """

  @type path :: [String.t()]
  @type key :: :root | {:ticket, String.t()}
  @type entry :: %{String.t() => term()}
  @type found :: {:dir, path()} | {:file, path(), entry()}

  @doc "What `path` is, or what must be fetched first to know, or `:enoent`."
  @spec resolve(map(), path()) :: {:ok, found()} | {:need, key()} | :enoent
  def resolve(_listings, []), do: {:ok, {:dir, []}}

  def resolve(listings, [name]) do
    with {:ok, root} <- listing(listings, :root) do
      cond do
        MapSet.member?(root.tickets, name) -> {:ok, {:dir, [name]}}
        Map.has_key?(root.files, name) -> {:ok, {:file, [name], root.files[name]}}
        true -> :enoent
      end
    end
  end

  def resolve(listings, [number | rest] = path) do
    with {:ok, root} <- listing(listings, :root),
         true <- MapSet.member?(root.tickets, number) || :enoent,
         {:ok, ticket} <- listing(listings, {:ticket, number}) do
      inside(ticket, path, Enum.join(rest, "/"))
    end
  end

  defp inside(ticket, path, joined) do
    cond do
      Map.has_key?(ticket.files, joined) -> {:ok, {:file, path, ticket.files[joined]}}
      Enum.any?(ticket.folders, &(&1 == joined)) -> {:ok, {:dir, path}}
      true -> :enoent
    end
  end

  defp listing(listings, key) do
    case listings do
      %{^key => %{data: data}} -> {:ok, data}
      _none -> {:need, key}
    end
  end

  @doc """
  The names directly inside a folder: `{:ok, [{name, :dir | :file}]}` sorted, or what to fetch.
  """
  @spec children(map(), path()) :: {:ok, [{String.t(), :dir | :file}]} | {:need, key()} | :enoent
  def children(listings, []) do
    with {:ok, root} <- listing(listings, :root) do
      tickets = for number <- root.tickets, do: {number, :dir}
      files = for {name, _entry} <- root.files, do: {name, :file}
      {:ok, Enum.sort(tickets ++ files)}
    end
  end

  def children(listings, [number | rest] = path) do
    case resolve(listings, path) do
      {:ok, {:dir, ^path}} -> inside_children(listings, number, rest)
      {:need, _key} = need -> need
      _other -> :enoent
    end
  end

  defp inside_children(listings, number, rest) do
    with {:ok, ticket} <- listing(listings, {:ticket, number}) do
      prefix = if rest == [], do: "", else: Enum.join(rest, "/") <> "/"

      names =
        ticket.files
        |> Map.keys()
        |> Enum.filter(&String.starts_with?(&1, prefix))
        |> Enum.map(&child(String.replace_prefix(&1, prefix, "")))
        |> Enum.uniq()
        |> Enum.sort()

      {:ok, names}
    end
  end

  defp child(name) do
    case String.split(name, "/", parts: 2) do
      [folder, _rest] -> {folder, :dir}
      [file] -> {file, :file}
    end
  end

  @doc """
  The root's listing as `resolve/2` reads it. A malformed entry — a name that is not one — is
  dropped, and the platform has already checked them: this is the second line, for a platform
  that is wrong.
  """
  @spec root(map()) :: map()
  def root(%{"tickets" => tickets, "files" => files}) do
    %{
      tickets: tickets |> Enum.map(&to_string/1) |> Enum.filter(&name?/1) |> MapSet.new(),
      files: index(files, false)
    }
  end

  @doc "A ticket's listing as `resolve/2` reads it: the files by path, and the folders they imply."
  @spec ticket(map()) :: map()
  def ticket(%{"files" => files}) do
    index = index(files, true)

    folders =
      index
      |> Map.keys()
      |> Enum.flat_map(fn path ->
        case String.split(path, "/") do
          [_file] -> []
          parts -> [Enum.join(Enum.drop(parts, -1), "/")]
        end
      end)
      |> Enum.uniq()

    %{files: index, folders: folders}
  end

  defp index(files, nested?) do
    files
    |> Enum.filter(&valid?(&1, nested?))
    |> Map.new(&{&1["path"], &1})
  end

  defp valid?(%{"path" => path, "size" => size} = entry, nested?)
       when is_binary(path) and is_integer(size) and size >= 0 do
    parts = String.split(path, "/")
    allowed = if nested?, do: 2, else: 1

    length(parts) <= allowed and Enum.all?(parts, &name?/1) and
      (is_binary(entry["inline"]) or ref?(entry["ref"]))
  end

  defp valid?(_entry, _nested?), do: false

  # The cache is keyed by it, so it is a file name on this disk: a version's id and nothing else.
  defp ref?(ref),
    do: is_binary(ref) and Regex.match?(~r/\A[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/, ref)

  @doc "Whether `name` is one name: not empty, not `.` or `..`, no `/`, no NUL, at most 255 bytes."
  @spec name?(term()) :: boolean()
  def name?(name) when is_binary(name),
    do:
      name != "" and name not in [".", ".."] and byte_size(name) <= 255 and
        not String.contains?(name, ["/", <<0>>])

  def name?(_name), do: false

  @doc "The parent of a path; the root's is the root."
  @spec parent(path()) :: path()
  def parent([]), do: []
  def parent(path), do: Enum.drop(path, -1)

  @doc """
  A number that is the same for the same path, for a qid (and so an inode number): the first 64 bits
  of a sha256 of the path. `:erlang.phash2/1` had 2^27 values, and a project with some thousands of
  files had a real chance of two sharing one.
  """
  @spec number(path()) :: non_neg_integer()
  def number(path) do
    <<number::64, _rest::binary>> = :crypto.hash(:sha256, :erlang.term_to_binary(path))
    number
  end
end
