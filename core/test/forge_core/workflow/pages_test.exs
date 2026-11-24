defmodule ForgeCore.Workflow.PagesTest do
  @moduledoc """
  `name@` in `produces` and `opens` on a human state (`docs/design/pages.md`,
  `docs/design/workflow-grammar-v1.md` § Semantics and § Validation): what the parser reads, what
  the validator refuses by name, and what each helper says about the marker.
  """

  use ExUnit.Case, async: true

  alias ForgeCore.Job.Outcome
  alias ForgeCore.Job.Spec
  alias ForgeCore.Workflow
  alias ForgeCore.Workflow.{Parser, State}

  @base """
  version: 1
  initial: authoring
  commands:
    build: { run: .forge/commands/build.sh, timeout: 10m, produces: [build.log, "bundle/*"] }
  states:
    authoring:
      prompt: agents/author.md
      produces: [form@, notes.md]
      outcomes: [done]
      budget: { turns: 5, tokens: 200k }
    filling_in:
      opens: form
    importing:
      prompt: agents/import.md
      inputs: [notes.md]
      produces: [import.md]
      budget: { turns: 5, tokens: 200k }
    finished: {}
  transitions:
    - { from: authoring, to: filling_in }
    - { from: filling_in, to: importing }
    - { from: importing, to: finished }
  limits: { ticket_tokens: 1M }
  """

  defp base_map do
    {:ok, map} = YamlElixir.read_from_string(@base)
    map
  end

  defp with_state(name, changes) do
    map = base_map()
    put_in(map, ["states", name], Map.merge(map["states"][name] || %{}, changes))
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

  describe "the marker" do
    test "a page is told from a document, a group and a presentation" do
      assert Workflow.page?("form@")
      refute Workflow.page?("form")
      refute Workflow.page?("form/*")
      refute Workflow.page?("form!")
      refute Workflow.page?(nil)
      assert Workflow.page_name("form@") == "form"
      assert Workflow.page_names(["a.md", "form@", "pkg/*", "wizard@"]) == ["form", "wizard"]
    end

    test "a page is not a document, so it never carries the outcome" do
      refute Workflow.document?("form@")
      assert Workflow.produced_name("form@") == "form"
      assert Workflow.outcome_document(["form@", "plan.md"]) == "plan.md"
      assert Workflow.outcome_document(["form@"]) == nil
    end
  end

  describe "the grammar" do
    test "a state producing a page, and a human state opening it, parse" do
      assert {:ok, workflow} = Parser.from_map(base_map())
      assert workflow.states["authoring"].produces == ["form@", "notes.md"]
      assert workflow.states["filling_in"].opens == "form"
      assert workflow.states["authoring"].opens == nil
      assert State.outcome_document(workflow.states["authoring"]) == "notes.md"
    end

    test "opens must be a string" do
      assert [message] =
               refused(with_state("filling_in", %{"opens" => 3}), "states.filling_in.opens")

      assert message =~ "non-empty string"
    end

    test "a page may be optional, by its name" do
      map = with_state("authoring", %{"optional" => ["form"]})
      assert errors(map) == []
    end

    test "a page's name that no state produces cannot be optional" do
      assert [message] =
               refused(
                 with_state("authoring", %{"optional" => ["wizard"]}),
                 "states.authoring.optional[0]"
               )

      assert message =~ "not a document this state produces"
    end
  end

  describe "what the validator refuses" do
    test "opens on anything but a human state" do
      for state <- ["authoring", "importing"] do
        assert [message] =
                 refused(with_state(state, %{"opens" => "form"}), "states.#{state}.opens")

        assert message =~ "only a human state"
      end
    end

    test "opens a page no state produces" do
      assert [message] =
               refused(
                 with_state("filling_in", %{"opens" => "wizard"}),
                 "states.filling_in.opens"
               )

      assert message =~ "not a page that a state of this workflow produces"
    end

    test "opens a document is not opening a page" do
      assert [message] =
               refused(
                 with_state("filling_in", %{"opens" => "notes.md"}),
                 "states.filling_in.opens"
               )

      assert message =~ "not a page"
    end

    test "a human state, a command state and an update step produce no page" do
      assert [message] =
               refused(
                 with_state("filling_in", %{"produces" => ["form@"]}),
                 "states.filling_in.produces"
               )

      assert message =~ "pages"

      command_state = %{"invoke" => ["build"], "produces" => ["x@"]}

      assert refused(with_state("filling_in", command_state), "states.filling_in.produces") != []

      update = %{"on_enter" => "update", "produces" => ["x@"]}
      assert refused(with_state("finished", update), "states.finished.produces") != []
    end

    test "a command produces no page" do
      map = put_in(base_map(), ["commands", "build", "produces"], "report@")
      assert [message] = refused(map, "commands.build.produces")
      assert message =~ "produces no page"
    end

    test "a page and a document, group, presentation or command's output of one name" do
      for {entry, what} <- [
            {"form", "document"},
            {"form/*", "group of files"},
            {"form!", "presentation"}
          ] do
        map = with_state("importing", %{"produces" => ["import.md", entry]})
        messages = errors(map) |> Enum.map(&elem(&1, 1))

        assert Enum.any?(messages, &(&1 =~ "also produced as a" and &1 =~ what)),
               "#{entry}: #{inspect(messages)}"
      end

      map = put_in(base_map(), ["commands", "build", "produces"], ["form", "bundle/*"])
      assert Enum.any?(errors(map), fn {_path, message} -> message =~ "by command" end)

      map = put_in(base_map(), ["commands", "build", "produces"], ["build.log", "form/*"])

      assert Enum.any?(errors(map), fn {_path, message} ->
               message =~ "group of files by a command"
             end)
    end

    test "a page is one state's" do
      map = with_state("importing", %{"produces" => ["import.md", "form@"]})

      assert [message] = refused(map, "states.authoring.produces[0]")
      assert message =~ "more than one state"
    end

    test "a page is not an input and is not approved" do
      assert [message] =
               refused(
                 with_state("importing", %{"inputs" => ["form@"]}),
                 "states.importing.inputs[0]"
               )

      assert message =~ "page is not an input"

      map =
        Map.update!(base_map(), "transitions", fn [first | rest] ->
          [Map.put(first, "approve", ["form@"]) | rest]
        end)

      assert [message] = refused(map, "transitions[0].approve[0]")
      assert message =~ "page cannot be approved"
    end

    test "a page's name is held to an artifact's" do
      map = with_state("authoring", %{"produces" => ["bad name@", "notes.md"]})
      assert Enum.any?(errors(map), fn {_path, message} -> message =~ "single path segment" end)

      map = with_state("authoring", %{"produces" => ["changeset@", "notes.md"]})
      assert refused(map, "states.authoring.produces[0]") != []
    end
  end

  describe "a chat step" do
    defp chat_map(produces) do
      map = base_map()

      put_in(map, ["states", "authoring"], %{
        "chat" => true,
        "prompt" => "agents/author.md",
        "produces" => produces,
        "outcomes" => ["done"]
      })
    end

    test "may declare a page, where it may declare neither a group nor a presentation" do
      assert errors(chat_map(["notes.md", "form@"])) == []
      assert refused(chat_map(["notes.md", "pkg/*"]), "states.authoring.produces[1]") != []
      assert refused(chat_map(["notes.md", "deck.md!"]), "states.authoring.produces[1]") != []
    end

    test "may excuse a page as optional, as it may a document" do
      assert errors(
               put_in(chat_map(["notes.md", "form@"]), ["states", "authoring", "optional"], [
                 "form"
               ])
             ) ==
               []
    end
  end

  describe "the job's own contract" do
    defp spec(overrides \\ []) do
      struct!(
        %Spec{
          job_id: "job-1",
          state: "authoring",
          attempt: 1,
          prompt: "p",
          commit: String.duplicate("a", 40),
          branch: "ticket/1",
          ticket: %{number: 1, title: "t", ticket_type: nil},
          budget: %{turns: 5, tokens: 100},
          produces: ["notes.md", "form@", "pkg/*", "deck.md!", "changeset"],
          outcomes: ["done"]
        },
        overrides
      )
    end

    defp run(overrides) do
      Map.merge(
        %{
          killed: nil,
          exit_status: 0,
          result: %{subtype: "success", is_error: false, text: nil},
          documents: %{"notes.md" => ForgeCore.Document.parse!("---\noutcome: done\n---\nx")},
          invalid: %{},
          missing: [],
          undeclared: []
        },
        overrides
      )
    end

    test "a page is its own kind of output" do
      assert Spec.page_outputs(spec()) == ["form"]
      assert Spec.document_outputs(spec()) == ["notes.md", "deck.md"]
      assert Spec.group_outputs(spec()) == ["pkg"]
      assert Spec.presentation_outputs(spec()) == ["deck.md"]
      assert Spec.page_outputs(spec(produces: ["notes.md"])) == []
    end

    test "a page the job did not write is an error, unless it is optional" do
      assert {:finished, :error, nil, "missing outputs: form"} =
               Outcome.decide(spec(), run(%{missing: ["form"]}))

      assert {:finished, :converged, "done", _} =
               Outcome.decide(spec(optional: ["form"]), run(%{missing: ["form"]}))
    end
  end
end
