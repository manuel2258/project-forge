defmodule Forge.Git.Hooks do
  @moduledoc """
  The generated hooks in every bare repository the platform owns, and the repository
  configuration they read.

  Hooks are rewritten whenever the platform starts, not only when a repository is created: a
  generated file that is written once at creation time is a landmine, because an upgrade to a rule
  would then apply to new repositories only.

  Per-request facts travel in the environment; per-repository facts live in `git config`. The
  allowed ref is per-request so it cannot come from config, and the mirror must fire for a push
  the endpoint never mediated — the platform's own merge — so it cannot come from the environment.
  The mirror therefore has no column on `projects`: a column would be a second source of truth
  that the hook, which is the enforcement point, cannot read. The default branch does have one,
  and `install/2` copies it into the repository so the hook can see it.
  See `docs/design/git-hosting.md`.
  """

  alias Forge.Git
  alias Forge.Projects.Project

  @hooks ~w(pre-receive post-receive)

  @doc """
  Writes both hooks into `repo_path` and copies `project`'s default branch onto the repository.
  Idempotent, and it leaves the mirror configuration alone — that is `set_mirror/3`'s.
  """
  @spec install(String.t(), Project.t()) :: :ok | {:error, term()}
  def install(repo_path, %Project{default_branch: default}) do
    with :ok <- write_hooks(repo_path),
         :ok <- config(repo_path, "forge.defaultBranch", default) do
      head(repo_path, default)
    end
  end

  # `git init --bare` points HEAD at git's own default branch name, which for a project whose
  # default is anything else is a branch that never exists — and a client cloning the repository
  # is then told it is empty. HEAD is what a clone with no `--branch` follows, so it has to name
  # the project's default branch.
  defp head(repo_path, default) do
    with {:ok, _out} <- Git.run(repo_path, ["symbolic-ref", "HEAD", "refs/heads/" <> default]) do
      :ok
    end
  end

  @doc """
  Points the repository's mirror at `url`, or removes it when `url` is `nil` or blank. `refs` is
  the glob the mirror carries, defaulting to the default branch alone.
  """
  @spec set_mirror(String.t(), String.t() | nil, String.t() | nil) :: :ok | {:error, term()}
  def set_mirror(repo_path, url, refs \\ nil) do
    with :ok <- config(repo_path, "forge.mirror", url) do
      config(repo_path, "forge.mirrorRefs", refs)
    end
  end

  @doc "The mirror this repository is configured with, or `nil`."
  @spec mirror(String.t()) :: String.t() | nil
  def mirror(repo_path), do: get(repo_path, "forge.mirror")

  @doc "The ref glob this repository mirrors, or `nil` when it is the default."
  @spec mirror_refs(String.t()) :: String.t() | nil
  def mirror_refs(repo_path), do: get(repo_path, "forge.mirrorRefs")

  defp write_hooks(repo_path) do
    dir = Path.join(repo_path, "hooks")

    Enum.reduce_while(@hooks, :ok, fn name, :ok ->
      case write_hook(dir, name) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {name, reason}}}
      end
    end)
  end

  # Written to a neighbour and renamed, so a push that arrives mid-write never execs half a
  # script. A rename within one directory is atomic.
  defp write_hook(dir, name) do
    wanted = source(name)
    path = Path.join(dir, name)
    tmp = path <> ".forge-tmp"

    if File.read(path) == {:ok, wanted} do
      :ok
    else
      with :ok <- File.mkdir_p(dir),
           :ok <- File.write(tmp, wanted),
           :ok <- File.chmod(tmp, 0o755) do
        File.rename(tmp, path)
      end
    end
  end

  defp source(name) do
    :forge
    |> Application.app_dir(Path.join("priv/git-hooks", name))
    |> File.read!()
  end

  defp get(repo_path, key) do
    case Git.run(repo_path, ["config", "--get", key]) do
      {:ok, value} -> blank_to_nil(String.trim(value))
      {:error, _reason} -> nil
    end
  end

  defp config(repo_path, key, nil), do: unset(repo_path, key)
  defp config(repo_path, key, ""), do: unset(repo_path, key)

  defp config(repo_path, key, value) do
    with {:ok, _out} <- Git.run(repo_path, ["config", "--local", key, value]), do: :ok
  end

  # `--unset` answers 5 for a key that was not set, which is not a failure here.
  defp unset(repo_path, key) do
    case Git.run(repo_path, ["config", "--local", "--unset", key]) do
      {:ok, _out} -> :ok
      {:error, {5, _out}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
