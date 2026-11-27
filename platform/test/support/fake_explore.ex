defmodule Forge.FakeExplore do
  @moduledoc """
  A stand-in for `Forge.Explore`, for the pages and the looks (`:explore_module`,
  `ForgeWeb.ExploreLive`): a copy as a map of paths, answered the way the machine answers it, and
  nothing else. The real round trip, the stream door and the worker's side have tests of their
  own; what these answer is what the pages are drawn from.

  `install/1` takes `files`, a map of a copy's paths to what is there: `{:file, bytes}`,
  `{:file, bytes, size}` (a file the machine says is that long, whose first bytes are given) or
  `{:link, target}`. Folders are the prefixes of those paths. `fail/1` makes every question answer
  with a code, and every question is also sent to the process that installed it as
  `{:explored, op, path}`.
  """

  alias ForgeCore.Explore, as: Limits

  @key :fake_explore

  @doc "Routes the pages to this module, answering from `files`. The caller gets every question."
  @spec install(map(), keyword()) :: :ok
  def install(files, opts \\ []) do
    Application.put_env(:forge, :explore_module, __MODULE__)

    Application.put_env(:forge, @key, %{
      files: files,
      error: nil,
      gate: false,
      mtime: Keyword.get(opts, :mtime, 1_795_000_000),
      owner: self()
    })

    # A test puts the platform back when it ends; a look (`Forge.Look.Setups.Explore`) is not a test
    # and its database goes with it.
    if Keyword.get(opts, :on_exit, true) do
      ExUnit.Callbacks.on_exit(fn ->
        Application.delete_env(:forge, :explore_module)
        Application.delete_env(:forge, @key)
      end)
    end

    :ok
  end

  @doc "Every question from now on is answered with `{:error, code}`."
  @spec fail(atom() | nil) :: :ok
  def fail(code), do: put(:error, code)

  @doc "While the gate is shut, every question waits for it to open: a page that is still asking."
  @spec gate(boolean()) :: :ok
  def gate(shut?), do: put(:gate, shut?)

  defp put(key, value),
    do: Application.put_env(:forge, @key, Map.put(state(), key, value))

  defp state, do: Application.fetch_env!(:forge, @key)

  defp asked(op, path) do
    send(state().owner, {:explored, op, path})
    wait_for_gate()
    state().error
  end

  defp wait_for_gate do
    if state().gate do
      Process.sleep(10)
      wait_for_gate()
    end
  end

  # -- the questions ------------------------------------------------------------------------

  def list(_copy, path, offset) do
    with nil <- asked(:list, path) |> failure(),
         {:ok, entries} <- entries(path) do
      page = entries |> Enum.slice(offset, Limits.page_size())
      {:ok, %{entries: page, total: length(entries), offset: offset}}
    end
  end

  def file(_copy, path) do
    with nil <- asked(:file, path) |> failure() do
      case lookup(path) do
        {:file, bytes, size} -> {:ok, facts(bytes, size)}
        {:link, target} -> {:ok, link_facts(target)}
        :dir -> {:ok, dir_facts(path)}
        nil -> {:error, :path_not_found}
      end
    end
  end

  def hash(_copy, path, on_progress) do
    with nil <- asked(:hash, path) |> failure() do
      hash_of(lookup(path), on_progress)
    end
  end

  defp hash_of({:file, bytes, size}, on_progress) do
    if on_progress, do: on_progress.(div(size, 2), size)
    {:ok, %{sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower), size: size}}
  end

  defp hash_of(_not_a_file, _on_progress), do: {:error, :not_a_file}

  def download(conn, _copy, path, opts) do
    case asked(:download, path) do
      nil ->
        conn
        |> Plug.Conn.put_resp_content_type("application/x-tar")
        |> Plug.Conn.send_resp(200, "archive of " <> path)

      code ->
        opts[:error].(conn, code)
    end
  end

  # -- the copy ------------------------------------------------------------------------------

  defp failure(nil), do: nil
  defp failure(code), do: {:error, code}

  defp lookup(""), do: :dir

  defp lookup(path) do
    case Map.get(state().files, path) do
      {:file, bytes} -> {:file, bytes, byte_size(bytes)}
      {:file, bytes, size} -> {:file, bytes, size}
      {:link, target} -> {:link, target}
      nil -> if folder?(path), do: :dir
    end
  end

  defp folder?(path),
    do: Enum.any?(Map.keys(state().files), &String.starts_with?(&1, path <> "/"))

  defp entries(path) do
    case lookup(path) do
      :dir -> {:ok, children(path)}
      nil -> {:error, :path_not_found}
      _file_or_link -> {:error, :not_a_folder}
    end
  end

  # The entries directly under a folder: folders first, then the rest, by name.
  defp children(path) do
    prefix = if path == "", do: "", else: path <> "/"

    names =
      for {key, _what} <- state().files,
          String.starts_with?(key, prefix),
          name =
            key
            |> binary_part(byte_size(prefix), byte_size(key) - byte_size(prefix))
            |> String.split("/")
            |> hd(),
          uniq: true,
          do: name

    names
    |> Enum.map(&entry(prefix <> &1, &1))
    |> Enum.sort_by(&{&1.kind != :dir, &1.name})
  end

  defp entry(path, name) do
    base = %{name: name, mtime: state().mtime, size: nil, entries: nil, target: nil}

    case lookup(path) do
      :dir -> Map.merge(base, %{kind: :dir, entries: length(children(path))})
      {:file, _bytes, size} -> Map.merge(base, %{kind: :file, size: size})
      {:link, target} -> Map.merge(base, %{kind: :link, target: target})
    end
  end

  defp facts(bytes, size) do
    head = binary_part(bytes, 0, min(byte_size(bytes), Limits.text_limit()))
    text? = text?(head)

    %{
      kind: :file,
      size: size,
      mtime: state().mtime,
      text?: text?,
      content: if(text?, do: head),
      truncated?: text? and size > Limits.text_limit(),
      target: nil,
      entries: nil
    }
  end

  defp dir_facts(path) do
    {:ok, children} = entries(path)

    %{
      kind: :dir,
      size: nil,
      mtime: state().mtime,
      text?: false,
      content: nil,
      truncated?: false,
      target: nil,
      entries: length(children)
    }
  end

  defp link_facts(target),
    do: %{
      kind: :link,
      size: nil,
      mtime: state().mtime,
      text?: false,
      content: nil,
      truncated?: false,
      target: target,
      entries: nil
    }

  defp text?(bytes), do: String.valid?(bytes) and not String.contains?(bytes, <<0>>)
end
