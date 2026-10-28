defmodule Forge.TicketTypes do
  @moduledoc """
  Which ticket types a project's repository declares at a commit, and which file a ticket of a
  given type reads. `docs/design/ticket-types.md` § Where they live and § Admission.

  A project has one of two layouts. **The single file**, `.forge/workflow.yml`, is one unnamed
  type and nothing in the product mentions types. **The directory**, `.forge/workflows/`, holds
  one type per `<name>.yml`. Both at once is an error, because there is no rule for which wins.
  Anything else in the directory is reported as not a type and blocks nothing.

  Nothing here parses a workflow. It says which file; `Forge.Tickets` reads and parses it.
  """

  alias Forge.Git
  alias ForgeCore.Workflow

  @single ".forge/workflow.yml"
  @dir ".forge/workflows"

  @type layout :: %{
          form: :single | :types,
          types: [%{name: String.t(), path: String.t()}],
          not_types: [%{path: String.t(), why: String.t()}]
        }

  @doc "The path of the single workflow file."
  @spec single_path() :: String.t()
  def single_path, do: @single

  @doc "The directory ticket types live in."
  @spec dir() :: String.t()
  def dir, do: @dir

  @doc "The path of the file a type's workflow is read from: nil is the single file."
  @spec path(String.t() | nil) :: String.t()
  def path(nil), do: @single
  def path(name), do: "#{@dir}/#{name}.yml"

  @doc """
  The project's layout at `sha`, or why it has none: `{:both_workflow_forms, single, dir}` when
  there are both, and when there is neither the single file nor a type, `{:no_workflow_file,
  path}` — or `{:no_ticket_type_in, dir, not_types}` when the directory holds files and none of
  them is a type, so that what the author put there, and why it is not one, is said rather than
  replaced by a sentence about a file they never meant to write.

  **The directory is in use when it holds a type.** Anything else in it is reported and blocks
  nothing: a `Bug Fix.yml` beside the single file leaves the single file in charge, rather than
  making the project one with both forms that admits nothing.
  """
  @spec layout(Git.repo(), Git.sha()) :: {:ok, layout()} | {:error, term()}
  def layout(repo, sha) do
    with {:ok, entries} <- Git.ls_dir(repo, sha, @dir) do
      {types, not_types} = classify(entries)
      single? = Git.exists?(repo, sha, @single)

      cond do
        single? and types != [] ->
          {:error, {:both_workflow_forms, @single, @dir <> "/"}}

        single? ->
          {:ok, %{form: :single, types: [], not_types: not_types}}

        types != [] ->
          {:ok, %{form: :types, types: types, not_types: not_types}}

        not_types != [] ->
          {:error, {:no_ticket_type_in, @dir <> "/", not_types}}

        true ->
          {:error, {:no_workflow_file, @single}}
      end
    end
  end

  @doc """
  The type a ticket is admitted as, and the file it reads: `{:ok, name_or_nil, path}`.

  On the single file there are no types, and naming one is refused. In the directory a type is
  required when there is more than one, and implied when there is one; there is no default,
  because a default is how a bug quietly runs the feature lifecycle.
  """
  @spec for_admission(layout(), String.t() | nil, [String.t()]) ::
          {:ok, String.t() | nil, String.t()} | {:error, term()}
  def for_admission(layout, name, releases \\ [])

  def for_admission(%{form: :single}, nil, _releases), do: {:ok, nil, @single}
  def for_admission(%{form: :single}, name, _releases), do: {:error, {:no_ticket_types, name}}

  # `releases` is the names of the types that set `release: true` (`docs/design/ticket-types.md`
  # § Releases): naming one is refused, and the rest are chosen from as if it were not there, so a
  # project of one ordinary type and its release still implies the ordinary one.
  def for_admission(%{form: :types, types: types}, name, releases) do
    if name in releases do
      {:error, {:release_ticket_type, name}}
    else
      case Enum.reject(types, &(&1.name in releases)) do
        [] -> {:error, {:only_release_types, Enum.map(types, & &1.path)}}
        ordinary -> admission(ordinary, name)
      end
    end
  end

  defp admission([%{name: name, path: path}], nil), do: {:ok, name, path}
  defp admission(types, nil), do: {:error, {:ticket_type_required, names(types)}}

  defp admission(types, name) do
    case Enum.find(types, &(&1.name == name)) do
      %{path: path} -> {:ok, name, path}
      nil -> {:error, {:unknown_ticket_type, name, names(types)}}
    end
  end

  @doc """
  The file a release is read from: the one type that sets `release: true`, as `{:ok, name,
  path}`. `releases` is the names of the types that do. None, or the single file, is
  `{:error, :no_release_workflow}`; two or more is `{:error, {:several_release_workflows,
  paths}}`, because neither is nearer than the other (`docs/design/ticket-types.md` § Releases).
  """
  @spec for_release(layout(), [String.t()]) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  def for_release(%{form: :types, types: types}, releases) do
    case Enum.filter(types, &(&1.name in releases)) do
      [] -> {:error, :no_release_workflow}
      [%{name: name, path: path}] -> {:ok, name, path}
      several -> {:error, {:several_release_workflows, Enum.map(several, & &1.path)}}
    end
  end

  def for_release(%{form: :single}, _releases), do: {:error, :no_release_workflow}

  @doc """
  The file a re-pin of a ticket of `name` reads: its own type's, at the new commit. A type whose
  file is gone — the single file included, when a project has moved to the directory — refuses,
  rather than guessing which new type the ticket is.
  """
  @spec for_repin(layout(), String.t() | nil) ::
          {:ok, String.t() | nil, String.t()} | {:error, term()}
  def for_repin(%{form: :single}, nil), do: {:ok, nil, @single}

  def for_repin(%{form: :types, types: types}, name) when is_binary(name) do
    case Enum.find(types, &(&1.name == name)) do
      %{path: path} -> {:ok, name, path}
      nil -> {:error, {:ticket_type_gone, name, path(name)}}
    end
  end

  def for_repin(_layout, name), do: {:error, {:ticket_type_gone, name, path(name)}}

  defp names(types), do: Enum.map(types, & &1.name)

  defp classify(entries) do
    {types, not_types} =
      Enum.reduce(entries, {[], []}, fn entry, {types, not_types} ->
        case type(entry) do
          {:ok, type} -> {[type | types], not_types}
          {:error, why} -> {types, [%{path: entry.path, why: why} | not_types]}
        end
      end)

    {Enum.sort_by(types, & &1.name), Enum.sort_by(not_types, & &1.path)}
  end

  defp type(%{kind: :blob, name: name, path: path}) do
    stem = Path.basename(name, ".yml")

    cond do
      not String.ends_with?(name, ".yml") ->
        {:error, "not a .yml file"}

      not Workflow.valid_name?(stem) ->
        {:error, "#{inspect(stem)} is not a type name: " <> Workflow.name_rule()}

      true ->
        {:ok, %{name: stem, path: path}}
    end
  end

  defp type(%{kind: :tree}),
    do: {:error, "a directory: a type is a .yml file directly in .forge/workflows/"}

  defp type(%{kind: :link}), do: {:error, "a symbolic link, not a file"}
  defp type(%{kind: _other}), do: {:error, "not a file"}
end
