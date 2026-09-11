defmodule ForgeWorker.Job.Dir do
  @moduledoc """
  The job directory: the agent's whole interface to the platform, as files.
  See `docs/design/job-prompt.md`.

      <root>/<job_id>/spec.json
      <root>/<job_id>/prompt.md
      <root>/<job_id>/inputs/<name>
      <root>/<job_id>/out/<name>
      <root>/<job_id>/transcript.jsonl
      <root>/<job_id>/stderr.log
  """

  alias ForgeCore.Document
  alias ForgeCore.Job.Spec

  @doc "Creates the directory for `spec` under `root`, writes spec and inputs, returns its path."
  @spec prepare(String.t(), Spec.t()) :: String.t()
  def prepare(root, %Spec{} = spec) do
    job_dir = Path.join(root, spec.job_id)
    File.rm_rf!(job_dir)
    File.mkdir_p!(Path.join(job_dir, "inputs"))
    File.mkdir_p!(Path.join(job_dir, "out"))
    File.write!(Path.join(job_dir, "spec.json"), Spec.to_json(spec))

    Enum.each(spec.inputs, fn input ->
      path = Path.join([job_dir, "inputs", input.name])
      File.write!(path, input.content)
      File.chmod!(path, 0o444)
    end)

    job_dir
  end

  @doc "Reads and parses what the agent wrote under `out/`, against what the spec declared."
  @spec collect(String.t(), Spec.t()) :: %{
          documents: %{String.t() => Document.t()},
          invalid: %{String.t() => [ForgeCore.Error.t()]},
          missing: [String.t()],
          undeclared: [String.t()]
        }
  def collect(job_dir, %Spec{} = spec) do
    out = Path.join(job_dir, "out")
    declared = Spec.document_outputs(spec)
    written = out |> File.ls!() |> Enum.sort()

    parsed =
      declared
      |> Enum.filter(&(&1 in written))
      |> Map.new(fn name ->
        {name, out |> Path.join(name) |> File.read!() |> Document.parse()}
      end)

    %{
      documents: for({name, {:ok, doc}} <- parsed, into: %{}, do: {name, doc}),
      invalid: for({name, {:error, errors}} <- parsed, into: %{}, do: {name, errors}),
      missing: declared -- written,
      undeclared: written -- declared
    }
  end

  @spec prompt_path(String.t()) :: String.t()
  def prompt_path(job_dir), do: Path.join(job_dir, "prompt.md")

  @spec transcript_path(String.t()) :: String.t()
  def transcript_path(job_dir), do: Path.join(job_dir, "transcript.jsonl")

  @spec stderr_path(String.t()) :: String.t()
  def stderr_path(job_dir), do: Path.join(job_dir, "stderr.log")
end
