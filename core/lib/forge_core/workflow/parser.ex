defmodule ForgeCore.Workflow.Parser do
  @moduledoc """
  Parses a workflow definition, as YAML text or an already decoded map, into a validated
  `ForgeCore.Workflow`. Every error found is returned, not only the first, so a project can
  fix its file in one round.

  Options:

    * `:prompt_exists` - a function from a prompt path to boolean. When given, every job
      state's prompt is checked with it (normally against the pinned commit).
    * `:read_library` - a function from a path under `.forge/` to `{:ok, text}` or `:error`, at
      the same commit. What `import` is resolved with (`ForgeCore.Workflow.Imports`); without it,
      a definition that imports anything is refused.

  `load/2` is what admission calls: it returns the flattened definition beside the workflow,
  because that — with no `import` and no `extends` left in it — is what a ticket pins.
  `from_map/2` reads a pinned one back, and resolves nothing.
  """

  alias ForgeCore.Error
  alias ForgeCore.Workflow

  alias ForgeCore.Workflow.{
    Budget,
    Command,
    Defaults,
    Imports,
    Keys,
    Limits,
    Resources,
    State,
    Transition,
    Validator
  }

  @top_keys ~w(version description initial states transitions limits defaults commands)
  @state_keys ~w(prompt env model inputs produces optional outcomes budget on_enter on_conflict
                 resources invoke exit may_invoke secrets)
  @command_keys ~w(run env produces timeout resources secrets)
  @grant_keys ~w(max concurrent)
  @transition_keys ~w(from to when approve max)
  @budget_keys ~w(turns cost)
  @limit_keys ~w(ticket_cost)
  @defaults_keys ~w(resources)
  @resources_keys ~w(memory cpu)

  # Named here rather than left to `unknown_keys/3`, so the message says *why* the key is not
  # allowed. `disk` is the obvious third dimension and there is nothing to enforce it with yet
  # (`docs/design/commands.md` § Resources); "unknown key" would read as a typo.
  @reserved_resources_keys ~w(disk)

  @type result :: {:ok, Workflow.t()} | {:error, [Error.t()]}

  @spec parse(String.t(), keyword()) :: result()
  def parse(yaml, opts \\ []) when is_binary(yaml) do
    case load(yaml, opts) do
      {:ok, workflow, _flat} -> {:ok, workflow}
      {:error, errors} -> {:error, errors}
    end
  end

  @doc """
  Parses `yaml`, resolving its imports with `:read_library`, into the workflow and the flattened
  definition it was built from — the map a ticket pins. An error about a part a library supplied
  names that library.
  """
  @spec load(String.t(), keyword()) :: {:ok, Workflow.t(), map()} | {:error, [Error.t()]}
  def load(yaml, opts \\ []) when is_binary(yaml) do
    with {:ok, map} <- decode(yaml),
         {:ok, flat, origins} <- Imports.resolve(map, Keyword.get(opts, :read_library)) do
      case from_map(flat, opts) do
        {:ok, workflow} -> {:ok, workflow, flat}
        {:error, errors} -> {:error, Imports.attribute(errors, origins)}
      end
    end
  end

  defp decode(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, map} when is_map(map) -> no_complex_keys(map)
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
    with {:ok, map} <- no_complex_keys(map) do
      case build(map) do
        {workflow, []} -> validate(workflow, opts)
        {_workflow, errors} -> {:error, sort(errors)}
      end
    end
  end

  defp no_complex_keys(map) do
    case Keys.errors(map) do
      [] -> {:ok, map}
      errors -> {:error, sort(errors)}
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
    {defaults, e6} = defaults(map)
    {commands, e7} = commands(map)
    {description, e8} = optional_string(map, "description", "")

    workflow = %Workflow{
      version: version,
      description: description,
      initial: initial,
      states: states,
      transitions: transitions,
      limits: limits,
      defaults: defaults,
      commands: commands
    }

    {workflow, unknown_keys(map, @top_keys, "") ++ e1 ++ e2 ++ e3 ++ e4 ++ e5 ++ e6 ++ e7 ++ e8}
  end

  # `docs/design/workflow-grammar-v1.md` § Commands. A mapping of names, each a mapping of its own;
  # absent is no commands at all, which is every workflow written before they existed.
  defp commands(map) do
    case Map.get(map, "commands") do
      nil ->
        {%{}, []}

      commands when is_map(commands) ->
        commands
        |> Enum.map(fn {name, definition} -> command(to_string(name), definition) end)
        |> collect(%{}, fn command, acc -> Map.put(acc, command.name, command) end)

      _ ->
        {%{}, [Error.new("commands", "must be a mapping of command names")]}
    end
  end

  defp command(name, definition) when is_map(definition) do
    path = Error.join("commands", name)
    {run, e1} = required_string(definition, "run", path)
    {env, e2} = optional_string(definition, "env", path)
    {{produces, outputs}, e3} = command_produces(definition, path)
    {timeout_ms, e4} = duration(definition, "timeout", path)
    {resources, e5} = resources(definition, path)
    {secrets, e6} = string_list(definition, "secrets", path)

    command = %Command{
      name: name,
      run: run,
      env: env,
      produces: produces,
      outputs: outputs,
      timeout_ms: timeout_ms,
      resources: resources,
      secrets: secrets || []
    }

    {command, unknown_keys(definition, @command_keys, path) ++ e1 ++ e2 ++ e3 ++ e4 ++ e5 ++ e6}
  end

  defp command(name, _definition) do
    {%Command{name: name}, [Error.new(Error.join("commands", name), "must be a mapping")]}
  end

  # A name — the log — or a list of at most one name and any number of groups of files.
  defp command_produces(definition, path) do
    produces_path = Error.join(path, "produces")

    case Map.get(definition, "produces") do
      nil ->
        {{nil, []}, []}

      name when is_binary(name) and name != "" ->
        split_produces([name], produces_path)

      list when is_list(list) and list != [] ->
        if Enum.all?(list, &(is_binary(&1) and &1 != "")),
          do: split_produces(list, produces_path),
          else: {{nil, []}, [Error.new(produces_path, "must be a list of non-empty strings")]}

      _other ->
        {{nil, []},
         [Error.new(produces_path, "must be an artifact name, or a list of one and groups")]}
    end
  end

  defp split_produces(names, path) do
    case Enum.split_with(names, &Workflow.group?/1) do
      {groups, []} -> {{nil, groups}, []}
      {groups, [log]} -> {{log, groups}, []}
      {_groups, _many} -> {{nil, []}, [Error.new(path, "names at most one log")]}
    end
  end

  defp duration(map, key, path) do
    case Map.get(map, key) do
      nil ->
        {nil, [Error.new(Error.join(path, key), "is required")]}

      value ->
        case Command.parse_duration(value) do
          {:ok, ms} ->
            {ms, []}

          :error ->
            {nil,
             [
               Error.new(
                 Error.join(path, key),
                 "must be a duration of at most a day: a whole number and one of s, m or h, like 20m"
               )
             ]}
        end
    end
  end

  defp defaults(map) do
    case Map.get(map, "defaults") do
      nil ->
        {nil, []}

      defaults when is_map(defaults) ->
        {resources, e1} = resources(defaults, "defaults")
        errors = unknown_keys(defaults, @defaults_keys, "defaults") ++ e1
        {if(errors == [], do: %Defaults{resources: resources}), errors}

      _ ->
        {nil, [Error.new("defaults", "must be a mapping")]}
    end
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
    {model, e8} = optional_string(definition, "model", path)
    {resources, e9} = resources(definition, path)
    {invoke, e10} = invoke(definition, path)
    {exit, e11} = exit_map(definition, path)
    {may_invoke, e12} = may_invoke(definition, path)
    {on_conflict, e13} = optional_string(definition, "on_conflict", path)
    {secrets, e14} = string_list(definition, "secrets", path)
    {optional, e15} = string_list(definition, "optional", path)

    state = %State{
      name: name,
      prompt: prompt,
      env: env,
      model: model,
      inputs: inputs || [],
      produces: produces || [],
      optional: optional || [],
      outcomes: outcomes,
      budget: budget,
      resources: resources,
      on_enter: on_enter,
      invoke: invoke,
      exit: exit,
      may_invoke: may_invoke,
      on_conflict: on_conflict,
      secrets: secrets || []
    }

    {state,
     unknown_keys(definition, @state_keys, path) ++
       e1 ++
       e2 ++
       e3 ++ e4 ++ e5 ++ e6 ++ e7 ++ e8 ++ e9 ++ e10 ++ e11 ++ e12 ++ e13 ++ e14 ++ e15}
  end

  defp state(name, _definition) do
    {%State{name: name},
     [Error.new(Error.join("states", name), "must be a mapping ({} for a human state)")]}
  end

  # Each entry is a command's name, or a list whose head is the name and whose tail is the argument
  # vector. A whole number in the tail is taken as its digits — `[test, --jobs, 4]` is what anyone
  # writes — and anything else that is not a string is refused rather than guessed at, because the
  # vector reaches `exec` exactly as written.
  defp invoke(definition, path) do
    invoke_path = Error.join(path, "invoke")

    case Map.get(definition, "invoke") do
      nil ->
        {[], []}

      entries when is_list(entries) and entries != [] ->
        entries
        |> Enum.with_index()
        |> Enum.map(fn {entry, index} -> invocation(entry, Error.join(invoke_path, index)) end)
        |> collect([], fn invocation, acc -> acc ++ [invocation] end)

      _ ->
        {[], [Error.new(invoke_path, "must be a non-empty list of commands")]}
    end
  end

  defp invocation(name, _path) when is_binary(name) and name != "",
    do: {%{command: name, args: []}, []}

  defp invocation([name | args], path) when is_binary(name) and name != "" do
    if Enum.all?(args, &(is_binary(&1) or is_integer(&1))),
      do: {%{command: name, args: Enum.map(args, &to_string/1)}, []},
      else: {nil, [Error.new(path, "arguments must be strings")]}
  end

  defp invocation(_entry, path),
    do:
      {nil, [Error.new(path, "must be a command name, or a list of the name and its arguments")]}

  # Keys are exit statuses or `"*"`; values are outcome names. A status may arrive as its digits:
  # the pinned definition is stored as JSON, where every key is a string, and `{0: done}` comes
  # back as `{"0": done}` — refusing that would make every command state's pinning unreadable
  # the first time it is read back.
  defp exit_map(definition, path) do
    exit_path = Error.join(path, "exit")

    case Map.get(definition, "exit") do
      nil ->
        {nil, []}

      exit when is_map(exit) and map_size(exit) > 0 ->
        entries =
          exit
          |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
          |> Enum.map(fn {key, value} -> exit_entry(key, value, exit_path) end)

        errors = Enum.flat_map(entries, &elem(&1, 1))
        {if(errors == [], do: Map.new(entries, &elem(&1, 0))), errors}

      _ ->
        {nil, [Error.new(exit_path, "must be a mapping of exit statuses to outcomes")]}
    end
  end

  defp exit_entry(key, value, path) do
    {status, key_errors} =
      case exit_key(key) do
        {:ok, status} -> {status, []}
        :error -> {key, [Error.new(path, "#{inspect(key)} is not an exit status or \"*\"")]}
      end

    value_errors =
      if is_binary(value) and value != "",
        do: [],
        else: [Error.new(Error.join(path, to_string(key)), "must name an outcome")]

    {{status, value}, key_errors ++ value_errors}
  end

  defp exit_key("*"), do: {:ok, "*"}
  defp exit_key(key) when is_integer(key) and key >= 0, do: {:ok, key}

  defp exit_key(key) when is_binary(key) do
    if Regex.match?(~r/\A[0-9]+\z/, key), do: {:ok, String.to_integer(key)}, else: :error
  end

  defp exit_key(_key), do: :error

  defp may_invoke(definition, path) do
    grants_path = Error.join(path, "may_invoke")

    case Map.get(definition, "may_invoke") do
      nil ->
        {%{}, []}

      grants when is_map(grants) ->
        grants
        |> Enum.map(fn {name, grant} -> grant(to_string(name), grant, grants_path) end)
        |> collect(%{}, fn {name, grant}, acc -> Map.put(acc, name, grant) end)

      _ ->
        {%{}, [Error.new(grants_path, "must be a mapping of command names")]}
    end
  end

  defp grant(name, grant, path) when is_map(grant) do
    path = Error.join(path, name)
    {max, e1} = positive_integer(grant, "max", path, required: true)
    {concurrent, e2} = positive_integer(grant, "concurrent", path, required: false)

    {{name, %{max: max, concurrent: concurrent}},
     unknown_keys(grant, @grant_keys, path) ++ e1 ++ e2}
  end

  defp grant(name, _grant, path),
    do: {{name, nil}, [Error.new(Error.join(path, name), "must be a mapping with max")]}

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

  # Both fields are optional, and that is what makes `defaults:` worth having: a state wanting
  # more memory than the default should not have to restate the core count to get it.
  # `ForgeCore.Workflow.resources/2` is where the chain is walked.
  defp resources(definition, path) do
    resources_path = Error.join(path, "resources")

    case Map.get(definition, "resources") do
      nil ->
        {nil, []}

      resources when is_map(resources) ->
        {memory, e1} = memory(resources, "memory", resources_path)
        {cpu, e2} = positive_integer(resources, "cpu", resources_path, required: false)

        errors =
          unknown_keys(resources, @resources_keys ++ @reserved_resources_keys, resources_path) ++
            reserved_keys(resources, @reserved_resources_keys, resources_path) ++ e1 ++ e2

        {if(errors == [], do: %Resources{memory: memory, cpu: cpu}), errors}

      _ ->
        {nil, [Error.new(resources_path, "must be a mapping of memory and cpu")]}
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

  defp reserved_keys(map, reserved, path) do
    map
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.filter(&(&1 in reserved))
    |> Enum.sort()
    |> Enum.map(&Error.new(Error.join(path, &1), "is reserved"))
  end

  # A memory ceiling: a byte size, and no smaller than the least a job can run in. Refused by name
  # below it, not as "must be a byte size" — `2` is one, and it is the one that took a machine
  # down (`docs/design/workflow-grammar-v1.md` § Resources).
  defp memory(map, key, path) do
    case Map.get(map, key) do
      nil -> {nil, []}
      value -> value |> Resources.parse_bytes() |> ceiling(Error.join(path, key))
    end
  end

  defp ceiling({:ok, bytes}, path) do
    if Resources.enough_memory?(bytes),
      do: {bytes, []},
      else: {nil, [Error.new(path, Resources.too_little_memory())]}
  end

  # Named rather than lumped in with "must be a byte size": `4GB` is what somebody who meant
  # `4GiB` writes, and the two differ by enough to matter to a memory ceiling.
  defp ceiling({:error, {:decimal_unit, binary}}, path),
    do: {nil, [Error.new(path, "must use a binary unit; did you mean #{binary}?")]}

  defp ceiling(:error, path) do
    units = Enum.join(Resources.units(), ", ")
    {nil, [Error.new(path, "must be a positive number of bytes or a size in #{units}")]}
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
