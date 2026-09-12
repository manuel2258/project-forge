defmodule ForgeCore.Workflow.Validator do
  @moduledoc """
  Semantic validation of a structurally sound workflow, one function per rule in
  `docs/design/workflow-grammar-v1.md`. Returns every violation found.
  """

  alias ForgeCore.Error
  alias ForgeCore.Workflow
  alias ForgeCore.Workflow.{State, Transition}

  # Artifact and state names are single path segments: they become file and directory
  # names in the job directory and must never escape it.
  @name_format ~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/

  @spec validate(Workflow.t(), keyword()) :: [Error.t()]
  def validate(%Workflow{} = workflow, opts \\ []) do
    [
      names(workflow),
      initial(workflow),
      state_shapes(workflow),
      artifact_names(workflow),
      outcome_declarations(workflow),
      transitions(workflow),
      reachability(workflow),
      prompts(workflow, Keyword.get(opts, :prompt_exists))
    ]
    |> List.flatten()
  end

  # -- rules --------------------------------------------------------------------------------

  defp names(%Workflow{states: states}) do
    Enum.flat_map(states, fn {name, state} ->
      path = Error.join("states", name)

      state_errors =
        if valid_name?(name),
          do: [],
          else: [
            Error.new(path, "state name must be a single path segment: letters, digits, . _ -")
          ]

      artifact_errors =
        (state.inputs ++ state.produces)
        |> Enum.reject(&(valid_name?(&1) or reserved_prefix?(&1)))
        |> Enum.uniq()
        |> Enum.map(
          &Error.new(
            path,
            "artifact name #{inspect(&1)} must be a single path segment: letters, digits, . _ -"
          )
        )

      state_errors ++ artifact_errors
    end)
  end

  defp valid_name?(name), do: Regex.match?(@name_format, name) and name not in [".", ".."]

  defp initial(%Workflow{initial: initial} = workflow) do
    case Workflow.state(workflow, initial) do
      %State{prompt: nil} -> [Error.new("initial", "must name a job state, not a human state")]
      %State{} -> []
      nil -> [Error.new("initial", "names an unknown state #{inspect(initial)}")]
    end
  end

  defp state_shapes(%Workflow{states: states}) do
    Enum.flat_map(states, fn {name, state} -> state_shape(Error.join("states", name), state) end)
  end

  defp state_shape(path, %State{prompt: nil} = human) do
    present =
      [
        env: human.env,
        inputs: human.inputs,
        produces: human.produces,
        outcomes: human.outcomes,
        budget: human.budget
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, []] end)
      |> Enum.map(fn {key, _value} -> to_string(key) end)

    Enum.map(
      present,
      &Error.new(Error.join(path, &1), "not allowed on a human state (no prompt)")
    )
  end

  defp state_shape(path, %State{budget: nil}),
    do: [Error.new(Error.join(path, "budget"), "is required on a job state")]

  defp state_shape(_path, %State{}), do: []

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

  defp input_error(workflow, producers_before, path, name, index) do
    producers = Workflow.producers(workflow, name)

    cond do
      reserved_prefix?(name) ->
        Error.new(
          Error.join(path, index),
          "prefix groups (name/*) are reserved for a later version"
        )

      name == Workflow.answers_artifact() ->
        Error.new(Error.join(path, index), "answers.md is platform-managed and never declared")

      name == Workflow.ticket_artifact() ->
        nil

      producers == [] ->
        Error.new(Error.join(path, index), "#{inspect(name)} is not produced by any state")

      not Enum.any?(producers, &MapSet.member?(producers_before, &1)) ->
        Error.new(
          Error.join(path, index),
          "#{inspect(name)} is not produced by any state that runs before this one"
        )

      true ->
        nil
    end
  end

  defp produce_error(workflow, path, name, index) do
    producers = Workflow.producers(workflow, name)

    cond do
      reserved_prefix?(name) ->
        Error.new(
          Error.join(path, index),
          "prefix groups (name/*) are reserved for a later version"
        )

      name in [Workflow.ticket_artifact(), Workflow.answers_artifact()] ->
        Error.new(Error.join(path, index), "#{inspect(name)} is reserved and cannot be produced")

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

  defp reserved_prefix?(name), do: String.ends_with?(name, "/*")

  defp outcome_declarations(%Workflow{states: states}) do
    Enum.flat_map(states, fn {name, state} ->
      outcome_declaration(Error.join("states", name), state)
    end)
  end

  defp outcome_declaration(_path, %State{outcomes: nil}), do: []

  defp outcome_declaration(path, %State{outcomes: declared} = state) do
    path = Error.join(path, "outcomes")
    engine = Enum.filter(declared, &(&1 in Workflow.engine_outcomes()))
    duplicates = declared -- Enum.uniq(declared)

    needs_document =
      declared != [Workflow.default_outcome()] and State.outcome_document(state) == nil

    List.flatten([
      if(declared == [], do: Error.new(path, "must not be empty"), else: []),
      Enum.map(
        engine,
        &Error.new(path, "#{inspect(&1)} is an engine outcome and cannot be declared")
      ),
      Enum.map(
        Enum.uniq(duplicates),
        &Error.new(path, "#{inspect(&1)} is declared more than once")
      ),
      if(needs_document,
        do: Error.new(path, "declaring outcomes other than done requires a document in produces"),
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

  defp when_errors(_workflow, path, %State{prompt: nil}, %Transition{when: outcome})
       when outcome != nil do
    [Error.new(Error.join(path, "when"), "not allowed on a transition from a human state")]
  end

  defp when_errors(_workflow, _path, %State{prompt: nil}, _transition), do: []

  defp when_errors(workflow, path, %State{name: name}, %Transition{} = transition) do
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
    |> Enum.reject(fn {artifact, _index} ->
      Enum.any?(Workflow.producers(workflow, artifact), &MapSet.member?(allowed, &1))
    end)
    |> Enum.map(fn {artifact, index} ->
      Error.new(
        Error.join(Error.join(path, "approve"), index),
        "#{inspect(artifact)} is not produced by #{inspect(from)} or a state before it"
      )
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
      %State{} = state -> State.job?(state)
      nil -> false
    end
  end

  # Skipped when initial is unknown: that is already one error, not one per state.
  defp reachability(%Workflow{initial: initial, states: states} = workflow)
       when is_map_key(states, initial) do
    reachable =
      walk(workflow, [initial], MapSet.new(), &Workflow.transitions_from(&1, &2), & &1.to)

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

  defp transitions_to(%Workflow{transitions: transitions}, name),
    do: Enum.filter(transitions, &(&1.to == name))

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
