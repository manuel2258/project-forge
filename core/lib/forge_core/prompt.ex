defmodule ForgeCore.Prompt do
  @moduledoc """
  Composes the prompt a job's agent receives: the platform preamble, the project's state
  prompt, and the job manifest rendered from the spec. See `docs/design/job-prompt.md`.
  """

  alias ForgeCore.Job.Spec
  alias ForgeCore.Workflow

  @preamble_path Path.join(:code.priv_dir(:forge_core), "preamble.md")
  @external_resource @preamble_path
  @preamble File.read!(@preamble_path)
  @preamble_hash "sha256:" <> Base.encode16(:crypto.hash(:sha256, @preamble), case: :lower)

  @doc "The platform-owned preamble, identical for every job."
  @spec preamble() :: String.t()
  def preamble, do: @preamble

  @doc "Hash of the preamble, recorded in every job spec."
  @spec preamble_hash() :: String.t()
  def preamble_hash, do: @preamble_hash

  @doc "The full prompt for `spec`, given the absolute job directory."
  @spec compose(Spec.t(), String.t()) :: String.t()
  def compose(%Spec{} = spec, job_dir) do
    [
      @preamble,
      "---\n\n# Project instructions for state `#{spec.state}`\n\n" <> String.trim(spec.prompt),
      "---\n\n" <> manifest(spec, job_dir)
    ]
    |> Enum.map_join("\n\n", &String.trim_trailing/1)
    |> Kernel.<>("\n")
  end

  @doc "The job manifest section: what this job is, its inputs, outputs, outcomes and budget."
  @spec manifest(Spec.t(), String.t()) :: String.t()
  def manifest(%Spec{} = spec, job_dir) do
    """
    # Job manifest

    - Ticket #{spec.ticket.number}: #{spec.ticket.title}
    - State: `#{spec.state}` (attempt #{spec.attempt})
    - Job directory: `#{job_dir}`
    - Branch: `#{spec.branch}` (workflow pinned at commit `#{spec.commit}`)

    ## Inputs (read-only)

    #{inputs(spec, job_dir)}

    ## Outputs to write

    #{outputs(spec, job_dir)}

    ## Allowed outcomes

    #{outcomes(spec)}

    ## Budget

    - Turns: #{spec.budget.turns}
    - Cost: #{spec.budget.cost} USD
    """
  end

  defp inputs(%Spec{inputs: []}, _job_dir), do: "- none"

  defp inputs(%Spec{inputs: inputs}, job_dir) do
    Enum.map_join(inputs, "\n", fn input ->
      "- `#{input.name}` version #{input.version} -> `#{Path.join([job_dir, "inputs", input.name])}`"
    end)
  end

  defp outputs(%Spec{produces: produces} = spec, job_dir) do
    outcome_document = Spec.outcome_document(spec)

    Enum.map_join(produces, "\n", fn name ->
      cond do
        not Workflow.document?(name) ->
          "- `#{name}`: the diff of your commits on `#{spec.branch}`; no file to write"

        name == outcome_document ->
          "- `#{name}` -> `#{Path.join([job_dir, "out", name])}` (carries the outcome)"

        true ->
          "- `#{name}` -> `#{Path.join([job_dir, "out", name])}`"
      end
    end)
  end

  defp outcomes(%Spec{outcomes: outcomes}) do
    listed = Enum.map_join(outcomes, ", ", &"`#{&1}`")
    "#{listed}, or `did_not_converge` if the work could not be completed."
  end
end
