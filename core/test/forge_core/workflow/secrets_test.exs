defmodule ForgeCore.Workflow.SecretsTest do
  @moduledoc """
  `secrets` in the grammar (`docs/design/secrets.md` § The workflow is the access list): a job
  state and a command name the project secrets their jobs are handed, and nothing else may.
  """

  use ExUnit.Case, async: true

  alias ForgeCore.Workflow.Parser

  @base """
  version: 1
  initial: implementing
  commands:
    publish:
      run: .forge/commands/publish.sh
      timeout: 10m
      secrets: [CARGO_REGISTRY_TOKEN]
  states:
    implementing:
      prompt: agents/implement.md
      produces: [changeset]
      may_invoke:
        publish: { max: 1 }
      budget: { turns: 10, cost: 1 }
      secrets: [STRIPE_TEST_KEY, SENTRY_TOKEN]
    publishing:
      invoke: [publish]
      exit: { 0: done, "*": failed }
    done: {}
  transitions:
    - { from: implementing, to: publishing }
    - { from: publishing, to: done }
    - { from: publishing, to: implementing, when: failed }
  limits:
    ticket_cost: 5
  """

  defp base_map do
    {:ok, map} = YamlElixir.read_from_string(@base)
    map
  end

  defp messages(map) do
    case Parser.from_map(map) do
      {:ok, _workflow} -> []
      {:error, errors} -> Enum.map(errors, &{&1.path, &1.message})
    end
  end

  test "a job state and a command name their secrets, and a state with none has none" do
    assert {:ok, workflow} = Parser.from_map(base_map())

    assert workflow.states["implementing"].secrets == ["STRIPE_TEST_KEY", "SENTRY_TOKEN"]
    assert workflow.commands["publish"].secrets == ["CARGO_REGISTRY_TOKEN"]
    assert workflow.states["publishing"].secrets == []
    assert workflow.states["done"].secrets == []
  end

  test "a name no secret could have is refused, for its format or because it is reserved" do
    map =
      base_map()
      |> put_in(["states", "implementing", "secrets"], ["stripe_key", "ANTHROPIC_BASE_URL"])
      |> put_in(["commands", "publish", "secrets"], ["LD_PRELOAD"])

    assert messages(map) == [
             {"commands.publish.secrets",
              ~s("LD_PRELOAD" is reserved: a job's environment needs it for itself)},
             {"states.implementing.secrets",
              ~s("ANTHROPIC_BASE_URL" is reserved: a job's environment needs it for itself)},
             {"states.implementing.secrets",
              ~s("stripe_key" is not a secret's name: upper case letters, digits and _, ) <>
                "starting with a letter"}
           ]
  end

  test "a name listed twice is refused" do
    map =
      put_in(base_map(), ["states", "implementing", "secrets"], ["SENTRY_TOKEN", "SENTRY_TOKEN"])

    assert messages(map) == [
             {"states.implementing.secrets", ~s("SENTRY_TOKEN" is listed more than once)}
           ]
  end

  # Each command brings its own, as it brings its own `env`; a human state runs nothing to hand
  # one to.
  test "a command state and a human state may not name secrets" do
    map =
      base_map()
      |> put_in(["states", "publishing", "secrets"], ["SENTRY_TOKEN"])
      |> put_in(["states", "done", "secrets"], ["SENTRY_TOKEN"])

    assert messages(map) == [
             {"states.done.secrets", "not allowed on a human state (no prompt)"},
             {"states.publishing.secrets", "not allowed on a command state"}
           ]
  end

  # A default is a secret in every job, which is what listing them per state exists to avoid.
  test "defaults may not name secrets" do
    map = put_in(base_map(), ["defaults"], %{"secrets" => ["SENTRY_TOKEN"]})
    assert [{"defaults.secrets", _unknown}] = messages(map)
  end

  # On a state and on a command alike: a string where a list belongs is not read as none.
  test "secrets is a list of names" do
    map = put_in(base_map(), ["states", "implementing", "secrets"], "SENTRY_TOKEN")

    assert messages(map) == [
             {"states.implementing.secrets", "must be a list of non-empty strings"}
           ]

    map = put_in(base_map(), ["commands", "publish", "secrets"], "CARGO_REGISTRY_TOKEN")

    assert messages(map) == [
             {"commands.publish.secrets", "must be a list of non-empty strings"}
           ]
  end
end
