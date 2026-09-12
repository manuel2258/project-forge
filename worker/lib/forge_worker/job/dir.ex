defmodule ForgeWorker.Job.Dir do
  @moduledoc """
  The job directory: the agent's whole interface to the platform, as files.
  See `docs/design/job-prompt.md`.

      <root>/<job_id>/spec.json
      <root>/<job_id>/prompt.md
      <root>/<job_id>/inputs/<name>
      <root>/<job_id>/out/<name>
      <root>/<job_id>/home                 HOME for the harness process
      <root>/<job_id>/transcript-<run>.jsonl
      <root>/<job_id>/stderr.log
  """

  alias ForgeCore.Document
  alias ForgeCore.Job.Spec

  @uuid ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  @doc """
  Prepares the directory for `spec` under `root` and returns its path. On a first run it is
  created; on a resume the spec and inputs are refreshed while `out/`, earlier transcripts
  and the harness home are kept, so nothing the job already produced is lost.
  """
  @spec prepare(String.t(), Spec.t()) :: String.t()
  def prepare(root, %Spec{job_id: job_id} = spec) do
    unless Regex.match?(@uuid, job_id) do
      raise ArgumentError, "job id must be a UUID, got #{inspect(job_id)}"
    end

    job_dir = Path.join(root, job_id)
    inputs = Path.join(job_dir, "inputs")
    File.rm_rf!(inputs)
    File.mkdir_p!(inputs)
    File.mkdir_p!(Path.join(job_dir, "out"))
    File.mkdir_p!(home_dir(job_dir))
    File.write!(Path.join(job_dir, "spec.json"), Spec.to_json(spec))

    Enum.each(spec.inputs, fn input ->
      path = Path.join(inputs, input.name)
      File.write!(path, input.content)
      File.chmod!(path, 0o444)
    end)

    job_dir
  end

  @doc "The harness's private HOME, so its own state lives with the job and not the operator."
  @spec home_dir(String.t()) :: String.t()
  def home_dir(job_dir), do: Path.join(job_dir, "home")

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
      |> Map.new(fn name -> {name, read_document(Path.join(out, name))} end)

    %{
      documents: for({name, {:ok, doc}} <- parsed, into: %{}, do: {name, doc}),
      invalid: for({name, {:error, errors}} <- parsed, into: %{}, do: {name, errors}),
      missing: declared -- written,
      undeclared: written -- declared
    }
  end

  # Only regular files count. A directory or a FIFO in `out/` would crash or hang the reader.
  defp read_document(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        path |> File.read!() |> Document.parse()

      {:ok, %File.Stat{type: type}} ->
        {:error, [ForgeCore.Error.new("", "output must be a regular file, got #{type}")]}

      {:error, reason} ->
        {:error, [ForgeCore.Error.new("", "output unreadable: #{inspect(reason)}")]}
    end
  end

  @spec prompt_path(String.t()) :: String.t()
  def prompt_path(job_dir), do: Path.join(job_dir, "prompt.md")

  @doc "A fresh transcript path for this run: `transcript-1.jsonl`, `transcript-2.jsonl`, ..."
  @spec new_transcript_path(String.t()) :: String.t()
  def new_transcript_path(job_dir) do
    run = job_dir |> File.ls!() |> Enum.count(&String.starts_with?(&1, "transcript-"))
    Path.join(job_dir, "transcript-#{run + 1}.jsonl")
  end

  @spec stderr_path(String.t()) :: String.t()
  def stderr_path(job_dir), do: Path.join(job_dir, "stderr.log")
end
