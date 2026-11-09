defmodule Forge.ReleaseRecords.Tag do
  @moduledoc """
  The git tag of a release (`docs/design/ticket-types.md` § The record, the tag, the history).

  Made by the platform on the record's commit, as an annotated tag by the platform's identity
  (`Forge.Git.identity/0`), and pushed with `Forge.Git.push_internal/2` so that `pre-receive` admits
  it (create only, on a commit in the default branch's history) and `post-receive` mirrors it.
  **Never moves a tag and never raises**: every failure is an answer the record stores in words.
  """

  alias Forge.Git
  alias Forge.Projects
  alias Forge.Projects.Project

  @type result ::
          {:tagged, String.t()}
          | {:taken, String.t(), String.t()}
          | {:failed, String.t(), String.t()}

  @reason_bytes 300

  @doc "`v<version>`, a leading `v` of the version dropped first: `0.18.0` and `v0.18.0` agree."
  @spec name(String.t()) :: String.t()
  def name(version), do: "v" <> String.replace_prefix(version, "v", "")

  @doc """
  Makes the tag for `version` on `sha`, with `message` as its text (the tag's name when blank).

  `{:tagged, name}` when it was made or was already on `sha`; `{:taken, name, other}` when the name
  points at another commit, which is left alone; `{:failed, name, reason}` otherwise.
  """
  @spec make(Project.t(), String.t(), Git.sha(), String.t() | nil) :: result()
  def make(%Project{} = project, version, sha, message) do
    repo = Projects.repo_path(project)
    name = name(version)

    case existing(repo, name) do
      {:ok, ^sha} -> {:tagged, name}
      {:ok, other} -> {:taken, name, other}
      :none -> create(repo, name, sha, message)
    end
  end

  defp create(repo, name, sha, message) do
    ref = "refs/tags/" <> name

    with :ok <- check_name(repo, ref),
         {:ok, tag} <- write_tag(repo, name, sha, message),
         :ok <- Git.push_internal(repo, tag <> ":" <> ref) do
      {:tagged, name}
    else
      {:error, reason} -> after_failure(repo, name, sha, reason)
    end
  end

  # A semantic version can be a name git refuses (`1.0.0-a..b`), and the version was only held to
  # the shape a title can safely take.
  defp check_name(repo, ref) do
    case Git.run(repo, ["check-ref-format", {:data, ref}]) do
      {:ok, _out} -> :ok
      {:error, _reason} -> {:error, :bad_name}
    end
  end

  # Re-read once: a concurrent conclusion may have made the tag between our read and our push,
  # and then the push is refused for creating what exists.
  defp after_failure(repo, name, sha, reason) do
    case existing(repo, name) do
      {:ok, ^sha} -> {:tagged, name}
      {:ok, other} -> {:taken, name, other}
      :none -> {:failed, name, words(reason)}
    end
  end

  defp existing(repo, name) do
    case Git.run(repo, [
           "rev-parse",
           "--verify",
           "--quiet",
           {:data, "refs/tags/" <> name <> "^{commit}"}
         ]) do
      {:ok, out} -> {:ok, String.trim(out)}
      {:error, _reason} -> :none
    end
  end

  defp write_tag(repo, name, sha, message) do
    {tagger, email} = Git.identity()
    text = if blank?(message), do: name, else: String.trim_trailing(message)

    body =
      "object #{sha}\ntype commit\ntag #{name}\ntagger #{tagger} <#{email}> " <>
        "#{System.os_time(:second)} +0000\n\n#{text}\n"

    Git.with_scratch_file("release-tag", body, fn file ->
      case Git.run(repo, ["hash-object", "-t", "tag", "-w", {:data, file}]) do
        {:ok, out} -> {:ok, String.trim(out)}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp blank?(message), do: not is_binary(message) or String.trim(message) == ""

  defp words(:bad_name), do: "the name is not one git accepts as a tag"
  defp words({:scratch_file, reason}), do: "could not write the tag: #{inspect(reason)}"

  defp words({code, output}) when is_integer(code) and is_binary(output) do
    case output |> String.replace(~r/\s+/, " ") |> String.trim() do
      "" -> "git refused the tag"
      detail -> "git refused the tag: " <> clip(detail)
    end
  end

  defp words(other), do: "the tag could not be made: " <> clip(inspect(other))

  defp clip(text) do
    if byte_size(text) > @reason_bytes,
      do: String.slice(text, 0, @reason_bytes) <> "…",
      else: text
  end
end
