defmodule ForgeCore.Workflow.Imports do
  @moduledoc """
  Flattens a workflow's `import` and `extends` into a plain v1 definition, before it is parsed.
  `docs/design/ticket-types.md` § Imports is the note; this is its rules.

  A **library** is a file under `.forge/`, outside `workflows/`, holding `commands`, `defaults`
  and state templates under `states`, and nothing else. A workflow names libraries in `import`
  and takes a template by writing `extends: <name>` in a state of its own.

  - `commands` are imported whole. A name declared twice — by two libraries, or by a library and
    the workflow — is an error naming both: `build` means one thing in a project.
  - `defaults` are imported field by field, and the workflow's own win, which is the
    nearest-first order `resources` already resolve in. Two libraries setting the same field is an
    error, because neither is nearer.
  - `states` are never imported implicitly: every state must be reachable, and transitions are the
    workflow's, so a state nobody named would be an unreachable one reported from a file its author
    did not open. The keys a workflow's state writes replace the template's whole — a `budget` in
    the workflow is the budget, not a patch to one.
  - Imports are one level deep, so there are no cycles to find and no diamond to order.

  **What comes out is what is pinned.** A ticket's stored definition is re-read with
  `Parser.from_map/2` and no repository, everywhere its workflow is read, so it must hold no
  `import` and no `extends`. The result also carries where each imported part came from, so an
  error about it can name the library rather than the file that does not contain it
  (`attribute/2`).

  Resolution errors are returned alone, without parsing what could be flattened: a state whose
  `extends` named nothing would otherwise be reported again as a state with no prompt and no
  budget, which is the same mistake told twice and the second time wrongly.
  """

  alias ForgeCore.Error
  alias ForgeCore.Workflow

  @library_keys ~w(commands defaults states)
  @types_dir "workflows"

  @typedoc "Reads a file by its path under `.forge/`, at the commit the workflow is read at."
  @type reader :: (String.t() -> {:ok, String.t()} | :error)

  @typedoc """
  Where an imported part came from: a path prefix into the result, the library, and the same part's
  path in the library — which differs when a state extends a template under a name of its own.
  """
  @type origins :: [{String.t(), String.t(), String.t()}]

  @doc """
  Resolves `map`'s imports with `read`. `{:ok, flat, origins}`, or every resolution error found.

  A `nil` reader resolves a definition that imports nothing, and refuses one that does: there is
  nothing to read a library with.
  """
  @spec resolve(map(), reader() | nil) :: {:ok, map(), origins()} | {:error, [Error.t()]}
  def resolve(map, read) when is_map(map) do
    # A library that is not there, or not a library, is reported alone: merging without it would
    # report every state extending one of its templates as extending nothing.
    with {:ok, libraries} <- libraries(map, read) do
      merge(map, libraries)
    end
  end

  defp libraries(map, read) do
    {paths, e1} = import_paths(map)
    {libraries, e2} = read_libraries(paths, read)

    case e1 ++ e2 do
      [] -> {:ok, libraries}
      errors -> {:error, sorted(errors)}
    end
  end

  defp merge(map, libraries) do
    {commands, commands_origins, e1} = merge_commands(map, libraries)
    {defaults, defaults_origins, e2} = merge_defaults(map, libraries)
    {states, states_origins, e3} = merge_states(map, libraries)

    case e1 ++ e2 ++ e3 do
      [] ->
        flat =
          map
          |> Map.delete("import")
          |> put_present("commands", commands)
          |> put_present("defaults", defaults)
          |> put_present("states", states)

        {:ok, flat, commands_origins ++ defaults_origins ++ states_origins}

      errors ->
        {:error, sorted(errors)}
    end
  end

  defp sorted(errors), do: Enum.sort_by(errors, &{&1.file || "", &1.path, &1.message})

  @doc """
  Names the library each error is about, where the part of the definition its path points into
  was imported, and gives its path in that library — `fixing: {extends: implementing}` with a bad
  budget in the template is `common.yml: states.implementing.budget…`, where the mistake is, not
  `states.fixing`, which the library does not have. The longest matching prefix wins, so a key a
  workflow's own state wrote over a template is the workflow's, not the library's.
  """
  @spec attribute([Error.t()], origins()) :: [Error.t()]
  def attribute(errors, []), do: errors

  def attribute(errors, origins) do
    Enum.map(errors, fn
      %Error{file: nil, path: path} = error ->
        case origin(origins, path) do
          nil -> error
          {prefix, file, there} -> %{error | file: file, path: there <> drop(path, prefix)}
        end

      error ->
        error
    end)
  end

  defp origin(origins, path) do
    origins
    |> Enum.filter(fn {prefix, _file, _there} -> under?(path, prefix) end)
    |> Enum.max_by(fn {prefix, _file, _there} -> String.length(prefix) end, fn -> nil end)
  end

  defp drop(path, prefix),
    do: binary_part(path, byte_size(prefix), byte_size(path) - byte_size(prefix))

  defp under?(path, prefix) do
    path == prefix or String.starts_with?(path, prefix <> ".") or
      String.starts_with?(path, prefix <> "[")
  end

  @doc """
  Whether `path` may name a library: segments that are each a valid name, under `.forge/` and
  not in `workflows/`, where every file is a ticket type.

  The check is lexical, and that is the same model as the read it guards: a library is read from
  the git tree at a commit, by path, and a tree lookup follows no symlink and resolves no `..`.
  Every segment being a name — which refuses `.`, `..`, empty and leading-dot segments — keeps
  the path inside `.forge/` by construction.
  """
  @spec library_path?(term()) :: boolean()
  def library_path?(path) when is_binary(path) do
    case String.split(path, "/") do
      [@types_dir | _rest] -> false
      segments -> Enum.all?(segments, &Workflow.valid_name?/1)
    end
  end

  def library_path?(_path), do: false

  # -- import ---------------------------------------------------------------------------------

  defp import_paths(map) do
    case Map.get(map, "import") do
      nil ->
        {[], []}

      paths when is_list(paths) ->
        paths
        |> Enum.with_index()
        |> Enum.reduce({[], []}, &import_path/2)

      _other ->
        {[], [Error.new("import", "must be a list of library paths under .forge/")]}
    end
  end

  defp import_path({path, index}, {acc, errors}) do
    at = Error.join("import", index)

    cond do
      not library_path?(path) ->
        {acc, errors ++ [Error.new(at, path_error(path))]}

      Enum.any?(acc, fn {seen, _at} -> seen == path end) ->
        {acc, errors ++ [Error.new(at, "#{inspect(path)} is imported twice")]}

      true ->
        {acc ++ [{path, at}], errors}
    end
  end

  defp path_error(path) when is_binary(path) do
    if String.starts_with?(path, @types_dir <> "/"),
      do: "#{inspect(path)} is a ticket type, not a library: a type cannot be imported",
      else:
        "#{inspect(path)} must be a path under .forge/, like common.yml, of names: " <>
          Workflow.name_rule()
  end

  defp path_error(path), do: "#{inspect(path)} must be a path under .forge/, like common.yml"

  defp read_libraries([], _read), do: {[], []}

  defp read_libraries(paths, nil) do
    {[],
     Enum.map(paths, fn {_path, at} ->
       Error.new(at, "cannot be read here: there is no repository to read a library from")
     end)}
  end

  defp read_libraries(paths, read) do
    Enum.reduce(paths, {[], []}, fn {path, at}, {libraries, errors} ->
      case library(path, at, read) do
        {:ok, library} -> {libraries ++ [{path, library}], errors}
        {:error, more} -> {libraries, errors ++ more}
      end
    end)
  end

  defp library(path, at, read) do
    with {:ok, text} <- read_file(path, at, read),
         {:ok, map} <- decode(text, path) do
      case library_errors(map, path) do
        [] -> {:ok, map}
        errors -> {:error, errors}
      end
    end
  end

  defp read_file(path, at, read) do
    case read.(path) do
      {:ok, text} when is_binary(text) -> {:ok, text}
      _missing -> {:error, [Error.new(at, "#{inspect(path)} does not exist at this commit")]}
    end
  end

  defp decode(text, path) do
    case YamlElixir.read_from_string(text) do
      {:ok, map} when is_map(map) ->
        case ForgeCore.Workflow.Keys.errors(map) do
          [] -> {:ok, map}
          errors -> {:error, Enum.map(errors, &in_file(&1, path))}
        end

      {:ok, _other} ->
        {:error, [in_file(Error.new("", "a library must be a mapping"), path)]}

      {:error, %{message: message}} ->
        {:error, [in_file(Error.new("", "invalid YAML: #{message}"), path)]}
    end
  end

  # What a library may hold is checked here, because nothing else ever reads one alone: its
  # commands and defaults are validated as part of each workflow that imports them.
  defp library_errors(map, path) do
    keys =
      map
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.sort()
      |> Enum.flat_map(fn
        key when key in @library_keys -> []
        "import" -> [Error.new("import", "imports are one level deep: a library cannot import")]
        key -> [Error.new(key, "not allowed in a library, which holds only #{library_keys()}")]
      end)

    shapes =
      Enum.flat_map(@library_keys, fn key ->
        case Map.get(map, key) do
          nil -> []
          value when is_map(value) -> section_errors(key, value)
          _other -> [Error.new(key, "must be a mapping")]
        end
      end)

    Enum.map(keys ++ shapes, &in_file(&1, path))
  end

  defp library_keys, do: Enum.join(@library_keys, ", ")

  defp section_errors("states", templates) do
    Enum.flat_map(templates, fn {name, template} ->
      at = Error.join("states", to_string(name))

      cond do
        not is_map(template) ->
          [Error.new(at, "a state template must be a mapping")]

        Map.has_key?(template, "extends") ->
          [Error.new(Error.join(at, "extends"), extends_deep())]

        true ->
          []
      end
    end)
  end

  defp section_errors(_key, _value), do: []

  defp extends_deep, do: "a state template cannot extend another: imports are one level deep"

  # -- commands -------------------------------------------------------------------------------

  defp merge_commands(map, libraries) do
    own = Map.get(map, "commands")

    if own == nil or is_map(own) do
      initial = {own || %{}, Map.new(Map.keys(own || %{}), &{to_string(&1), nil}), [], []}

      {commands, _from, origins, errors} =
        fold_section(libraries, "commands", initial, &import_command/3)

      {if(own == nil and commands == %{}, do: nil, else: commands), origins, errors}
    else
      # Not a mapping: the parser says so about the workflow's own key, and there is nothing to
      # merge into.
      {own, [], []}
    end
  end

  defp import_command({name, definition}, file, {commands, from, origins, errors}) do
    name = to_string(name)
    at = Error.join("commands", name)

    case Map.fetch(from, name) do
      {:ok, nil} ->
        error = in_file(Error.new(at, "is also declared by the workflow importing this"), file)
        {commands, from, origins, errors ++ [error]}

      {:ok, other} ->
        error = in_file(Error.new(at, "is also declared in #{other}"), file)
        {commands, from, origins, errors ++ [error]}

      :error ->
        {Map.put(commands, name, definition), Map.put(from, name, file),
         origins ++ [{at, file, at}], errors}
    end
  end

  # -- defaults -------------------------------------------------------------------------------

  defp merge_defaults(map, libraries) do
    own = Map.get(map, "defaults")

    if own == nil or is_map(own) do
      initial = {own || %{}, %{}, [], []}

      {defaults, _from, origins, errors} =
        fold_section(libraries, "defaults", initial, &import_default/3)

      {if(own == nil and defaults == %{}, do: nil, else: defaults), origins, errors}
    else
      {own, [], []}
    end
  end

  # A mapping — `resources` — is imported field by field; anything else whole, so that the parser
  # still sees, and names, a key a library should not have set.
  defp import_default({key, value}, file, acc) when is_map(value) do
    key = to_string(key)

    value
    |> Enum.sort_by(fn {field, _value} -> to_string(field) end)
    |> Enum.reduce(acc, fn {field, field_value}, acc ->
      import_field(acc, key, to_string(field), field_value, file)
    end)
  end

  defp import_default({key, value}, file, {defaults, _from, _origins, _errors} = acc) do
    key = to_string(key)

    claim(
      acc,
      Error.join("defaults", key),
      Map.has_key?(defaults, key),
      file,
      &Map.put(&1, key, value)
    )
  end

  defp import_field({defaults, _from, _origins, _errors} = acc, key, field, value, file) do
    case Map.get(defaults, key) do
      own when own == nil or is_map(own) ->
        own = own || %{}
        at = Error.join(Error.join("defaults", key), field)

        claim(
          acc,
          at,
          Map.has_key?(own, field),
          file,
          &Map.put(&1, key, Map.put(own, field, value))
        )

      _not_a_mapping ->
        # The workflow's own `defaults.<key>` is not a mapping: the parser says so, and the
        # workflow's own wins whatever it holds.
        acc
    end
  end

  # A library's value is taken when nothing has set it. The workflow's own is nearer and wins; a
  # second library setting it is an error, because neither library is nearer than the other.
  # `from` is asked first: a field an earlier library set is present too, and is not the
  # workflow's.
  defp claim({defaults, from, origins, errors} = acc, at, present?, file, put) do
    cond do
      Map.has_key?(from, at) ->
        error = in_file(Error.new(at, "is also set in #{from[at]}"), file)
        {defaults, from, origins, errors ++ [error]}

      present? ->
        acc

      true ->
        {put.(defaults), Map.put(from, at, file), origins ++ [{at, file, at}], errors}
    end
  end

  # -- states ---------------------------------------------------------------------------------

  defp merge_states(map, libraries) do
    {templates, template_errors} = templates(libraries)

    case Map.get(map, "states") do
      states when is_map(states) ->
        {resolved, origins, errors} =
          states
          |> Enum.sort_by(fn {name, _definition} -> to_string(name) end)
          |> Enum.reduce({%{}, [], []}, fn {name, definition}, {acc, origins, errors} ->
            {state, more_origins, more_errors} = extend(to_string(name), definition, templates)
            {Map.put(acc, name, state), origins ++ more_origins, errors ++ more_errors}
          end)

        {resolved, origins, template_errors ++ errors}

      other ->
        {other, [], template_errors}
    end
  end

  defp templates(libraries), do: fold_section(libraries, "states", {%{}, []}, &add_template/3)

  defp add_template({name, template}, file, {templates, errors}) do
    name = to_string(name)

    case Map.fetch(templates, name) do
      {:ok, {other, _template}} ->
        error =
          in_file(Error.new(Error.join("states", name), "is also declared in #{other}"), file)

        {templates, errors ++ [error]}

      :error ->
        {Map.put(templates, name, {file, template}), errors}
    end
  end

  defp extend(name, %{"extends" => template_name} = definition, templates) do
    at = Error.join(Error.join("states", name), "extends")
    own = Map.delete(definition, "extends")

    case Map.fetch(templates, template_name) do
      {:ok, {file, template}} ->
        origins =
          for {key, _value} <- template,
              not Map.has_key?(own, key),
              do:
                {Error.join(Error.join("states", name), to_string(key)), file,
                 Error.join(Error.join("states", template_name), to_string(key))}

        {Map.merge(template, own), origins, []}

      :error ->
        {own, [], [Error.new(at, extends_error(template_name, templates))]}
    end
  end

  defp extend(_name, definition, _templates), do: {definition, [], []}

  defp extends_error(name, templates) when is_binary(name) and name != "" do
    case templates |> Map.keys() |> Enum.sort() do
      [] ->
        "names #{inspect(name)}, and no library this imports declares a state template"

      known ->
        "names #{inspect(name)}, which no imported library declares; it has #{Enum.join(known, ", ")}"
    end
  end

  defp extends_error(_name, _templates), do: "must name a state template from an imported library"

  # -- helpers --------------------------------------------------------------------------------

  # Every entry of one section across the libraries, in import order and then by name, folded with
  # `fun`. The order is what makes "is also declared in" name the earlier file every time.
  defp fold_section(libraries, section, acc, fun) do
    for {file, library} <- libraries,
        # An empty section — `commands:` with everything under it commented out — is YAML's
        # null, and is no entries rather than something to sort.
        entry <- Enum.sort_by(Map.get(library, section) || %{}, &to_string(elem(&1, 0))),
        reduce: acc do
      acc -> fun.(entry, file, acc)
    end
  end

  defp in_file(%Error{} = error, file), do: %{error | file: file}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
