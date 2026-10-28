defmodule ForgeCore.PromptTest do
  use ExUnit.Case, async: true

  import ForgeCore.Fixtures

  alias ForgeCore.Job.Spec
  alias ForgeCore.Prompt

  # A conversation's spec: no ticket, no state, no budget, no outcomes. Everything the workflow
  # fixture has and a chat does not, which is exactly what the chat prompt has to cope with.
  defp chat_spec(overrides \\ %{}) do
    Map.merge(
      %Spec{
        job_id: "chat-1",
        kind: :chat,
        prompt: "Tell me about this repository.",
        branch: "chat/2026-09-15-abc",
        commit: String.duplicate("b", 40),
        preamble_hash: "sha256:y"
      },
      overrides
    )
  end

  test "the preamble is the shipped file and has a stable hash" do
    assert String.starts_with?(Prompt.preamble(), "# You are one job in a ticket lifecycle")
    assert "sha256:" <> hex = Prompt.preamble_hash()
    assert String.length(hex) == 64
  end

  test "compose/2 layers preamble, state prompt and manifest" do
    prompt = Prompt.compose(spec(), "/var/forge/jobs/job-1")

    assert [preamble, project, manifest] = String.split(prompt, "\n---\n\n")
    assert String.starts_with?(preamble, "# You are one job")
    assert String.trim(project) == "# Project instructions for state `planning`\n\nWrite a plan."
    assert String.starts_with?(manifest, "# Job manifest")

    assert manifest =~ "- Ticket 7: Persist the high score table"

    assert manifest =~
             "- `refinement.md` version 2 -> `/var/forge/jobs/job-1/inputs/refinement.md`"

    assert manifest =~ "- `plan.md` -> `/var/forge/jobs/job-1/out/plan.md` (carries the outcome)"
    assert manifest =~ "- `changeset`: the diff of your commits on `ticket/7`; no file to write"
    assert manifest =~ "`done`, `plan_invalid`, or `did_not_converge`"
    assert manifest =~ "- Turns: 40\n- Cost: 2.0 USD"
  end

  # `docs/design/secrets.md` § Delivery: a job is told which variables it holds — by name, never
  # by value — and asked not to print them; one that holds none is told nothing about secrets.
  describe "secrets" do
    test "a job holding secrets is told their names and what not to do with them" do
      manifest = Prompt.manifest(%{spec() | secrets: ["STRIPE_TEST_KEY", "SENTRY_TOKEN"]}, "/j")

      assert manifest =~ "## Secrets in your environment"
      assert manifest =~ "`$STRIPE_TEST_KEY`, `$SENTRY_TOKEN` — set for your work by the project."
      assert manifest =~ "Do not print them, commit them"

      refute Prompt.manifest(spec(), "/j") =~ "Secrets"
    end

    test "a conversation holding secrets is told the same" do
      manifest = Prompt.chat_manifest(chat_spec(%{secrets: ["STRIPE_TEST_KEY"]}), "/j")
      assert manifest =~ "## Secrets in your environment"
      assert manifest =~ "`$STRIPE_TEST_KEY`"

      refute Prompt.chat_manifest(chat_spec(), "/j") =~ "Secrets"
    end

    # A spec stored before secrets existed — a job pending when the release goes out — has
    # neither key, and reads as holding none, not as a manifest that cannot be drawn.
    test "a spec from before secrets holds none" do
      map = spec() |> Spec.to_json() |> Jason.decode!() |> Map.drop(["secrets", "secrets_gone"])
      spec = Spec.from_map(map)

      assert spec.secrets == []
      assert spec.secrets_gone == []
      refute Prompt.manifest(spec, "/j") =~ "Secrets"
    end

    test "the names survive the spec's trip through JSON" do
      spec = %{spec() | secrets: ["STRIPE_TEST_KEY"], secrets_gone: ["OLD_KEY"]}

      assert {:ok, %Spec{secrets: ["STRIPE_TEST_KEY"], secrets_gone: ["OLD_KEY"]}} =
               spec |> Spec.to_json() |> Spec.from_json()
    end

    # A conversation reopened after a deletion resumes a session whose first manifest named the
    # secret; the continuation is what it reads now, and it says what holds and what is gone.
    test "a reopened conversation is told what it holds now, and what was deleted" do
      spec = chat_spec(%{secrets: ["STRIPE_TEST_KEY"], secrets_gone: ["OLD_KEY"]})
      continuation = Prompt.continuation(spec, "/j", "abc123")

      assert continuation =~ "## Secrets in your environment"
      assert continuation =~ "`$STRIPE_TEST_KEY` — set for your work by the project."

      assert continuation =~
               "`$OLD_KEY` — deleted by the project since this conversation was opened"

      # All of them gone is still said; none at all says nothing.
      gone = Prompt.continuation(chat_spec(%{secrets_gone: ["OLD_KEY"]}), "/j", "abc123")
      assert gone =~ "`$OLD_KEY` — deleted"
      refute gone =~ "set for your work"

      refute Prompt.continuation(chat_spec(), "/j", "abc123") =~ "Secrets"

      # A cold reopen reads the manifest, which says the same.
      assert Prompt.chat_manifest(spec, "/j") =~ "`$OLD_KEY` — deleted"
    end
  end

  # `docs/design/job-prompt.md` § Commands: a job is told what it may run and how to ask, and a
  # resumed one what came back — in the manifest, so a cold start knows too.
  describe "commands" do
    test "a job that may invoke is told what, how many remain, and how to ask" do
      spec = %{
        spec()
        | may_invoke: %{
            "test" => %{"max" => 20, "concurrent" => 4, "remaining" => 17},
            "build" => %{"max" => 40, "concurrent" => nil}
          }
      }

      manifest = Prompt.manifest(spec, "/j")

      assert manifest =~ "## Commands you may run"

      assert manifest =~
               "- `build`: 40 of 40 invocations left\n- `test`: 17 of 20 invocations left, at most 4 at once"

      assert manifest =~ "write `/j/invoke.json`"
      assert manifest =~ ~s([{"command": "build", "args": ["--release"]}, {"command": "test"}])
      assert manifest =~ "Your work is committed and pushed, the commands run against that commit"
    end

    # The commit a command runs at is the push the run makes on its way to parking — and only a
    # state that declares `changeset` makes one (`docs/design/commands.md` § The ensured commit).
    # Telling a `reviewing` agent its edits are in the tree the command sees would have it read
    # a build of code that was never there.
    test "a state that produces no changeset is told its commands run without its edits" do
      spec = %{spec() | produces: ["report.md"], may_invoke: %{"test" => %{"max" => 2}}}

      manifest = Prompt.manifest(spec, "/j")

      assert manifest =~ "`changeset` is not one of your outputs, so nothing of your tree is"
      assert manifest =~ "against `ticket/7` as this run found it, without your edits"
      refute manifest =~ "Your work is committed and pushed"
    end

    test "a group of files is told where its files go and what they are kept as" do
      manifest = Prompt.manifest(%{spec() | produces: ["plan.md", "shots/*"]}, "/j")

      assert manifest =~
               "- `shots/*` -> any number of files in `/j/out/shots/`, each kept as `shots/<file>`"
    end

    # The marker is the declaration, so the manifest must name the path the agent actually writes
    # and must not read as an ordinary document: nothing downstream consumes it, and the quoting
    # convention is the only thing the review page needs from the prose
    # (`docs/design/job-prompt.md` § Presentations).
    test "a presentation is named by its real path, and said to be read by no later job" do
      manifest = Prompt.manifest(%{spec() | produces: ["plan.md", "deck.md!"]}, "/j")

      assert manifest =~ "- `deck.md` -> `/j/out/deck.md`: a presentation."
      assert manifest =~ "read by no later job"
      assert manifest =~ "`path:42-58`"
      refute manifest =~ "deck.md!"
      refute manifest =~ "- `deck.md` -> `/j/out/deck.md`\n"
    end

    # An agent told nothing about `optional` assumes what a declared output has always meant, and
    # pads rather than finishing without one.
    test "an optional output is named as one, and a required one is not" do
      spec = %{spec() | produces: ["plan.md", "deck.md!"], optional: ["deck.md"]}
      manifest = Prompt.manifest(spec, "/j")

      assert manifest =~ "Optional: you may finish without writing it"
      assert manifest =~ "`deck.md` -> `/j/out/deck.md`: a presentation."

      [plan_line, deck_line] =
        manifest |> String.split("\n") |> Enum.filter(&String.contains?(&1, "/j/out/"))

      assert plan_line =~ "plan.md"
      refute plan_line =~ "Optional"
      assert deck_line =~ "Optional"
    end

    test "a required document says nothing about being optional" do
      refute Prompt.manifest(spec(), "/j") =~ "Optional"
    end

    test "a presentation says where the path is from, and that the page draws a few" do
      manifest = Prompt.manifest(%{spec() | produces: ["deck.md!"]}, "/j")

      assert manifest =~ "the path from the repository root"
      assert manifest =~ "A handful of quotes are drawn"
    end

    test "a presentation that is the only document says it carries the outcome" do
      manifest = Prompt.manifest(%{spec() | produces: ["deck.md!", "changeset"]}, "/j")

      assert manifest =~ "- `deck.md` -> `/j/out/deck.md` (carries the outcome): a presentation."
    end

    test "a job that may not invoke is not told the file exists" do
      manifest = Prompt.manifest(spec(), "/j")
      refute manifest =~ "invoke.json"
      refute manifest =~ "Commands you"
    end

    test "a resumed job is told what each command did, and where its log is" do
      results = [
        %{
          "command" => "build",
          "args" => ["--release", "a b"],
          "at" => String.duplicate("c", 40),
          "exit_status" => 0,
          "outcome" => "converged",
          "duration_ms" => 42_300,
          "log" => "1-build.log"
        },
        %{
          "command" => "test",
          "args" => [],
          "exit_status" => nil,
          "outcome" => "error",
          "log" => "2-test.log"
        },
        %{"command" => "bench", "args" => [], "outcome" => "cancelled"},
        %{"command" => "lint", "args" => [], "refused" => "this state may not run lint"}
      ]

      manifest = Prompt.manifest(%{spec() | command_results: results}, "/j")

      assert manifest =~
               "- `build` `[\"--release\",\"a b\"]` at `cccccccccccc`: exit 0 in 42s; log `/j/commands/1-build.log`"

      assert manifest =~
               "- `test`: no exit status — it outlived its timeout or could not be run; log `/j/commands/2-test.log`"

      assert manifest =~ "- `bench`: cancelled before it finished"
      assert manifest =~ "- `lint`: refused — this state may not run lint"
    end
  end

  # `docs/design/job-prompt.md` § Integrating the default branch: a job a conflict sent here is
  # told what conflicted, what landed meanwhile, and to merge rather than rebase.
  describe "an integrating job" do
    defp integrating(integration) do
      %{
        spec()
        | state: "integrating",
          entered: %{
            "from" => "review_ready",
            "outcome" => "merge_conflict",
            "by" => "person",
            "comment" => nil
          },
          integration: integration
      }
    end

    @head String.duplicate("e", 40)

    test "is told the head, the paths, what landed, and to merge" do
      manifest =
        Prompt.manifest(
          integrating(%{
            "default_branch" => "main",
            "head" => @head,
            "base" => String.duplicate("b", 40),
            "paths" => ["AppState.kt", "ui/HomeScreen.kt"],
            "changeset" => String.duplicate("c", 40),
            "merges" => [
              %{"sha" => String.duplicate("1", 40), "subject" => "Merge ticket/12: Settings"},
              %{"sha" => String.duplicate("2", 40), "subject" => "Merge ticket/10: Home"}
            ],
            "more" => 3
          }),
          "/j"
        )

      assert manifest =~ "## Integrating `main`"
      assert manifest =~ "`main` was at `eeeeeeeeeeee` when this run was assigned"
      assert manifest =~ "as `origin/main`, which may be a little newer: that is the one to merge"

      assert manifest =~
               "It conflicted in these paths when its changeset `cccccccccccc` was tried:\n\n" <>
                 "- `AppState.kt`\n- `ui/HomeScreen.kt`"

      assert manifest =~ "since this ticket's base `bbbbbbbbbbbb`, newest first"

      assert manifest =~
               "- `111111111111` Merge ticket/12: Settings\n" <>
                 "- `222222222222` Merge ticket/10: Home\n- and 3 more"

      assert manifest =~ "`git merge origin/main`"
      assert manifest =~ "**Do not rebase, and do not reset the branch.**"
      assert manifest =~ "keeps `origin/main` as its second parent"

      # After how it got here, and before what it reads.
      [arrival, rest] = String.split(manifest, "## Integrating `main`", parts: 2)
      assert arrival =~ "The ticket came from `review_ready` on `merge_conflict`"
      assert rest =~ "## Inputs (read-only)"
    end

    test "sent here by a person with nothing recorded, says so" do
      # Nothing landed since the base: the platform sends an empty list, and nothing is listed.
      manifest =
        Prompt.manifest(
          integrating(%{"default_branch" => "trunk", "merges" => [], "more" => 0}),
          "/j"
        )

      assert manifest =~ "The checkout has `trunk` as `origin/trunk`: that is the one to merge."
      assert manifest =~ "No conflict is recorded for this ticket: a person sent it here."
      refute manifest =~ "What has landed"
      refute manifest =~ "and 0 more"
      # A part with nothing to say leaves no gap where it would have been.
      [_before, section] = String.split(manifest, "## Integrating", parts: 2)
      [section, _after] = String.split(section, "## Inputs", parts: 2)
      refute section =~ "\n\n\n"
    end

    test "lists what landed without a count when there is no more" do
      manifest =
        Prompt.manifest(
          integrating(%{
            "default_branch" => "main",
            "paths" => ["a"],
            "merges" => [%{"sha" => @head, "subject" => "Merge ticket/3"}],
            "more" => 0
          }),
          "/j"
        )

      assert manifest =~ "What has landed on `main`, newest first"
      assert manifest =~ "It conflicted in these paths:\n\n- `a`"
      refute manifest =~ "more"

      # A count nobody sent is no count.
      without =
        Prompt.manifest(
          integrating(%{
            "default_branch" => "main",
            "merges" => [%{"sha" => @head, "subject" => "Merge ticket/3"}]
          }),
          "/j"
        )

      refute without =~ "more"
    end

    test "every other job is told nothing about it" do
      refute Prompt.manifest(spec(), "/j") =~ "Integrating"
    end

    test "survives the wire" do
      spec = integrating(%{"default_branch" => "main", "paths" => ["a"]})
      {:ok, decoded} = spec |> Spec.to_json() |> Spec.from_json()

      assert decoded.integration == %{"default_branch" => "main", "paths" => ["a"]}
    end
  end

  # A second review's first question is what changed since the first; the manifest says which
  # commit that one read, beside the changeset this one reads.
  describe "the changeset a previous attempt read" do
    defp with_changeset(version, previous) do
      input = %ForgeCore.Job.Spec.Input{name: "changeset", version: version, content: "diff"}
      %{spec() | attempt: 2, inputs: [input], previous_changeset: previous}
    end

    test "is named beside this one's, with the diff to run" do
      old = String.duplicate("a", 40)
      manifest = Prompt.manifest(with_changeset(String.duplicate("b", 40), old), "/j")

      assert manifest =~
               "\n  attempt 1 of this state read it at `aaaaaaaaaaaa`; `git diff #{old}` is what changed on the branch since"
    end

    test "says so when it is the same commit" do
      same = String.duplicate("c", 40)

      assert Prompt.manifest(with_changeset(same, same), "/j") =~
               "attempt 1 of this state read the same commit; nothing changed since"
    end

    test "says nothing on a first attempt" do
      refute Prompt.manifest(with_changeset("d", nil), "/j") =~ "of this state read"
    end
  end

  # `docs/design/capacity.md` § Spend caps: a lowered cost says what it was lowered from and by
  # what, and the ticket's allowance is named beside the job's own budget.
  describe "the budget" do
    test "names what the ticket has left" do
      budget = %{turns: 20, cost: 30, ticket_left: 96.2, ticket_limit: 140}
      manifest = Prompt.manifest(%{spec() | budget: budget}, "/j")

      assert manifest =~ "- Cost: 30 USD\n"
      assert manifest =~ "- The ticket: 96.20 of 140 USD left for every job still to run on it"
    end

    test "says what a lowered cost was lowered from, and by which cap" do
      for {by, left} <- [{"ticket", "what the ticket has left"}, {"day", "what the day has left"}] do
        budget = %{turns: 20, cost: 3.5, declared: 30, lowered_by: by}
        manifest = Prompt.manifest(%{spec() | budget: budget}, "/j")

        assert manifest =~ "- Cost: 3.5 USD — lowered from the state's 30 USD to #{left}"
      end
    end

    test "a budget stated alone says only itself" do
      manifest = Prompt.manifest(%{spec() | budget: %{turns: 20, cost: 30}}, "/j")

      assert manifest =~ "- Cost: 30 USD\n"
      refute manifest =~ "lowered"
      refute manifest =~ "The ticket:"
    end

    test "survives the wire with what the platform added" do
      budget = %{
        turns: 20,
        cost: 3.5,
        declared: 30,
        lowered_by: "ticket",
        ticket_left: 3.5,
        ticket_limit: 140
      }

      spec = %{spec() | budget: budget}

      assert {:ok, %{budget: ^budget}} =
               spec |> ForgeCore.Job.Spec.to_json() |> ForgeCore.Job.Spec.from_json()
    end
  end

  # `docs/design/job-prompt.md` § How the job arrived: a job sent back has to be told by what, and
  # a person's note on the way is the reason itself.
  describe "how the job arrived" do
    test "names the state, the outcome and who took it, with what they wrote" do
      manifest = Prompt.manifest(spec(), "/j")

      assert manifest =~
               "The ticket came from `refining` on `done`; a person took the transition."

      assert manifest =~ "They wrote:\n\n```text\nKeep the table local.\n```"
    end

    test "the engine's transition carries no note" do
      entered = %{"from" => "reviewing", "outcome" => "changes_requested", "by" => "engine"}
      manifest = Prompt.manifest(%{spec() | entered: entered}, "/j")

      assert manifest =~ "came from `reviewing` on `changes_requested`; the engine took"
      refute manifest =~ "They wrote"
    end

    # Out of a human state there is no job's outcome to name, and inventing the transition's
    # default `done` would say a job finished that never ran.
    test "a person's choice with no job behind it names no outcome" do
      entered = %{"from" => "human_testing", "outcome" => nil, "by" => "person"}

      assert Prompt.manifest(%{spec() | entered: entered}, "/j") =~
               "The ticket came from `human_testing`; a person took the transition."
    end

    test "the first state says so" do
      assert Prompt.manifest(%{spec() | entered: nil}, "/j") =~
               "This is the ticket's first state."
    end

    # A failed build sends the ticket to the one job that has to fix it; the outcome's name is not
    # the reason, the log is. Named with its path, as a resume's own results are.
    test "out of a command state, names what its commands said and where their logs are" do
      entered = %{"from" => "packaging", "outcome" => "build_failed", "by" => "engine"}

      results = [
        %{
          "command" => "build",
          "args" => [],
          "at" => String.duplicate("d", 40),
          "exit_status" => 1,
          "outcome" => "converged",
          "duration_ms" => 2_000,
          "log" => "entered-1-build.log"
        }
      ]

      manifest =
        Prompt.manifest(%{spec() | entered: entered, entered_commands: results}, "/j")

      assert manifest =~ "came from `packaging` on `build_failed`; the engine took"
      assert manifest =~ "What `packaging`'s commands said"

      assert manifest =~
               "- `build` at `dddddddddddd`: exit 1 in 2s; log `/j/commands/entered-1-build.log`"

      refute manifest =~ "Commands you ran"
      refute Prompt.manifest(%{spec() | entered: entered}, "/j") =~ "commands said"
    end

    test "a note is fenced past any backticks in it" do
      entered = %{spec().entered | "comment" => "run ```mix test``` first"}

      assert Prompt.manifest(%{spec() | entered: entered}, "/j") =~
               "````text\nrun ```mix test``` first\n````"
    end

    test "an optional input not written yet is named as such" do
      manifest = Prompt.manifest(spec(), "/j")

      assert manifest =~
               "- `implementation.md`: not written on this ticket yet; it may be on a later visit"

      refute Prompt.manifest(%{spec() | absent_inputs: []}, "/j") =~ "not written on this ticket"
    end
  end

  # Both affordances are files, and a file an agent is never told about is a file it never
  # opens. These are the four things it has to know: where to read, where to write, that a
  # proposal is a suggestion rather than a ticket, and that the format's only front matter is the
  # type it suggests — anything else the parser refuses, so an agent that guesses wrong loses the
  # proposal.
  # A process the kernel killed at the job's ceiling exits 137 and says nothing else, and an agent
  # that does not know that runs the same build again into the same wall. Both preambles name the
  # variable that holds the ceiling, since the preamble is one document for every job.
  describe "what the preambles say about memory" do
    test "both name the ceiling and what a SIGKILL most likely means" do
      for preamble <- [Prompt.preamble(), Prompt.chat_preamble()] do
        flat = String.replace(preamble, "\n", " ")

        assert flat =~ "$FORGE_MEMORY_MAX"
        assert flat =~ "SIGKILL"
        assert flat =~ "exit status 137"
        assert flat =~ "less parallelism"
      end
    end
  end

  # `docs/design/archive.md`: the folder is live, and an agent that does not know it is not pinned
  # cites "the plan" as if it were an input.
  describe "what the preambles say about the archive" do
    test "both name the folder, say it is live and not pinned, and what each failed read means" do
      for preamble <- [Prompt.preamble(), Prompt.chat_preamble()] do
        flat = String.replace(preamble, ~r/\s+/, " ")

        assert flat =~ "$FORGE_JOB/archive/"
        assert flat =~ "live, not pinned"
        assert flat =~ "cite a version"

        for errno <- [
              "Connection timed out",
              "No such file",
              "Permission denied",
              "Input/output error"
            ],
            do: assert(flat =~ errno)
      end

      assert ForgeCore.Workflow.archive_dir() == "archive"
    end
  end

  # A job is handed its ticket's type beside its number, and only when there is one.
  describe "the manifest's ticket type" do
    test "is named when the ticket has one, and absent when it does not" do
      typed = %{spec() | ticket: %{spec().ticket | ticket_type: "bug"}}
      assert Prompt.manifest(typed, "/j") =~ "- Type: `bug`\n- State:"

      refute Prompt.manifest(%{spec() | ticket: %{spec().ticket | ticket_type: nil}}, "/j") =~
               "Type:"
    end

    test "survives the spec's round trip, and a spec from before types has none" do
      typed = %{spec() | ticket: %{number: 7, title: "x", ticket_type: "bug"}}
      wire = typed |> ForgeCore.Job.Spec.to_json() |> Jason.decode!()
      assert ForgeCore.Job.Spec.from_map(wire).ticket.ticket_type == "bug"

      older = update_in(wire, ["ticket"], &Map.delete(&1, "ticket_type"))

      assert ForgeCore.Job.Spec.from_map(older).ticket == %{
               number: 7,
               title: "x",
               ticket_type: nil
             }
    end
  end

  describe "what the preamble says about proposing and reading" do
    test "a job is told where the other tickets are and what is not in them" do
      flat = Prompt.preamble() |> String.replace("\n", " ")

      assert flat =~ "$FORGE_JOB/tickets/"
      assert flat =~ "index.md"
      assert flat =~ "snapshot"
      assert flat =~ "body and nothing else"
    end

    test "a job is told how to propose, and that it is a suggestion" do
      flat = Prompt.preamble() |> String.replace("\n", " ")

      assert flat =~ "$FORGE_JOB/out/proposals/"
      assert flat =~ "No other front matter"
      assert flat =~ "`type: bug`"
      assert flat =~ "suggestion, not a ticket"
    end

    # The preamble tells a job that an undeclared file in `out/` is refused. `proposals/` is the
    # exception, so the rule has to name it — otherwise the preamble forbids in one paragraph what
    # it asks for in the next.
    test "the undeclared-output rule names the one directory it does not cover" do
      [rule] =
        Prompt.preamble()
        |> String.split("\n\n")
        |> Enum.filter(&(&1 =~ "An undeclared file"))

      assert rule =~ "proposals/"
    end

    # The examples are what an agent copies. Two refinements failed in production on question
    # blocks that were not YAML, and one project's own prompt showed the shape that failed. The
    # platform's examples are parsed by the platform's parser, as a job's and a chat's would be.
    test "the question blocks the preambles show are ones the parser accepts" do
      for {preamble, opts} <- [
            {Prompt.preamble(), []},
            {Prompt.chat_preamble(), [blocking: :always]}
          ] do
        [block] = Regex.run(~r/```question\n.*?\n```\n/s, preamble)
        assert {:ok, %{questions: [question]}} = ForgeCore.Document.parse(block, opts)
        assert question.key == "storage"
        assert Enum.all?(question.options, & &1.detail)
        assert ForgeCore.Document.Question.recommended(question)
      end
    end

    # What the parser refuses on length has to be what the agent was told, in both preambles: a
    # limit the agent never read is a correction round it could not have avoided.
    test "both preambles state the limits the parser enforces, and ask for plain words" do
      %{text: text, label: label, detail: detail} = ForgeCore.Document.Question.limits()

      stated =
        "`text` at most #{text} characters, `label` at most #{label}, `detail` at most #{detail}"

      for preamble <- [Prompt.preamble(), Prompt.chat_preamble()] do
        # List items wrap with an indent, so every run of whitespace is one space.
        flat = String.replace(preamble, ~r/\s+/, " ")

        assert flat =~ stated
        assert flat =~ "no words joined with hyphens"
        assert flat =~ "`recommended: true`"
      end
    end

    test "a job is told to quote question text, that it is resumed to fix a refused output, " <>
           "and what tools it has" do
      flat = Prompt.preamble() |> String.replace("\n", " ")

      assert flat =~ "Put `text`, `anchor`, `assumption`, `label` and `detail` in double quotes"
      assert flat =~ "you are told exactly what is wrong and resumed to fix it"
      assert flat =~ "`python3`"
      refute ForgeCore.Workflow.platform_overview() =~ "`python3`"
    end

    test "a conversation is told the same two things, in its own words" do
      preamble = Prompt.chat_preamble()
      # Wrapped prose, so the sentences are matched with the line breaks taken out. A test that
      # matched the raw text would pass or fail on where the paragraph happened to wrap.
      flat = String.replace(preamble, "\n", " ")

      assert preamble =~ "$FORGE_JOB/tickets/"
      assert preamble =~ "$FORGE_JOB/out/proposals/"
      assert flat =~ "No other front matter"
      assert flat =~ "`type: bug`"

      # It has a person in it, so a question belongs in the reply rather than in the file.
      assert flat =~ "ask it in your reply"
    end

    # The preamble said proposals were recorded "when the conversation ends". They are recorded
    # at the end of each turn — and the sentence argued against itself, because its own reason
    # was that there is no goodbye to save them for. Nothing checked the timing claim.
    test "a conversation is told when its proposals are recorded, and it is per turn" do
      flat = Prompt.chat_preamble() |> String.replace("\n", " ")

      assert flat =~ "recorded at the end of each turn"
      refute flat =~ "recorded when the conversation ends"
    end
  end

  # The whole of the chat path was unexercised: nothing called `chat_preamble/0`,
  # `chat_manifest/2` or `compose/2` on a chat spec. The module's own docstring spends nine lines
  # saying that handing a conversation the job preamble "was not economy; it was telling the
  # agent to be a job" — and restoring that bug is a one-word edit the suite could not see.
  describe "a conversation" do
    test "gets its own preamble, which is a different document from a job's" do
      assert String.starts_with?(Prompt.chat_preamble(), "# You are in a conversation")

      # The point of the pair. If `chat_preamble/0` ever returns `@preamble` again, this is what
      # says so — and the hashes must differ too, since a chat's spec records its own.
      refute Prompt.chat_preamble() == Prompt.preamble()
      refute Prompt.chat_preamble_hash() == Prompt.preamble_hash()
      assert "sha256:" <> hex = Prompt.chat_preamble_hash()
      assert String.length(hex) == 64
    end

    test "is never told it is one job in a ticket lifecycle" do
      prompt = Prompt.compose(chat_spec(), "/var/forge/jobs/chat-1")

      assert String.starts_with?(prompt, "# You are in a conversation")

      # The four things the job preamble says that a conversation has no version of. Asserting
      # the absence rather than the presence, because the failure being guarded is the job
      # preamble arriving whole.
      refute prompt =~ "# You are one job in a ticket lifecycle"
      refute prompt =~ "Allowed outcomes"
      refute prompt =~ "# Job manifest"
      refute prompt =~ "Budget"
    end

    test "is layered preamble, manifest and the person's words" do
      prompt = Prompt.compose(chat_spec(), "/var/forge/jobs/chat-1")

      assert [preamble, manifest, said] = String.split(prompt, "\n---\n\n")
      assert String.starts_with?(preamble, "# You are in a conversation")
      assert String.starts_with?(manifest, "# This is a conversation")
      assert String.trim(said) == "Tell me about this repository."
    end

    # There is no state to leave and no outcome to declare, so the manifest says what a chat
    # actually has: a branch whose commits are kept, and where it is.
    test "is told the branch its work is kept on, and where it is" do
      manifest = Prompt.chat_manifest(chat_spec(), "/var/forge/jobs/chat-1")

      # Unwrapped first: the sentence is hard-wrapped in the heredoc, and a test that pinned the
      # line break would fail the next time the paragraph was re-flowed rather than changed.
      unwrapped = String.replace(manifest, "\n", " ")
      assert unwrapped =~ "Work you commit on `chat/2026-09-15-abc` is kept and can be merged"

      assert manifest =~ "- Job directory: `/var/forge/jobs/chat-1`"
      assert manifest =~ "- Branch: `chat/2026-09-15-abc`"
    end

    # A chat started from a project rather than a ticket. It must not be told it is working a
    # ticket, and must not be pointed at a `history/` directory that was never written.
    test "about the repository as a whole is not given a ticket or a history" do
      manifest = Prompt.chat_manifest(chat_spec(), "/var/forge/jobs/chat-1")

      assert manifest =~ "- About the repository as a whole."
      refute manifest =~ "About ticket"
      refute manifest =~ "What already ran on this ticket"
      refute manifest =~ "/history"
    end

    # A chat started from a ticket gets both: which ticket it is about, and the transcripts of
    # every job that already ran on it.
    test "about a ticket is told which, and where the jobs that already ran are" do
      spec = chat_spec(%{ticket: %{number: 7, title: "Persist the high score table"}})
      manifest = Prompt.chat_manifest(spec, "/var/forge/jobs/chat-1")

      assert manifest =~ "- About ticket 7: Persist the high score table"
      assert manifest =~ "## What already ran on this ticket"
      assert manifest =~ "/var/forge/jobs/chat-1/history"
    end

    # `docs/design/conversations.md` § Taking a transition: a ticket chat is told what it may ask
    # the engine for, with each edge's `approve` list, and that the list is a snapshot.
    test "about a ticket is told the transitions it may ask for" do
      spec =
        chat_spec(%{
          ticket: %{number: 7, title: "Persist the high score table"},
          moving: %{
            "transitions" => [
              %{"to" => "planning", "approve" => ["refinement.md"]},
              %{"to" => "verifying", "approve" => []}
            ],
            "pending" => nil,
            "job_live" => false
          }
        })

      manifest = Prompt.chat_manifest(spec, "/var/forge/jobs/chat-1")
      flat = String.replace(manifest, "\n", " ")

      assert manifest =~ "## Moving the ticket"
      assert manifest =~ "`/var/forge/jobs/chat-1/transition.json`"
      assert manifest =~ "- `planning` — approves `refinement.md` on the way"
      assert manifest =~ "- `verifying`"
      assert flat =~ "as of when this conversation started"
      # Nothing is pending and no job is live, so neither is claimed.
      refute manifest =~ "already pending"
      refute manifest =~ "was running"
    end

    test "about a ticket with nothing to take says so plainly" do
      spec =
        chat_spec(%{
          ticket: %{number: 7, title: "Done"},
          moving: %{"transitions" => [], "pending" => nil, "job_live" => false}
        })

      manifest = Prompt.chat_manifest(spec, "/var/forge/jobs/chat-1")

      assert manifest =~ "## Moving the ticket"
      assert manifest =~ "No transition is declared out of the ticket's state"
    end

    test "about a ticket with a decision pending, or a live job, is told" do
      spec =
        chat_spec(%{
          ticket: %{number: 7, title: "Persist"},
          moving: %{
            "transitions" => [],
            "pending" => %{
              "to" => "planning",
              "outcome" => "done",
              "approve" => ["refinement.md"]
            },
            "job_live" => true
          }
        })

      flat = spec |> Prompt.chat_manifest("/var/forge/jobs/chat-1") |> String.replace("\n", " ")

      assert flat =~ "already pending on this ticket: moving to `planning` on `done`"
      assert flat =~ "approving `refinement.md`"
      assert flat =~ "A job of the ticket's state was running"
      assert flat =~ "cancels the ticket and restores it"
    end

    # A target two edges reach can never be asked for, because the request names no outcome. Said
    # so in the list rather than offered as though it could be taken — and said accurately: the
    # ticket page cannot take one either.
    test "about a ticket marks a target that cannot be asked for" do
      spec =
        chat_spec(%{
          ticket: %{number: 7, title: "Round and round"},
          moving: %{
            "transitions" => [
              %{"to" => "implementing", "approve" => [], "ambiguous" => true},
              %{"to" => "verifying", "approve" => [], "ambiguous" => false}
            ],
            "pending" => nil,
            "job_live" => false
          }
        })

      manifest = Prompt.chat_manifest(spec, "/var/forge/jobs/chat-1")
      flat = String.replace(manifest, "\n", " ")

      assert flat =~ "`implementing` — **cannot be asked for**"
      assert flat =~ "Nor can the ticket page"
      # The one that can be is still plainly offered.
      assert manifest =~ "- `verifying`"
    end

    # A pinning that no longer parses has nothing to offer, and an empty list would read as a
    # state with no way out — a different problem with a different answer.
    test "about a ticket whose workflow no longer parses says that instead" do
      spec =
        chat_spec(%{
          ticket: %{number: 7, title: "Stuck"},
          moving: %{
            "transitions" => [],
            "pending" => nil,
            "job_live" => false,
            "workflow_broken" => true
          }
        })

      manifest = Prompt.chat_manifest(spec, "/var/forge/jobs/chat-1")

      assert manifest =~ "pinned workflow no longer parses"
      assert manifest =~ "repin"
      refute manifest =~ "No transition is declared"
    end

    # A project chat has no ticket and nothing to transition, so it is not handed a section
    # describing a file it can never usefully write.
    test "about the repository as a whole is told nothing about moving a ticket" do
      spec =
        chat_spec(%{
          moving: %{
            "transitions" => [%{"to" => "planning", "approve" => []}],
            "pending" => nil,
            "job_live" => true
          }
        })

      refute Prompt.chat_manifest(spec, "/var/forge/jobs/chat-1") =~ "Moving the ticket"
    end

    # A reopened conversation is a new process, and the message at the end of its prompt is the
    # next thing the person said. Without this section the agent is handed a file it is never
    # told about and a message it takes for an opening, and it answers as though nothing had
    # been said — the failure `docs/design/conversations.md` § Lifetime is built against.
    test "that was reopened is pointed at what was said before, and told it is not the first" do
      spec = chat_spec(%{replay: "# The conversation so far\n", prompt: nil})
      manifest = Prompt.chat_manifest(spec, "/var/forge/jobs/chat-1")
      flat = String.replace(manifest, "\n", " ")

      assert manifest =~ "## This conversation was reopened"
      assert manifest =~ "`/var/forge/jobs/chat-1/conversation.md`"
      assert flat =~ "Read it before you reply"
      assert flat =~ "the next thing the person said — not the first"
    end

    # And a first start is not told about a file nobody wrote.
    test "that was never reopened is not pointed at a conversation file" do
      manifest = Prompt.chat_manifest(chat_spec(), "/var/forge/jobs/chat-1")

      refute manifest =~ "reopened"
      refute manifest =~ "conversation.md"
    end

    # Ending a conversation deletes an unmerged branch, and the agent is the one the person asks
    # about their work — so it is told, and can say so before rather than after.
    test "is told what ending the conversation does to its branch" do
      flat = Prompt.chat_preamble() |> String.replace("\n", " ")

      assert flat =~ "a branch they have not merged is deleted unless it would not merge cleanly"
    end

    # A file an agent is never told about is a file it never writes. What it is told has to match
    # what is recorded: where, which names are kept, and that each turn records it.
    test "is told where a document it means to keep goes, and which names are not its" do
      flat = Prompt.chat_preamble() |> String.replace("\n", " ")

      assert flat =~ "`$FORGE_JOB/out/`, one per document"
      assert flat =~ "recorded at the end of each turn as a version"
      assert flat =~ "The name is one path segment"

      for reserved <- ["`ticket`", "`answers.md`", "`changeset`", "`proposals`", "`proposal-`"] do
        assert flat =~ reserved
      end

      # It said there was nowhere for a document to go, which stopped being true.
      refute flat =~ "nowhere for those to go"
    end

    # Every reopen clears `out/`, resumed or cold, so the agent is told where what it
    # wrote before now is, and that writing it to `out/` again is what changes it.
    test "is told where what it wrote before a reopen is, and how to change it" do
      flat = Prompt.chat_preamble() |> String.replace(~r/\s+/, " ")

      assert flat =~ "otherwise the documents this conversation wrote itself"
      assert flat =~ "copy it from `inputs/` into `out/`"
    end

    # It said a ticket's next job reads what a chat wrote. A job reads the inputs its state
    # declares, pinned when the job was created — so a name no state produces reaches no job.
    test "is not told that the ticket's next job reads whatever it writes" do
      flat = Prompt.chat_preamble() |> String.replace(~r/\s+/, " ")

      refute flat =~ "which its next job reads"
      assert flat =~ "a name the workflow never produces reaches no job at all"
    end

    # What the platform does with a document is what the agent is told: a question block in one
    # is text, and a document a person is deciding about is refused until they have.
    test "is told a document asks nothing, and which of a ticket's it may not write" do
      flat = Prompt.chat_preamble() |> String.replace(~r/\s+/, " ")

      assert flat =~ "asks nobody anything"
      assert flat =~ "one holding the question a waiting job stopped on"
      assert flat =~ "one waiting for their approval"
    end

    test "is told in its preamble where a reopened conversation's past is kept" do
      assert Prompt.chat_preamble() =~ "$FORGE_JOB/conversation.md"
    end

    test "with no inputs says so rather than leaving the section blank" do
      assert Prompt.chat_manifest(chat_spec(), "/var/forge/jobs/chat-1") =~ "- none"
    end
  end

  # A run that resumes its harness session already holds the preamble and the state prompt. What
  # it lacks is what happened while it was stopped, which is what `continuation/3` says —
  # `docs/design/job-prompt.md` § The continuation prompt.
  describe "a continuation" do
    @answers "# Answers\n\nDecisions a person made on this ticket, oldest first.\n\n" <>
               "## backend\n\nQ: Local file or SQLite?\n\nA: sqlite\n"

    defp resumed_spec(answers \\ @answers) do
      spec = spec()

      %{
        spec
        | inputs: spec.inputs ++ [%Spec.Input{name: "answers.md", version: 3, content: answers}]
      }
    end

    # The whole saving. A continuation that carried the preamble or the state prompt would be
    # `compose/2` with a paragraph on top, and a resumed session would read its contract twice.
    test "is not the whole prompt again: no preamble and no state prompt" do
      prompt = Prompt.continuation(resumed_spec(), "/var/forge/jobs/job-1", "c0ffee")

      assert String.starts_with?(prompt, "# Continue this job")
      refute prompt =~ "# You are one job in a ticket lifecycle"
      refute prompt =~ "# Project instructions for state"
      refute prompt =~ "Write a plan."
    end

    # Asked of the Answers section and nothing else: the manifest below it lists the same input
    # with its version and path, so a whole-prompt match passed with both dropped from here.
    test "names the answers, verbatim, with the version and path they were pinned at" do
      prompt = Prompt.continuation(resumed_spec(), "/var/forge/jobs/job-1", "c0ffee")

      [_before, from_answers] = String.split(prompt, "## Answers\n", parts: 2)
      [section, _rest] = String.split(from_answers, "\n## Your branch", parts: 2)
      flat = String.replace(section, ~r/\s+/, " ")

      assert flat =~ "`answers.md` version 3"
      assert flat =~ "`/var/forge/jobs/job-1/inputs/answers.md`"
      assert section =~ "```markdown\n" <> String.trim(@answers) <> "\n```\n"
    end

    # A free-text answer is a person's words, and a person may quote a fenced block. A fence that
    # did not outgrow it would close early and leave the rest of the prompt inside a code block.
    test "fences the answers with more backticks than they contain" do
      quoted = @answers <> "\n## format\n\nQ: Which?\n\nA: like this:\n\n````\nx = 1\n````\n"
      prompt = Prompt.continuation(resumed_spec(quoted), "/var/forge/jobs/job-1", nil)

      assert prompt =~ "`````markdown\n# Answers"
      assert prompt =~ "x = 1\n````\n`````\n"
    end

    test "names the branch and the commit the worktree is at" do
      prompt = Prompt.continuation(resumed_spec(), "/var/forge/jobs/job-1", "c0ffee")

      assert prompt =~ "## Your branch\n\n`ticket/7`, at `c0ffee`, checked out"
    end

    test "says only the branch when the commit could not be read" do
      prompt = Prompt.continuation(resumed_spec(), "/var/forge/jobs/job-1", nil)

      assert prompt =~ "## Your branch\n\n`ticket/7`, checked out"
    end

    test "tells a state that kept a changeset that the files are the ones it left" do
      prompt = Prompt.continuation(resumed_spec(), "/var/forge/jobs/job-1", "c0ffee")

      assert prompt =~ "the files are what you left"
    end

    # A state that declares no `changeset` had its tree discarded rather than committed, and the
    # resume snapshots the template or the seed and resets to the branch head — so its files are
    # *not* the ones it left. This is the one thing the agent is about to act on.
    test "tells a state that kept none that the worktree is the branch, not its files" do
      spec = %{resumed_spec() | produces: ["report.md"]}

      prompt = Prompt.continuation(spec, "/var/forge/jobs/job-1", "c0ffee")

      assert prompt =~ "nothing of the earlier run's tree was kept"
      assert prompt =~ "the branch as it stands rather than the files you left"
      refute prompt =~ "the files are what you left"
    end

    # The manifest is whole and last, because it is what may have moved: the answers are now an
    # input, and the budget is the one this run was assigned.
    test "ends with the manifest as it stands, answers among the inputs" do
      spec = %{resumed_spec() | budget: %{turns: 40, cost: 0.75}}
      prompt = Prompt.continuation(spec, "/var/forge/jobs/job-1", "c0ffee")

      assert [_changes, manifest] = String.split(prompt, "\n---\n\n")
      assert manifest == Prompt.manifest(spec, "/var/forge/jobs/job-1")
      assert manifest =~ "- `answers.md` version 3 -> `/var/forge/jobs/job-1/inputs/answers.md`"
      assert manifest =~ "- Cost: 0.75 USD"
    end

    # No path resumes a session without an answer today — only a run that stopped to ask records
    # one — but this is handed a spec, not that history, and must not say a person answered when
    # the spec carries no answer.
    test "with no answers among the inputs says nothing about answers" do
      prompt = Prompt.continuation(spec(), "/var/forge/jobs/job-1", "c0ffee")

      refute prompt =~ "## Answers"
      refute prompt =~ "A person answered"
      assert prompt =~ "## Your branch"
    end

    # `docs/design/claude-code-events.md` § Resume: an attempt that came back resumes its
    # predecessor's session as a fork. It remembers writing its outputs, and must be told those
    # were the last attempt's.
    test "for a new attempt says whose session it is, and that the outputs are written again" do
      spec = %{resumed_spec() | attempt: 3}
      prompt = Prompt.continuation(spec, "/var/forge/jobs/job-1", "c0ffee", fork: true)

      assert String.starts_with?(prompt, "# A new attempt of `planning`")

      assert prompt =~
               "This is attempt 3 of `planning`, and the session you are in is attempt\n2's"

      assert prompt =~ "**Nothing you wrote last time counts for this attempt.**"
      refute prompt =~ "# Continue this job"

      # The rest is a resume's: the answers, the branch, the whole manifest last.
      assert prompt =~ "## Answers"
      assert prompt =~ "## Your branch"
      assert [_changes, manifest] = String.split(prompt, "\n---\n\n")
      assert manifest == Prompt.manifest(spec, "/var/forge/jobs/job-1")
    end

    # A `budget_exhausted` self-loop sends the state back to itself, so there is no "went on and
    # came back" to tell it about — and the one thing worth telling it is why a second budget
    # exists at all (`docs/design/claude-code-events.md` § Resume).
    test "for a new attempt after a budget stop says that, not that the ticket went on" do
      entered = %{"from" => "planning", "outcome" => "budget_exhausted", "by" => "engine"}
      spec = %{resumed_spec() | attempt: 2, entered: entered}
      prompt = Prompt.continuation(spec, "/var/forge/jobs/job-1", "c0ffee", fork: true)

      assert String.starts_with?(prompt, "# A new attempt of `planning`")
      assert prompt =~ "ran out of budget before it reached an outcome"
      assert prompt =~ "**reach a declared outcome inside it.**"
      refute prompt =~ "The ticket went on from here"

      # It is still a new attempt, so the outputs paragraph stands: what the stopped run wrote
      # was kept as a version of its own and is not in this attempt's `out/`.
      assert prompt =~ "**Nothing you wrote last time counts for this attempt.**"
    end

    # The same outcome out of *another* state is an ordinary way back: that state ran out of
    # budget and the workflow sent the ticket here, which did go on from here and come back.
    test "for a new attempt whose budget stop was another state's reads as coming back" do
      entered = %{"from" => "reviewing", "outcome" => "budget_exhausted", "by" => "engine"}
      spec = %{resumed_spec() | attempt: 2, entered: entered}
      prompt = Prompt.continuation(spec, "/var/forge/jobs/job-1", "c0ffee", fork: true)

      assert prompt =~ "The ticket went on from here and has come back"
      refute prompt =~ "ran out of budget"
    end

    # And the other half of the same rule: a self-loop that is *not* a budget stop. `dev.yml`
    # sends a state back into itself on `did_not_converge` too, so a same-state arrival alone
    # does not mean the budget ran out — and telling that attempt it did would name the wrong
    # thing to watch. Only the two together read as a budget stop.
    test "for a new attempt sent back to itself on another outcome reads as coming back" do
      entered = %{"from" => "planning", "outcome" => "did_not_converge", "by" => "engine"}
      spec = %{resumed_spec() | attempt: 2, entered: entered}
      prompt = Prompt.continuation(spec, "/var/forge/jobs/job-1", "c0ffee", fork: true)

      assert prompt =~ "The ticket went on from here and has come back"
      refute prompt =~ "ran out of budget"
    end

    test "for a resume of the same attempt says nothing of a new one" do
      prompt = Prompt.continuation(resumed_spec(), "/var/forge/jobs/job-1", "c0ffee", fork: false)

      assert String.starts_with?(prompt, "# Continue this job")
      refute prompt =~ "Nothing you wrote last time"
    end
  end

  # `docs/design/conversations.md` § Lifetime: a reopened conversation resumes its session, so
  # it is told only that it stopped and where its branch is — none of the replay a cold reopen
  # needs, which it would otherwise read and answer all over again.
  describe "a reopened conversation's continuation" do
    test "says it resumes, where the branch is, and ends with what the person said since" do
      spec = chat_spec(%{prompt: "Did the migration land?", replay: "# earlier\n"})
      prompt = Prompt.continuation(spec, "/var/forge/jobs/chat-1", "beef")

      assert String.starts_with?(prompt, "# This conversation was reopened")
      assert prompt =~ "`chat/2026-09-15-abc`, at `beef`"
      assert String.ends_with?(prompt, "---\n\nDid the migration land?\n")

      refute prompt =~ "conversation.md"
      refute prompt =~ Prompt.chat_preamble() |> String.split("\n") |> hd()
      refute prompt =~ "# This is a conversation"
    end

    test "with nothing said since, ends at the branch" do
      prompt = Prompt.continuation(chat_spec(%{prompt: "  "}), "/var/forge/jobs/chat-1", nil)

      refute prompt =~ "---"
      assert String.ends_with?(prompt, "`git log` says which.\n")
    end
  end
end
