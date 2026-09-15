defmodule ForgeCore.Job.Spec do
  @moduledoc """
  The immutable specification a job receives. Built by the platform at job creation, stored
  on the job row, sent to the worker, and never changed. See `docs/design/data-model.md`.

  Documents are inlined as `inputs[].content` so the worker needs no further round trip.
  `answered_keys` lists question keys a person has already answered on this ticket; a
  blocking question with one of these keys does not stop the job again. It is filled at
  run time, not stored.
  """

  alias ForgeCore.Job.Spec.Input
  alias ForgeCore.Workflow

  # A conversation has no state, no outcomes and no budget of its own, so the keys a workflow
  # job must have cannot be enforced by the struct any more. They are enforced by `validate/1`
  # instead, at the one place a workflow spec is built — which is a weaker guarantee than the
  # compiler's and is why it is called rather than merely available.
  #
  # The alternative was a second struct, and it was rejected because a union type would then have
  # to be threaded through `Dir.prepare/3`, `Dir.collect/2`, `Prompt.compose/2`, `Slice.prepare/1`
  # and the whole wire format, to distinguish two things that are the same job everywhere else.
  @enforce_keys [:job_id, :branch]
  defstruct [
    :job_id,
    :ticket,
    :state,
    :attempt,
    :prompt,
    :prompt_path,
    :env,
    # What this job runs on, already resolved: the state's model, else the project's, else nil
    # for whatever the machine was built with. The worker does not re-decide it — the platform
    # knows the state and the project, and the machine knows neither.
    :model,
    :commit,
    :branch,
    :budget,
    :preamble_hash,
    kind: :workflow,
    inputs: [],
    produces: [],
    outcomes: ["done"],
    permitted_children: [],
    answered_keys: []
  ]

  @workflow_keys [
    :ticket,
    :state,
    :attempt,
    :prompt,
    :produces,
    :outcomes,
    :budget,
    :commit,
    :branch
  ]

  @type t :: %__MODULE__{
          job_id: String.t(),
          kind: :workflow | :chat,
          ticket: %{number: pos_integer(), title: String.t()} | nil,
          state: String.t() | nil,
          attempt: pos_integer() | nil,
          prompt: String.t() | nil,
          prompt_path: String.t() | nil,
          env: String.t() | nil,
          model: String.t() | nil,
          commit: String.t(),
          branch: String.t(),
          budget: %{turns: pos_integer(), cost: number()},
          preamble_hash: String.t() | nil,
          inputs: [Input.t()],
          produces: [String.t()],
          outcomes: [String.t()],
          permitted_children: [String.t()],
          answered_keys: [String.t()]
        }

  defmodule Input do
    @moduledoc """
    One pinned input: an artifact name, the version consumed, and its content. For the
    `changeset` input the version is the head commit the diff was taken at.
    """

    @enforce_keys [:name, :version, :content]
    defstruct [:name, :version, :content]

    @type t :: %__MODULE__{
            name: String.t(),
            version: pos_integer() | String.t(),
            content: String.t()
          }
  end

  @doc "The document whose front matter carries the outcome, or nil if none is produced."
  @spec outcome_document(t()) :: String.t() | nil
  def outcome_document(%__MODULE__{produces: produces}),
    do: Enum.find(produces, &Workflow.document?/1)

  @doc "Declared outputs that are documents, i.e. files the agent must write."
  @spec document_outputs(t()) :: [String.t()]
  def document_outputs(%__MODULE__{produces: produces}),
    do: Enum.filter(produces, &Workflow.document?/1)

  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = spec) do
    spec
    |> Map.from_struct()
    |> Map.update!(:inputs, fn inputs -> Enum.map(inputs, &Map.from_struct/1) end)
    |> Jason.encode!(pretty: true)
  end

  @spec from_json(String.t()) :: {:ok, t()} | {:error, term()}
  def from_json(json) when is_binary(json) do
    with {:ok, map} <- Jason.decode(json) do
      {:ok, from_map(map)}
    end
  end

  @doc "Builds a spec from a map with string or atom keys, as stored on the job row."
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    get = fn key -> Map.get(map, to_string(key)) || Map.get(map, key) end

    %__MODULE__{
      job_id: get.(:job_id),
      kind: kind(get.(:kind)),
      ticket: ticket_from_map(get.(:ticket)),
      state: get.(:state),
      attempt: get.(:attempt),
      prompt: get.(:prompt),
      prompt_path: get.(:prompt_path),
      env: get.(:env),
      model: get.(:model),
      commit: get.(:commit),
      branch: get.(:branch),
      budget: budget_from_map(get.(:budget)),
      preamble_hash: get.(:preamble_hash),
      inputs: Enum.map(get.(:inputs) || [], &input_from_map/1),
      produces: get.(:produces) || [],
      outcomes: get.(:outcomes) || ["done"],
      permitted_children: get.(:permitted_children) || [],
      answered_keys: get.(:answered_keys) || []
    }
  end

  # A conversation's spec carries no ticket and no budget, and a round trip must give back the
  # nil rather than a map of nils — `%{number: nil, title: nil}` is truthy, and every `if
  # spec.ticket` downstream would take the wrong branch.
  defp ticket_from_map(nil), do: nil
  defp ticket_from_map(map), do: %{number: nested(map, :number), title: nested(map, :title)}

  defp budget_from_map(nil), do: nil
  defp budget_from_map(map), do: %{turns: nested(map, :turns), cost: nested(map, :cost)}

  defp kind(nil), do: :workflow
  defp kind("chat"), do: :chat
  defp kind("workflow"), do: :workflow
  defp kind(kind) when is_atom(kind), do: kind

  @doc """
  Checks that a workflow spec has everything a workflow job needs, now that the struct cannot.

  Called where a spec is built, not where one is read: a spec that reaches the worker incomplete
  is a job that fails on the machine after a credential has been minted and a slice made.
  """
  @spec validate(t()) :: :ok | {:error, [atom()]}
  def validate(%__MODULE__{kind: :chat} = spec) do
    if spec.job_id && spec.branch, do: :ok, else: {:error, [:job_id, :branch]}
  end

  def validate(%__MODULE__{} = spec) do
    case Enum.filter(@workflow_keys, &is_nil(Map.fetch!(spec, &1))) do
      [] -> :ok
      missing -> {:error, missing}
    end
  end

  defp input_from_map(map) do
    %Input{
      name: nested(map, :name),
      version: nested(map, :version),
      content: nested(map, :content)
    }
  end

  defp nested(nil, _key), do: nil
  defp nested(map, key), do: Map.get(map, to_string(key)) || Map.get(map, key)
end
