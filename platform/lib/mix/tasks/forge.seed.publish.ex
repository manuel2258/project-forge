defmodule Mix.Tasks.Forge.Seed.Publish do
  @shortdoc "Publishes a worker seed: mix forge.seed.publish PROJECT DIRECTORY"

  @moduledoc """
  Publishes a project's worker seed — a full clone plus its warm build directory — to the
  store, and makes it the one workers fetch.

  `docs/design/worker-tier.md` § Volumes and the seed says what belongs in DIRECTORY and why it
  is maintained rather than derived: M1 measured a build directory produced from the dependency
  closure and the toolchain rebuilt all of it, while one copied from another checkout rebuilt
  only the project's own sources. So this is a blob somebody keeps up to date, and refreshing
  it is an operator's action with this task behind it.

  DIRECTORY is archived as it stands, which means the clone in it must be a clone and not a
  git worktree: a worktree's `.git` is a file pointing at a repository that will not be there,
  and every snapshot of it would share one index and one HEAD.

      mix forge.seed.publish demo /var/lib/seeds/demo

  The id is the archive's own hash, so publishing the same bytes twice names the same seed and
  the second `put` is refused — which is the store saying nothing changed, not an error worth
  acting on.
  """

  use Mix.Task

  alias Forge.{CLI, Projects, Storage}

  @impl true
  def run(args) do
    case args do
      [name, dir] -> publish(name, Path.expand(dir))
      _other -> CLI.fail("usage: mix forge.seed.publish PROJECT DIRECTORY")
    end
  end

  defp publish(name, dir) do
    CLI.boot()

    project = Projects.by_name(name) || CLI.fail("unknown project #{name}")
    File.dir?(dir) || CLI.fail("#{dir} is not a directory")
    File.dir?(Path.join(dir, ".git")) || CLI.fail("#{dir} does not look like a clone")

    tarball = archive(dir)

    try do
      upload(project, seed_id(tarball), tarball)
    after
      File.rm(tarball)
    end
  end

  defp upload(project, seed_id, tarball) do
    key = Storage.Key.seed(project.name, seed_id)
    Mix.shell().info("publishing #{key}")

    case Storage.put(key, {:file, tarball}, []) do
      {:ok, %{size: size}} -> Mix.shell().info("uploaded #{size} bytes")
      # The id is the bytes' own hash, so this is the store saying nothing changed.
      {:error, :exists} -> Mix.shell().info("already in the store; the bytes are unchanged")
      {:error, reason} -> CLI.fail("could not upload the seed: #{inspect(reason)}")
    end

    case Projects.update(project, %{seed_id: seed_id}) do
      {:ok, _project} -> Mix.shell().info("#{project.name} now seeds from #{key}")
      {:error, changeset} -> CLI.fail(inspect(changeset.errors))
    end
  end

  # The contents of the directory, not the directory itself: the worker unpacks into a volume
  # it made, so an extra level would put the clone one directory too deep.
  defp archive(dir) do
    tarball =
      Path.join(System.tmp_dir!(), "forge-seed-#{System.unique_integer([:positive])}.tar.gz")

    case System.cmd("tar", ["-czf", tarball, "-C", dir, "."], stderr_to_stdout: true) do
      {_out, 0} -> tarball
      {out, code} -> CLI.fail("could not archive #{dir} (#{code}): #{out}")
    end
  end

  # `<seed_id>` identifies the contents, not the time (`docs/design/storage.md` § Keys), so it
  # is the archive's hash. Streamed, because a seed is hundreds of megabytes.
  defp seed_id(tarball) do
    hash =
      tarball
      |> File.stream!(1024 * 1024)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    "sha256-" <> String.slice(hash, 0, 32)
  end
end
