defmodule ForgeCore.Workflow.ChatStepTest do
  @moduledoc """
  `chat: true` on a job state (`docs/design/workflow-grammar-v1.md` § Chat steps): what the
  parser reads, what the validator refuses by name, and what the manifest tells the agent.
  """

  use ExUnit.Case, async: true

  alias ForgeCore.Job.Spec
  alias ForgeCore.Prompt
  alias ForgeCore.Workflow.{Parser, State}

  @base """
  version: 1
  initial: refining
  commands:
    build: { run: .forge/commands/build.sh, timeout: 10m }
  states:
    refining:
      chat: true
      prompt: agents/refine.md
      inputs: [ticket]
      produces: [refinement.md]
      outcomes: [done, needs_more]
    planning:
      prompt: agents/plan.md
      budget: { turns: 5, cost: 1 }
    review_ready: {}
  transitions:
    - { from: refining, to: planning, approve: [refinement.md] }
    - { from: refining, to: review_ready, when: needs_more }
    - { from: planning, to: review_ready }
  limits: { ticket_cost: 5 }
  """

  defp base_map do
    {:ok, map} = YamlElixir.read_from_string(@base)
    map
  end

  defp with_step(changes) do
    map = base_map()
    put_in(map, ["states", "refining"], Map.merge(map["states"]["refining"], changes))
  end

  defp errors(map) do
    case Parser.from_map(map) do
      {:ok, _workflow} -> []
      {:error, errors} -> Enum.map(errors, &{&1.path, &1.message})
    end
  end

  defp refused(map, path) do
    errors(map) |> Enum.filter(fn {at, _} -> at == path end) |> Enum.map(&elem(&1, 1))
  end

  test "a chat step parses, needs no budget, and is a job state to everything else" do
    assert {:ok, workflow} = Parser.from_map(base_map())
    step = workflow.states["refining"]

    assert State.chat?(step)
    assert State.job?(step)
    refute State.chat?(workflow.states["planning"])
    refute State.chat?(workflow.states["review_ready"])
    assert step.budget == nil
  end

  test "a workflow that marks no chat step parses with chat false everywhere" do
    map = base_map()

    {:ok, workflow} =
      map
      |> update_in(["states", "refining"], &Map.delete(&1, "chat"))
      |> then(&put_in(&1, ["states", "refining", "budget"], %{"turns" => 3, "cost" => 1}))
      |> Parser.from_map()

    assert Enum.all?(workflow.states, fn {_name, state} -> state.chat == false end)
  end

  test "chat must be true or false" do
    assert [{"states.refining.chat", "must be true or false"}] =
             Enum.filter(errors(with_step(%{"chat" => "yes"})), &(elem(&1, 0) =~ "chat"))
  end

  test "a budget is refused on a chat step, by name, with the reason" do
    assert [message] =
             refused(
               with_step(%{"budget" => %{"turns" => 3, "cost" => 1}}),
               "states.refining.budget"
             )

    assert message =~ "no ceiling"
  end

  test "may_invoke is refused on a chat step" do
    assert [message] =
             refused(
               with_step(%{"may_invoke" => %{"build" => %{"max" => 1}}}),
               "states.refining.may_invoke"
             )

    assert message =~ "invokes no commands"
  end

  test "exit is refused on a chat step: the person chooses its outcome" do
    assert [message] =
             refused(with_step(%{"exit" => %{"0" => "done"}}), "states.refining.exit")

    assert message =~ "person chooses"
  end

  test "changeset and commit-message are refused in a chat step's produces, each by name" do
    assert [message] =
             refused(
               with_step(%{"produces" => ["refinement.md", "changeset"]}),
               "states.refining.produces[1]"
             )

    assert message =~ "own branch"

    assert [message] =
             refused(
               with_step(%{"produces" => ["refinement.md", "commit-message"]}),
               "states.refining.produces[1]"
             )

    assert message =~ "commit-message"
  end

  test "a group of files and a presentation are refused in a chat step's produces" do
    assert [message] =
             refused(
               with_step(%{"produces" => ["refinement.md", "out/*"]}),
               "states.refining.produces[1]"
             )

    assert message =~ "group of files"

    assert [message] =
             refused(
               with_step(%{"produces" => ["refinement.md", "deck.md!"]}),
               "states.refining.produces[1]"
             )

    assert message =~ "presentation"
  end

  test "the outcome document cannot be optional, another document can" do
    assert [message] =
             refused(with_step(%{"optional" => ["refinement.md"]}), "states.refining.optional")

    assert message =~ "cannot be optional"

    map = with_step(%{"produces" => ["refinement.md", "notes.md"], "optional" => ["notes.md"]})
    assert refused(map, "states.refining.optional") == []
  end

  test "chat is refused on a command state and on a human state" do
    map = base_map()

    command =
      put_in(map, ["states", "building"], %{
        "invoke" => ["build"],
        "exit" => %{"0" => "done", "*" => "failed"},
        "chat" => true
      })

    assert [message] = refused(command, "states.building.chat")
    assert message =~ "not allowed on a command state"

    human = put_in(map, ["states", "review_ready", "chat"], true)
    assert [message] = refused(human, "states.review_ready.chat")
    assert message =~ "not allowed on a human state"
  end

  test "every other rule still applies: an undeclared outcome on an edge, an approval nothing produced" do
    map =
      update_in(
        base_map(),
        ["transitions"],
        &Enum.map(&1, fn t ->
          if t["when"] == "needs_more", do: %{t | "when" => "bogus"}, else: t
        end)
      )

    assert Enum.any?(errors(map), fn {_path, message} -> message =~ "bogus" end)

    map =
      update_in(base_map(), ["transitions"], fn [first | rest] ->
        [Map.put(first, "approve", ["plan.md"]) | rest]
      end)

    assert errors(map) != []

    map =
      update_in(
        base_map(),
        ["states", "refining"],
        &(Map.put(&1, "outcomes", ["done", "needs_more"]) |> Map.put("produces", []))
      )

    assert errors(map) != []
  end

  test "chat arrives through a library's state template and through extends" do
    common = """
    states:
      refining:
        chat: true
        prompt: agents/refine.md
        produces: [refinement.md]
    """

    type = """
    version: 1
    import: [common.yml]
    initial: refining
    states:
      refining:
        extends: refining
        inputs: [ticket]
      review_ready: {}
    transitions:
      - { from: refining, to: review_ready }
    limits: { ticket_cost: 5 }
    """

    reader = fn path -> if path == "common.yml", do: {:ok, common}, else: :error end

    assert {:ok, workflow, _flat} = Parser.load(type, read_library: reader)
    assert State.chat?(workflow.states["refining"])
    assert workflow.states["refining"].budget == nil
  end

  describe "the manifest" do
    defp step_spec(overrides \\ %{}) do
      step = %{
        "state" => "refining",
        "visit" => 1,
        "inputs" => ["ticket"],
        "produces" => ["refinement.md"],
        "optional" => [],
        "outcomes" => [
          %{"outcome" => "done", "to" => "planning", "approve" => ["refinement.md"]},
          %{"outcome" => "needs_more", "to" => "review_ready", "approve" => []}
        ],
        "entered" => nil
      }

      struct!(
        Spec,
        Map.merge(
          %{
            job_id: "j",
            kind: :chat,
            branch: "chat/j",
            prompt: "Refine the ticket.",
            ticket: %{number: 7, title: "T", ticket_type: nil},
            step: step
          },
          overrides
        )
      )
    end

    test "names the documents, the outcomes and that the person alone ends the step" do
      manifest = Prompt.chat_manifest(step_spec(), "/j")

      assert manifest =~ "## This step"
      assert manifest =~ "`refinement.md` -> `/j/out/refinement.md`"
      assert manifest =~ "`done` -> `planning`, approving `refinement.md`"
      assert manifest =~ "`needs_more` -> `review_ready`"
      assert manifest =~ "The person alone chooses the outcome and ends the step"
      assert manifest =~ "ignored"
      refute manifest =~ "## Moving the ticket"
      refute manifest =~ "return to the step"
    end

    test "a conversation that is not a step has no such section" do
      refute Prompt.chat_manifest(step_spec(%{step: nil}), "/j") =~ "## This step"
    end

    test "a return visit says so and where it came from" do
      step = put_in(step_spec().step, ["visit"], 2)

      step =
        Map.put(step, "entered", %{
          "from" => "planning",
          "outcome" => "plan_invalid",
          "by" => "engine",
          "comment" => nil
        })

      manifest = Prompt.chat_manifest(step_spec(%{step: step}), "/j")

      assert manifest =~ "return to the step: visit 2"
      assert manifest =~ "planning"
    end

    test "the step survives a round trip through the spec's JSON, every field of it" do
      step =
        step_spec().step
        |> Map.merge(%{
          "visit" => 3,
          "prompt" => "Refine the ticket.",
          "optional" => ["notes.md"],
          "produces" => ["refinement.md", "notes.md"],
          "entered" => %{
            "from" => "planning",
            "outcome" => "plan_invalid",
            "by" => "engine",
            "comment" => "too big"
          }
        })

      {:ok, spec} = step_spec(%{step: step}) |> Spec.to_json() |> Spec.from_json()

      assert spec.step == step
      assert Spec.from_map(%{"job_id" => "j", "branch" => "b"}).step == nil
    end

    test "a step built with atom keys is read as the one with string keys" do
      step = %{
        state: "refining",
        prompt: "p",
        visit: 2,
        inputs: ["ticket"],
        produces: ["a.md"],
        optional: ["a.md"],
        outcomes: [%{outcome: "done", to: "next", approve: ["a.md"]}],
        entered: nil
      }

      spec = Spec.from_map(%{job_id: "j", branch: "b", step: step})

      assert spec.step == %{
               "state" => "refining",
               "prompt" => "p",
               "visit" => 2,
               "inputs" => ["ticket"],
               "produces" => ["a.md"],
               "optional" => ["a.md"],
               "outcomes" => [%{"outcome" => "done", "to" => "next", "approve" => ["a.md"]}],
               "entered" => nil
             }
    end

    test "the manifest draws the step's own instructions, inputs and optional documents" do
      step =
        step_spec().step
        |> Map.merge(%{
          "prompt" => "  Ask about the failing case first.  ",
          "produces" => ["refinement.md", "notes.md"],
          "optional" => ["notes.md"]
        })

      manifest = Prompt.chat_manifest(step_spec(%{step: step}), "/j")

      assert manifest =~ "### The step's instructions\n\nAsk about the failing case first.\n"
      assert manifest =~ "declared inputs, among the documents above: `ticket`."
      assert manifest =~ "`notes.md` -> `/j/out/notes.md`. Optional:"
      refute manifest =~ "`refinement.md` -> `/j/out/refinement.md`. Optional"
      assert manifest =~ "there is no\n`transition.json` for this step"
      assert manifest =~ "visit 1"
    end

    test "a step with no input or document says so" do
      step = Map.merge(step_spec().step, %{"inputs" => [], "produces" => []})
      manifest = Prompt.chat_manifest(step_spec(%{step: step}), "/j")

      assert manifest =~ "This step declares no document to write."
      refute manifest =~ "declared inputs"
    end
  end
end
