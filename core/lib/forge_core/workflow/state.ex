defmodule ForgeCore.Workflow.State do
  @moduledoc """
  One state of a workflow. A job state has a `prompt` and runs one job per entry; a command
  state has `invoke` and runs the commands it names, mapping their exit statuses through `exit`
  (`docs/design/commands.md`); a human state has neither and waits for a transition taken by a
  person or the engine.

  `on_enter` names actions the platform takes when a ticket arrives in the state. `merge` is
  the only one in v1: entering the state merges the changeset its transition named into the
  project's default branch. `on_conflict`, on that state alone, names where a conflict sends the
  ticket instead (`docs/design/workflow-grammar-v1.md` § Merging).
  """

  alias ForgeCore.Workflow
  alias ForgeCore.Workflow.{Budget, Resources}

  @actions [:merge]

  @enforce_keys [:name]
  defstruct [
    :name,
    :prompt,
    :env,
    :model,
    :effort,
    :budget,
    :outcomes,
    :resources,
    :exit,
    :on_conflict,
    inputs: [],
    produces: [],
    optional: [],
    on_enter: [],
    invoke: [],
    may_invoke: %{},
    secrets: []
  ]

  @typedoc "One entry of `invoke`: the command's name and the argument vector it is run with."
  @type invocation :: %{command: String.t(), args: [String.t()]}

  @typedoc "What `may_invoke` grants for one command. `concurrent` nil is no limit of its own."
  @type grant :: %{max: pos_integer(), concurrent: pos_integer() | nil}

  @type action :: :merge

  @type t :: %__MODULE__{
          name: String.t(),
          prompt: String.t() | nil,
          env: String.t() | nil,
          # What this state's job runs on. Nil means the project's, then the machine's — see
          # `docs/design/workflow-grammar-v1.md` § Model for why it is per state and why its
          # value is not validated against a list.
          model: String.t() | nil,
          # How hard this state's job thinks. Nil means the project's, then the machine's — see
          # `docs/design/workflow-grammar-v1.md` § Effort for why it is a dial of its own and why
          # its value is not validated against a list.
          effort: String.t() | nil,
          budget: Budget.t() | nil,
          inputs: [String.t()],
          produces: [String.t()],
          # A job state's: which of its produced documents it may finish without writing, by
          # artifact name (`docs/design/workflow-grammar-v1.md` § Semantics).
          optional: [String.t()],
          outcomes: [String.t()] | nil,
          # What this state's job asks the scheduler for. Nil in either field means the
          # workflow's defaults, then the platform's — `ForgeCore.Workflow.resources/2` walks
          # the part of that chain this project can see.
          resources: Resources.t() | nil,
          on_enter: [action()],
          # The merging state's: where a conflict sends the ticket instead of refusing or sticking.
          on_conflict: String.t() | nil,
          # A command state's: what it runs on entry, and the outcome each exit status selects —
          # keyed by the status, or `"*"` for any other.
          invoke: [invocation()],
          exit: %{(non_neg_integer() | String.t()) => String.t()} | nil,
          # A job state's: which commands its agent may run, and how many.
          may_invoke: %{String.t() => grant()},
          # A job state's: the project secrets its job is handed, by name
          # (`docs/design/secrets.md` § The workflow is the access list).
          secrets: [String.t()]
        }

  @doc "The entry actions v1 knows."
  @spec actions() :: [action()]
  def actions, do: @actions

  @spec merges?(t()) :: boolean()
  def merges?(%__MODULE__{on_enter: on_enter}), do: :merge in on_enter

  @doc "Whether the state runs an agent: it has a prompt."
  @spec job?(t()) :: boolean()
  def job?(%__MODULE__{prompt: prompt}), do: prompt != nil

  @doc "Whether the state runs commands on entry and nothing else."
  @spec command?(t()) :: boolean()
  # `prompt: nil` is an equivalent mutant for any validated workflow, which refuses a state with
  # both a prompt and `invoke`; kept so the three shapes stay exclusive by definition.
  def command?(%__MODULE__{prompt: nil, invoke: [_ | _]}), do: true
  def command?(%__MODULE__{}), do: false

  @doc "Whether entering the state starts work — an agent or commands — that ends in an outcome."
  @spec runs?(t()) :: boolean()
  def runs?(state), do: job?(state) or command?(state)

  @doc "Whether the state waits for a person: it runs nothing."
  @spec human?(t()) :: boolean()
  def human?(state), do: not runs?(state)

  @doc """
  The document whose front matter carries the job's outcome, or nil if none.

  `ForgeCore.Workflow.outcome_document/1`'s answer about this state's `produces`. Its one caller
  here asks only whether there is one, so the stripping is an equivalent mutant *at this call
  site* and is pinned where it is defined and where `ForgeCore.Job.Spec` reads it — the name the
  worker writes and the engine keys on comes from there.
  """
  @spec outcome_document(t()) :: String.t() | nil
  def outcome_document(%__MODULE__{produces: produces}), do: Workflow.outcome_document(produces)

  @doc "Whether this state may finish without writing `name`."
  @spec optional?(t(), String.t()) :: boolean()
  def optional?(%__MODULE__{optional: optional}, name), do: name in optional
end
