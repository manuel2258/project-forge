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
    # What a reopened conversation had already said, rendered, for the new process to read as
    # `$FORGE_JOB/conversation.md`. Nil for a conversation's first process and for every workflow
    # job. Inlined like an input's content, and for the same reason: the worker needs no further
    # round trip (`docs/design/conversations.md` § Lifetime).
    :replay,
    # How the ticket came into this job's state: `%{"from", "outcome", "by", "comment"}`, from the
    # transition that created the job, or nil for the ticket's first state
    # (`docs/design/job-prompt.md` § How the job arrived). `"batch"` too when it came from a
    # command state: the batch of commands that state last ran to a decision.
    :entered,
    # A command job's whole description, string keys: `name`, `args`, `run`, `script` (the text of
    # `run` at the pinned commit), `at` (the commit to run against), `timeout_ms`, `produces` and
    # `batch`, and `concurrent` when its invoker's grant limits it (`docs/design/commands.md`).
    :command,
    kind: :workflow,
    inputs: [],
    # Optional inputs that had not been written when the job was created, by name. Named so the
    # manifest can say so rather than leave the agent to guess whether a missing file is a failure
    # (`docs/design/workflow-grammar-v1.md` § Inputs).
    absent_inputs: [],
    produces: [],
    outcomes: ["done"],
    permitted_children: [],
    answered_keys: [],
    # What this job's agent may invoke, by command: `%{"max", "concurrent"}` from the state, and
    # `"remaining"` added at run time (`docs/design/workflow-grammar-v1.md` § Commands).
    may_invoke: %{},
    # The batch a parked job invoked, filled at run time for its resume: each entry's `command`,
    # `args`, `at`, `exit_status`, `outcome`, `duration_ms`, `log` (the file name under
    # `$FORGE_JOB/commands/`) or `refused` (`docs/design/job-prompt.md` § Commands).
    command_results: [],
    # The batch `entered` names, filled at run time the same way, each entry's `log` named
    # `entered-<n>-<command>.log`: what the commands of the state that sent the ticket here said
    # (`docs/design/job-prompt.md` § How the job arrived).
    entered_commands: [],
    # The commit the previous attempt of this state read as its `changeset`, filled at run time
    # for a job that reads one too: what a second review asks first is what changed since the
    # first (`docs/design/job-prompt.md` § How the job arrived).
    previous_changeset: nil,
    # An integrating job's (`docs/design/job-prompt.md` § Integrating the default branch), string
    # keys: `default_branch` when it is made, and at run time `head`, `base`, `paths`,
    # `changeset`, `merges` (each `sha` and `subject`, newest first) and `more`, for the manifest.
    # Nil for every other job.
    integration: nil,
    # The names of the project secrets this run holds in its environment, filled at assignment —
    # never a value, which travels sealed beside the spec (`docs/design/secrets.md` § Delivery).
    # What the manifest names, so the agent knows they are there and what not to do with them.
    secrets: [],
    # A conversation's: what it was opened with that has been deleted since, so a reopened one is
    # told the variable is gone rather than finding it missing (`docs/design/secrets.md`
    # § Conversations). Always empty for a workflow job, which does not run without them.
    secrets_gone: []
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
          kind: :workflow | :chat | :command,
          command: %{String.t() => term()} | nil,
          may_invoke: %{String.t() => %{String.t() => pos_integer() | nil}},
          command_results: [%{String.t() => term()}],
          entered_commands: [%{String.t() => term()}],
          previous_changeset: String.t() | nil,
          integration: %{String.t() => term()} | nil,
          secrets: [String.t()],
          secrets_gone: [String.t()],
          ticket:
            %{number: pos_integer(), title: String.t(), ticket_type: String.t() | nil} | nil,
          state: String.t() | nil,
          attempt: pos_integer() | nil,
          prompt: String.t() | nil,
          prompt_path: String.t() | nil,
          env: String.t() | nil,
          model: String.t() | nil,
          commit: String.t(),
          branch: String.t(),
          # At run time also `ticket_left` and `ticket_limit`, and `declared` and `lowered_by`
          # when the cost is less than the state declared.
          budget: %{
            required(:turns) => pos_integer(),
            required(:cost) => number(),
            optional(atom()) => term()
          },
          preamble_hash: String.t() | nil,
          replay: String.t() | nil,
          entered: %{String.t() => String.t() | nil} | nil,
          inputs: [Input.t()],
          absent_inputs: [String.t()],
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

  @doc """
  The groups of files this job writes, by directory name: an agent's declared `name/*`, a
  command's `outputs` (`docs/design/workflow-grammar-v1.md` § Semantics).
  """
  @spec group_outputs(t()) :: [String.t()]
  def group_outputs(%__MODULE__{kind: :command, command: command}),
    do: Enum.map((command || %{})["outputs"] || [], &Workflow.group_name/1)

  def group_outputs(%__MODULE__{produces: produces}),
    do: for(name <- produces, Workflow.group?(name), do: Workflow.group_name(name))

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
      replay: get.(:replay),
      entered: entered_from_map(get.(:entered)),
      inputs: Enum.map(or_default(get, :inputs, []), &input_from_map/1),
      absent_inputs: or_default(get, :absent_inputs, []),
      command: get.(:command),
      may_invoke: or_default(get, :may_invoke, %{}),
      command_results: or_default(get, :command_results, []),
      entered_commands: or_default(get, :entered_commands, []),
      previous_changeset: get.(:previous_changeset),
      integration: get.(:integration),
      produces: or_default(get, :produces, []),
      outcomes: or_default(get, :outcomes, ["done"]),
      permitted_children: or_default(get, :permitted_children, []),
      answered_keys: or_default(get, :answered_keys, []),
      secrets: or_default(get, :secrets, []),
      secrets_gone: or_default(get, :secrets_gone, [])
    }
  end

  # A key the map leaves out comes back as its empty value, never nil: every caller folds over it.
  # A function rather than `||` inline, which Credo counts as a branch each.
  defp or_default(get, key, default), do: get.(key) || default

  # A conversation's spec carries no ticket and no budget, and a round trip must give back the
  # nil rather than a map of nils — `%{number: nil, title: nil}` is truthy, and every `if
  # spec.ticket` downstream would take the wrong branch.
  defp ticket_from_map(nil), do: nil
  # `ticket_type` is absent from a spec made before ticket types: the single workflow file.
  defp ticket_from_map(map),
    do: %{
      number: nested(map, :number),
      title: nested(map, :title),
      ticket_type: nested(map, :ticket_type)
    }

  # String keys whichever way it arrived, because the manifest reads it by string and a spec built
  # in memory and one read back from the row must render the same.
  defp entered_from_map(nil), do: nil

  defp entered_from_map(map) do
    entered = %{
      "from" => nested(map, :from),
      "outcome" => nested(map, :outcome),
      "by" => nested(map, :by),
      "comment" => nested(map, :comment)
    }

    # Only from a command state, so every other arrival keeps the shape it always had.
    case nested(map, :batch) do
      nil -> entered
      batch -> Map.put(entered, "batch", batch)
    end
  end

  defp budget_from_map(nil), do: nil

  # `turns` and `cost` always; the rest only when the platform added them at run time — the
  # ticket's allowance, and what a lowered cost was lowered from and by — so a budget stated on its
  # own keeps the shape it always had.
  defp budget_from_map(map) do
    [:ticket_left, :ticket_limit, :declared, :lowered_by]
    |> Enum.reduce(%{turns: nested(map, :turns), cost: nested(map, :cost)}, fn key, budget ->
      case nested(map, key) do
        nil -> budget
        value -> Map.put(budget, key, value)
      end
    end)
  end

  # Named rather than converted, and a kind nobody knows is refused as `Result` refuses a status it
  # does not know: a spec whose kind is guessed runs the wrong job.
  defp kind(nil), do: :workflow
  defp kind(kind) when kind in ["chat", :chat], do: :chat
  defp kind(kind) when kind in ["workflow", :workflow], do: :workflow
  defp kind(kind) when kind in ["command", :command], do: :command
  defp kind(other), do: raise(ArgumentError, "unknown job kind: #{inspect(other)}")

  @doc """
  Checks that a workflow spec has everything a workflow job needs, now that the struct cannot.

  Called where a spec is built, not where one is read: a spec that reaches the worker incomplete
  is a job that fails on the machine after a credential has been minted and a slice made.
  """
  @spec validate(t()) :: :ok | {:error, [atom()]}
  def validate(%__MODULE__{kind: :chat} = spec) do
    if spec.job_id && spec.branch, do: :ok, else: {:error, [:job_id, :branch]}
  end

  # A command runs a script at a commit, and neither can be guessed on the machine.
  def validate(%__MODULE__{kind: :command} = spec) do
    command = spec.command || %{}

    missing =
      [job_id: spec.job_id, branch: spec.branch, script: command["script"], at: command["at"]]
      |> Enum.filter(fn {_key, value} -> is_nil(value) end)
      |> Enum.map(&elem(&1, 0))

    if missing == [], do: :ok, else: {:error, missing}
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
