defmodule Forge.Jobs.Blobs do
  @moduledoc """
  A run's groups of files on the platform (`docs/design/workflow-grammar-v1.md` § Semantics,
  `docs/design/storage.md` § Serving): where the worker may put them, and recording what it put as
  blob versions on the ticket.

  What the worker reports is not a guard. A file is recorded only when its group is one the job
  declared, its name is an artifact name, and its key is under the job's own keys and in the
  store — whatever the result says about it.
  """

  alias Ecto.Multi
  alias Forge.{Artifacts, Storage}
  alias Forge.Jobs.Job
  alias ForgeCore.Job.{Result, Spec}
  alias ForgeCore.Workflow

  require Logger

  @doc """
  What the assignment carries for a job that declares a group of files: a prefix of its own keys,
  fresh per assignment as a transcript's key is, and a `put` token for it that lives `lifetime_ms`
  past its minting. Empty for a job that declares none.
  """
  @spec outputs(Job.t(), Spec.t(), non_neg_integer()) :: map()
  def outputs(%Job{} = job, %Spec{} = spec, lifetime_ms) do
    case Spec.group_outputs(spec) do
      [] ->
        %{}

      _groups ->
        prefix = Storage.Key.job_prefix(job.id, "out-" <> Storage.Key.nonce())

        %{
          "outputs" => %{
            "prefix" => prefix,
            "token" => Storage.Token.sign_prefix(prefix, outlasting_ms: lifetime_ms)
          }
        }
    end
  end

  @doc "Adds a blob version to `multi` for each file of the result it may record."
  @spec put(Multi.t(), term(), Job.t(), Spec.t(), Result.t()) :: Multi.t()
  def put(multi, ticket_id, %Job{} = job, %Spec{} = spec, %Result{blobs: blobs}) do
    groups = Spec.group_outputs(spec)

    blobs
    |> Enum.sort()
    |> Enum.reduce(multi, fn {name, info}, multi ->
      with :ok <- declared(name, groups),
           {:ok, key} <- owned(job, info),
           {:ok, %{hash: hash}} <- Storage.stat(key) do
        Artifacts.put_version(multi, {:blob, name}, ticket_id, name, :blob, {:job, job.id}, %{
          blob_uri: Storage.uri(key),
          content_hash: hash
        })
      else
        {:error, reason} ->
          Logger.warning("job #{job.id} reported #{inspect(name)}: #{inspect(reason)}")
          multi
      end
    end)
  end

  defp declared(name, groups) do
    case String.split(name, "/", parts: 2) do
      [group, file] ->
        if group in groups and Workflow.valid_name?(file), do: :ok, else: {:error, :undeclared}

      _other ->
        {:error, :undeclared}
    end
  end

  defp owned(%Job{id: id}, %{"key" => key}) do
    if Storage.Key.job?(key, id), do: {:ok, key}, else: {:error, :not_this_jobs}
  end

  defp owned(_job, _info), do: {:error, :no_key}
end
