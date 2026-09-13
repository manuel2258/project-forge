defmodule ForgeCore.Workflow.Parser do
  @moduledoc """
  Parses a workflow definition, as YAML text or an already decoded map, into a validated
  `ForgeCore.Workflow`. Every error found is returned, not only the first, so a project can
  fix its file in one round.

  Options:

    * `:prompt_exists` - a function from a prompt path to boolean. When given, every job
      state's prompt is checked with it (normally against the pinned commit).
  """

  alias ForgeCore.Error
  alias ForgeCore.Workflow
  alias ForgeCore.Workflow.{Budget, Limits, State, Transition, Validator}

  @top_keys ~w(version initial states transitions limits)
  @state_keys ~w(prompt env inputs produces outcomes budget on_enter)
  @transition_keys ~w(from to when approve max)
  @budget_keys ~w(turns cost)
  @limit_keys ~w(ticket_cost)

  @type result :: {:ok, Workflow.t()} | {:error, [Error.t()]}

  @spec parse(String.t(), keyword()) :: result()
  def parse(yaml, opts \\ []) when is_binary(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, map} when is_map(map) -> from_map(map, opts)
      {:ok, _other} -> {:error, [Error.new("", "expected a mapping at the top level")]}
      {:error, %{message: message}} -> {:error, [Error.new("", "invalid YAML: #{message}")]}
    end
  end

  @spec parse!(String.t(), keyword()) :: Workflow.t()
  def parse!(yaml, opts \\ []) do
    case parse(yaml, opts) do
      {:ok, workflow} -> workflow
      {:error, errors} -> raise ArgumentError, "invalid workflow:\n" <> Error.format(errors)
    end
  end

  @doc "Builds and validates a workflow from a decoded YAML map (string keys)."
  @spec from_map(map(), keyword()) :: result()
  def from_map(map, opts \\ []) when is_map(map) do
    case build(map) do
      {workflow, []} -> validate(workflow, opts)
      {_workflow, errors} -> {:error, sort(errors)}
    end
  end

  defp validate(workflow, opts) do
    case Validator.validate(workflow, opts) do
      [] -> {:ok, normalise(workflow)}
      errors -> {:error, sort(errors)}
    end
  end

  # Fill in defaults that validation had to see as "absent".
  defp normalise(%Workflow{states: states} = workflow) do
    states =
      Map.new(states, fn
        {name, %State{prompt: nil} = human} ->
          {name, human}

        {name, %State{outcomes: nil} = job} ->
          {name, %{job | outcomes: [Workflow.default_outcome()]}}

        {name, job} ->
          {name, job}
      end)

    %{workflow | states: states}
  end

  defp sort(errors), do: Enum.sort_by(errors, &{&1.path, &1.message})

  # -- structure ----------------------------------------------------------------------------

  defp build(map) do
    {version, e1} = version(map)
    {initial, e2} = required_string(map, "initial", "")
    {states, e3} = states(map)
    {transitions, e4} = transitions(map)
    {limits, e5} = limits(map)

    workflow = %Workflow{
      version: version,
      initial: initial,
      states: states,
      transitions: transitions,
      limits: limits
    }

    {workflow, unknown_keys(map, @top_keys, "") ++ e1 ++ e2 ++ e3 ++ e4 ++ e5}
  end

  defp version(map) do
    case Map.get(map, "version") do
      1 -> {1, []}
      nil -> {nil, [Error.new("version", "is required")]}
      _ -> {nil, [Error.new("version", "must be 1")]}
    end
  end

  defp states(map) do
    case Map.get(map, "states") do
      states when is_map(states) and map_size(states) > 0 ->
        states
        |> Enum.map(fn {name, definition} -> state(to_string(name), definition) end)
        |> collect(%{}, fn state, acc -> Map.put(acc, state.name, state) end)

      _ ->
        {%{}, [Error.new("states", "must be a non-empty mapping of state names")]}
    end
  end

  defp state(name, definition) when is_map(definition) do
    path = Error.join("states", name)
    {prompt, e1} = optional_string(definition, "prompt", path)
    {env, e2} = optional_string(definition, "env", path)
    {inputs, e3} = string_list(definition, "inputs", path)
    {produces, e4} = string_list(definition, "produces", path)
    {outcomes, e5} = string_list(definition, "outcomes", path)
    {budget, e6} = budget(definition, path)
    {on_enter, e7} = on_enter(definition, path)

    state = %State{
      name: name,
      prompt: prompt,
      env: env,
      inputs: inputs || [],
      produces: produces || [],
      outcomes: outcomes,
      budget: budget,
      on_enter: on_enter
    }

    {state, unknown_keys(definition, @state_keys, path) ++ e1 ++ e2 ++ e3 ++ e4 ++ e5 ++ e6 ++ e7}
  end

  defp state(name, _definition) do
    {%State{name: name},
     [Error.new(Error.join("states", name), "must be a mapping ({} for a human state)")]}
  end

  # One action or a list of them. Unknown actions are named here rather than in the validator,
  # because the struct holds atoms and an unknown one has nowhere to go.
  defp on_enter(definition, path) do
    known = Enum.map(State.actions(), &Atom.to_string/1)
    action_path = Error.join(path, "on_enter")

    case Map.get(definition, "on_enter") do
      nil ->
        {[], []}

      value when is_binary(value) ->
        on_enter_actions([value], known, action_path)

      value when is_list(value) ->
        on_enter_actions(value, known, action_path)

      _other ->
        {[], [Error.new(action_path, "must be an action or a list of them")]}
    end
  end

  defp on_enter_actions(values, known, path) do
    case Enum.reject(values, &(is_binary(&1) and &1 in known)) do
      [] -> {Enum.map(values, &String.to_existing_atom/1), []}
      bad -> {[], Enum.map(bad, &Error.new(path, "unknown action #{inspect(&1)}"))}
    end
  end

  defp budget(definition, path) do
    budget_path = Error.join(path, "budget")

    case Map.get(definition, "budget") do
      nil ->
        {nil, []}

      budget when is_map(budget) ->
        {turns, e1} = positive_integer(budget, "turns", budget_path, required: true)
        {cost, e2} = non_negative_number(budget, "cost", budget_path, required: true)
        errors = unknown_keys(budget, @budget_keys, budget_path) ++ e1 ++ e2
        {if(errors == [], do: %Budget{turns: turns, cost: cost}), errors}

      _ ->
        {nil, [Error.new(budget_path, "must be a mapping with turns and cost")]}
    end
  end

  defp transitions(map) do
    case Map.get(map, "transitions") do
      transitions when is_list(transitions) ->
        transitions
        |> Enum.with_index()
        |> Enum.map(fn {definition, index} ->
          transition(definition, Error.join("transitions", index))
        end)
        |> collect([], fn transition, acc -> acc ++ [transition] end)

      _ ->
        {[], [Error.new("transitions", "must be a list")]}
    end
  end

  defp transition(definition, path) when is_map(definition) do
    {from, e1} = required_string(definition, "from", path)
    {to, e2} = required_string(definition, "to", path)
    {when_outcome, e3} = optional_string(definition, "when", path)
    {approve, e4} = string_list(definition, "approve", path)
    {max, e5} = positive_integer(definition, "max", path, required: false)

    transition = %Transition{
      from: from,
      to: to,
      when: when_outcome,
      approve: approve || [],
      max: max
    }

    {transition, unknown_keys(definition, @transition_keys, path) ++ e1 ++ e2 ++ e3 ++ e4 ++ e5}
  end

  defp transition(_definition, path) do
    {%Transition{from: nil, to: nil}, [Error.new(path, "must be a mapping")]}
  end

  defp limits(map) do
    case Map.get(map, "limits") do
      limits when is_map(limits) ->
        {ticket_cost, errors} =
          non_negative_number(limits, "ticket_cost", "limits", required: true)

        errors = unknown_keys(limits, @limit_keys, "limits") ++ errors
        {if(errors == [], do: %Limits{ticket_cost: ticket_cost}), errors}

      _ ->
        {nil, [Error.new("limits", "must be a mapping with ticket_cost")]}
    end
  end

  # -- field helpers ------------------------------------------------------------------------

  defp collect(results, initial, put) do
    Enum.reduce(results, {initial, []}, fn {value, errors}, {acc, acc_errors} ->
      {put.(value, acc), acc_errors ++ errors}
    end)
  end

  defp unknown_keys(map, allowed, path) do
    map
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 in allowed))
    |> Enum.sort()
    |> Enum.map(&Error.new(Error.join(path, &1), "unknown key"))
  end

  defp required_string(map, key, path) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {value, []}
      nil -> {nil, [Error.new(Error.join(path, key), "is required")]}
      _ -> {nil, [Error.new(Error.join(path, key), "must be a non-empty string")]}
    end
  end

  defp optional_string(map, key, path) do
    case Map.get(map, key) do
      nil -> {nil, []}
      value when is_binary(value) and value != "" -> {value, []}
      _ -> {nil, [Error.new(Error.join(path, key), "must be a non-empty string")]}
    end
  end

  defp string_list(map, key, path) do
    value = Map.get(map, key)

    cond do
      is_nil(value) -> {nil, []}
      is_list(value) and Enum.all?(value, &(is_binary(&1) and &1 != "")) -> {value, []}
      true -> {nil, [Error.new(Error.join(path, key), "must be a list of non-empty strings")]}
    end
  end

  defp positive_integer(map, key, path, required: required) do
    case Map.get(map, key) do
      value when is_integer(value) and value > 0 -> {value, []}
      nil when required -> {nil, [Error.new(Error.join(path, key), "is required")]}
      nil -> {nil, []}
      _ -> {nil, [Error.new(Error.join(path, key), "must be a positive integer")]}
    end
  end

  defp non_negative_number(map, key, path, required: required) do
    case Map.get(map, key) do
      value when is_number(value) and value >= 0 -> {value, []}
      nil when required -> {nil, [Error.new(Error.join(path, key), "is required")]}
      nil -> {nil, []}
      _ -> {nil, [Error.new(Error.join(path, key), "must be a non-negative number")]}
    end
  end
end
