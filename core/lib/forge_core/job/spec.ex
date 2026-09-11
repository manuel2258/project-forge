defmodule ForgeCore.Job.Spec do
  @moduledoc """
  The immutable specification a job receives. Built by the platform at job creation, stored
  on the job row, sent to the worker, and never changed. See `docs/design/data-model.md`.

  Documents are inlined as `inputs[].content` so the worker needs no further round trip.
  """

  alias ForgeCore.Job.Spec.Input
  alias ForgeCore.Workflow

  @enforce_keys [
    :job_id,
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
  defstruct [
    :job_id,
    :ticket,
    :state,
    :attempt,
    :prompt,
    :prompt_path,
    :env,
    :commit,
    :branch,
    :budget,
    :preamble_hash,
    inputs: [],
    produces: [],
    outcomes: ["done"],
    permitted_children: []
  ]

  @type t :: %__MODULE__{
          job_id: String.t(),
          ticket: %{number: pos_integer(), title: String.t()},
          state: String.t(),
          attempt: pos_integer(),
          prompt: String.t(),
          prompt_path: String.t() | nil,
          env: String.t() | nil,
          commit: String.t(),
          branch: String.t(),
          budget: %{turns: pos_integer(), cost: number()},
          preamble_hash: String.t() | nil,
          inputs: [Input.t()],
          produces: [String.t()],
          outcomes: [String.t()],
          permitted_children: [String.t()]
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
      ticket: %{number: nested(get.(:ticket), :number), title: nested(get.(:ticket), :title)},
      state: get.(:state),
      attempt: get.(:attempt),
      prompt: get.(:prompt),
      prompt_path: get.(:prompt_path),
      env: get.(:env),
      commit: get.(:commit),
      branch: get.(:branch),
      budget: %{turns: nested(get.(:budget), :turns), cost: nested(get.(:budget), :cost)},
      preamble_hash: get.(:preamble_hash),
      inputs: Enum.map(get.(:inputs) || [], &input_from_map/1),
      produces: get.(:produces) || [],
      outcomes: get.(:outcomes) || ["done"],
      permitted_children: get.(:permitted_children) || []
    }
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
