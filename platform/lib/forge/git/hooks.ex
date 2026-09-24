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
  Writes both hooks into `repo_path`, copies `project`'s default branch onto the repository, and
  migrates a scalar `forge.mirror` to the named mirror `default` if one is still there.
  """
  @spec install(String.t(), Project.t()) :: :ok | {:error, term()}
  def install(repo_path, %Project{default_branch: default}) do
    with :ok <- write_hooks(repo_path),
         :ok <- config(repo_path, "forge.defaultBranch", default),
         :ok <- migrate_scalar(repo_path) do
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
  Every mirror this repository is configured with, by name, with what the hook last said about
  each. `docs/design/git-hosting.md` § What the mirrors say about themselves.

  **The URL is read back without its userinfo.** `put_mirror/4`'s caller refuses to store one
  carrying a credential, but `migrate_scalar/1` deliberately carries an old scalar over
  unmodified, and the old mechanism had no credential store — so `https://user:token@host/x.git`
  is the likeliest thing a pre-mirrors node has configured. Stripping it here rather than in each
  template makes "a mirror URL is safe to print" a property of the one read every surface goes
  through. The stored value keeps its userinfo: the hook still needs it to push, and a migrated
  mirror that works must go on working.
  """
  @spec list_mirrors(String.t()) :: [map()]
  def list_mirrors(repo_path) do
    repo_path
    |> names()
    |> Enum.map(fn name ->
      %{
        name: name,
        url: strip_userinfo(get(repo_path, "forge.mirror.#{name}.url")),
        refs: get(repo_path, "forge.mirror.#{name}.refs"),
        user: get(repo_path, "forge.mirror.#{name}.user"),
        last_status: get(repo_path, "forge.mirror.#{name}.lastStatus"),
        last_at: get(repo_path, "forge.mirror.#{name}.lastAt"),
        last_error: get(repo_path, "forge.mirror.#{name}.lastError"),
        last_ok_at: get(repo_path, "forge.mirror.#{name}.lastOkAt")
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Creates or replaces one mirror. `opts` takes `:refs` and `:user`, both optional."
  @spec put_mirror(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def put_mirror(repo_path, name, url, opts \\ []) do
    with :ok <- config(repo_path, "forge.mirror.#{name}.url", url),
         :ok <- config(repo_path, "forge.mirror.#{name}.refs", opts[:refs]) do
      config(repo_path, "forge.mirror.#{name}.user", opts[:user])
    end
  end

  @doc "Removes one mirror and everything the hook recorded about it."
  @spec delete_mirror(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_mirror(repo_path, name) do
    case Git.run(repo_path, ["config", "--local", "--remove-section", "forge.mirror.#{name}"]) do
      {:ok, _out} -> :ok
      # 128 is "no such section", which is the state the caller wanted anyway.
      {:error, {128, _out}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # `https://user:token@host/x` becomes `https://host/x`, and anything without a `scheme://user@`
  # prefix is left alone — including the `git@host:path` an even older mirror may hold, which has
  # no password half to leak and is not a URL this could take apart safely.
  @userinfo ~r{\A([a-zA-Z][a-zA-Z0-9+.\-]*://)[^/@]*@}

  defp strip_userinfo(nil), do: nil
  defp strip_userinfo(url), do: String.replace(url, @userinfo, "\\1")

  # `--local`, like the hook: a `forge.mirror.<name>.url` in the service user's own ~/.gitconfig
  # would otherwise be listed as a mirror of every repository on the node, and could not be
  # removed from the UI, because `delete_mirror/2` unsets `--local`.
  defp names(repo_path) do
    case Git.run(repo_path, [
           "config",
           "--local",
           "--get-regexp",
           ~S(^forge\.mirror\.[a-z0-9-]+\.url$)
         ]) do
      {:ok, out} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          line
          |> String.split(" ", parts: 2)
          |> hd()
          |> String.replace_prefix("forge.mirror.", "")
          |> String.replace_suffix(".url", "")
        end)

      {:error, _reason} ->
        []
    end
  end

  # **Runs on every boot, because there is no other moment every repository passes.** A node that
  # upgrades has `forge.mirror` set and no named mirrors; it becomes the mirror called `default`.
  # A URL the new rules refuse — an ssh remote, say — is carried over rather than dropped, so the
  # hook can report it as failing and an operator can see that it stopped.
  defp migrate_scalar(repo_path) do
    with [] <- names(repo_path),
         url when is_binary(url) <- get(repo_path, "forge.mirror") do
      refs = get(repo_path, "forge.mirrorRefs")

      with :ok <- put_mirror(repo_path, "default", url, refs: refs),
           :ok <- unset(repo_path, "forge.mirror") do
        unset(repo_path, "forge.mirrorRefs")
      end
    else
      _already -> :ok
    end
  end

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
    case Git.run(repo_path, ["config", "--local", "--get", key]) do
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
