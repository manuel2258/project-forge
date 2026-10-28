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

  alias ForgeCore.Workflow.{Command, Defaults, Limits, Resources, State, Transition}

  @engine_outcomes ~w(did_not_converge budget_exhausted error cancelled)
  @default_outcome "done"
  @merge_conflict "merge_conflict"
  @ticket "ticket"
  @changeset "changeset"
  @commit_message "commit-message"
  @answers "answers.md"
  @proposals "proposals"
  @proposal_prefix "proposal-"
  @tickets_dir "tickets"
  @archive_dir "archive"
  @replay "conversation.md"

  @enforce_keys [:initial, :states, :transitions, :limits]
  defstruct version: 1,
            description: nil,
            initial: nil,
            states: %{},
            transitions: [],
            limits: nil,
            defaults: nil,
            commands: %{}

  @type state_name :: String.t()
  @type artifact_name :: String.t()
  @type outcome :: String.t()

  @type t :: %__MODULE__{
          version: 1,
          description: String.t() | nil,
          initial: state_name(),
          states: %{state_name() => State.t()},
          transitions: [Transition.t()],
          limits: Limits.t(),
          defaults: Defaults.t() | nil,
          commands: %{String.t() => Command.t()}
        }

  @doc "Outcomes every job may end with, whatever its state declares."
  @spec engine_outcomes() :: [outcome()]
  def engine_outcomes, do: @engine_outcomes

  @doc "The outcome a transition matches when it names none."
  @spec default_outcome() :: outcome()
  def default_outcome, do: @default_outcome

  @doc """
  The outcome a transition is recorded on when a merge conflict sends the ticket down its merging
  state's `on_conflict` (`docs/design/workflow-grammar-v1.md` § Merging). No job ends on it and no
  `when` selects it; it is what `transition.taken` says and what the next job is told it came on.
  """
  @spec merge_conflict_outcome() :: outcome()
  def merge_conflict_outcome, do: @merge_conflict

  @doc "Reserved input name for the ticket body."
  def ticket_artifact, do: @ticket

  @doc "Reserved artifact name for the diff of the job's branch."
  def changeset_artifact, do: @changeset

  @doc """
  Reserved artifact name for what the merge commit says.

  An ordinary document in every other respect — a state declares it, a job writes it to `out/`,
  and it is kept as a version like any other. What is reserved is that a workflow which merges
  must have a state producing it, that no state may declare it `optional` or make it the document
  a choice of outcomes is read from — it is a plain git message and carries no front matter to
  choose in — and that the merge's entry action reads it directly rather than through a job's
  inputs (`docs/design/workflow-grammar-v1.md` § Semantics).
  """
  def commit_message_artifact, do: @commit_message

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

  **A file already named with the prefix keeps its one prefix.** Agents read the backlog, where
  open proposals are listed under their stored names, and copy the convention: six of one
  project's ten open proposals were stored as `proposal-proposal-…`, which is what the person
  read. The prompt says the platform adds it; this makes the guess harmless when it is wrong.
  """
  @spec proposal_artifact(artifact_name()) :: artifact_name()
  def proposal_artifact(@proposal_prefix <> _rest = file), do: file
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

  @doc "The read-only folder of the project's past in a job directory (`docs/design/archive.md`)."
  @spec archive_dir() :: String.t()
  def archive_dir, do: @archive_dir

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
  #
  # Anchored with `\A` and `\z`, not `^` and `$`: `$` also matches before a final newline, so
  # `"feature\n"` was a name — a ticket type listed beside `feature` that read the same, and a
  # row of the backlog's index broken across two lines.
  @name_format ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

  @doc """
  Whether `name` may be an artifact's or a state's: one path segment of letters, digits, `.`,
  `_` and `-`, starting with a letter or a digit. The validator's rule for a workflow, and the
  rule for what a conversation writes, which is why it lives here rather than in either.
  """
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name), do: is_binary(name) and Regex.match?(@name_format, name)

  @doc """
  `valid_name?/1`'s rule in words, for every message that refuses a name by it: one wording, so a
  state, an artifact, a command, a ticket type and a library path are refused in the same terms.
  """
  @spec name_rule() :: String.t()
  def name_rule, do: "letters, digits, . _ -, starting with a letter or digit"

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
        "must be a single path segment: " <> name_rule()

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

  @doc "Whether an artifact name denotes a document: not the changeset, and not a group of files."
  @spec document?(artifact_name()) :: boolean()
  def document?(name), do: name != @changeset and not group?(name)

  @doc """
  Whether a `produces` entry is a group of files, `name/*` (`docs/design/workflow-grammar-v1.md`
  § Semantics): any number of files a job writes into `out/<name>/`, each kept as a blob.
  """
  @spec group?(artifact_name()) :: boolean()
  def group?(name), do: is_binary(name) and String.ends_with?(name, "/*")

  @doc "The directory a group's files are written to, and the prefix of their artifacts' names."
  @spec group_name(artifact_name()) :: String.t()
  def group_name(name), do: String.replace_suffix(name, "/*", "")

  @doc """
  Whether a `produces` entry is a presentation, `name!` (`docs/design/workflow-grammar-v1.md`
  § Semantics): a document in everything but the kind it is recorded under, written for the person
  deciding whether to merge and read by no later job.
  """
  @spec presentation?(artifact_name()) :: boolean()
  def presentation?(name), do: is_binary(name) and String.ends_with?(name, "!")

  @doc "The artifact a presentation is recorded under: the declaration less its `!`."
  @spec presentation_name(artifact_name()) :: String.t()
  def presentation_name(name), do: String.replace_suffix(name, "!", "")

  @doc """
  The artifact `name` really names, whichever marker a `produces` or `inputs` entry carries.

  For callers that hold an entry without knowing which kind it is. A caller that already knows it
  has a group calls `group_name/1`, which says so at the call site.

  The order of the two branches is an equivalent mutant: `/*` and `!` cannot both end one name —
  the validator refuses `x!/*` and `x/*!` because neither strips to an artifact name — so no test
  can tell them apart, and none should be written that claims to.
  """
  @spec produced_name(artifact_name()) :: String.t()
  def produced_name(name) do
    cond do
      group?(name) -> group_name(name)
      presentation?(name) -> presentation_name(name)
      true -> name
    end
  end

  @doc """
  The document whose front matter carries the outcome of a job producing `produces`, or nil.

  The first document declared, by the name it is written under — one definition, because the state
  and the job's spec answer the same question about the same list and used to answer it twice.
  """
  @spec outcome_document([artifact_name()]) :: String.t() | nil
  def outcome_document(produces) when is_list(produces) do
    case Enum.find(produces, &document?/1) do
      nil -> nil
      name -> produced_name(name)
    end
  end

  @doc "The artifact a file of a group is kept as: `package/app.tar.gz`."
  @spec member(String.t(), String.t()) :: artifact_name()
  def member(group, file), do: group <> "/" <> file

  @spec state(t(), state_name()) :: State.t() | nil
  def state(%__MODULE__{states: states}, name), do: Map.get(states, name)

  @spec transitions_from(t(), state_name()) :: [Transition.t()]
  def transitions_from(%__MODULE__{transitions: transitions}, name) do
    Enum.filter(transitions, &(&1.from == name))
  end

  @spec terminal?(t(), state_name()) :: boolean()
  def terminal?(workflow, name), do: transitions_from(workflow, name) == []

  @doc "Whether entering `name` merges the changeset its transition named. See `State`."
  @spec merges_on_enter?(t(), state_name()) :: boolean()
  def merges_on_enter?(workflow, name) do
    case state(workflow, name) do
      nil -> false
      state -> State.merges?(state)
    end
  end

  @doc """
  Where a merge conflict sends a ticket from the merging state `name`: its `on_conflict`, or nil
  when it names none. Only a merging state may name one (`ForgeCore.Workflow.Validator`).
  """
  @spec on_conflict(t(), state_name()) :: state_name() | nil
  def on_conflict(workflow, name) do
    case state(workflow, name) do
      %State{on_conflict: target} -> target
      nil -> nil
    end
  end

  @doc """
  The edge a conflict takes into the merging state `merging`'s `on_conflict`, from wherever the
  ticket is: `from` is the state it was leaving — the merging state itself after a late race, or
  the state whose transition into it the check refused. Nil when `merging` names no target.

  It is no declared transition, and nothing but a conflict takes it: the merging state stays
  terminal (`docs/design/workflow-grammar-v1.md` § Merging).
  """
  @spec conflict_transition(t(), state_name(), state_name()) :: Transition.t() | nil
  def conflict_transition(workflow, from, merging) do
    case on_conflict(workflow, merging) do
      nil -> nil
      target -> %Transition{from: from, to: target, when: @merge_conflict}
    end
  end

  @doc """
  Whether `name` is an integrating state: the `on_conflict` of a state that merges. Its job's
  checkout also fetches the default branch, and its manifest says what conflicted
  (`docs/design/job-prompt.md` § Integrating the default branch).
  """
  @spec integrating?(t(), state_name()) :: boolean()
  def integrating?(%__MODULE__{states: states} = workflow, name) do
    Enum.any?(states, fn {merging, _state} -> on_conflict(workflow, merging) == name end)
  end

  @doc """
  Every edge a ticket can move along: the declared transitions, and each merging state's
  `on_conflict` as an edge out of it. What a walk of the graph follows — reachability, what runs
  before what — because the ticket reaches an `on_conflict` target only by it. Not what
  `transitions_from/2` answers: that is what a person or an outcome may choose, and the merging
  state offers neither.
  """
  @spec edges(t()) :: [Transition.t()]
  def edges(%__MODULE__{transitions: transitions, states: states} = workflow) do
    conflicts =
      states |> Map.keys() |> Enum.flat_map(&List.wrap(conflict_transition(workflow, &1, &1)))

    transitions ++ conflicts
  end

  @doc "The edges out of `name`, as `edges/1` counts them."
  @spec edges_from(t(), state_name()) :: [Transition.t()]
  def edges_from(workflow, name), do: workflow |> edges() |> Enum.filter(&(&1.from == name))

  @doc """
  The command whose log is recorded as `artifact`, or nil. A command's log is a blob, and a state
  may read it as an input: always an optional one, since whether the command has run by then is
  not something the transitions can say (`docs/design/workflow-grammar-v1.md` § Inputs).
  """
  @spec log_producer(t(), artifact_name()) :: String.t() | nil
  def log_producer(%__MODULE__{commands: commands}, artifact) do
    Enum.find_value(commands, fn {name, %Command{produces: produces}} ->
      if produces == artifact, do: name
    end)
  end

  @doc "Names of the states that produce `artifact`, sorted."
  @spec producers(t(), artifact_name()) :: [state_name()]
  def producers(%__MODULE__{states: states}, artifact) do
    names = for {name, %State{produces: produces}} <- states, artifact in produces, do: name
    Enum.sort(names)
  end

  @doc """
  Whether `input` is certain to exist when a job in `state_name` starts: every way from `initial`
  into the state passes through a job state that produces it. See
  `docs/design/workflow-grammar-v1.md` § Inputs.

  An input that is not required is optional, and a job starts without it when it has not been
  written yet — the case a loop makes, where a later state sends work back with its reasons. The
  ticket body and the changeset always exist, so they are always required. A document a human
  state produces never makes an input required: nothing obliges the person to write it, and a
  command's log never does either, for the same reason in another form — no job state produces
  it, so every way in avoids its producers and it comes out optional with no clause of its own.

  The walk goes forward from `initial` and stops at every producer, so the consumer is reached
  only along a path none of whose earlier states produced the input. The consumer's own
  production does not count — a job reads its inputs before it writes anything.

  **A producer stops the walk only on the edges it leaves having written.** An engine outcome —
  `error`, `did_not_converge`, `budget_exhausted`, `cancelled` — is how a job ends when it may
  not have: a missing document is itself `error`. So an edge out of a producer on one of those
  is walked through, and a state it reaches reads the input as optional.

  **A producer that declares the input `optional` is no producer for this purpose**, for the same
  reason a human state is not: it may end `done` having written nothing, so no walk through it
  guarantees the input exists. Without that, a workflow could declare an output optional and read
  it as a required input, and the job that read it could not be created at all — which undoes the
  transition into it and sticks the ticket.
  """
  @spec required_input?(t(), state_name(), artifact_name()) :: boolean()
  def required_input?(%__MODULE__{}, _state_name, @ticket), do: true
  def required_input?(%__MODULE__{}, _state_name, @changeset), do: true

  def required_input?(%__MODULE__{initial: initial} = workflow, state_name, input) do
    producers =
      workflow
      |> producers(input)
      |> Enum.map(&state(workflow, &1))
      |> Enum.filter(&State.job?/1)
      |> Enum.reject(&State.optional?(&1, input))
      |> MapSet.new(& &1.name)

    not reaches_avoiding?(workflow, [initial], state_name, producers, MapSet.new())
  end

  defp reaches_avoiding?(_workflow, [], _target, _blocked, _seen), do: false

  defp reaches_avoiding?(workflow, [node | rest], target, blocked, seen) do
    cond do
      node == target ->
        true

      MapSet.member?(seen, node) ->
        reaches_avoiding?(workflow, rest, target, blocked, seen)

      true ->
        next =
          workflow
          |> edges_from(node)
          |> Enum.filter(&(not MapSet.member?(blocked, node) or unwritten?(&1)))
          |> Enum.map(& &1.to)

        reaches_avoiding?(workflow, next ++ rest, target, blocked, MapSet.put(seen, node))
    end
  end

  defp unwritten?(transition), do: Transition.outcome(transition) in @engine_outcomes

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

  @doc """
  Outcomes a job in `state_name` may end with: engine outcomes plus declared ones. A command
  state declares the values of its `exit` map (`docs/design/workflow-grammar-v1.md` § Commands).
  """
  @spec outcomes(t(), state_name()) :: [outcome()]
  def outcomes(%__MODULE__{} = workflow, state_name) do
    case state(workflow, state_name) do
      nil -> @engine_outcomes
      %State{prompt: nil, exit: %{} = exit} -> @engine_outcomes ++ Enum.uniq(Map.values(exit))
      %State{prompt: nil} -> @engine_outcomes
      %State{outcomes: nil} -> @engine_outcomes ++ [@default_outcome]
      %State{outcomes: declared} -> @engine_outcomes ++ declared
    end
  end

  @spec command(t(), String.t()) :: Command.t() | nil
  def command(%__MODULE__{commands: commands}, name), do: Map.get(commands, name)

  @doc """
  What a command invoked from `state_name` asks the scheduler for: the command's declaration, then
  the invoking state's, then the workflow's defaults (`docs/design/workflow-grammar-v1.md`
  § Resources). Nil fields are the platform's to fill, as in `resources/2`.
  """
  @spec command_resources(t(), String.t(), state_name()) :: Resources.t()
  def command_resources(%__MODULE__{defaults: defaults} = workflow, command_name, state_name) do
    command =
      case command(workflow, command_name) do
        %Command{resources: resources} -> resources
        nil -> nil
      end

    state =
      case state(workflow, state_name) do
        %State{resources: resources} -> resources
        nil -> nil
      end

    Resources.resolve([command, state, defaults && defaults.resources])
  end

  @doc """
  The outcome a command state's batch selects: the first non-zero status among its commands, in
  `invoke` order, or zero when every one exited zero, looked up in `exit`. `nil` in `statuses` is a
  command that ended with no status and counts as non-zero, matching only `"*"`; a status no key
  matches is the engine outcome `error` (`docs/design/commands.md` § An invocation is a job).
  """
  @spec exit_outcome(%{(non_neg_integer() | String.t()) => outcome()}, [integer() | nil]) ::
          outcome()
  def exit_outcome(exit, statuses) when is_map(exit) and is_list(statuses) do
    # The default is an atom and not nil: a command with no status *is* nil, and a find that
    # returned it would read as "every command exited zero".
    case Enum.find(statuses, :all_zero, &(&1 != 0)) do
      :all_zero -> Map.get(exit, 0) || Map.get(exit, "*") || "error"
      status -> exit_for(exit, status)
    end
  end

  # A nil status — a command that ended without one — finds no key, since the parser's keys are
  # integers and `"*"`, and so falls to `"*"` like any status nothing names.
  defp exit_for(exit, status), do: Map.get(exit, status) || Map.get(exit, "*") || "error"
end
