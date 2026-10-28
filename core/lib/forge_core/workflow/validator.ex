defmodule ForgeCore.Workflow.Validator do
  @moduledoc """
  Semantic validation of a structurally sound workflow, one function per rule in
  `docs/design/workflow-grammar-v1.md`. Returns every violation found.
  """

  alias ForgeCore.Error
  alias ForgeCore.Workflow
  alias ForgeCore.Workflow.{State, Transition}

  @spec validate(Workflow.t(), keyword()) :: [Error.t()]
  def validate(%Workflow{} = workflow, opts \\ []) do
    [
      release(workflow, Keyword.get(opts, :single_file, false)),
      names(workflow),
      initial(workflow),
      state_shapes(workflow),
      optional_outputs(workflow),
      entry_actions(workflow),
      conflict_targets(workflow),
      queueing_edges(workflow),
      artifact_names(workflow),
      commands(workflow, Keyword.get(opts, :file_exists)),
      invocations(workflow),
      secret_names(workflow),
      outcome_declarations(workflow),
      transitions(workflow),
      reachability(workflow),
      prompts(workflow, Keyword.get(opts, :prompt_exists))
    ]
    |> List.flatten()
  end

  # -- rules --------------------------------------------------------------------------------

  # `docs/design/ticket-types.md` § Releases. The single file has no types, so nothing could
  # start it as the release. Here and not in the parser because a stored pin must never meet it.
  defp release(%Workflow{release: true}, true),
    do: [
      Error.new(
        "release",
        "only a ticket type in .forge/workflows/ can be a release: .forge/workflow.yml has no types"
      )
    ]

  defp release(_workflow, _single_file), do: []

  defp names(%Workflow{states: states}) do
    Enum.flat_map(states, fn {name, state} ->
      path = Error.join("states", name)

      state_errors =
        if valid_name?(name),
          do: [],
          else: [
            Error.new(path, "state name must be a single path segment: " <> Workflow.name_rule())
          ]

      artifact_errors =
        (state.inputs ++ state.produces)
        |> Enum.map(&Workflow.produced_name/1)
        |> Enum.reject(&valid_name?/1)
        |> Enum.uniq()
        |> Enum.map(
          &Error.new(
            path,
            "artifact name #{inspect(&1)} must be a single path segment: " <> Workflow.name_rule()
          )
        )

      state_errors ++ artifact_errors
    end)
  end

  # `Workflow.valid_name?/1`, which says why the rule is what it is. One definition, because a
  # conversation's documents are held to it too.
  defp valid_name?(name), do: Workflow.valid_name?(name)

  defp initial(%Workflow{initial: initial} = workflow) do
    case Workflow.state(workflow, initial) do
      %State{prompt: nil, invoke: [_ | _]} ->
        [Error.new("initial", "must name a job state, not a command state")]

      %State{prompt: nil} ->
        [Error.new("initial", "must name a job state, not a human state")]

      %State{} ->
        []

      nil ->
        [Error.new("initial", "names an unknown state #{inspect(initial)}")]
    end
  end

  defp state_shapes(%Workflow{states: states}) do
    Enum.flat_map(states, fn {name, state} -> state_shape(Error.join("states", name), state) end)
  end

  # Three shapes (`docs/design/workflow-grammar-v1.md` § Validation). A state with a prompt runs
  # an agent, one with `invoke` runs commands, and one with neither waits for a person; a state
  # with both would be two things on one entry.
  defp state_shape(path, %State{prompt: prompt, invoke: [_ | _]}) when is_binary(prompt),
    do: [
      Error.new(
        Error.join(path, "invoke"),
        "a state runs an agent or commands, not both: it has a prompt"
      )
    ]

  # A command's environment and size are the command's own; the state has nothing to run them with
  # but `resources`, which its commands fall back to. `model` and `effort` are not the command's
  # own either — a command job carries no harness at all (`docs/design/commands.md`), so both name
  # a dial nothing here turns.
  defp state_shape(path, %State{prompt: nil, invoke: [_ | _]} = command) do
    present =
      [
        env: command.env,
        model: command.model,
        effort: command.effort,
        inputs: command.inputs,
        produces: command.produces,
        optional: command.optional,
        outcomes: command.outcomes,
        budget: command.budget,
        may_invoke: command.may_invoke,
        # Each command brings its own, as it brings its own `env` (`docs/design/secrets.md`).
        secrets: command.secrets,
        # A command runs and ends by itself; a conversation is what a person ends.
        chat: command.chat
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, [], %{}, false] end)
      |> Enum.map(
        &Error.new(Error.join(path, to_string(elem(&1, 0))), "not allowed on a command state")
      )

    exit =
      if command.exit == nil,
        do: [Error.new(Error.join(path, "exit"), "is required on a command state")],
        else: []

    present ++ exit ++ engine_exits(path, command.exit)
  end

  # A human state may produce documents a person writes while the ticket rests there, and nothing
  # else: the changeset is the branch a job's commits make, and a person does not commit through
  # a state (`docs/design/workflow-grammar-v1.md` § Semantics).
  defp state_shape(path, %State{prompt: nil} = human) do
    changeset =
      if Enum.any?(human.produces, &(not Workflow.document?(&1) or Workflow.presentation?(&1))),
        do: [
          Error.new(
            Error.join(path, "produces"),
            "a human state writes documents, not #{Workflow.changeset_artifact()}, " <>
              "groups of files or presentations"
          )
        ],
        else: []

    present =
      [
        env: human.env,
        model: human.model,
        effort: human.effort,
        inputs: human.inputs,
        # Nothing obliges a person to write a human state's documents, so every one of them is
        # already optional and saying so declares nothing.
        optional: human.optional,
        outcomes: human.outcomes,
        budget: human.budget,
        # Nothing runs, so there is nothing to size — and a declaration nothing reads is one the
        # author believes is doing something.
        resources: human.resources,
        exit: human.exit,
        may_invoke: human.may_invoke,
        secrets: human.secrets,
        chat: human.chat
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, [], %{}, false] end)
      |> Enum.map(fn {key, _value} -> to_string(key) end)

    changeset ++
      Enum.map(
        present,
        &Error.new(Error.join(path, &1), "not allowed on a human state (no prompt)")
      )
  end

  # A chat step is a conversation: nothing in it ends without a person, so it has no ceiling to
  # state, no commands to invoke, and nothing to commit to the ticket's branch
  # (`docs/design/workflow-grammar-v1.md` § Chat steps). Every other rule of a job state holds.
  defp state_shape(path, %State{chat: true} = step) do
    budget =
      if step.budget == nil,
        do: [],
        else: [
          Error.new(
            Error.join(path, "budget"),
            "not allowed on a chat step: a conversation has no ceiling"
          )
        ]

    may_invoke =
      if step.may_invoke == %{},
        do: [],
        else: [
          Error.new(
            Error.join(path, "may_invoke"),
            "not allowed on a chat step: it invokes no commands"
          )
        ]

    exit =
      if step.exit == nil,
        do: [],
        else: [
          Error.new(
            Error.join(path, "exit"),
            "not allowed on a chat step: a person chooses its outcome"
          )
        ]

    budget ++ may_invoke ++ exit ++ chat_produces(path, step)
  end

  defp state_shape(path, %State{} = job) do
    budget =
      if job.budget == nil,
        do: [Error.new(Error.join(path, "budget"), "is required on a job state")],
        else: []

    exit =
      if job.exit == nil,
        do: [],
        else: [
          Error.new(
            Error.join(path, "exit"),
            "not allowed on a job state: its agent declares outcomes"
          )
        ]

    budget ++ exit
  end

  defp chat_produces(path, step) do
    produces_path = Error.join(path, "produces")

    produced =
      step.produces
      |> Enum.with_index()
      |> Enum.flat_map(fn {entry, index} ->
        at = Error.join(produces_path, index)

        cond do
          entry == Workflow.changeset_artifact() ->
            [
              Error.new(
                at,
                "a chat step commits to its own branch and cannot produce " <>
                  Workflow.changeset_artifact()
              )
            ]

          entry == Workflow.commit_message_artifact() ->
            [
              Error.new(
                at,
                "#{Workflow.commit_message_artifact()} belongs to the conversation's own " <>
                  "branch, and a chat step cannot produce it"
              )
            ]

          Workflow.group?(entry) ->
            [Error.new(at, "a chat step writes documents, not a group of files")]

          Workflow.presentation?(entry) ->
            [Error.new(at, "a chat step writes documents, not a presentation")]

          true ->
            []
        end
      end)

    outcome_document = Workflow.outcome_document(step.produces)

    optional =
      if outcome_document != nil and outcome_document in step.optional,
        do: [
          Error.new(
            Error.join(path, "optional"),
            "#{inspect(outcome_document)} is the document a chat step must write before it " <>
              "can be accepted and cannot be optional"
          )
        ],
        else: []

    produced ++ optional
  end

  # An engine outcome is the engine's to decide — a command state's `exit` naming `error` would let
  # a failing build pass for a platform fault.
  defp engine_exits(_path, nil), do: []

  defp engine_exits(path, exit) do
    values = exit |> Map.values() |> Enum.uniq() |> Enum.sort()

    Enum.flat_map(values, fn value ->
      cond do
        value in Workflow.engine_outcomes() ->
          [
            Error.new(
              Error.join(path, "exit"),
              "#{inspect(value)} is an engine outcome and cannot be mapped to"
            )
          ]

        value == Workflow.merge_conflict_outcome() ->
          [Error.new(Error.join(path, "exit"), merge_conflict_reserved(value))]

        true ->
          []
      end
    end)
  end

  # The outcome the conflict route is recorded on (`docs/design/workflow-grammar-v1.md` § Merging).
  # A job that could end on it would arrive in its next state told a conflict sent it, and an edge
  # declared on it would share the route's count.
  defp merge_conflict_reserved(outcome),
    do: "#{inspect(outcome)} is the platform's: a merge conflict is recorded on it"

  # `on_enter` is a state's entry, and a job state's entry already runs a job: two things on one
  # entry would leave their order undefined. A ticket has one branch and merges once, so at most
  # one state may merge, and it cannot be where a ticket starts.
  defp entry_actions(%Workflow{states: states, initial: initial} = workflow) do
    merging =
      states
      |> Enum.filter(fn {_name, state} -> State.merges?(state) end)
      |> Enum.map(fn {name, _state} -> name end)
      |> Enum.sort()

    Enum.concat([
      Enum.flat_map(states, &entry_action_shape/1),
      merge_count(merging),
      merge_not_initial(merging, initial),
      merge_needs_artifact(merging, workflow, Workflow.changeset_artifact()),
      merge_needs_artifact(merging, workflow, Workflow.commit_message_artifact())
    ])
  end

  defp entry_action_shape({name, %State{on_enter: [_ | _]} = state}) do
    path = Error.join(Error.join("states", name), "on_enter")

    cond do
      State.job?(state) ->
        [Error.new(path, "not allowed on a job state: entering it already runs a job")]

      State.command?(state) ->
        [Error.new(path, "not allowed on a command state: entering it already runs its commands")]

      true ->
        []
    end
  end

  defp entry_action_shape({_name, %State{}}), do: []

  defp merge_count([_one]), do: []
  defp merge_count([]), do: []

  defp merge_count(many) do
    [Error.new("states", "only one state may merge; #{Enum.join(many, ", ")} all do")]
  end

  defp merge_not_initial(merging, initial) do
    if initial in merging do
      [Error.new("initial", "names a state that merges, so a ticket would merge at admission")]
    else
      []
    end
  end

  # Both reserved names a merge reads, by one rule: without the changeset there is nothing to
  # merge and without the message there is nothing for the commit to say, and a third name of the
  # shape would come here rather than beside here (`CLAUDE.md` § Rules).
  #
  # **Asked of the produced name, not the declaration.** `produces` entries carry markers — a
  # presentation ends `!` — and everything that records an artifact goes through
  # `Workflow.produced_name/1`, so a state declaring `commit-message!` does produce the artifact
  # the merge reads and comparing the raw entry told it the merge had no producer.
  defp merge_needs_artifact([], _workflow, _name), do: []

  defp merge_needs_artifact([state_name | _rest], %Workflow{} = workflow, name) do
    if Workflow.produced?(workflow, name) do
      []
    else
      [
        Error.new(
          Error.join(Error.join("states", state_name), "on_enter"),
          "merge needs a state that produces #{name}"
        )
      ]
    end
  end

  # `docs/design/workflow-grammar-v1.md` § The merge queue: only an edge into a merging state has
  # anything to queue for, and none out of a chat step — its Accept ends the conversation, so a
  # ticket taken out of the line would rest in a step with nothing left to Accept.
  defp queueing_edges(%Workflow{transitions: transitions} = workflow) do
    transitions
    |> Enum.with_index()
    |> Enum.filter(fn {transition, _index} -> transition.queue == true end)
    |> Enum.flat_map(fn {transition, index} ->
      path = Error.join(Error.join("transitions", index), "queue")

      cond do
        not Workflow.merges_on_enter?(workflow, transition.to) ->
          [
            Error.new(
              path,
              "only an edge into a merging state (one with on_enter: merge) can queue; " <>
                "#{inspect(transition.to)} merges nothing"
            )
          ]

        State.chat?(Workflow.state(workflow, transition.from) || %State{name: ""}) ->
          [
            Error.new(
              path,
              "an edge out of a chat step cannot queue: #{inspect(transition.from)} is ended " <>
                "by Accept, which merges at once"
            )
          ]

        true ->
          []
      end
    end)
  end

  # `docs/design/workflow-grammar-v1.md` § Merging: where a conflict goes is the merging state's to
  # say, and it has to be somewhere a conflict can be dealt with — an agent that integrates, or a
  # person — and away from the state that could not merge.
  defp conflict_targets(%Workflow{states: states} = workflow) do
    states
    |> Enum.filter(fn {_name, state} -> state.on_conflict != nil end)
    |> Enum.flat_map(fn {name, state} ->
      path = Error.join(Error.join("states", name), "on_conflict")
      conflict_target(workflow, path, name, state, Workflow.state(workflow, state.on_conflict))
    end)
  end

  defp conflict_target(workflow, path, name, %State{on_conflict: target_name} = state, target) do
    cond do
      not State.merges?(state) ->
        [Error.new(path, "only the state that merges may say where a conflict goes")]

      target == nil ->
        [Error.new(path, "names an unknown state #{inspect(target_name)}")]

      target_name == name ->
        [Error.new(path, "cannot be the state that merges: a conflict has to leave it")]

      State.command?(target) ->
        [
          Error.new(
            path,
            "must be a job state or a human state: a command's checkout has no default branch to merge"
          )
        ]

      Workflow.terminal?(workflow, target_name) ->
        [
          Error.new(
            path,
            "names #{inspect(target_name)}, which has no transition out: a conflict there would end the ticket unmerged"
          )
        ]

      State.job?(target) and Enum.any?(workflow.transitions, &(&1.to == target_name)) ->
        [
          Error.new(
            path,
            "names #{inspect(target_name)}, which a transition also leads into: an integrating state is reached by a conflict only"
          )
        ]

      true ->
        []
    end
  end

  defp artifact_names(%Workflow{states: states} = workflow) do
    Enum.flat_map(states, fn {name, state} ->
      path = Error.join("states", name)
      producers_before = ancestors(workflow, name)

      inputs =
        Enum.with_index(
          state.inputs,
          &input_error(workflow, producers_before, Error.join(path, "inputs"), &1, &2)
        )

      produces =
        Enum.with_index(
          state.produces,
          &produce_error(workflow, Error.join(path, "produces"), &1, &2)
        )

      Enum.reject(inputs ++ produces, &is_nil/1)
    end)
  end

  # Whether `name` is a presentation, either way round: the entry carries the marker, or it names
  # the artifact a presentation elsewhere in the workflow is recorded under. Without the first,
  # `inputs: [deck.md!]` and `approve: [deck.md!]` would both find their producer by name and read
  # as perfectly ordinary ones.
  defp presents?(workflow, name),
    do: Workflow.presentation?(name) or Workflow.producers(workflow, name <> "!") != []

  defp input_error(workflow, producers_before, path, name, index) do
    producers = Workflow.producers(workflow, name)

    cond do
      Workflow.group?(name) ->
        Error.new(Error.join(path, index), "a group of files is not an input yet")

      name == Workflow.answers_artifact() ->
        Error.new(Error.join(path, index), "answers.md is platform-managed and never declared")

      reserved = Workflow.reserved_name_error(name) ->
        Error.new(Error.join(path, index), reserved)

      # After the two above, so a reserved name is refused for being reserved rather than for a
      # presentation someone declared under it: `produce_error/4` orders them the same way.
      presents?(workflow, name) ->
        Error.new(
          Error.join(path, index),
          "#{inspect(Workflow.produced_name(name))} is a presentation and cannot be an input"
        )

      name == Workflow.ticket_artifact() ->
        nil

      producers == [] ->
        unproduced_input_error(workflow, path, name, index)

      # `any?` and `all?` cannot differ here: an artifact with more than one producer is already
      # an error of its own ("is produced by more than one state"), so `producers` is a list of
      # one by the time a workflow is valid. A mutation sweep flagged this as unprotected — it is
      # an equivalent mutant, not a missing test, and the only way to tell the two apart would be
      # a workflow the grammar refuses for a different reason.
      not Enum.any?(producers, &MapSet.member?(producers_before, &1)) ->
        Error.new(
          Error.join(path, index),
          "#{inspect(name)} is not produced by any state that runs before this one"
        )

      true ->
        nil
    end
  end

  # A command's log is an input no state produces: read as the latest version the ticket has, and
  # optional wherever it is read, so there is no ordering for it to break
  # (`workflow-grammar-v1.md` § Inputs).
  defp unproduced_input_error(workflow, path, name, index) do
    if Workflow.log_producer(workflow, name) == nil,
      do:
        Error.new(
          Error.join(path, index),
          "#{inspect(name)} is not produced by any state or command"
        )
  end

  # `commit-message` is the text of the merge commit (`docs/design/workflow-grammar-v1.md`
  # § Produces), so it has to be declared as a plain document. A group records one artifact per
  # file — `commit-message/<file>`, never `commit-message` — so a workflow declaring
  # `commit-message/*` validated and then stuck every ticket that reached its merge, which is
  # what this rule exists to catch here instead. A presentation would validate and work, and is
  # refused for the premise rather than for a failure: this one carries no front matter and
  # nobody views it as prose.
  defp commit_message_kind_error(path, name) do
    message = Workflow.commit_message_artifact()

    if name != message and Workflow.produced_name(name) == message do
      Error.new(
        path,
        "#{inspect(name)} must be declared as the plain document #{message}: it is the text of " <>
          "the merge commit, which is neither a presentation nor a group of files"
      )
    end
  end

  defp produce_error(workflow, path, name, index) do
    producers = Workflow.producers(workflow, name)

    cond do
      # **Before the group and presentation branches**, because it is about which of the three
      # kinds this one name may be declared as.
      marked = commit_message_kind_error(Error.join(path, index), name) ->
        marked

      Workflow.group?(name) ->
        group_error(workflow, Error.join(path, index), name, producers)

      Workflow.presentation?(name) ->
        presentation_error(workflow, Error.join(path, index), name, producers)

      name in [Workflow.ticket_artifact(), Workflow.answers_artifact()] ->
        Error.new(Error.join(path, index), "#{inspect(name)} is reserved and cannot be produced")

      reserved = Workflow.reserved_name_error(name) ->
        Error.new(Error.join(path, index), reserved)

      name == Workflow.changeset_artifact() ->
        nil

      length(producers) > 1 ->
        Error.new(
          Error.join(path, index),
          "#{inspect(name)} is produced by more than one state: #{Enum.join(Enum.sort(producers), ", ")}"
        )

      true ->
        nil
    end
  end

  # A group names a directory under `out/`, so it may not be one the platform keeps there, nor share
  # its name with a document — `out/package` cannot be a file and a directory at once — and it is
  # one state's or one command's (`docs/design/workflow-grammar-v1.md` § Validation).
  defp group_error(workflow, path, group, producers) do
    name = Workflow.group_name(group)

    cond do
      reserved = Workflow.document_name_error(name) ->
        Error.new(path, reserved)

      Workflow.producers(workflow, name) != [] ->
        Error.new(path, "#{inspect(name)} is also produced as a document")

      length(producers) > 1 ->
        Error.new(
          path,
          "#{inspect(group)} is produced by more than one state: #{Enum.join(Enum.sort(producers), ", ")}"
        )

      command_producing(workflow, group) != [] ->
        Error.new(path, "#{inspect(group)} is also produced by a command")

      true ->
        nil
    end
  end

  # A presentation is one artifact under one kind, so the name it is recorded under may not also be
  # something's document — a state's or a command's log — nor a group of files, a state's or a
  # command's, and it is one job state's (`docs/design/workflow-grammar-v1.md` § Validation). Every
  # collision is checked from here and only from here: the pass sees the whole workflow, so the
  # order the two were declared in makes no difference to the answer, and the other side cannot
  # see this one — `command_outputs_errors/4` matches `deck.md` and `deck.md/*`, neither of which
  # is the declaration `deck.md!`.
  #
  # The order of the branches is what the message says when more than one is true, and is
  # asserted: a collision is reported as the collision it is, nearest first.
  defp presentation_error(workflow, path, declared, producers) do
    name = Workflow.presentation_name(declared)

    cond do
      reserved = Workflow.document_name_error(name) ->
        Error.new(path, reserved)

      Workflow.producers(workflow, name) != [] ->
        Error.new(path, "#{inspect(name)} is also produced as a document")

      Workflow.producers(workflow, name <> "/*") != [] ->
        Error.new(path, "#{inspect(name)} is also produced as a group of files")

      command_producing(workflow, name <> "/*") != [] ->
        Error.new(path, "#{inspect(name)} is also produced as a group of files by a command")

      command = Workflow.log_producer(workflow, name) ->
        Error.new(path, "#{inspect(name)} is also produced by command #{inspect(command)}")

      length(producers) > 1 ->
        Error.new(
          path,
          "#{inspect(declared)} is produced by more than one state: #{Enum.join(Enum.sort(producers), ", ")}"
        )

      true ->
        nil
    end
  end

  defp command_producing(%Workflow{commands: commands}, group) do
    for {name, command} <- commands, group in command.outputs, do: name
  end

  # -- optional outputs ---------------------------------------------------------------------

  # `docs/design/workflow-grammar-v1.md` § Semantics: a job state's `optional` names its own
  # produced documents, by the artifact's name and not the declaration's. Checked here rather
  # than in `produce_error/4` because the entry is not a `produces` entry: it points at one.
  defp optional_outputs(%Workflow{states: states}) do
    Enum.flat_map(states, fn {name, state} ->
      path = Error.join(Error.join("states", name), "optional")

      documents =
        for entry <- state.produces, Workflow.document?(entry), do: Workflow.produced_name(entry)

      repeated = state.optional -- Enum.uniq(state.optional)

      state.optional
      |> Enum.with_index()
      |> Enum.flat_map(&optional_entry(&1, path, state, documents, repeated))
    end)
  end

  defp optional_entry({entry, index}, path, state, documents, repeated) do
    case optional_error(state, entry, documents, repeated) do
      nil -> []
      message -> [Error.new(Error.join(path, index), message)]
    end
  end

  defp optional_error(state, entry, documents, repeated) do
    cond do
      not valid_name?(entry) ->
        "must be a single path segment: " <> Workflow.name_rule()

      entry in repeated ->
        "#{inspect(entry)} is listed twice"

      true ->
        optional_target_error(state, entry, documents)
    end
  end

  # What a well-formed, unrepeated entry points at: nil where it is one of the state's own
  # documents and may be excused, otherwise why it may not be.
  defp optional_target_error(state, entry, documents) do
    cond do
      # Before the clause below, not after it: `commit-message` is one of the state's own
      # documents, so "it is a document this state produces" would excuse it like any other.
      # Merging has nothing to fall back on when it is absent, which is what makes it the one
      # produced document a state may not be let off writing.
      #
      # `entry in documents` as well, so that a state which does not produce it is told *that*
      # instead by the last clause. Excusing a document the state never writes is a different
      # mistake and saying "cannot be optional" sent the author looking for the wrong one.
      entry == Workflow.commit_message_artifact() and entry in documents ->
        "#{Workflow.commit_message_artifact()} is what the merge commit says and cannot be optional"

      entry in documents ->
        nil

      entry == Workflow.changeset_artifact() and entry in state.produces ->
        "#{Workflow.changeset_artifact()} is the diff of the job's commits and cannot be optional"

      Enum.any?(state.produces, &(Workflow.group?(&1) and Workflow.group_name(&1) == entry)) ->
        "#{inspect(entry)} is a group of files, which has no minimum and cannot be optional"

      true ->
        "#{inspect(entry)} is not a document this state produces"
    end
  end

  # -- secrets ------------------------------------------------------------------------------

  # `docs/design/secrets.md` § The workflow is the access list: a name is checked here against the
  # same rule a secret is saved under (`ForgeCore.Secret`), so a workflow cannot ask for a name no
  # secret could ever have. Whether the project has set it is the platform's question, when the
  # job is scheduled, because secrets change after a workflow is pinned.
  defp secret_names(%Workflow{states: states, commands: commands}) do
    listed =
      Enum.map(states, fn {name, state} -> {Error.join("states", name), state.secrets} end) ++
        Enum.map(commands, fn {name, command} ->
          {Error.join("commands", name), command.secrets}
        end)

    # Unsorted: the parser sorts every error it returns (`Parser.sort/1`).
    Enum.flat_map(listed, fn {path, names} ->
      secret_list_errors(Error.join(path, "secrets"), names)
    end)
  end

  defp secret_list_errors(path, names) do
    repeated =
      names
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(fn {name, _count} ->
        Error.new(path, "#{inspect(name)} is listed more than once")
      end)

    Enum.flat_map(names, &secret_name_error(path, &1)) ++ repeated
  end

  defp secret_name_error(path, name) do
    case ForgeCore.Secret.validate_name(name) do
      :ok ->
        []

      {:error, :format} ->
        [
          Error.new(
            path,
            "#{inspect(name)} is not a secret's name: upper case letters, digits and _, " <>
              "starting with a letter"
          )
        ]

      {:error, :reserved} ->
        [Error.new(path, "#{inspect(name)} is reserved: a job's environment needs it for itself")]
    end
  end

  # -- commands -----------------------------------------------------------------------------

  # `docs/design/workflow-grammar-v1.md` § Validation: a command has a script under `.forge/` that
  # exists at the pinned commit, and what it produces is a name nobody else produces.
  defp commands(%Workflow{commands: commands} = workflow, exists) do
    commands
    |> Enum.sort_by(fn {name, _command} -> name end)
    |> Enum.flat_map(fn {name, command} ->
      path = Error.join("commands", name)

      List.flatten([
        if(valid_name?(name),
          do: [],
          else: [
            Error.new(
              path,
              "command name must be a single path segment: " <> Workflow.name_rule()
            )
          ]
        ),
        run_errors(Error.join(path, "run"), command.run, exists),
        command_produces_errors(workflow, name, Error.join(path, "produces"), command.produces),
        command_outputs_errors(workflow, name, Error.join(path, "produces"), command.outputs)
      ])
    end)
  end

  # Lexical, and it has to be: the check runs against a commit, not a filesystem, and the platform
  # reads the script out of git by this path rather than opening it. There is no symlink between
  # the check and the read for a lexical rule to be wrong about.
  defp run_errors(_path, nil, _exists), do: []

  defp run_errors(path, run, exists) do
    segments = String.split(run, "/")

    cond do
      not String.starts_with?(run, ".forge/") or Enum.any?(segments, &(&1 in ["", ".", ".."])) ->
        [Error.new(path, "must be a path under .forge/, like .forge/commands/build.sh")]

      is_function(exists, 1) and not exists.(run) ->
        [Error.new(path, "file #{inspect(run)} does not exist at the pinned commit")]

      true ->
        []
    end
  end

  defp command_outputs_errors(workflow, name, path, outputs) do
    Enum.flat_map(outputs, fn group ->
      group_name = Workflow.group_name(group)

      others =
        for {other, command} <- workflow.commands,
            other != name,
            group in command.outputs,
            do: other

      cond do
        not valid_name?(group_name) ->
          [Error.new(path, "#{inspect(group)} must name its files with a single path segment")]

        reserved = Workflow.document_name_error(group_name) ->
          [Error.new(path, reserved)]

        Workflow.producers(workflow, group) != [] or
            Workflow.producers(workflow, group_name) != [] ->
          [Error.new(path, "#{inspect(group)} is already produced by a state")]

        others != [] ->
          [
            Error.new(
              path,
              "#{inspect(group)} is also produced by #{Enum.join(Enum.sort(others), ", ")}"
            )
          ]

        true ->
          []
      end
    end)
  end

  defp command_produces_errors(_workflow, _name, _path, nil), do: []

  defp command_produces_errors(workflow, name, path, produces) do
    other_commands =
      for {other, command} <- workflow.commands,
          other != name,
          command.produces == produces,
          do: other

    cond do
      not valid_name?(produces) ->
        [Error.new(path, "artifact name must be a single path segment: " <> Workflow.name_rule())]

      produces in [
        Workflow.ticket_artifact(),
        Workflow.answers_artifact(),
        Workflow.changeset_artifact()
      ] ->
        [Error.new(path, "#{inspect(produces)} is reserved and cannot be produced")]

      reserved = Workflow.reserved_name_error(produces) ->
        [Error.new(path, reserved)]

      Workflow.producers(workflow, produces) != [] ->
        [Error.new(path, "#{inspect(produces)} is already produced by a state")]

      other_commands != [] ->
        [
          Error.new(
            path,
            "#{inspect(produces)} is also produced by #{Enum.join(Enum.sort(other_commands), ", ")}"
          )
        ]

      true ->
        []
    end
  end

  # Every command a state invokes or lets its agent invoke is one the workflow declares.
  defp invocations(%Workflow{states: states, commands: commands}) do
    states
    |> Enum.sort_by(fn {name, _state} -> name end)
    |> Enum.flat_map(fn {name, state} ->
      path = Error.join("states", name)

      invoked =
        state.invoke
        |> Enum.with_index()
        |> Enum.reject(fn {%{command: command}, _index} -> Map.has_key?(commands, command) end)
        |> Enum.map(fn {%{command: command}, index} ->
          Error.new(
            Error.join(Error.join(path, "invoke"), index),
            "#{inspect(command)} is not a declared command"
          )
        end)

      granted =
        state.may_invoke
        |> Map.keys()
        |> Enum.sort()
        |> Enum.reject(&Map.has_key?(commands, &1))
        |> Enum.map(
          &Error.new(Error.join(Error.join(path, "may_invoke"), &1), "is not a declared command")
        )

      invoked ++ granted
    end)
  end

  defp outcome_declarations(%Workflow{states: states}) do
    Enum.flat_map(states, fn {name, state} ->
      outcome_declaration(Error.join("states", name), state)
    end)
  end

  defp outcome_declaration(_path, %State{outcomes: nil}), do: []

  defp outcome_declaration(path, %State{outcomes: declared} = state) do
    path = Error.join(path, "outcomes")
    engine = Enum.filter(declared, &(&1 in Workflow.engine_outcomes()))
    conflict = Enum.filter(declared, &(&1 == Workflow.merge_conflict_outcome()))
    duplicates = declared -- Enum.uniq(declared)

    document = State.outcome_document(state)
    needs_document = declared != [Workflow.default_outcome()] and document == nil

    # **And a document that was written.** An absent optional outcome document is `done` and can
    # be nothing else — there is no front matter to choose with — so a state that declares a
    # choice and excuses the document the choice is made in has given itself a way to take the
    # `done` edge by writing nothing. Worse where `done` is not among the outcomes: the job
    # converges on an outcome no transition can match, and the ticket sticks behind a job that
    # succeeded. Beside the rule above because it is the same rule: an outcome other than `done`
    # is chosen in a document, so there has to be one, and it has to be written.
    unwritten_document =
      declared != [Workflow.default_outcome()] and document != nil and
        State.optional?(state, document)

    # **And not the one document specified to carry no front matter.** `commit-message` is a
    # plain git message — the prompts ask for one and the merge writes it verbatim — so a state
    # whose outcome document is that one has declared a choice it can never make: every job would
    # read `done` out of a message with no front matter, and the state's other edges would be
    # dead. `State.outcome_document/1` is the *first* document in `produces`, so this is a
    # question of order, which is why `.forge/common.yml` keeps `presentation.md!` ahead of it.
    message_document =
      declared != [Workflow.default_outcome()] and
        document == Workflow.commit_message_artifact()

    List.flatten([
      if(declared == [], do: Error.new(path, "must not be empty"), else: []),
      Enum.map(
        engine,
        &Error.new(path, "#{inspect(&1)} is an engine outcome and cannot be declared")
      ),
      conflict |> Enum.uniq() |> Enum.map(&Error.new(path, merge_conflict_reserved(&1))),
      Enum.map(
        Enum.uniq(duplicates),
        &Error.new(path, "#{inspect(&1)} is declared more than once")
      ),
      if(needs_document,
        do: Error.new(path, "declaring outcomes other than done requires a document in produces"),
        else: []
      ),
      if(unwritten_document,
        do:
          Error.new(
            path,
            "declaring outcomes other than done requires the document that carries the " <>
              "outcome: #{inspect(document)} is optional, and an outcome nobody wrote is done"
          ),
        else: []
      ),
      if(message_document,
        do:
          Error.new(
            path,
            "declaring outcomes other than done requires a document that can carry one: " <>
              "#{Workflow.commit_message_artifact()} is a plain git message with no front " <>
              "matter, and is first in produces"
          ),
        else: []
      )
    ])
  end

  defp transitions(%Workflow{transitions: transitions} = workflow) do
    indexed = Enum.with_index(transitions)

    per_transition =
      Enum.flat_map(indexed, fn {transition, index} ->
        transition_errors(workflow, Error.join("transitions", index), transition)
      end)

    per_transition ++ duplicate_outcomes(workflow, indexed)
  end

  defp transition_errors(workflow, path, %Transition{} = transition) do
    from = Workflow.state(workflow, transition.from)
    to = Workflow.state(workflow, transition.to)

    List.flatten([
      if(from == nil,
        do:
          Error.new(
            Error.join(path, "from"),
            "names an unknown state #{inspect(transition.from)}"
          ),
        else: []
      ),
      if(to == nil,
        do: Error.new(Error.join(path, "to"), "names an unknown state #{inspect(transition.to)}"),
        else: []
      ),
      if(from, do: when_errors(workflow, path, from, transition), else: []),
      if(from, do: approve_errors(workflow, path, from, transition), else: [])
    ])
  end

  defp when_errors(workflow, path, %State{} = from, %Transition{} = transition) do
    if State.human?(from),
      do: human_when(path, transition),
      else: runs_when(workflow, path, from, transition)
  end

  defp human_when(path, %Transition{when: outcome}) when outcome != nil,
    do: [Error.new(Error.join(path, "when"), "not allowed on a transition from a human state")]

  defp human_when(_path, _transition), do: []

  defp runs_when(workflow, path, %State{name: name}, %Transition{} = transition) do
    outcome = Transition.outcome(transition)

    if outcome in Workflow.outcomes(workflow, name) do
      []
    else
      [
        Error.new(
          Error.join(path, "when"),
          "#{inspect(outcome)} is not an outcome of state #{inspect(name)}"
        )
      ]
    end
  end

  defp approve_errors(workflow, path, %State{name: from}, %Transition{approve: approve}) do
    allowed = MapSet.put(ancestors(workflow, from), from)

    approve
    |> Enum.with_index()
    |> Enum.flat_map(fn {artifact, index} ->
      at = Error.join(Error.join(path, "approve"), index)

      cond do
        Workflow.group?(artifact) ->
          [Error.new(at, "a group of files cannot be approved")]

        # The operator reads it above the control that merges and confirms; no surface offers to
        # approve or edit it (`docs/design/ui.md` § Changes), and a transition pinning it would
        # draw a second element under the id the card already draws the message's block with.
        artifact == Workflow.commit_message_artifact() ->
          [
            Error.new(
              at,
              "#{Workflow.commit_message_artifact()} is what the merge commit says and is read, " <>
                "not approved"
            )
          ]

        presents?(workflow, artifact) ->
          [Error.new(at, "a presentation carries no approval")]

        Enum.any?(Workflow.producers(workflow, artifact), &MapSet.member?(allowed, &1)) ->
          []

        true ->
          [
            Error.new(
              at,
              "#{inspect(artifact)} is not produced by #{inspect(from)} or a state before it"
            )
          ]
      end
    end)
  end

  defp duplicate_outcomes(workflow, indexed) do
    indexed
    |> Enum.filter(fn {transition, _index} -> job_state?(workflow, transition.from) end)
    |> Enum.group_by(fn {transition, _index} ->
      {transition.from, Transition.outcome(transition)}
    end)
    |> Enum.filter(fn {_key, group} -> length(group) > 1 end)
    |> Enum.sort()
    |> Enum.flat_map(fn {{from, outcome}, group} ->
      Enum.map(group, fn {_transition, index} ->
        Error.new(
          Error.join("transitions", index),
          "more than one transition from #{inspect(from)} on #{inspect(outcome)}"
        )
      end)
    end)
  end

  defp job_state?(workflow, name) do
    case Workflow.state(workflow, name) do
      %State{} = state -> State.runs?(state)
      nil -> false
    end
  end

  # Skipped when initial is unknown: that is already one error, not one per state.
  defp reachability(%Workflow{initial: initial, states: states} = workflow)
       when is_map_key(states, initial) do
    # Along `on_conflict` too: an integrating state is reached by nothing else.
    reachable = walk(workflow, [initial], MapSet.new(), &Workflow.edges_from(&1, &2), & &1.to)

    states
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(reachable, &1))
    |> Enum.sort()
    |> Enum.map(&Error.new(Error.join("states", &1), "is not reachable from initial"))
  end

  defp reachability(%Workflow{}), do: []

  defp ancestors(workflow, name) do
    walk(workflow, [name], MapSet.new(), &transitions_to(&1, &2), & &1.from)
  end

  # Every edge, `on_conflict` included: what an integrating state reads was written before the
  # merge it was sent from was tried.
  defp transitions_to(%Workflow{} = workflow, name),
    do: workflow |> Workflow.edges() |> Enum.filter(&(&1.to == name))

  # Generic graph walk over transitions; `edges` lists a node's edges, `next` picks the neighbour.
  defp walk(_workflow, [], seen, _edges, _next), do: seen

  defp walk(workflow, [node | rest], seen, edges, next) do
    if MapSet.member?(seen, node) do
      walk(workflow, rest, seen, edges, next)
    else
      neighbours = workflow |> edges.(node) |> Enum.map(next)
      walk(workflow, neighbours ++ rest, MapSet.put(seen, node), edges, next)
    end
  end

  defp prompts(_workflow, nil), do: []

  defp prompts(%Workflow{states: states}, exists) when is_function(exists, 1) do
    states
    |> Enum.filter(fn {_name, state} -> State.job?(state) and not exists.(state.prompt) end)
    |> Enum.sort()
    |> Enum.map(fn {name, state} ->
      Error.new(
        Error.join(Error.join("states", name), "prompt"),
        "file #{inspect(state.prompt)} does not exist at the pinned commit"
      )
    end)
  end
end
