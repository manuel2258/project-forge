defmodule ForgeCore.Workflow do
  @moduledoc """
  A parsed and validated workflow definition, grammar v1.

  See `docs/design/workflow-grammar-v1.md`. Build one with `ForgeCore.Workflow.Parser`;
  this module only holds the data and answers questions about it.
  """

  # The grammar an agent is handed when it is asked to write or change a workflow, embedded from
  # the design note that defines it rather than copied. One source: a second copy would drift
  # from the validator the first time either changed, and the copy is what the agent would read.
  @grammar_path Path.join(__DIR__, "../../../docs/design/workflow-grammar-v1.md")
  @external_resource @grammar_path
  @grammar File.read!(@grammar_path)

  @platform_path Path.join(:code.priv_dir(:forge_core), "platform.md")
  @external_resource @platform_path
  @platform File.read!(@platform_path)

  @doc """
  The workflow grammar, as a document to hand to an agent.

  A conversation asked to bootstrap a project has to write `.forge/workflow.yml`, and nothing in
  a project's own repository says what that file may contain. This is what the validator accepts,
  which is the only answer worth giving.
  """
  @spec grammar() :: String.t()
  def grammar, do: @grammar

  @doc """
  What the platform is, for an agent that needs to know what becomes of its output.

  Written to `$FORGE_JOB/platform/` for every job and every conversation, and **named in the
  prompt rather than inlined into it**: an agent with file tools reads what it needs, and a
  preamble that grew to hold all of this would be paid for on every turn by every job that never
  had a question about the machinery.
  """
  @spec platform_overview() :: String.t()
  def platform_overview, do: @platform

  @doc "The files written to `$FORGE_JOB/platform/`, as `{name, content}`."
  @spec platform_docs() :: [{String.t(), String.t()}]
  def platform_docs, do: [{"platform.md", @platform}, {"workflow-grammar.md", @grammar}]

  alias ForgeCore.Workflow.{Defaults, Limits, Resources, State, Transition}

  @engine_outcomes ~w(did_not_converge budget_exhausted error cancelled)
  @default_outcome "done"
  @ticket "ticket"
  @changeset "changeset"
  @answers "answers.md"
  @proposals "proposals"
  @proposal_prefix "proposal-"
  @tickets_dir "tickets"
  @replay "conversation.md"

  @enforce_keys [:initial, :states, :transitions, :limits]
  defstruct version: 1, initial: nil, states: %{}, transitions: [], limits: nil, defaults: nil

  @type state_name :: String.t()
  @type artifact_name :: String.t()
  @type outcome :: String.t()

  @type t :: %__MODULE__{
          version: 1,
          initial: state_name(),
          states: %{state_name() => State.t()},
          transitions: [Transition.t()],
          limits: Limits.t(),
          defaults: Defaults.t() | nil
        }

  @doc "Outcomes every job may end with, whatever its state declares."
  @spec engine_outcomes() :: [outcome()]
  def engine_outcomes, do: @engine_outcomes

  @doc "The outcome a transition matches when it names none."
  @spec default_outcome() :: outcome()
  def default_outcome, do: @default_outcome

  @doc "Reserved input name for the ticket body."
  def ticket_artifact, do: @ticket

  @doc "Reserved artifact name for the diff of the job's branch."
  def changeset_artifact, do: @changeset

  @doc "Platform-managed document holding answers; never declared in a workflow."
  def answers_artifact, do: @answers

  @doc """
  The reserved subdirectory of `out/` an agent writes ticket proposals into.

  A directory rather than a reserved filename, because a job may propose more than one thing and
  the alternative is a naming scheme inside a single file. See `docs/design/ticket-proposals.md`
  § The files.
  """
  def proposals_dir, do: @proposals

  @doc """
  The artifact name a proposal written as `out/proposals/<file>` is stored under.

  Prefixed rather than bare, because the prefix is what says a job-scoped artifact is a
  proposal. The agent's own filename is kept after it: it is the only place the agent gets to
  say what a proposal is about in a word, and the title says it in a sentence.
  """
  @spec proposal_artifact(artifact_name()) :: artifact_name()
  def proposal_artifact(file), do: @proposal_prefix <> file

  @doc "Whether an artifact name is a proposal's, i.e. carries the reserved prefix."
  @spec proposal?(artifact_name()) :: boolean()
  def proposal?(name), do: String.starts_with?(name, @proposal_prefix)

  @doc """
  Whether an artifact name is one the platform keeps for a job's transcript
  (`transcript-<state>-<attempt>.jsonl`, a blob). A document under such a name, written before
  the transcript it collides with exists, would leave that job unable to record its result —
  refused at `Forge.Artifacts`' kind check, retried by the worker for ever. So the whole prefix is
  the platform's, not only the names already taken.
  """
  @spec transcript?(artifact_name()) :: boolean()
  def transcript?(name), do: String.starts_with?(name, "transcript-")

  @doc """
  The directory of `$FORGE_JOB` holding the project's tickets, for a job that wants to know
  what else exists. See `docs/design/ticket-proposals.md` § Reading the backlog.
  """
  def tickets_dir, do: @tickets_dir

  @doc """
  The file in `$FORGE_JOB` holding what a reopened conversation had already said, for the new
  process to read. See `docs/design/conversations.md` § Lifetime.
  """
  def replay_file, do: @replay

  # Artifact and state names are single path segments: they become file and directory names in
  # the job directory and must never escape it.
  #
  # The leading-alphanumeric requirement is the whole of that guard, and `.`, `..` and every
  # other all-dots name are refused by it rather than by any list — there is one defence here,
  # not two. Widening this to allow a leading dot would therefore make `..` a legal artifact
  # name and a write to the job directory's parent; the names test in `parser_test.exs` is what
  # would notice.
  @name_format ~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/

  @doc """
  Whether `name` may be an artifact's or a state's: one path segment of letters, digits, `.`,
  `_` and `-`, starting with a letter or a digit. The validator's rule for a workflow, and the
  rule for what a conversation writes, which is why it lives here rather than in either.
  """
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name), do: is_binary(name) and Regex.match?(@name_format, name)

  @doc """
  Why an agent may not write `name` in `out/` as a document of its own accord, or nil if it may.

  A conversation declares nothing, so what it writes is held to the rules a workflow's `produces`
  is held to where they apply (`docs/design/conversations.md` § Commits): a valid name, and none
  the platform keeps for itself — the ticket's body, the answers it writes, the changeset, the
  two shapes proposals take, and the prefix transcripts are stored under.
  """
  @spec document_name_error(String.t()) :: String.t() | nil
  def document_name_error(name) do
    cond do
      not valid_name?(name) ->
        "must be a single path segment: letters, digits, . _ -, starting with a letter or digit"

      name in [@ticket, @answers, @changeset] ->
        "#{inspect(name)} is reserved"

      true ->
        reserved_name_error(name)
    end
  end

  @doc """
  Why `name` is one the platform stores something of its own under — the two shapes proposals
  take, and the prefix transcripts are kept at — or nil.

  Asked of what a conversation writes (`document_name_error/1`) and of what a workflow's state
  may produce (`ForgeCore.Workflow.Validator`), which is the same collision from two directions:
  a file or a row the job does not own.
  """
  @spec reserved_name_error(String.t()) :: String.t() | nil
  def reserved_name_error(name) do
    cond do
      name == @proposals or proposal?(name) -> "#{inspect(name)} is reserved for ticket proposals"
      transcript?(name) -> "#{inspect(name)} is reserved for job transcripts"
      true -> nil
    end
  end

  @doc "Whether an artifact name denotes a document rather than the changeset."
  @spec document?(artifact_name()) :: boolean()
  def document?(name), do: name != @changeset

  @spec state(t(), state_name()) :: State.t() | nil
  def state(%__MODULE__{states: states}, name), do: Map.get(states, name)

  @spec transitions_from(t(), state_name()) :: [Transition.t()]
  def transitions_from(%__MODULE__{transitions: transitions}, name) do
    Enum.filter(transitions, &(&1.from == name))
  end

  @spec terminal?(t(), state_name()) :: boolean()
  def terminal?(workflow, name), do: transitions_from(workflow, name) == []

  @doc "Whether entering `name` merges the ticket's approved changeset. See `State`."
  @spec merges_on_enter?(t(), state_name()) :: boolean()
  def merges_on_enter?(workflow, name) do
    case state(workflow, name) do
      nil -> false
      state -> State.merges?(state)
    end
  end

  @doc "Names of the states that produce `artifact`, sorted."
  @spec producers(t(), artifact_name()) :: [state_name()]
  def producers(%__MODULE__{states: states}, artifact) do
    names = for {name, %State{produces: produces}} <- states, artifact in produces, do: name
    Enum.sort(names)
  end

  @doc """
  What a job in `state_name` asks the scheduler for: the state's declaration, then the
  workflow's defaults.

  **Either field may still be nil**, and that is the contract rather than an oversight: the last
  link of the chain is the platform's configured slice, and `forge_core` has no configuration to
  read it from. A caller that needs a number supplies the last one
  (`docs/design/provisioning.md` § What a job asks for).

  A state that does not exist, or a human state that runs no job, resolves the same way as one
  declaring nothing. Neither has a job to size, and returning the defaults costs the caller
  nothing it would not already have to handle.
  """
  @spec resources(t(), state_name()) :: Resources.t()
  def resources(%__MODULE__{defaults: defaults} = workflow, state_name) do
    state =
      case state(workflow, state_name) do
        %State{resources: resources} -> resources
        nil -> nil
      end

    Resources.resolve([state, defaults && defaults.resources])
  end

  @doc "Outcomes a job in `state_name` may end with: engine outcomes plus declared ones."
  @spec outcomes(t(), state_name()) :: [outcome()]
  def outcomes(%__MODULE__{} = workflow, state_name) do
    case state(workflow, state_name) do
      %State{prompt: nil} -> @engine_outcomes
      %State{outcomes: nil} -> @engine_outcomes ++ [@default_outcome]
      %State{outcomes: declared} -> @engine_outcomes ++ declared
      nil -> @engine_outcomes
    end
  end
end
